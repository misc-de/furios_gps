# What we found out

The README says what this does and how to run it. This file says *why*: what
was measured, on which device, and what the measurements mean - including the
one that argues against this project rather than for it.

Device: FuriPhone FLX1 (radon), FuriOS, `geoclue-2.0`
2.7.1-3+furios7+git20260623011505. GNSS through the hybris source
(`android.hardware.gnss-service.mediatek`), network location through BeaconDB.

---

## 1. The shipped state is not "off", it is "GeoIP"

`/etc/geoclue/geoclue.conf` as FuriOS installs it:

    [wifi]
    enable=false
    url=https://api.beacondb.net/v1/geolocate

A URL that is never used, under a key that is switched off. That reads like
somebody prepared the setting and left it for later, and the consequence is
written three lines above it in geoclue's own comment:

    # If this source and the static source below are both disabled a GeoIP-only
    # source will be used instead.

`[static-source] enable` is false as well. So the shipped phone has no network
location source except its own IP address. Nothing in the interface says this;
a person reading the settings screen sees location working.

## 2. Turning the Wi-Fi source on is not the fix

With `enable=true` the phone asks BeaconDB properly. The answer, when BeaconDB
does not recognise a single network in range, is not an absence:

    {"location": {...}, "accuracy": 25000.0, "fallback": "ipf"}

`ipf` is ichnaea's marker for *this came from the IP address, not from what you
sent me*. It is documented, it is in every such answer, and **geoclue does not
read it**. `gclue-web-source` takes `location` and `accuracy` and publishes
them. The accuracy is honest - 25 km - but an application that asks for a
position and gets one 25 km wide generally uses it, and on mobile data the
centre of that circle is the carrier's exit node rather than anywhere the phone
has been.

The timing is what makes it matter. The web source answers in a fraction of a
second; a GNSS fix takes seconds outdoors and may never arrive indoors. So the
IP position is not a fallback that fills in when GNSS fails - it is the first
answer, and for short-lived location requests it is the only one.

## 3. What was measured on 14 September 2026

Indoors, phone on Wi-Fi, mobile data also up.

**Networks in range: 50.** BeaconDB recognised none of them. In the hour
between boot and this being installed, geoclue made 25 Wi-Fi lookups of its own
accord and **every one of them came back an IP fallback** - not one real
position among them. (Those 25 went through the hand-rolled predecessor, which
applies the same rule; the count is geoclue's `Not Found` lines, which are what
a refusal looks like from its side.)

One deliberate probe (`gpsctl probe`, a query with an empty access-point list,
which is the query the filter is about):

    ok    the service answered with an IP fallback, and the proxy refused it
    furios-gps-proxy[47890]: rejected an IP fallback (radius 25000 m)

Counters after the probe and three lookups geoclue made on its own:

    asked: 4    located: 0    rejected: 4    wide: 0    not_found: 0

`located: 0` is the finding, not a fault. At this location BeaconDB has no
coverage at all, so the Wi-Fi source was never going to contribute a real
position either way. What it *was* contributing was a 25 km circle around a
point the phone had not been to.

With the filter in place, geoclue's log says:

    geoclue[47897]: Failed to query location: Query location SOUP error: Not Found

That line is the filter working. geoclue's web source reads a non-2xx as "this
source has nothing", which is exactly what should be said about an answer that
is really just the question echoed back.

## 4. The instrument, twice wrong, and what it says once it works

This section has been written three times and the first two were wrong. Both
errors are worth keeping, because they are the same error.

**First attempt.** `where-am-i` was asked for a position with the filter in
place and printed nothing, over 75 seconds and then five minutes more. Written
down as "the phone has no position". Wrong: run it in the shipped state, where
a position is there for the asking, and it prints nothing too. Ninety seconds,
both streams, exit 0. An instrument that gives the same answer whatever is in
front of it is not an instrument.

**Second attempt.** Going one level down, `GetClient` on the GeoClue2 Manager
was seen to hang until killed, and so was `CreateClient`, while property reads
on the same object answered at once. Written down as "geoclue never hands out
a client - a defect of its own". Also wrong, and this one was self-inflicted:
a geoclue demo agent had been started by hand a few minutes earlier and then
killed, and geoclue was blocking on authorisation from an agent that no longer
answered. With no agent running at all, `GetClient` returns immediately, three
times out of three.

