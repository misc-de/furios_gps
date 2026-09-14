#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Builds a .deb from the work tree. Architecture-independent - two scripts, two
# units and a policy file, nothing compiled.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

PKG="furios-gps-fix"
# The commit COUNT leads the version, not the hash: dpkg compares digit runs
# numerically and anything else as text, so a hash would decide the order
# between two builds - and hashes are not monotonic.
COUNT=$(git rev-list --count HEAD 2>/dev/null || echo 0)
DATE=$(git log -1 --format=%cd --date=format:%Y%m%d 2>/dev/null || date +%Y%m%d)
HASH=$(git rev-parse --short HEAD 2>/dev/null || echo 0)
VERSION="0.1.0+git$COUNT.$DATE.$HASH"
[ -n "$(git status --porcelain 2>/dev/null)" ] && VERSION="$VERSION+dirty$(date +%Y%m%d%H%M%S)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
# mktemp makes it 0700, and that mode travels into the package as the mode of
# "./". Nothing should be able to learn the root directory's permissions from
# a package of ours.
chmod 755 "$STAGE"
echo "package $PKG $VERSION (all)"

install -Dm755 gpsctl                 "$STAGE/usr/bin/gpsctl"
install -Dm755 tools/furios-gps-proxy "$STAGE/usr/bin/furios-gps-proxy"

install -Dm644 systemd/furios-gps-proxy.service \
    "$STAGE/usr/lib/systemd/system/furios-gps-proxy.service"
install -Dm644 systemd/furios-gps-fix.service \
    "$STAGE/usr/lib/systemd/system/furios-gps-fix.service"

# Straight into place, not under /usr/share: polkit reads its actions from this
# directory only, and the file describes what this package's own /usr/bin/gpsctl
# is allowed to do - so it belongs to the package and goes away with it.
install -Dm644 polkit/de.misc-de.gpsctl.policy \
    "$STAGE/usr/share/polkit-1/actions/de.misc-de.gpsctl.policy"

# The file FuriOS ships, kept for what revert falls back to and for the tests.
# Under /usr/share and never copied into /etc: geoclue.conf is geoclue's
# conffile, and a second package writing one is how an upgrade starts asking
# people which version of a file they want.
install -Dm644 original-files/geoclue.conf \
    "$STAGE/usr/share/$PKG/original-files/geoclue.conf"

install -Dm644 README.md   "$STAGE/usr/share/doc/$PKG/README.md"
install -Dm644 FINDINGS.md "$STAGE/usr/share/doc/$PKG/FINDINGS.md"
install -Dm644 LICENSE     "$STAGE/usr/share/doc/$PKG/LICENSE"
install -Dm644 NOTICE      "$STAGE/usr/share/doc/$PKG/NOTICE"

cat > "$STAGE/usr/share/doc/$PKG/copyright" <<'COPY'
Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
Upstream-Name: furios_gps
Source: https://github.com/misc-de/furios_gps

Files: *
Copyright: 2026 misc-de
License: MIT

Files: original-files/geoclue.conf
Copyright: 2026 The GeoClue authors
Comment: The configuration file as the geoclue-2.0 package ships it, kept
 unmodified so that revert has somewhere to go and the tests have something
 real to work on. Not installed into /etc by this package.
License: GPL-2.0+

License: MIT
 Permission is hereby granted, free of charge, to any person obtaining a
 copy of this software and associated documentation files (the "Software"),
 to deal in the Software without restriction, including without limitation
 the rights to use, copy, modify, merge, publish, distribute, sublicense,
 and/or sell copies of the Software, and to permit persons to whom the
 Software is furnished to do so, subject to the following conditions:
 .
 The above copyright notice and this permission notice shall be included
 in all copies or substantial portions of the Software.
 .
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
 OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

License: GPL-2.0+
 On Debian systems the full text is in
 /usr/share/common-licenses/GPL-2.
COPY
chmod 644 "$STAGE/usr/share/doc/$PKG/copyright"

