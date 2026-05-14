#!/usr/bin/env bash
# flush_ipc.sh — remove all SysV IPC resources visible in `ipcs -a`
# Removes shared memory segments, semaphore sets, and message queues.

set -euo pipefail

removed=0
failed=0

remove_resources() {
    local type="$1"   # m, s, q
    local cmd="$2"    # ipcrm flag: -m, -s, -q

    while IFS= read -r id; do
        if ipcrm "$cmd" "$id" 2>/dev/null; then
            echo "  Removed $type id=$id"
            (( removed++ )) || true
        else
            echo "  Failed to remove $type id=$id (may need sudo)" >&2
            (( failed++ )) || true
        fi
    done < <(ipcs -a | awk -v t="$type" '$1 == t { print $2 }')
}

echo "Flushing SysV IPC resources..."

echo "Shared memory segments:"
remove_resources m -m

echo "Semaphore sets:"
remove_resources s -s

echo "Message queues:"
remove_resources q -q

echo ""
echo "Done. Removed: $removed  Failed: $failed"

if [[ $failed -gt 0 ]]; then
    echo "Re-run with sudo to remove resources owned by other users." >&2
    exit 1
fi