So the phone was never broken in the way two consecutive write-ups claimed.
What `where-am-i` is really doing is still unexplained, and it does not matter:
it is not the tool.

**What works** is asking geoclue over its own interface on *one held
connection*. That is the part `gdbus` cannot do - each call is its own
connection, geoclue ties the client object to the connection that created it,
and the object is gone before the next call arrives:

    Error: org.freedesktop.DBus.Error.UnknownMethod:
    Object does not exist at path "/org/freedesktop/GeoClue2/Client/5"

Held open from one process (`tools/ask-geoclue.py`, Gio), it behaves:
`GetClient`, set `DesktopId`, set `RequestedAccuracyLevel` to 8, `Start`,
and wait for `LocationUpdated`.

**The measurement, at last.** Indoors, no sky view, filter in place, accuracy
level Exact requested: `Start: ok`, and **no position in 75 seconds**. That is
a real result from a client that really started.

It is not yet a *proof* about this project, because the instrument has not been
shown to report a position when there is one - and that is exactly the check
the first attempt skipped. The honest way to close it costs nothing: outdoors,
in this same state, GNSS should produce a fix and the same script should report
it. Until then the claim stands at this: with the filter in place, and
BeaconDB having no coverage here (§3), the phone gets no position indoors -
which is what the phone's owner is asking for, since the only position on offer
was the carrier's exit node.

## 5. Why the answer is filtered and not the question

Three other places could have held this fix, and each is worse.

**Patch geoclue** to read the `fallback` field. Correct, upstream, and gone at
the next package update - the sibling modem project exists mostly to keep
patches alive across updates, and that is a lot of machinery for one `if`.

**Point geoclue at a different service.** Every ichnaea-compatible service
answers IP fallbacks the same way; it is in the API, not in BeaconDB.

**Leave the Wi-Fi source off**, as shipped. That is the state this started
from, and it is the worst of the three: the GeoIP-only source is the same IP
position with no marker on it at all and no way to tell it apart.

A proxy on loopback needs no patch, survives every update of everything, and
can be taken out again by putting one URL back.

## 6. What it costs to run, and what happens when something breaks

Gone over deliberately, on the device, because a filter nobody notices is the
only kind worth having.

### Idle: two wakeups a second, for nothing

The proxy sits in `accept()` all day. Measured, it did not:

    voluntary context switches in 30 idle seconds:  60
    CPU ticks:                                       1

Two wakeups a second, for the uptime of a phone that never suspends. The cause
is not in this code but in what it did not say: `socketserver.serve_forever()`
polls its own shutdown flag every `poll_interval` seconds and the default is
0.5. Nothing here calls `shutdown()` - the service is stopped with a signal,
which does not wait for a poll - so the interval is now an hour:

    voluntary context switches in 30 idle seconds:   0
    CPU ticks:                                       0

RSS is 24 MB, which is python, and the process is one thread.

### A service that restarted for ever

`Restart=always` with `RestartSec=3`, and systemd's default limit of 5 starts
in 10 seconds. Five starts three seconds apart need *twelve* seconds, so the
limit could never be reached: a port that stays taken - the hand-rolled
predecessor coming back, say - meant a process starting, failing and starting
again every three seconds for the rest of the boot, which on this phone is
until somebody reboots it.

Now `RestartSec=5` with a 120-second window, so five failures actually trip the
limit. Verified by taking the port and starting the service:

    t+30s: activating  NRestarts=5
    t+40s: failed      NRestarts=7
    furios-gps-proxy.service: Start request repeated too quickly.

Giving up is safe here, which is why it is allowed to: a proxy that is not
listening means geoclue gets a refused connection and reports no Wi-Fi
position - the same thing it reports when the filter refuses one. And
`gpsctl status` says so rather than leaving it to be guessed:

    FAIL  furios-gps-proxy.service is not running - every Wi-Fi lookup fails

### One thread per connection, and nothing counting them

