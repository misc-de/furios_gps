#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Builds a .deb from the work tree. Architecture-independent - two scripts, two
# units and a policy file, nothing compiled.
set -e
cd "$(dirname "$0")/.."
ROOT=$(pwd)

PKG="furios-gps-contribute"
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

install -Dm755 tools/furios-gps-contribute "$STAGE/usr/bin/furios-gps-contribute"
install -Dm644 systemd/furios-gps-contribute.service \
    "$STAGE/usr/lib/systemd/user/furios-gps-contribute.service"
install -Dm755 tools/furios-gps-firefox "$STAGE/usr/bin/furios-gps-firefox"
for u in furios-gps-firefox.service furios-gps-firefox.path; do
    install -Dm644 "systemd/$u" "$STAGE/usr/lib/systemd/user/$u"
done

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

COPY
chmod 644 "$STAGE/usr/share/doc/$PKG/copyright"

mkdir -p "$STAGE/DEBIAN"
# python3-gi because the tool asks geoclue and NetworkManager over D-Bus.
# Replaces the package this one used to be: the location filter it carried is
# retired, and geoclue itself now refuses IP-derived positions.
cat > "$STAGE/DEBIAN/control" <<CONTROL
Package: $PKG
Version: $VERSION
Architecture: all
Maintainer: misc-de <11610690+misc-de@users.noreply.github.com>
Section: utils
Priority: optional
Depends: geoclue-2.0, python3, python3-gi, systemd
Replaces: furios-gps-fix
Conflicts: furios-gps-fix
Description: Contributes Wi-Fi observations to beaconDB, off until switched on
 Hands beaconDB the Wi-Fi networks in range together with a satellite
 position, so that Wi-Fi location works in places it does not yet. Only GNSS
 fixes are used, hidden networks and names ending in _nomap or _optout are
 never collected, and submissions go out over Wi-Fi only, batched and minutes
 apart. Nothing is collected or sent until "furios-gps-contribute on".
 .
 Also carries furios-gps-firefox, which lets Firefox and its web apps wait
 for the satellite fix instead of giving up after 12 seconds - likewise off
 until "furios-gps-firefox on".
CONTROL

# No maintainer scripts: the unit is a user unit and stays off, and the tool
# does nothing without the marker its owner places.

rm -f "$ROOT/packaging/${PKG}_"*.deb
OUT="$ROOT/packaging/${PKG}_${VERSION}_all.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT" >/dev/null
echo "done: $OUT"

[ "${1:-}" = --install ] && sudo dpkg -i "$OUT"
exit 0
