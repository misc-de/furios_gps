# SPDX-FileCopyrightText: Copyright (c) 2026 misc-de
# SPDX-License-Identifier: MIT
# A test harness small enough to read in one sitting.
#
# No framework on purpose: this has to run on the phone itself, where every
# extra dependency is one more thing that can be missing at the moment you
# need the tests most.

TESTS_RUN=0
TESTS_FAILED=0

ok()   { printf '  \033[32mok\033[0m   %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '       %s\n' "$2"; }

check() {
    # check <description> <expected> <actual>
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$1" "expected [$2], got [$3]"
    fi
}

check_status() {
    # check_status <description> <expected exit code> <command...>
    local desc=$1 want=$2; shift 2
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" = "$want" ]; then
        ok "$desc"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        fail "$desc" "expected exit $want, got $got"
    fi
}

# systemctl_stub <path>
# A systemctl for a sandbox home: enable and disable make and remove the
# links the way the real one does (from WantedBy=), is-enabled answers from
# those links, and it fails like the real one when a unit file is missing or
# when there is no user manager to talk to (SANDBOX_NO_BUS=1). Every call is
# logged to $SANDBOX/systemctl.log.
systemctl_stub() {
cat > "$1" <<'STUB'
#!/bin/bash
echo "$*" >> "$SANDBOX/systemctl.log"
if [ "${SANDBOX_NO_BUS:-}" = 1 ]; then
    echo "Failed to connect to bus: No medium found" >&2; exit 1
fi
user=; verb=; units=()
for a; do
    case $a in
        --user) user=1 ;;
        -*) ;;
        *) if [ -z "$verb" ]; then verb=$a; else units+=("$a"); fi ;;
    esac
done
[ -n "$user" ] || { echo "no system manager in the sandbox" >&2; exit 1; }
dir=$HOME/.config/systemd/user
case $verb in
    enable|disable)
        for u in "${units[@]}"; do
            [ -f "$dir/$u" ] || { echo "Unit file $u does not exist." >&2; exit 1; }
            if [ "$verb" = enable ]; then
                for t in $(sed -n 's/^WantedBy=//p' "$dir/$u"); do
                    mkdir -p "$dir/$t.wants"
                    ln -sf "$dir/$u" "$dir/$t.wants/$u"
                done
            else
                rm -f "$dir"/*.wants/"$u"
            fi
        done ;;
    is-enabled)
        # Word on stdout and exit status, as the real one answers.
        rc=0
        for u in "${units[@]}"; do
            if ls "$dir"/*.wants/"$u" >/dev/null 2>&1; then echo enabled
            else echo disabled; rc=1; fi
        done
        exit $rc ;;
    is-active) exit 3 ;;
esac
exit 0
STUB
    chmod +x "$1"
}

summary() {
    printf '\n  %d checks, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
    [ "$TESTS_FAILED" -eq 0 ]
}
