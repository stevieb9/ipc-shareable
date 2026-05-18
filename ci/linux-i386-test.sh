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
PROVE_ARGS="${*:--v t}"
HOST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
# i386 chroot path inside the VM
CHROOT="/opt/chroot-i386"
CHROOT_REPO="${CHROOT}/opt/ipc-shareable"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# Determine the actual guest home directory (Lima appends .linux on Linux VMs)
GUEST_HOME="$(limactl shell "$VM" -- sh -lc 'echo $HOME')"
GUEST_REPO="${GUEST_HOME}/ipc-shareable"

echo "==> Setting up i386 chroot (first run ~5 min, subsequent runs instant)..."
limactl shell "$VM" -- sh -lc "
    set -e
    if [ ! -f '${CHROOT}/usr/bin/perl' ]; then
        sudo apt-get update -qq
        sudo apt-get install -y debootstrap systemd-container
        sudo debootstrap --arch=i386 bookworm '${CHROOT}' http://deb.debian.org/debian/
        sudo systemd-nspawn -D '${CHROOT}' apt-get install -y perl cpanminus build-essential
        sudo systemd-nspawn -D '${CHROOT}' cpanm --notest --quiet JSON String::CRC32 Test::SharedFork Mock::Sub
    fi
"

echo "==> Copying source into i386 chroot..."
limactl shell "$VM" -- sh -lc "sudo rm -rf '${CHROOT_REPO}' && sudo mkdir -p '${CHROOT}/opt'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"
limactl shell "$VM" -- sh -lc "sudo cp -a '${GUEST_REPO}/.' '${CHROOT_REPO}/'"

echo "==> Running tests in i386 chroot (32-bit Perl)..."
limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' \\
        sh -c 'cd /opt/ipc-shareable && CI_TESTING=1 prove -l ${PROVE_ARGS}'"