`ThreadingHTTPServer` starts a thread per connection. On loopback, but loopback
on this phone means every account and every application on it: opening
connections in a loop was a way for anything running here to exhaust memory and
take the location filter down with it. There is a ceiling of 64 now, which is
64 more than the one question geoclue asks at a time.

### Root, and where it comes from

**No sudoers entry, anywhere.** Nothing in this project writes to
`/etc/sudoers.d`, and nothing is setuid - checked, not assumed. The only way
this gets root without somebody typing a password is the polkit action, which
names one binary, allows `allow_active` alone, and is argued for in the file
itself. `install.sh` calls `sudo` because a person is running it and can be
asked; that is not a rule left behind afterwards.

What that action can be pointed at is bounded from the other side too. `gpsctl`
validates the profile name against a fixed list before it acts on it, refuses
every `GPSCTL_*` override when it is root, and now pins its own `PATH` rather
than inheriting one - it does everything by calling `systemctl`, `awk`, `sed`,
`mktemp`, and an inherited `PATH` decides which of those it gets. pkexec
sanitises `PATH` and sudo usually does, but "usually" is not a property to
build a root program on.

`geoclue.conf` is written through a temporary file in the same directory and
renamed over the original, so a geoclue starting in the middle of a switch
reads either the whole old file or the whole new one. It is written back as
`root:root` 0644 - **it was found owned by the login user on this phone**,
which meant the unprivileged account could point the geolocation lookup at any
server it liked and be told it was anywhere at all.

The unit itself runs under `DynamicUser` with no capabilities, a read-only
system, no home, no devices, a system-call filter, and - added here -
`SocketBindAllow=ipv4:tcp:8765` with everything else denied, so a proxy that is
ever made to listen somewhere else simply cannot.

### What is not defended against, and why

Any local program can send a query through the proxy to BeaconDB. That is not a
capability this adds: the same program can reach `api.beacondb.net` directly,
over the same network, without asking anybody. A check here would cost every
lookup something and buy nothing, so there is none.

## 7. Traps

**The marker, not the radius.** The obvious rule is "throw away anything wider
than N kilometres", and it is wrong twice over: a genuine Wi-Fi fix in a
sparsely mapped area is legitimately wide, and an IP fallback in a
well-mapped city can come back narrow. The only reliable signal is the marker
the service puts there on purpose. The width is counted anyway, separately - an
unmarked answer wider than 40 km is the thing to look at if BeaconDB ever stops
setting `fallback`, and `rejected` staying at 0 while `wide` climbs is what
that would look like.

**`lacf` is not `ipf`.** ichnaea marks a cell-area fallback the same way it
marks an IP fallback, with a different value. A cell-area position is derived
from something the phone actually sent and is not what this is about. Refusing
it would have thrown away a real, if coarse, source.

**Two proxies, one port.** The hand-rolled ancestor of this package had been
running out of `~/Scripts` since 12 May 2026 under its own unit. Both bind
8765, and two services wanting one port means the loser dies at every boot -
silently, because the survivor answers and everything looks fine. The installer
and the package's postinst both stop and disable the old unit before they start
theirs, and leave its files alone: taking somebody's script out from under them
is not an installer's job.

**Restarting geoclue from a unit ordered before it.** geoclue reads its config
once, at start, so the config has to be on disk before geoclue starts - hence
`Before=geoclue.service`. A boot unit that then *restarts* geoclue is a
deadlock, and the sibling audio project built exactly that one and spent a
morning on it. `gpsctl boot` runs with `--no-restart` for that reason, and the
unit is `SuccessExitStatus=0 1` so a filter that cannot be applied cannot keep
the boot from finishing.

**An instrument that says the same thing whatever happens.** `where-am-i` was
used to check whether the phone still had a position after the filter went in.
It printed nothing - and it prints nothing in the shipped state too, where a
position certainly is available. Every conclusion drawn from its silence was
worthless. The check that catches this is the cheap one: point the instrument
at the state where the answer is known before trusting it on the state where it
is not.

**Debugging tools that change what they are measuring.** Starting geoclue's
demo agent by hand and then killing it leaves geoclue blocking on authorisation
from an agent that is gone, which looks exactly like "geoclue never hands out a
client" - and got written down as a defect of the phone. It was a defect of the
investigation. A tool started to observe a system is part of the system until
it is properly gone.

