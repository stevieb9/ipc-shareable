#!/usr/bin/env bash
# flush_ipc.sh — remove all SysV IPC resources visible in ipcs listings.
# Removes shared memory segments, semaphore sets, and message queues.

# Usage:
#   ./scripts/flush_ipc.sh            # remove resources
#   ./scripts/flush_ipc.sh --dry-run  # show what would be removed
#   ./scripts/flush_ipc.sh -n         # short alias for --dry-run

set -euo pipefail

removed=0
failed=0
dry_run=0

case "${1:-}" in
    -n|--dry-run)
        dry_run=1
        ;;
    "")
        ;;
    *)
        echo "Usage: $0 [--dry-run|-n]" >&2
        exit 2
        ;;
esac

remove_resources() {
    local listing="$1" # ipcs listing flag: -m, -s, -q
    local cmd="$2"     # ipcrm flag: -m, -s, -q
    local label="$3"   # display label: m, s, q

    while IFS= read -r id; do
        if [[ $dry_run -eq 1 ]]; then
            echo "  Would remove $label id=$id"
            continue
        fi

        if ipcrm "$cmd" "$id" 2>/dev/null; then
            echo "  Removed $label id=$id"
            (( removed++ )) || true
        else
            echo "  Failed to remove $label id=$id (may need sudo)" >&2
            (( failed++ )) || true
        fi
    done < <(
        ipcs "$listing" | awk '
            # BSD/macOS: rows look like "m 65536 0x..."
            # Linux (util-linux): rows look like "0x... 65536 owner ..."
            # In both cases, the second field is the numeric IPC id.
            $2 ~ /^[0-9]+$/ { print $2 }
        '
    )
}

if [[ $dry_run -eq 1 ]]; then
    echo "Dry-run: showing SysV IPC resources that would be removed..."
else
    echo "Flushing SysV IPC resources..."
fi

echo "Shared memory segments:"
remove_resources -m -m m

echo "Semaphore sets:"
remove_resources -s -s s

echo "Message queues:"
remove_resources -q -q q

echo ""
if [[ $dry_run -eq 1 ]]; then
    echo "Done (dry-run)."
else
    echo "Done. Removed: $removed  Failed: $failed"
fi

if [[ $dry_run -eq 0 && $failed -gt 0 ]]; then
    echo "Re-run with sudo to remove resources owned by other users." >&2
    exit 1
fi
