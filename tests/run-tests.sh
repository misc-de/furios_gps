#!/bin/bash
# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# Everything that can be checked without a network and without a GPS fix.
#
# What is here: the rule the proxy applies, and gpsctl's judgement about what
# it may write and what it must leave alone. Both run against copies and stubs,
# so a test run never changes the phone it runs on.
#
# What is not here, and cannot be: whether the phone stops claiming to be in
# the wrong city. That is "gpsctl probe" for the one query, and a walk outside
# with the map open for the rest.
#
# Not with sudo. As root gpsctl refuses every GPSCTL_* override - which is the
# point of that guard - and the whole suite would test nothing.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
FAILED=0

if [ "$(id -u)" -eq 0 ]; then
    printf '\033[31mDo not run this with sudo.\033[0m As root gpsctl refuses the\n'
    printf 'overrides these tests need, and every one of them would pass vacuously.\n'
    exit 2
fi

run() {
    printf '\n\033[1m== %s\033[0m\n' "$1"
    shift
    "$@" || FAILED=$((FAILED + 1))
}

run "the rule the proxy applies"  "$ROOT/tools/furios-gps-proxy" --self-test
run "what gpsctl writes, and what it leaves alone" bash "$HERE/test-gpsctl.sh"

is_python() { head -1 "$1" 2>/dev/null | grep -q 'python'; }

printf '\n\033[1m== shell scripts parse\033[0m\n'
for f in "$ROOT"/*.sh "$ROOT"/gpsctl "$ROOT"/tests/*.sh "$ROOT"/packaging/*.sh "$ROOT"/tools/*; do
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
noise='Unit .* not found|Command /usr/bin/(gpsctl|furios-gps-proxy) is not executable'
[ -x /usr/bin/gpsctl ] && [ -x /usr/bin/furios-gps-proxy ] && noise='Unit .* not found'
if ! command -v systemd-analyze >/dev/null 2>&1; then
    printf '  \033[33mskipped\033[0m - systemd-analyze not available\n'
else
    for u in "$ROOT"/systemd/*.service; do
        [ -f "$u" ] || continue
        if systemd-analyze verify "$u" 2>&1 | grep -vE "$noise" | grep -q .; then
            printf '  \033[31mFAIL\033[0m %s\n' "$(basename "$u")"
            systemd-analyze verify "$u" 2>&1 | grep -vE "$noise" | sed 's/^/       /'
            FAILED=$((FAILED + 1))
        else
            printf '  \033[32mok\033[0m   %s\n' "$(basename "$u")"
        fi
    done
fi

# A polkit action with malformed XML is not rejected loudly - polkit ignores
# the file, pkexec refuses, and the switch in the app looks broken for a reason
# nothing on the screen explains.
printf '\n\033[1m== the polkit action parses\033[0m\n'
for f in "$ROOT"/polkit/*.policy; do
    [ -f "$f" ] || continue
    if err=$(python3 -c 'import sys,xml.etree.ElementTree as E; E.parse(sys.argv[1])' "$f" 2>&1); then
        printf '  \033[32mok\033[0m   %s\n' "$(basename "$f")"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$(basename "$f")"
        printf '       %s\n' "$err"
        FAILED=$((FAILED + 1))
    fi
done

# The action names the binary it may run. If that path and the one the app
# actually starts ever drift apart, pkexec simply refuses and nothing says why.
printf '\n\033[1m== the polkit action names the right binary\033[0m\n'
want=$(grep -o '<annotate key="org.freedesktop.policykit.exec.path">[^<]*' \
       "$ROOT/polkit/de.misc-de.gpsctl.policy" | sed 's/.*>//')
if [ "$want" = /usr/bin/gpsctl ]; then
    printf '  \033[32mok\033[0m   %s (install.sh rewrites it for /usr/local)\n' "$want"
else
    printf '  \033[31mFAIL\033[0m names %s, but the package installs /usr/bin/gpsctl\n' "$want"
    FAILED=$((FAILED + 1))
fi

printf '\n'
if [ "$FAILED" -eq 0 ]; then
    printf '\033[32mall suites passed\033[0m\n'
else
    printf '\033[31m%d suite(s) failed\033[0m\n' "$FAILED"
fi
exit $([ "$FAILED" -eq 0 ] && echo 0 || echo 1)