**An idempotent command that restarts something is not idempotent.** `apply`
ended with an unconditional `systemctl try-restart` of the proxy, for a good
reason - a package upgrade installs new code and leaves the old process
running. But `gpsctl boot` calls `apply`, so that restart happened at every
boot: the proxy was started by its own unit, and then stopped and started again
by the boot unit a moment later, in the window before geoclue's first lookup -
which is precisely the window the proxy's unit file is written to keep it out
of. It also threw away the counters each time, and a re-run of the installer
did the same. Measured: two `apply` runs in a row, and the counters from the
first were gone. Now the restart asks whether the program on disk is newer than
the process serving from it, and anything it cannot read is treated as a reason
to restart rather than a reason to skip one.

**geoclue is D-Bus activated.** Most of the time there is no geoclue running to
restart at all; it starts when something asks and exits when nothing is asking.
`try-restart` is the honest verb - restart it if it is up, otherwise leave it
to start on demand with the config now on disk. A plain `restart` would start a
service nobody asked for.

**An environment override is an arbitrary-file edit.** `gpsctl` reads
`GPSCTL_CONF` and friends so the tests can point it at a scratch directory.
Under a polkit action that runs it as root without a password, that same
variable would let any active session rewrite any file on the phone. So as root
it refuses every `GPSCTL_*` override outright, and the tests run unprivileged
instead - which they can, because `apply` asks whether it can write the file
rather than asking whether it is root.

## From the README

The README was cut down to what somebody needs to use this. What follows was in it until then: the reasoning, the measurements and the trade-offs behind the decisions.

## What the filter does

`furios-gps-proxy` listens on `127.0.0.1:8765`, forwards the query to BeaconDB
unchanged, looks at the answer, and turns the marked ones into an HTTP 404.
geoclue's web source reads a non-2xx as "this source has nothing", which is the
truth of the matter, and the GNSS fix from the hybris source is left as the
only thing anybody is told. In geoclue's log the filter working looks like
this, and it is not an error:

    geoclue[47897]: Failed to query location: Query location SOUP error: Not Found

What it judges by is the marker and nothing else. A genuine Wi-Fi fix passes
through however wide it is, a cell-area fallback (`lacf`) is not an IP fallback
and passes, "nothing found" stays nothing found. Answers wider than 40 km that
carry no marker are counted separately: if that counter rises while `rejected`
stays at zero, BeaconDB has stopped setting the marker and this project needs
looking at. That is the early-warning post.

Nothing is cached, nothing is stored, and nothing is written down about *where*
anybody is. The counters in `/run/furios-gps-proxy/counters` say how many
answers were of which kind, they go away with the boot they describe, and they
are the whole of what the program remembers between two requests. The service
runs under `DynamicUser=yes` with no account of its own and answers only on
loopback.

## What it costs

This is a trade, and the honest version of it is: **a slow true position
instead of a fast false one.**

Where BeaconDB knows the Wi-Fi networks around you, nothing is lost - real
fixes pass through untouched and arrive as fast as they ever did. Where it does
not, the Wi-Fi source now contributes nothing at all, and the phone has to wait
for GNSS. Measured here on 14 September 2026, indoors, with fifty networks in
range: BeaconDB knew none of them and answered every query with an IP position
of 25 km radius. Twenty-five of those were refused in one hour.

How long that wait is has **not** been settled. Asked over geoclue's own
interface, indoors and with the filter in place, the phone reported no position
in 75 seconds - a real answer from a client that really started, but not yet a
proof, because the same instrument has still to be shown reporting a position
when there is one. Outdoors, where GNSS can fix, will close that. Two earlier
attempts at this measurement were wrong in instructive ways and
[FINDINGS.md](FINDINGS.md) §4 keeps both, along with the script that does work
- geoclue ties a client to the connection that created it, so anything built
out of separate `gdbus` calls measures nothing.

That is why `gpsctl status` checks `[hybris] enable = true` and says why, and
why it is the one key outside `[wifi]` the tool looks at. With the Wi-Fi answer
filtered and GNSS off as well, there would be no position of any kind. This
project will not change that key for you - it is not ours - but it will not let
you overlook it either.

