#!/bin/sh
# Run tests in a local OpenBSD VM (Lima/QEMU).
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
GUEST_USER="vagrant"
GUEST_HOME="/home/${GUEST_USER}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HOST_REPO is resolved from --project below, after argument parsing,
# so that --project async-event-interval ships the aei repo (sibling
# of ipc-shareable) and --project ipc-shareable ships this repo.
CACHE_DIR="${HOME}/.lima/_cache"
CACHED_QCOW2="${CACHE_DIR}/openbsd7.qcow2"

BOX_URL="https://vagrantcloud.com/generic/boxes/openbsd7/versions/4.3.12/providers/qemu/amd64/vagrant.box"
BOX_CHECKSUM="d7049b92338162c552c147f4647dc3ee44546b7dc44e7e9c4652ae332c06aad1"

PROJECT=""
XS_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  --project <name>  Project to test: ipc-shareable (default) or
                    async-event-interval
  -x, --xs          Build and test with XS (default: pure Perl only,
                    ipc-shareable only)
  -h, --help        Show this help message and exit

Environment:
  VM=<name>         Target a different Lima VM (default: openbsd-ipc)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0")                                # full suite, ipc-shareable
  $(basename "$0") --project async-event-interval # full suite, aei
  $(basename "$0") t/85-clean.t                   # single test file
  $(basename "$0") t                              # full suite, no -v
EOF
}

_PROVE_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project) shift; PROJECT="$1"; shift ;;
        -x|--xs)      XS_MODE=1; shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            _PROVE_ARGS="${_PROVE_ARGS} $1"; shift ;;
    esac
done
PROVE_ARGS="${_PROVE_ARGS# }"
PROVE_ARGS="${PROVE_ARGS:--v t}"

if [ -z "$PROJECT" ]; then
    echo "ERROR: --project is required. Use ipc-shareable or async-event-interval."
    usage
    exit 1
fi

case "$PROJECT" in
    ipc-shareable)
        GUEST_REPO="${GUEST_HOME}/ipc-shareable"
        OTHER_DEPS="String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval"
        IPC_INSTALL=""
        TEST_ENV="ASYNC_TESTING=1"
        TEST_MODULE="IPC::Shareable"
        ;;
    async-event-interval)
        GUEST_REPO="${GUEST_HOME}/async-event-interval"
        OTHER_DEPS="Test::SharedFork Mock::Sub Parallel::ForkManager"
        IPC_INSTALL="github"   # OpenBSD tar can't handle CPAN tarballs
        TEST_ENV=""
        TEST_MODULE="Async::Event::Interval"
        ;;
    *)
        echo "ERROR: Unknown project '${PROJECT}'. Use ipc-shareable or async-event-interval."
        usage
        exit 1
        ;;
esac

# Resolve HOST_REPO from --project: both repos must be siblings under the
# same parent directory (the grandparent of this CI script). This ensures
# the LOCAL copy of the selected project is shipped into the VM, not a
# CPAN release or the other repo's source.
HOST_REPO="$(cd "${SCRIPT_DIR}/../.." && pwd)/${PROJECT}"
if [ ! -d "$HOST_REPO" ]; then
    echo "ERROR: Could not find project '${PROJECT}' at ${HOST_REPO}"
    echo "       Both repos must live as siblings under $(dirname "$HOST_REPO")/"
    exit 1
fi

