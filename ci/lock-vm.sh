# lock-vm.sh — per-VM mutex to prevent concurrent test runs on the same VM.
# Source this from a *-test.sh script after $VM and $SCRIPT_DIR are set.
#
# Usage:
#   VM="${VM:-freebsd-ipc}"
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "${SCRIPT_DIR}/lock-vm.sh"
#   acquire_vm_lock
#
# The caller's cleanup / trap must call release_vm_lock to remove the lock
# file on exit (including SIGINT/SIGTERM).

acquire_vm_lock() {
    LOCKFILE="/tmp/ci-vm-${VM}.lock"

    _try_lock() {
        set -C
        { echo $$ > "$LOCKFILE"; } 2>/dev/null
        _locked=$?
        set +C
        return $_locked
    }

    while ! _try_lock; do
        if [ -f "$LOCKFILE" ]; then
            _existing_pid=$(cat "$LOCKFILE")
            if kill -0 "$_existing_pid" 2>/dev/null; then
                echo "ERROR: VM '${VM}' is already locked (${LOCKFILE}) by PID ${_existing_pid}" >&2
                echo "       If you are sure no other instance is running, remove:" >&2
                echo "         rm -f ${LOCKFILE}" >&2
                exit 1
            fi
        fi
        # Stale lock — remove and retry
        rm -f "$LOCKFILE"
    done
}

release_vm_lock() {
    rm -f "$LOCKFILE"
}
