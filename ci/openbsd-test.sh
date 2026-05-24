#!/bin/sh
# Run IPC::Shareable tests in a local OpenBSD VM (Lima/QEMU).
#
# Targets the CPAN smoker platform:
#   osname=openbsd, osvers=7.8, archname=OpenBSD.amd64-openbsd
#
# Uses the generic/openbsd7 Vagrant box (Roboxes) as the base image.
# The QCOW2 is extracted once and cached at ~/.lima/_cache/openbsd7.qcow2.
#
# Usage: ./ci/openbsd-test.sh [options] [prove options]

set -e

VM="${VM:-openbsd-ipc}"
HOST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
GUEST_USER="vagrant"
GUEST_HOME="/home/${GUEST_USER}"
GUEST_REPO="${GUEST_HOME}/ipc-shareable"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CACHE_DIR="${HOME}/.lima/_cache"
CACHED_QCOW2="${CACHE_DIR}/openbsd7.qcow2"

BOX_URL="https://vagrantcloud.com/generic/boxes/openbsd7/versions/4.3.12/providers/qemu/amd64/vagrant.box"
BOX_CHECKSUM="d7049b92338162c552c147f4647dc3ee44546b7dc44e7e9c4652ae332c06aad1"

LOCALE="en_US.UTF-8"
XS_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  -x, --xs      Build and test with XS (default: pure Perl only)
  -h, --help    Show this help message and exit

Environment:
  VM=<name>     Target a different Lima VM (default: openbsd-ipc)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0")                  # full suite
  $(basename "$0") t/85-clean.t    # single test file
  $(basename "$0") t               # full suite, no -v
EOF
}

_PROVE_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -x|--xs)      XS_MODE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            _PROVE_ARGS="${_PROVE_ARGS} $1"; shift ;;
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

# ── one-time: download Vagrant box and extract QCOW2 ────────────────────────

if [ ! -f "$CACHED_QCOW2" ]; then
    echo "==> Downloading generic/openbsd7 Vagrant box (one-time)..."
    mkdir -p "$CACHE_DIR"
    BOX_TMP="/tmp/openbsd7-vagrant.box"
    curl -fsSL -o "$BOX_TMP" "$BOX_URL"

    # Verify checksum
    ACTUAL=$( (shasum -a 256 "$BOX_TMP" 2>/dev/null || sha256sum "$BOX_TMP" 2>/dev/null) | awk '{print $1}')
    if [ -n "$ACTUAL" ] && [ "$ACTUAL" != "$BOX_CHECKSUM" ]; then
        echo "WARNING: checksum mismatch (expected ${BOX_CHECKSUM}, got ${ACTUAL})"
    fi

    echo "==> Extracting QCOW2 from Vagrant box..."
    EXTRACT_DIR="/tmp/openbsd7-extract"
    rm -rf "$EXTRACT_DIR"
    mkdir -p "$EXTRACT_DIR"
    tar xzf "$BOX_TMP" -C "$EXTRACT_DIR" box.img

    # Convert to a compact QCOW2 (the box.img is already QCOW2; copy and
    # shrink to save space).
    echo "==> Optimising QCOW2 image..."
    qemu-img convert -O qcow2 -c "$EXTRACT_DIR/box.img" "$CACHED_QCOW2" 2>/dev/null \
        || cp "$EXTRACT_DIR/box.img" "$CACHED_QCOW2"

    rm -f "$BOX_TMP"
    rm -rf "$EXTRACT_DIR"
    echo "==> QCOW2 cached at ${CACHED_QCOW2}"
fi

# ── create VM if it doesn't exist ───────────────────────────────────────────

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/openbsd-lima.yaml"
fi

# ── first-boot setup (one-time, requires direct QEMU for serial console) ──

_FB_SENTINEL="${HOME}/.lima/${VM}/.first-boot-done"

if [ ! -f "$_FB_SENTINEL" ]; then
    echo "==> First-boot setup (one-time)..."

    # Ensure any previous Lima-managed QEMU is stopped so our direct QEMU
    # can use the disk.
    limactl stop --force "$VM" >/dev/null 2>&1 || true
    # Lima deletes socket files on stop; recreate the cidata.iso which
    # Lima creates on create.  We need Lima's ssh.config for the instance
    # ID extraction.
    if [ ! -f "${HOME}/.lima/${VM}/cidata.iso" ]; then
        echo "ERROR: cidata.iso not found; VM may not have been created"
        exit 1
    fi

    python3 "${SCRIPT_DIR}/openbsd-first-boot.py" "$VM"
    touch "$_FB_SENTINEL"
    echo "==> First-boot setup complete."
fi

# ── start VM ────────────────────────────────────────────────────────────────

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM"

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

# ── install Perl dependencies ───────────────────────────────────────────────

echo "==> Installing Perl dependencies via CPAN (OpenBSD 7.4 packages offline)..."
limactl shell "$VM" -- sh -lc '
    sudo cpan -T String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval 2>&1
'

# ── copy source into VM ─────────────────────────────────────────────────────

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -lc "rm -rf '${GUEST_REPO}'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"
# Strip macOS resource-fork files (._*).
limactl shell "$VM" -- sh -lc "find '${GUEST_REPO}' -name '._*' -delete" \
    2>/dev/null || true

# ── run tests ───────────────────────────────────────────────────────────────

if [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in VM (XS)..."
    limactl shell "$VM" -- sh -lc \
        "cd '${GUEST_REPO}' && perl Makefile.PL && make && ASYNC_TESTING=1 prove -l -Iblib/arch ${PROVE_ARGS}"
else
    echo "==> Running tests in VM (pure Perl)..."
    limactl shell "$VM" -- sh -lc \
        "cd '${GUEST_REPO}' && ASYNC_TESTING=1 prove -l ${PROVE_ARGS}"
fi

echo "==> VM environment info..."
limactl shell "$VM" -- sh -lc "uname -a; perl -V:archname"

echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"