cleanup() {
    status=$?
    echo "==> Stopping VM '${VM}'..."

    # Try clean SSH shutdown first (avoids fsck on next boot)
    ssh -o ConnectTimeout=5 -F ~/.lima/"$VM"/ssh.config lima-"$VM" \
        'doas shutdown -h now' </dev/null 2>/dev/null || true

    # Wait for VM to power off
    _clean_shutdown=0
    for _i in $(seq 1 12); do
        limactl list 2>/dev/null | grep -q "^${VM}[[:space:]].*Running" || {
            _clean_shutdown=1; break; }
        sleep 5
    done

    # If still running, try limactl stop (ACPI) then force-stop
    if [ "$_clean_shutdown" -eq 0 ]; then
        echo "==> VM still running, trying Lima stop..."
        limactl stop "$VM" >/dev/null 2>&1 || true
        for _i in $(seq 1 6); do
            limactl list 2>/dev/null | grep -q "^${VM}[[:space:]].*Running" || {
                _clean_shutdown=1; break; }
            sleep 5
        done
    fi
    if [ "$_clean_shutdown" -eq 0 ]; then
        echo "==> Force-stopping VM..."
        limactl stop --force "$VM" >/dev/null 2>&1 || true
    fi

    # Save clean QCOW2 snapshot for fast recovery next run
    if [ "$_clean_shutdown" -eq 1 ]; then
        _DISK="${HOME}/.lima/${VM}/disk"
        echo "==> Saving clean VM snapshot..."
        qemu-img snapshot -c clean "$_DISK" 2>/dev/null || true
    fi

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

    # Take initial clean snapshot after first-boot (VM was halted cleanly)
    _DISK="${HOME}/.lima/${VM}/disk"
    qemu-img snapshot -c clean "$_DISK" 2>/dev/null || true

    echo "==> First-boot setup complete."
fi

# ── start VM ────────────────────────────────────────────────────────────────

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    _DISK="${HOME}/.lima/${VM}/disk"

    # Revert to last clean snapshot so fsck never runs on boot
    if qemu-img snapshot -l "$_DISK" 2>/dev/null | grep -q '\bclean\b'; then
        echo "==> Reverting to clean snapshot..."
        qemu-img snapshot -a clean "$_DISK" 2>/dev/null || true
    fi

    echo "==> Starting VM '${VM}'..."
    limactl start "$VM" &
    _LIMA_PID=$!

    # Monitor serial log for boot progress (fsck can be slow on TCG)
    _SERIAL_LOG="${HOME}/.lima/${VM}/serial.log"
    _FS_WARNED=0
    _ELAPSED=0
    echo "==> Waiting for VM to be ready..."
    while kill -0 $_LIMA_PID 2>/dev/null; do
        sleep 10
        _ELAPSED=$(( _ELAPSED + 10 ))
        if [ "$_FS_WARNED" = "0" ] && [ -f "$_SERIAL_LOG" ] \
            && grep -q 'fsck' "$_SERIAL_LOG" 2>/dev/null
        then
            echo "    ...fsck in progress (unclean shutdown); this may take a while on TCG"
            _FS_WARNED=1
        fi
        [ $(( _ELAPSED % 60 )) -eq 0 ] && \
            printf "    ...%d min elapsed\n" $(( _ELAPSED / 60 ))
    done
    wait "$_LIMA_PID" 2>/dev/null

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

# ── install Perl dependencies ───────────────────────────────────────────────

echo "==> Installing Perl dependencies via CPAN (OpenBSD packages offline)..."
limactl shell "$VM" -- sh -lc "
    sudo cpan -T ${OTHER_DEPS} 2>&1
"

if [ "${IPC_INSTALL}" = "github" ]; then
    # IPC::Shareable: install from GitHub because OpenBSD tar(1)
    # cannot handle PAX extended headers in modern CPAN tarballs.
    echo "==> Installing IPC::Shareable from GitHub (OpenBSD tar PAX workaround)..."
    limactl shell "$VM" -- sh -lc '
        IPC_URL="https://github.com/stevieb9/ipc-shareable/archive/refs/heads/master.zip"
        IPC_DIR="/tmp/ipc-shareable-install"
        rm -rf "$IPC_DIR" /tmp/ipc-shareable-master
        mkdir -p "$IPC_DIR"
        curl -fsSL -o "$IPC_DIR/master.zip" "$IPC_URL"
        unzip -qo "$IPC_DIR/master.zip" -d /tmp
        cd /tmp/ipc-shareable-master
        sudo perl Makefile.PL 2>&1
        sudo make 2>&1
        sudo make install 2>&1
        rm -rf "$IPC_DIR" /tmp/ipc-shareable-master
    '
fi

# ── copy source into VM ─────────────────────────────────────────────────────

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -lc "rm -rf '${GUEST_REPO}'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"
# Strip macOS resource-fork files (._*).
limactl shell "$VM" -- sh -lc "find '${GUEST_REPO}' -name '._*' -delete" \
    2>/dev/null || true

# ── clean up stale IPC from previous runs ────────────────────────────────────

echo "==> Cleaning up stale IPC segments/semaphores from previous runs..."
limactl shell "$VM" -- sh -lc "
    for id in \$(ipcs -m 2>/dev/null | awk '/${GUEST_USER}/ {print \$2}'); do
        ipcrm -m \$id 2>/dev/null || true
    done
    for id in \$(ipcs -s 2>/dev/null | awk '/${GUEST_USER}/ {print \$2}'); do
        ipcrm -s \$id 2>/dev/null || true
    done
" || true

# ── run tests ───────────────────────────────────────────────────────────────

_test_rc=0
if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in VM (XS)..."
    limactl shell "$VM" -- sh -lc \
        "cd '${GUEST_REPO}' && perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}" \
        || _test_rc=$?
else
    echo "==> Running tests in VM (pure Perl)..."
    limactl shell "$VM" -- sh -lc \
        "cd '${GUEST_REPO}' && ${TEST_ENV} PERL5LIB=lib prove -l ${PROVE_ARGS}" \
        || _test_rc=$?
fi

_VERSION=$(limactl shell "$VM" -- sh -lc "perl -I'${GUEST_REPO}/lib' -M${TEST_MODULE} -e 'print qq(${TEST_MODULE} \${TEST_MODULE}::VERSION\n)'" 2>/dev/null)
_OS_INFO=$(limactl shell "$VM" -- sh -lc 'uname -a' 2>/dev/null)
_PERL_VERSION=$(limactl shell "$VM" -- sh -lc "perl -e 'printf qq(%vd\n), \$^V'" 2>/dev/null)

echo ""
echo "==> Project: ${PROJECT}"
echo "==> Tested: ${_VERSION}"
echo "==> VM: ${VM}"
echo "==> OS Version: ${_OS_INFO}"
echo "==> Perl version: ${_PERL_VERSION}"
echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"

exit $_test_rc