## Minimally invasive

The whole change is **two keys in one section** of `geoclue.conf` plus one
service. The agent whitelist, the GNSS source, the submission settings and
which applications may ask at all belong to somebody else and are never read or
written, not on apply and not on revert.

What `[wifi]` looked like before this project first touched it is written to
`/etc/furios-gps-fix.shipped` on the first apply, and that is what revert puts
back - so a phone somebody had already configured by hand gets its own values
returned to it, not ours. The one exception is deliberate: our own proxy URL is
never recorded as the state to go back to, or revert would be a no-op for ever
after on any phone that already had the hand-rolled ancestor of this package
running.

The boot unit is ordered `Before=geoclue.service`, because geoclue reads its
config once, at start, and a config written afterwards means the first lookup
of the boot still goes wherever the old file said. It runs `gpsctl boot` with
`--no-restart`: restarting a service from inside a unit ordered against it is
how the sibling audio project once built a boot deadlock that survived the
reboot, and this does not repeat it. A filter that cannot be put in place is
not allowed to keep the boot from finishing either.

## What it costs to run

Nothing measurable when nobody is asking. The proxy is one thread asleep in
`accept()`: **zero wakeups and zero CPU ticks in 30 idle seconds**, 24 MB of
resident python. It got there by saying so - the obvious version of this
program wakes up twice a second for the uptime of the phone, because
`serve_forever()` polls its own shutdown flag every half second by default and
nothing here ever calls `shutdown()`.

If it cannot start - a port that stays taken - it gives up after five tries
instead of restarting every few seconds until the next reboot, and
`gpsctl status` says it is not running. Giving up is safe: geoclue gets a
refused connection and reports no Wi-Fi position, which is what it reports when
the filter refuses one anyway. Handler threads are capped, because on loopback
"one thread per connection" means any program on the phone could have taken the
filter down by opening connections in a loop.

[FINDINGS.md](FINDINGS.md) §6 has the numbers and the experiment behind each.

## Root, and what is granted

`gpsctl` writes `/etc/geoclue/geoclue.conf` and starts a service, so applying
and reverting need root. Everything that only reads - `status`, `profile`,
`check`, `probe` - does not.

**There is no sudoers entry and nothing here is setuid.** The only way this
gets root without somebody typing a password is the polkit action below.
`install.sh` calls `sudo` because a person is running it and can be asked - it
leaves no rule behind.

The polkit action lets the switch in the app do what `sudo gpsctl` does from a
terminal, with `allow_active=yes` and no password prompt. Two reasons, the same
two as the modem switch in the sibling project. There is nobody to ask: phosh
registers no polkit authentication agent, so an action set to `auth_admin` has
no way to put a prompt on the screen and the switch would be a control that
does nothing. And the grant is small: two keys in one file and one service, on
a phone where that file was owned by the login user to begin with. Not
`allow_any` and not `allow_inactive` - a remote session has no business
deciding where this phone says it is.

As root, `gpsctl` refuses every `GPSCTL_*` environment override outright. The
tests need those overrides and therefore run unprivileged, which works because
`apply` tests whether it can write the files rather than testing `id -u`.
Without that refusal, a policy that hands out one command without a password
would be handing out an arbitrary-file edit under a friendly name. For the same
reason it pins its own `PATH` instead of inheriting one: everything it does, it
does by calling `systemctl`, `awk`, `sed` or `mktemp`, and an inherited `PATH`
decides which of those it gets.

`geoclue.conf` is written through a temporary file in the same directory and
renamed over the original, so a geoclue starting mid-switch reads one whole
file or the other. It is written back `root:root` - it was found owned by the
login user on this phone, which meant the unprivileged account could point the
geolocation lookup anywhere it liked.

## Layout

    gpsctl                 the tool
    tools/                 the proxy, and the script that asks geoclue for a
                           position over one held connection
    original-files/        geoclue.conf as FuriOS ships it, for the tests
    systemd/               the proxy service and the boot unit
    polkit/                the action behind the switch in the app
    tests/                 what can be checked without a network
    packaging/             build-deb.sh
