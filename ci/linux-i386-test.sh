#!/bin/sh
# Run IPC::Shareable tests in a 32-bit i386 Linux environment via Lima/QEMU.
#
# The host VM is Debian 12 amd64 (no i386 cloud images exist for modern
# Debian).  An i386 debootstrap chroot is created inside the VM on the first
# run; subsequent runs reuse it.  Tests execute under systemd-nspawn so that
# /proc, /sys and /dev are available to the 32-bit Perl process.
#
# Usage: ./ci/linux-i386-test.sh [prove options]

set -e

VM="${VM:-linux-i386}"
HOST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
# i386 chroot path inside the VM
CHROOT="/opt/chroot-i386"
CHROOT_REPO="${CHROOT}/opt/ipc-shareable"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

XS_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  -x, --xs      Build and test with XS (default: pure Perl only)
  -h, --help      Show this help message and exit

Environment:
  VM=<name>       Target a different Lima VM (default: linux-i386)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0")                   # full suite
  $(basename "$0") t/24-clean.t     # single test file
  $(basename "$0") -v t/24-clean.t  # verbose, single file
  $(basename "$0") t                # full suite, no -v
EOF
}

_PROVE_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x|--xs)      XS_MODE=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         _PROVE_ARGS="${_PROVE_ARGS} $1"; shift ;;
    esac
done
PROVE_ARGS="${_PROVE_ARGS# }"
PROVE_ARGS="${PROVE_ARGS:--v t}"

cleanup() {
    status=$?
    echo "==> Stopping VM '${VM}'..."
    limactl stop "$VM" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    exit "$status"
}

trap cleanup EXIT INT TERM

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/linux-i386-lima.yaml"
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM"
    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

echo "==> Setting up i386 chroot (first run ~5 min, subsequent runs instant)..."
limactl shell "$VM" -- sh -lc "
    set -e
    if [ ! -f '${CHROOT}/usr/bin/perl' ]; then
        sudo apt-get update -qq
        sudo apt-get install -y debootstrap systemd-container
        sudo debootstrap --arch=i386 bookworm '${CHROOT}' http://deb.debian.org/debian/
        sudo systemd-nspawn -D '${CHROOT}' apt-get install -y perl cpanminus build-essential
    fi
    # Top-up: idempotent and cheap if already installed.  Ensures the chroot
    # has the IPC::Shareable test deps even when carried over from a previous
    # project (e.g. async-event-interval, which does not install these).
    sudo systemd-nspawn -D '${CHROOT}' cpanm --notest --quiet \\
        JSON String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval
"

echo "==> Copying source into i386 chroot..."
limactl shell "$VM" -- sh -lc "sudo rm -rf '${CHROOT_REPO}' && sudo mkdir -p '${CHROOT}/opt'"
COPYFILE_DISABLE=1 tar -C "$(dirname "$HOST_REPO")" -czf - "$(basename "$HOST_REPO")" | \
    limactl shell "$VM" -- sudo tar -C "${CHROOT}/opt" -xzf - \
        --transform "s|^$(basename "$HOST_REPO")|ipc-shareable|"
# Strip macOS resource-fork files (._*) that may have leaked through.
limactl shell "$VM" -- sudo find "${CHROOT_REPO}" -name '._*' -delete 2>/dev/null || true

echo "==> Cleaning up stale IPC segments/semaphores from previous runs..."
limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' \\
        sh -c '
            for id in \$(ipcs -m 2>/dev/null | awk \"/root/ {print \\\$2}\"); do
                ipcrm -m \$id 2>/dev/null || true
            done
            for id in \$(ipcs -s 2>/dev/null | awk \"/root/ {print \\\$2}\"); do
                ipcrm -s \$id 2>/dev/null || true
            done
        '
" || true

if [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in i386 chroot (32-bit Perl, XS)..."
    limactl shell "$VM" -- sh -lc "
        sudo systemd-nspawn -D '${CHROOT}' \\
            sh -c 'cd /opt/ipc-shareable && perl Makefile.PL && make && ASYNC_TESTING=1 PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}'"
else
    echo "==> Running tests in i386 chroot (32-bit Perl, pure Perl)..."
    limactl shell "$VM" -- sh -lc "
        sudo systemd-nspawn -D '${CHROOT}' \\
            sh -c 'cd /opt/ipc-shareable && ASYNC_TESTING=1 PERL5LIB=lib prove -l ${PROVE_ARGS}'"
fi

echo "==> IPC::Shareable version tested..."
limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' \\
        sh -c 'cd /opt/ipc-shareable && perl -Ilib -MIPC::Shareable -e \"print qq(IPC::Shareable \\\$IPC::Shareable::VERSION\\n)\"'"

echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"
