# furios_gps

A phone that could only ever be where its IP address said it was.

FuriOS ships geoclue with the Wi-Fi source switched off and BeaconDB's URL
sitting in the file unused. That looks like a setting nobody got round to, and
it is not: geoclue's own comment above the key spells out what it means.

    # Enable WiFi source
    # If this source and the static source below are both disabled a GeoIP-only
    # source will be used instead.
    enable=false

So the phone as it comes has exactly one way of working out where it is before
GNSS has a fix, and that is to ask what its IP address looks like. On Wi-Fi
that is roughly the right town. On mobile data it is the carrier's NAT exit -
a fixed point that on this phone sits tens of kilometres away and does not
move when the phone does.

**Switching the Wi-Fi source on does not fix it.** Hand a geolocation service
no Wi-Fi it recognises and it does not answer "I do not know". It answers with
the position of the address that asked, and it marks the answer as such:
ichnaea's API, which BeaconDB speaks, sets

    "fallback": "ipf"

next to the position. **geoclue does not look at that field.** It takes the
position like any other, and because the Wi-Fi source answers in a fraction of
a second while GNSS needs seconds to minutes, that is what every application
on the phone is told first.

This repository filters the answer instead of changing the question.

## Install

    git clone https://github.com/misc-de/furios_gps
    cd furios_gps && ./install.sh

or build a package:

    ./packaging/build-deb.sh --install

Both install the proxy, the boot unit and the polkit action, and apply the
filter immediately. Reversible with `./uninstall.sh` or
`apt remove furios-gps-fix` - and that reversal is a real one: geoclue's
`[wifi]` section goes back to what was in it before this was ever installed,
which the first `apply` writes down for exactly that purpose.

## gpsctl

    gpsctl status          what is in place, and what the proxy has seen
    gpsctl profile         which profile is recorded, and which one is running
    gpsctl set <profile>   switch and remember it
    gpsctl try <profile>   switch until the next boot
    gpsctl apply           put the filter in place (idempotent)
    gpsctl revert          back to the shipped state
    gpsctl check           status plus the rule tested against a stub upstream
    gpsctl probe           one real query to the service, to watch it refused
    gpsctl boot            make the phone match the recorded profile

Two profiles. `fixed` is the repair: the Wi-Fi source runs through the proxy
and positions derived from the IP address are thrown away. `shipped` is FuriOS
exactly as it came, and `gpsctl` says plainly what that means rather than
calling it "off" - the Wi-Fi source disabled, geoclue locating the phone by its
IP address, and nothing filtering the result.

`gpsctl probe` is the one worth running once. It sends a single query with no
Wi-Fi and no cell data in it - precisely the query that gets an IP fallback
back - and shows the filter refusing it:

    ok    the service answered with an IP fallback, and the proxy refused it

Everything else stays on the phone. `gpsctl check` runs the real request
handler against a stub upstream, so the rule is proved without BeaconDB being
told this phone exists.

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
not, the Wi-Fi source now contributes nothing at all, and the phone has no
position until GNSS gets one. Measured here on 14 September 2026, indoors, with
fifty networks in range: BeaconDB knew none of them and answered every query
with an IP position of 25 km radius. Twenty-five of those were refused in one
hour.

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

## Root, and what is granted

`gpsctl` writes `/etc/geoclue/geoclue.conf` and starts a service, so applying
and reverting need root. Everything that only reads - `status`, `profile`,
`check`, `probe` - does not.

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
would be handing out an arbitrary-file edit under a friendly name.

## Tests

    ./tests/run-tests.sh

What can be decided at a desk: that the rule passes a real fix and refuses a
marked one, that a wide unmarked answer and a cell-area fallback are not
mistaken for IP fallbacks, that unreadable JSON from upstream becomes an
upstream error rather than a position; that `gpsctl` writes into the section it
means and not into the next one, creates a missing section, reads a quoted
value the same as a bare one, and replaces rather than appends; that every
script parses, that both units are valid, and that the polkit action names the
binary the installer actually put there.

What cannot: whether the phone ends up in the right place on a map. That is
`gpsctl check` and `gpsctl probe`, on the device, outdoors, with a sky view.

## Layout

    gpsctl                 the tool
    tools/                 the proxy
    original-files/        geoclue.conf as FuriOS ships it, for the tests
    systemd/               the proxy service and the boot unit
    polkit/                the action behind the switch in the app
    tests/                 what can be checked without a network
    packaging/             build-deb.sh

## Licence

MIT, all of it - see [LICENSE](LICENSE). `original-files/geoclue.conf` is
geoclue's own file, kept unmodified for the tests and for what revert falls
back to; see [NOTICE](NOTICE).
