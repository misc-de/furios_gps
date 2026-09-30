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

## What it remembers, and where

Everything this project changes is written down BEFORE the first change, so
that switching off and uninstalling put back what was there - not what a new
phone probably has. All of it lives in `~/.config/furios-gps/`:

| File | Written by | What it records | Read by |
|---|---|---|---|
| `install-record/manifest` (+ `saved/`) | `install.sh`, first run | for each installed file: nothing there / somebody else's file (a copy in `saved/`) / ours from an install before records existed; and the checksum of what was installed | `uninstall.sh` |
| `unit-before-on` | `furios-gps-contribute on`, first time | whether `furios-gps-contribute.service` was enabled | `furios-gps-contribute off` |
| `firefox-record.json` | `furios-gps-firefox on`, per profile the first time it is seen | whether `user.js` existed and how it ended, which of our lines were already in `prefs.js` (your own `about:config` values), whether the two units were enabled | `furios-gps-firefox off` / `apply` |

A record is never rewritten by a second install or a second `on`. Restoring
puts back only what is still ours: a file or a value somebody changed after
us stays as it is, and `uninstall.sh` or `off` says so. Where there is no
record - installed or switched on before 30.9.2026 - both fall back to what
they did before (remove, disable) and say that they had none.

One deliberate exception: the Firefox block written by hand on 27.9.2026,
before `furios-gps-firefox` existed, is taken over as ours, and `off` removes
it like its own.

## Tests

    ./tests/run-tests.sh        # not with sudo

Runs against stubs and a state directory of its own, so a test run changes
nothing on the phone and sends nothing.

## Licence

MIT - see [LICENSE](LICENSE) and [NOTICE](NOTICE) for what this builds on.
