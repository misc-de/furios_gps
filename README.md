# furios_gps

Stops the FuriPhone FLX1 from reporting a location derived from its IP address.

As shipped, geoclue has its Wi-Fi source switched off, which leaves GeoIP as
the only way the phone can place itself before GNSS gets a fix. On mobile data
that is the carrier's NAT exit — often tens of kilometres away, and it does not
move when you do. Simply switching the Wi-Fi source back on does not help:
where the geolocation service recognises no networks, it answers with the
position of whoever asked and marks the answer as an IP fallback, and geoclue
ignores that marker.

This repository puts a small proxy in front of the Wi-Fi source that reads the
marker and drops those answers. Real Wi-Fi fixes pass through untouched; where
there are none, the phone waits for GNSS instead of claiming to be somewhere it
is not.

**The trade:** a slow true position instead of a fast false one. Indoors and
out of GNSS range, you may get no position at all — which is the honest answer.

## Install

    git clone https://github.com/misc-de/furios_gps
    cd furios_gps && ./install.sh

or as a package:

    ./packaging/build-deb.sh --install

Both install the proxy, the boot unit and the polkit action, and switch the
filter on straight away. Undo with `./uninstall.sh` or
`apt remove furios-gps-fix`; geoclue's `[wifi]` section is restored to exactly
what was in it beforehand.

## Usage

    gpsctl status          what is in place, and what the proxy has seen
    gpsctl profile         which profile is recorded, and which one is running
    gpsctl set <profile>   switch and remember it
    gpsctl try <profile>   switch until the next boot
    gpsctl apply           put the filter in place (idempotent)
    gpsctl revert          back to the shipped state
    gpsctl check           status plus the rule tested against a stub
    gpsctl probe           one real query, to watch the filter refuse it
    gpsctl boot            match the recorded profile (used by the boot unit)

Two profiles: `fixed` runs the Wi-Fi source through the filter, `shipped` is
FuriOS as it came.

Reading the state needs no privileges. Switching writes to
`/etc/geoclue/geoclue.conf`, so `set`, `try`, `apply` and `revert` need root —
via `sudo`, or without a password from the phone itself through the polkit
action, which is what the switch in the `misc-de` app uses.

`gpsctl probe` is the one worth running once. It sends a single query that is
bound to come back as an IP fallback and shows the filter refusing it.

## Contributing back

The filter above refuses positions beaconDB derived from an IP address. The
other direction is optional and off by default: handing beaconDB the
observations that would let it answer this area properly.

    furios-gps-contribute status      what it would send, and what it has
    furios-gps-contribute on|off      switch it on or off (no root)
    furios-gps-contribute once        one measurement, queued
    furios-gps-contribute once --dry-run   print it instead, and send nothing
    furios-gps-contribute send        hand over what is queued

Or the switch under **Contribute to beaconDB** on the GPS page of the app.

What is sent is the MAC address, channel and signal strength of the networks
in range, with a GNSS position. What is never sent: network names, hidden
networks, and anything whose name ends in `_nomap` or `_optout` - beaconDB's
rules, and the way an access point owner opts out.

The position has to come from satellites. geoclue can answer from a Wi-Fi
lookup, and that lookup is answered by beaconDB itself - submitting one would
hand the database its own estimate back as an observation. A fix is only used
when it carries an altitude, which network-derived positions do not, and when
it is accurate to 25 m or better.

Submissions go out over Wi-Fi only, batched, minutes apart, and a refusal is
dropped rather than retried. See [NOTICE](NOTICE) for what this means for the
networks around you.

## Tests

    ./tests/run-tests.sh        # not with sudo

Runs against copies and stubs, so a test run changes nothing on the phone.
What it cannot answer is whether the phone ends up in the right place on a map —
that is `gpsctl check` and `gpsctl probe`, outdoors, with a view of the sky.

## Licence

MIT — see [LICENSE](LICENSE) and [NOTICE](NOTICE) for what this builds on.
Why it is built this way, and the measurements behind it, are in
[FINDINGS.md](FINDINGS.md).
