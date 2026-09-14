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

## 4. The measurement that argues against this project

After the filter went in, `where-am-i` was asked for a position indoors and got
**nothing at all** - first over 75 seconds, then over a further five minutes.
No Wi-Fi position, because it is refused, and no GNSS fix, because there is no
sky view.

That is the cost, and it is not small. Before the filter the same phone in the
same room would have answered immediately, with a point 25 km away. The claim
this project makes is only that no answer is better than a confidently wrong
one - that an application which knows it has no position can say so, ask again,
or wait, whereas an application handed a wrong position simply acts on it.

It is a claim about which failure is more useful, not a claim that nothing was
lost. On a phone whose neighbourhood BeaconDB *does* know, nothing is lost at
all: real fixes carry no marker and pass through untouched.

This is why `gpsctl status` reports `[hybris] enable` even though this project
never writes that key. With the Wi-Fi answer filtered and GNSS switched off,
there would be no position of any kind, and that is a state somebody should be
told about rather than discover.

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
