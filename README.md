# furios_gps

Contributes Wi-Fi observations to [beaconDB](https://beacondb.net) from the
FuriPhone FLX1 - off until you switch it on - so that Wi-Fi location works in
places where it does not yet.

> **The location filter is retired (27.9.2026).** This repository started as a
> proxy that stopped geoclue from publishing the carrier's IP address as a
> position. geoclue 2.7.1-3+furios7 does that itself and ships the Wi-Fi source
> on, so the filter only duplicated it - while editing `/etc/geoclue/geoclue.conf`,
> a conffile of the geoclue package. It is no longer installed; `./uninstall.sh`
> removes it where an older version left it behind and puts geoclue.conf back.
> Settings of your own belong in `/etc/geoclue/conf.d/`. [FINDINGS.md](FINDINGS.md)
> keeps the measurements behind it.

## Install

    git clone https://github.com/misc-de/furios_gps
    cd furios_gps && ./install.sh

No root: the tool goes to `~/.local/bin`, its unit to
`~/.config/systemd/user`. Or as a package, `./packaging/build-deb.sh --install`.
Either way nothing is switched on. Undo with `./uninstall.sh` or
`apt remove furios-gps-contribute`.

## Usage

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

## Firefox and web apps: wait for the fix

Firefox asks geoclue for a position and gives up after 12 seconds; a cold
GNSS fix on this phone takes 30 to 80. A map in a Firefox web app then shows
no location while geoclue is still getting there.

    furios-gps-firefox status     how many profiles carry the prefs
    furios-gps-firefox on|off     switch it on or off (no root)

On writes three prefs into `user.js` of every profile in `profiles.ini`, in a
marked block (no fallback to Mozilla's location service, 3 minutes instead of
12 seconds, always ask for GNSS). A path unit gives new web app profiles the
same. The web app manager keeps everything outside its own block, so ours
survives it. Open apps pick it up when they are next started.

Off takes the block out again, and the values Firefox copied into `prefs.js`
with it - only those, not a value somebody set in `about:config`. A profile
that is open at that moment is cleaned at the next login. `apt remove` does
not do this; run `furios-gps-firefox off` first.

Or the switch under **Firefox and web apps** on the GPS page of the app.

## Tests

    ./tests/run-tests.sh        # not with sudo

Runs against stubs and a state directory of its own, so a test run changes
nothing on the phone and sends nothing.

## Licence

MIT - see [LICENSE](LICENSE) and [NOTICE](NOTICE) for what this builds on.
