#!/bin/sh
# Run IPC::Shareable tests across multiple VMs and summarize results.
#
# Usage: ./ci/vm-tests.sh [-f] [-l] [-s] [-a] [-k] [-h] [prove options]
#
#   -f, --freebsd     Run FreeBSD tests
#   -l, --linux       Run 32-bit Linux (i386) tests
#   -o, --openbsd     Run OpenBSD tests
#   -s, --solaris     Run Solaris/OmniOS tests
#   -d, --dragonfly   Run DragonFly BSD tests
#   -a, --all         Run all VMs (default)
#   -k, --keep-logs   Keep log files (default: deleted after run)
#   -h, --help        Show this help and exit
#
# Prove options are forwarded to each VM test script (default: -v t).
# Logs: /tmp/vm-tests-<timestamp>/  (deleted on exit unless -k given).
# A summary with failed test details is printed after all runs complete.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
LOGDIR="/tmp/vm-tests-${TIMESTAMP}"
RESULTS_DIR=$(mktemp -d /tmp/vm-tests-status-XXXXXX)
KEEP_LOGS=0
XS_MODE=0
DISPLAY_MODE=0

# Clean up status tempdir on exit; optionally keep logdir.
cleanup() {
    rm -rf "$RESULTS_DIR"
    if [ "$KEEP_LOGS" -eq 0 ] && [ -d "$LOGDIR" ]; then
        rm -rf "$LOGDIR"
    fi
}
trap cleanup EXIT

RUN_FREEBSD=0
RUN_LINUX=0
RUN_OPENBSD=0
RUN_SOLARIS=0
RUN_DRAGONFLY=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  -f, --freebsd     Run FreeBSD tests
  -l, --linux       Run 32-bit Linux (i386) tests
  -o, --openbsd     Run OpenBSD tests
  -s, --solaris     Run Solaris/OmniOS tests
  -d, --dragonfly   Run DragonFly BSD tests
  -a, --all         Run all VMs (default)
  -k, --keep-logs   Keep log files after the run (default: delete on success)
  -x, --xs          Build and test with XS on each VM (default: pure Perl only)
  -D, --display     Write output directly to stdout instead of log files
  -h, --help        Show this help and exit

Prove options are forwarded to each VM test script (default: -v t).
Output from each run is logged under /tmp/vm-tests-<timestamp>/.

Examples:
  $(basename "$0")                       # all VMs, full suite
  $(basename "$0") -s                    # Solaris only
  $(basename "$0") -f -l t/20-lock.t     # FreeBSD + Linux, single test
  $(basename "$0") -ks                   # Solaris only, keep logs
EOF
}

_PROVE_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -f|--freebsd)  RUN_FREEBSD=1; shift ;;
        -l|--linux)    RUN_LINUX=1; shift ;;
        -o|--openbsd)  RUN_OPENBSD=1; shift ;;
        -s|--solaris)  RUN_SOLARIS=1; shift ;;
        -d|--dragonfly) RUN_DRAGONFLY=1; shift ;;
        -a|--all)      RUN_FREEBSD=1; RUN_LINUX=1; RUN_OPENBSD=1; RUN_SOLARIS=1; RUN_DRAGONFLY=1; shift ;;
        -k|--keep-logs) KEEP_LOGS=1; shift ;;
        -x|--xs)       XS_MODE=1; shift ;;
        -D|--display)  DISPLAY_MODE=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             _PROVE_ARGS="${_PROVE_ARGS} $1"; shift ;;
    esac
done

if [ $RUN_FREEBSD -eq 0 ] && [ $RUN_LINUX -eq 0 ] && [ $RUN_OPENBSD -eq 0 ] && [ $RUN_SOLARIS -eq 0 ] && [ $RUN_DRAGONFLY -eq 0 ]; then
    RUN_FREEBSD=1; RUN_LINUX=1; RUN_OPENBSD=1; RUN_SOLARIS=1; RUN_DRAGONFLY=1
fi

PROVE_ARGS="${_PROVE_ARGS# }"
XS_FLAG=""
[ $XS_MODE -eq 1 ] && XS_FLAG="--xs"
[ $DISPLAY_MODE -eq 0 ] && mkdir -p "$LOGDIR"

# ── helpers ──────────────────────────────────────────────────────────────────

run_vm() {
    _label="$1"
    _script="$2"
    _log="${LOGDIR}/${_label}-${TIMESTAMP}.log"

    echo ""
    echo "=== ${_label}: starting at $(date) ==="

    if [ $DISPLAY_MODE -eq 1 ]; then
        if "${SCRIPT_DIR}/${_script}" ${XS_FLAG} ${PROVE_ARGS}; then
            echo "PASS" > "${RESULTS_DIR}/${_label}"
            echo "    ${_label}: PASS"
        else
            _rc=$?
            echo "FAIL:${_rc}" > "${RESULTS_DIR}/${_label}"
            echo "    ${_label}: FAIL (exit ${_rc})"
        fi
    else
        echo "    log: ${_log}"
        if "${SCRIPT_DIR}/${_script}" ${XS_FLAG} ${PROVE_ARGS} >"${_log}" 2>&1; then
            echo "PASS" > "${RESULTS_DIR}/${_label}"
            echo "    ${_label}: PASS"
        else
            _rc=$?
            echo "FAIL:${_rc}" > "${RESULTS_DIR}/${_label}"
            echo "    ${_label}: FAIL (exit ${_rc})"
        fi
    fi
}