mkdir -p "$STAGE/DEBIAN"
# geoclue-2.0 because there is nothing to configure without it. python3 because
# the proxy is written in it. curl only for "gpsctl probe", which is one
# command out of ten - a Recommends, not a Depends.
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: misc-de <11610690+misc-de@users.noreply.github.com>
Section: utils
Priority: optional
Depends: geoclue-2.0, python3, systemd
Recommends: curl
Description: Stops geoclue believing the carrier's IP address is where you are
 Asked where the phone is with no Wi-Fi it recognises, a geolocation service
 does not answer "I do not know": it answers with the location of the IP
 address that asked, which on mobile data is the carrier's NAT exit - a fixed
 point tens to hundreds of kilometres away. The answer is marked as such in
 the reply, and geoclue does not look at the marking. It publishes the position,
 and because the Wi-Fi source answers long before GNSS has a fix, that is what
 every app on the phone is told first.
 .
 This package puts a proxy on loopback between geoclue's Wi-Fi source and the
 service, throws away the answers that carry the marking, and leaves the real
 GNSS fix as the only thing anybody is told. gpsctl switches it on and off,
 says which state the phone is in, and counts what has been refused.
CONTROL

cat > "$STAGE/DEBIAN/postinst" <<'POST'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    # The hand-rolled ancestor of this package wants the same port, and two
    # services fighting over one means the loser dies at every boot.
    if systemctl cat beacondb-proxy.service >/dev/null 2>&1; then
        systemctl disable --now beacondb-proxy.service >/dev/null 2>&1 || true
        echo "furios-gps-fix: disabled beacondb-proxy.service - it wants the same port" >&2
    fi
    systemctl enable furios-gps-fix.service >/dev/null 2>&1 || true
    # "enable --now" does NOT restart a unit that is already running, so an
    # upgrade would install new code and leave the old process in charge - and
    # the old process is exactly the one with the bug that was just fixed.
    systemctl try-restart furios-gps-proxy.service >/dev/null 2>&1 || true
    # Put the filter in place now rather than at the next boot. Quiet, and
    # never fatal: a package that fails to configure would leave dpkg
    # half-done, which is a worse problem than an unfiltered geoclue.
    /usr/bin/gpsctl boot --quiet || \
        echo "furios-gps-fix: could not apply everything - run 'gpsctl status'" >&2
fi
exit 0
POST
chmod 755 "$STAGE/DEBIAN/postinst"

cat > "$STAGE/DEBIAN/prerm" <<'PRE'
#!/bin/sh
set -e
case "$1" in
remove)
    # Put geoclue.conf back while gpsctl is still here to do it with. After
    # the binary is gone the file would stay pointed at a proxy that no longer
    # exists - a phone with no Wi-Fi location at all, and nothing installed to
    # explain why.
    /usr/bin/gpsctl revert --quiet || true
    systemctl disable --now furios-gps-proxy.service >/dev/null 2>&1 || true
    systemctl disable --now furios-gps-fix.service >/dev/null 2>&1 || true
    ;;
esac
exit 0
PRE
chmod 755 "$STAGE/DEBIAN/prerm"

# Nothing on upgrade: the config this package writes is what the new postinst
# is about to write again anyway, and reverting in between would leave an
# upgrade that stops halfway with an unfiltered geoclue.

cat > "$STAGE/DEBIAN/postrm" <<'POSTRM'
#!/bin/sh
set -e
if [ "$1" = purge ]; then
    # The recorded profile and the recorded shipped values describe a package
    # that is no longer here. On remove they stay, so reinstalling remembers
    # the choice; on purge they go, like any other state.
    rm -f /etc/furios-gps-fix.profile /etc/furios-gps-fix.shipped
fi
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
POSTRM
chmod 755 "$STAGE/DEBIAN/postrm"

rm -f "$ROOT/packaging/${PKG}_"*.deb
OUT="$ROOT/packaging/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT" >/dev/null
echo "done: $OUT"

[ "${1:-}" = --install ] && sudo dpkg -i "$OUT"
exit 0
