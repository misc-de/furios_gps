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

## 4. The measurement that argues against this project - and why it is not one

This section first said that after the filter went in, `where-am-i` was asked
for a position indoors and got nothing, over 75 seconds and then over five more
minutes. It got nothing. That part is true and the conclusion drawn from it was
still wrong, because the instrument was never measuring what it was pointed at.

`/usr/libexec/geoclue-2.0/demos/where-am-i` prints nothing on this phone in
**any** state. Run with the filter in place: nothing. Run with `gpsctl try
shipped`, the state FuriOS ships, where a position is there for the asking:
nothing, over 90 seconds. Same silence, both streams, exit 0. It is the
`droid-sink.monitor` of this project - an instrument that returns the same
answer whatever is in front of it, and therefore no instrument at all.

What it is really hitting is one level down:

    gdbus call --system --dest org.freedesktop.GeoClue2 \
      --object-path /org/freedesktop/GeoClue2/Manager \
      --method org.freedesktop.GeoClue2.Manager.GetClient

hangs until it is killed. So does `CreateClient`. Reading properties on the
same object answers immediately:

    ({'InUse': <false>, 'AvailableAccuracyLevel': <uint32 8>},)

So geoclue is up, talking, and reporting that an Exact-accuracy source is
available - and never hands out a client to ask with. No geoclue agent is
registered either; the `[agent]` whitelist names four and none of them is
running. Starting the demo agent by hand changed nothing.

**None of that is caused by this project.** It is identical in the shipped
state, which is what made it findable at all. It is a defect of its own, on
this phone, and it is not this repository's to fix.

What remains measured, and is not in doubt:

- BeaconDB has no coverage at this location (§3), so the Wi-Fi source was
  contributing an IP position and nothing else;
- the proxy refuses those, and geoclue's own log shows its web source
  accepting the refusal as "this source has nothing".

What follows from that is an argument rather than a measurement, and is written
as one: where BeaconDB does not know the neighbourhood, the phone has no
network position and must wait for GNSS. **Whether GNSS then delivers on this
phone has not been shown here**, and until it is, the honest claim for this
project is the narrow one - that a position which is really just the question
echoed back is not published as if it were an observation.

The instrument for the wider claim still has to be found. `where-am-i` is not
it.

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

## 6. Traps

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