extract_failures() {
    _log="$1"
    [ -f "$_log" ] || return

    # Individual test failures (e.g. "t/foo.t .... 1/5 FAILED")
    grep -E 'FAILED|^t/.*FAIL' "$_log" 2>/dev/null || true

    # Prove's Test Summary Report section
    if grep -q 'Test Summary Report' "$_log" 2>/dev/null; then
        echo ""
        sed -n '/^Test Summary Report/,/^$/p' "$_log" | head -40
    fi
}

print_result() {
    _label="$1"
    _status_file="${RESULTS_DIR}/${_label}"
    if [ -f "$_status_file" ]; then
        _status=$(cat "$_status_file")
        case "$_status" in
            PASS) printf "  %-12s PASS\n" "$_label" ;;
            FAIL:*) printf "  %-12s FAIL (exit %s)\n" "$_label" "${_status#FAIL:}" ;;
        esac
    else
        printf "  %-12s SKIPPED\n" "$_label"
    fi
}

# ── run ──────────────────────────────────────────────────────────────────────

echo "=== vm-tests.sh started at $(date) ==="
echo "    prove args: ${PROVE_ARGS:--v t}"
echo "    mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"
if [ $DISPLAY_MODE -eq 1 ]; then
    echo "    output: stdout (display mode)"
else
    echo "    logs: ${LOGDIR}/"
fi
printf "    targets: "
[ $RUN_FREEBSD -eq 1 ]   && printf "freebsd "
[ $RUN_LINUX -eq 1 ]     && printf "linux-i386 "
[ $RUN_OPENBSD -eq 1 ]   && printf "openbsd "
[ $RUN_SOLARIS -eq 1 ]   && printf "solaris "
[ $RUN_DRAGONFLY -eq 1 ] && printf "dragonfly"
echo ""

OVERALL=0

if [ $RUN_FREEBSD -eq 1 ]; then
    run_vm "freebsd" "freebsd-test.sh" || OVERALL=1
fi

if [ $RUN_LINUX -eq 1 ]; then
    run_vm "linux-i386" "linux-i386-test.sh" || OVERALL=1
fi

if [ $RUN_OPENBSD -eq 1 ]; then
    run_vm "openbsd" "openbsd-test.sh" || OVERALL=1
fi

if [ $RUN_SOLARIS -eq 1 ]; then
    run_vm "solaris" "solaris-test.sh" || OVERALL=1
fi

if [ $RUN_DRAGONFLY -eq 1 ]; then
    run_vm "dragonfly" "dragonfly-test.sh" || OVERALL=1
fi

# ── summary ──────────────────────────────────────────────────────────────────

echo ""
echo "============================================================"
echo " RESULTS SUMMARY"
echo "============================================================"
echo ""

for _label in freebsd linux-i386 openbsd solaris dragonfly; do
    print_result "$_label"
done

if [ $DISPLAY_MODE -eq 0 ]; then
    _any_failures=0
    for _label in freebsd linux-i386 openbsd solaris dragonfly; do
        _status_file="${RESULTS_DIR}/${_label}"
        [ -f "$_status_file" ] || continue
        case "$(cat "$_status_file")" in
            FAIL:*)
                _any_failures=1
                _log="${LOGDIR}/${_label}-${TIMESTAMP}.log"
                echo ""
                echo "--- ${_label} failures ---"
                extract_failures "$_log"
                ;;
        esac
    done

    if [ $_any_failures -eq 0 ]; then
        echo "All selected VMs passed."
    fi
else
    echo ""
    for _label in freebsd linux-i386 openbsd solaris dragonfly; do
        _status_file="${RESULTS_DIR}/${_label}"
        [ -f "$_status_file" ] || continue
        case "$(cat "$_status_file")" in
            FAIL:*)
                echo "--- ${_label}: failures shown above ---"
                ;;
        esac
    done
fi

echo ""
if [ $DISPLAY_MODE -eq 1 ]; then
    echo "Output: stdout (display mode)"
else
    if [ "$KEEP_LOGS" -eq 1 ]; then
        echo "Logs kept: ${LOGDIR}/"
    else
        echo "Logs: ${LOGDIR}/ (deleted on exit; use -k to keep)"
    fi
fi
echo "Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"
echo "=== vm-tests.sh finished at $(date) ==="

exit $OVERALL
