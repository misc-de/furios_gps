#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Everything that can be checked without a network and without a GPS fix.
#
# What is here: what furios-gps-contribute collects, what it refuses to
# collect, and how gently it treats beaconDB. It runs against stubs and a
# state directory of its own, so a test run never changes the phone.
#
# What is not here, and cannot be: whether a submission helps. That is a walk
# outside with "furios-gps-contribute once --dry-run".
#
# Not with sudo: nothing here wants root, and a run as root would write its
# stub state where the real user's is.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
FAILED=0

if [ "$(id -u)" -eq 0 ]; then
    printf '\033[31mDo not run this with sudo.\033[0m\n'
    exit 2
fi

run() {
    printf '\n\033[1m== %s\033[0m\n' "$1"
    shift
    "$@" || FAILED=$((FAILED + 1))
}

run "contributing back, and not being a burden" bash "$HERE/test-contribute.sh"

is_python() { head -1 "$1" 2>/dev/null | grep -q 'python'; }

printf '\n\033[1m== shell scripts parse\033[0m\n'
for f in "$ROOT"/*.sh "$ROOT"/tests/*.sh "$ROOT"/packaging/*.sh "$ROOT"/tools/*; do
    [ -f "$f" ] || continue
    is_python "$f" && continue
    if bash -n "$f" 2>/dev/null; then
        printf '  \033[32mok\033[0m   %s\n' "${f#$ROOT/}"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "${f#$ROOT/}"
        FAILED=$((FAILED + 1))
    fi
done

printf '\n\033[1m== python scripts parse\033[0m\n'
for f in "$ROOT"/tools/*; do
    [ -f "$f" ] || continue
    is_python "$f" || continue
    if python3 -m py_compile "$f" 2>/dev/null; then
        printf '  \033[32mok\033[0m   %s\n' "${f#$ROOT/}"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "${f#$ROOT/}"
        FAILED=$((FAILED + 1))
    fi
done

# The units are the part nobody looks at until a boot goes wrong.
printf '\n\033[1m== systemd units\033[0m\n'
# Two complaints are expected off the device and are not defects: units this
# one is merely ordered against may not exist here, and the programs are not in
# /usr/bin until the package has been installed.
# A third one joined them: this phone has a broken unit of its own in
# /run/systemd/system/default.target.wants - a symlink literally named
# "runonce@*.service", star included - and systemd-analyze mentions it while
# resolving any target. It is not ours (nothing under furios- is involved) and
# there is nothing here to fix, so it is named rather than swept up by a
# pattern wide enough to hide our own faults too.
noise='Unit .* not found|Wants dependency dropin .*runonce@\*\.service is not a valid unit name'
if ! command -v systemd-analyze >/dev/null 2>&1; then
    printf '  \033[33mskipped\033[0m - systemd-analyze not available\n'
else
    for u in "$ROOT"/systemd/*.service; do
        [ -f "$u" ] || continue
        # A user unit checked as a system one is checked against the wrong
        # world: its targets do not exist there.
        modus=""
        grep -q 'WantedBy=default.target\|PartOf=graphical-session.target' "$u" \
            && modus="--user"
        # shellcheck disable=SC2086
        if systemd-analyze verify $modus "$u" 2>&1 | grep -vE "$noise" | grep -q .; then
            printf '  \033[31mFAIL\033[0m %s\n' "$(basename "$u")"
            # shellcheck disable=SC2086
            systemd-analyze verify $modus "$u" 2>&1 | grep -vE "$noise" | sed 's/^/       /'
            FAILED=$((FAILED + 1))
        else
            printf '  \033[32mok\033[0m   %s\n' "$(basename "$u")"
        fi
    done
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mall suites passed\033[0m\n'
else
    printf '\033[31m%d suite(s) failed\033[0m\n' "$FAILED"
fi
exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
