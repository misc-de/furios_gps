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
run "contributing back, and not being a burden" bash "$HERE/test-contribute.sh"

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
# A third one joined them: this phone has a broken unit of its own in
# /run/systemd/system/default.target.wants - a symlink literally named
# "runonce@*.service", star included - and systemd-analyze mentions it while
# resolving any target. It is not ours (nothing under furios- is involved) and
# there is nothing here to fix, so it is named rather than swept up by a
# pattern wide enough to hide our own faults too.
noise='Unit .* not found|Command /usr/bin/(gpsctl|furios-gps-proxy) is not executable'
noise="$noise"'|Wants dependency dropin .*runonce@\*\.service is not a valid unit name'
[ -x /usr/bin/gpsctl ] && [ -x /usr/bin/furios-gps-proxy ] \
    && noise='Unit .* not found|Wants dependency dropin .*runonce@\*\.service is not a valid unit name'
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

# Four properties that were each measured wrong on the device before they were
# written down here. None can be checked by running the program: they are
# promises the unit and the source make, and a later edit undoing one of them
# would be silent - the proxy would still work, and the phone would just wake
# up twice a second again, or restart for ever, or take an inherited PATH.
printf '\n\033[1m== the promises that cost battery when broken\033[0m\n'
check() {
    if eval "$2"; then
        printf '  \033[32mok\033[0m   %s\n' "$1"
    else
        printf '  \033[31mFAIL\033[0m %s\n' "$1"
        FAILED=$((FAILED + 1))
    fi
}
PROXY_SRC=$ROOT/tools/furios-gps-proxy
UNIT=$ROOT/systemd/furios-gps-proxy.service

# socketserver polls its own shutdown flag every poll_interval seconds, and the
# default of 0.5 is two wakeups a second for the uptime of a phone that never
# suspends. Measured: 60 voluntary context switches in 30 idle seconds before,
# 0 after.
check "the accept loop is not woken twice a second" \
      'grep -q "serve_forever(poll_interval=IDLE_POLL)" "$PROXY_SRC" &&
       [ "$(sed -n "s/^IDLE_POLL = //p" "$PROXY_SRC")" -ge 60 ]'

# One thread per connection with nothing counting them is a local denial of
# service from any account on the phone.
check "handler threads have a ceiling" \
      'grep -q "threading.active_count() > MAX_THREADS" "$PROXY_SRC"'

# Five starts three seconds apart need twelve seconds; the default window is
# ten, so the limit could never fire and a taken port meant restarting for ever.
# Both keys belong in [Unit] - put in [Service] systemd ignores them with a
# warning nobody reads, which is the failure this checks for.
unit_section() { sed -n '/^\[Unit\]/,/^\[Service\]/p' "$UNIT"; }
limit_window=$(unit_section | sed -n 's/^StartLimitIntervalSec=//p')
limit_burst=$(unit_section | sed -n 's/^StartLimitBurst=//p')
restart_delay=$(sed -n 's/^RestartSec=//p' "$UNIT")
check "the restart limit can actually be reached" \
      '[ -n "$limit_window" ] && [ -n "$limit_burst" ] && [ -n "$restart_delay" ] &&
       [ $((limit_burst * restart_delay)) -lt "$limit_window" ]'

# It runs as root from a polkit action and does everything by calling something
# else. /usr/local must be in that PATH: leaving it out made "gpsctl check"
# unable to find the proxy it had just started.
check "gpsctl pins its own PATH, /usr/local included" \
      'grep -q "^PATH=/usr/local/sbin:/usr/local/bin:" "$ROOT/gpsctl" &&
       grep -q "^export PATH" "$ROOT/gpsctl"'

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
