#!/bin/sh
# Run IPC::Shareable tests in a local OmniOS CE VM (Lima/QEMU).
#
# Targets the CPAN smoker platform:
#   osname=solaris, osvers=2.11, archname=i86pc-solaris-64
#
# Usage: ./ci/solaris-test.sh [prove options]

set -e

VM="${VM:-solaris-ipc}"
HOST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
GUEST_USER="solaris"
GUEST_HOME="/export/home/${GUEST_USER}.guest"
GUEST_REPO="${GUEST_HOME}/ipc-shareable"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  -h, --help      Show this help message and exit

Environment:
  VM=<name>       Target a different Lima VM (default: solaris-ipc)

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
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/solaris-lima.yaml"
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM" &
    _LIMA_PID=$!

    # OmniOS cloud images do not run Lima's cloud-init, so SSH and the
    # boot-done marker are set up via the serial console.  Poll for SSH;
    # if it isn't available after 60 s, run solaris-first-boot.py.
    # Subsequent starts are fast (the SMF service writes the marker).
    _SSH_OK=0
    for _I in $(seq 1 20); do
        if ssh -F ~/.lima/"$VM"/ssh.config lima-"$VM" true 2>/dev/null; then
            _SSH_OK=1; break
        fi
        sleep 3
    done

    if [ "$_SSH_OK" = "0" ]; then
        echo "==> SSH unavailable – running first-boot setup (one-time, slow on TCG)..."
        python3 "${SCRIPT_DIR}/solaris-first-boot.py" "$VM"
    fi

    wait "$_LIMA_PID" || true

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

# If sudo is missing the VM predates the first-boot install step; redo it.
if ! limactl shell "$VM" -- sh -lc 'command -v sudo >/dev/null 2>&1'; then
    echo "==> sudo not found – running first-boot setup..."
    python3 "${SCRIPT_DIR}/solaris-first-boot.py" "$VM"
fi

echo "==> Installing OmniOS packages and CPAN deps..."
limactl shell "$VM" -- sh -lc '
    set -e
    # System packages (pkg is idempotent for already-installed packages)
    sudo pkg install --accept -q \
        runtime/perl developer/gcc14 developer/build/gnu-make \
        system/management/sudo web/curl 2>&1 | grep -v "^$" || true

    # cpanm (skip if already installed)
    command -v cpanm >/dev/null 2>&1 || {
        curl -sL https://cpanmin.us -o /tmp/cpanm.pl
        sudo perl /tmp/cpanm.pl App::cpanminus
    }

    # CPAN deps — use gmake so ExtUtils::MakeMaker gets GNU make
    sudo env MAKE=gmake cpanm --notest \
        JSON String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval
'

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -lc "rm -rf '${GUEST_REPO}'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"

echo "==> Running tests in VM..."
limactl shell "$VM" -- sh -lc "
    export PATH=/usr/gnu/bin:/usr/bin:\$PATH
    cd '${GUEST_REPO}' && ASYNC_TESTING=1 prove -l ${PROVE_ARGS}
"
