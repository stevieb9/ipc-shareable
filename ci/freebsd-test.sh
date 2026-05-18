#!/bin/sh
# Run IPC::Shareable tests in a local FreeBSD VM (Lima template).
# Usage: ./ci/freebsd-test.sh [prove options]

set -e

VM="${VM:-freebsd-local}"
PROVE_ARGS="${*:--v t}"
HOST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
GUEST_HOME="/home/${USER}.guest"
GUEST_REPO="${GUEST_HOME}/ipc-shareable"

cleanup() {
    status=$?
    echo "==> Stopping VM '${VM}'..."
    limactl stop "$VM" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    exit "$status"
}

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false template:freebsd
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM"
fi

trap cleanup EXIT INT TERM

echo "==> Installing FreeBSD packages..."
limactl shell "$VM" -- sh -lc 'sudo pkg install -y perl5 p5-App-cpanminus gmake p5-ExtUtils-MakeMaker p5-JSON p5-String-CRC32 p5-Test-SharedFork p5-Mock-Sub'

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -lc "rm -rf '${GUEST_REPO}'"
limactl copy -r "$HOST_REPO" "$VM:${GUEST_HOME}/"

echo "==> Running tests in VM..."
limactl shell "$VM" -- sh -lc "cd '${GUEST_REPO}' && CI_TESTING=1 prove -l ${PROVE_ARGS}"
