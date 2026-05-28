#!/bin/sh
# Run tests in a local DragonFly BSD VM (Lima/QEMU).
#
# Targets the CPAN smoker platform:
#   osname=dragonfly, archname=x86_64-dragonfly
#
# DragonFly BSD does not publish cloud images. The raw .img.bz2 release image
# is downloaded once, decompressed, converted to QCOW2, and cached at
# ~/.lima/_cache/dragonfly64.qcow2.
#
# Usage: ./ci/dragonfly-test.sh [options] [prove options]

set -e

VM="${VM:-dragonfly-ipc}"
GUEST_USER="dragonfly"
GUEST_HOME="/home/${GUEST_USER}.guest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HOST_REPO is resolved from --project below, after argument parsing,
# so that --project async-event-interval ships the aei repo (sibling
# of ipc-shareable) and --project ipc-shareable ships this repo.
CACHE_DIR="${HOME}/.lima/_cache"
CACHED_QCOW2="${CACHE_DIR}/dragonfly64.qcow2"

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
  VM=<name>         Target a different Lima VM (default: dragonfly-ipc)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0") -p ipc-shareable               # full suite, ipc-shareable
  $(basename "$0") -p async-event-interval        # full suite, aei
  $(basename "$0") -p ipc-shareable t/85-clean.t  # single test file
  $(basename "$0") -p ipc-shareable t             # full suite, no -v
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
        OTHER_DEPS="JSON String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval"
        IPC_INSTALL=""
        TEST_ENV="PRINT_SEGS=1"
        TEST_MODULE="IPC::Shareable"
        ;;
    async-event-interval)
        GUEST_REPO="${GUEST_HOME}/async-event-interval"
        OTHER_DEPS="JSON Test::SharedFork Mock::Sub Parallel::ForkManager"
        IPC_INSTALL="sudo cpanm --reinstall --notest IPC::Shareable"
        TEST_ENV=""
        TEST_MODULE="Async::Event::Interval"
        ;;
    *)
        echo "ERROR: Unknown project '${PROJECT}'. Use ipc-shareable or async-event-interval."
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

# Tests that hang under TCG emulation — they use SIGALRM + sleep for
# parent/child synchronization, which races when signal delivery is slow.
# More round-trips = more likely to hang.
SKIP_TESTS="t/28-ipchv.t t/30-ipcref.t t/38-lsync.t t/66-protected_persist.t t/85-clean.t"

_DISK="${HOME}/.lima/${VM}/disk"

cleanup() {
    status=$?
    echo "==> Stopping VM '${VM}'..."

    # Try clean SSH shutdown first (avoids fsck on next boot)
    ssh -o ConnectTimeout=5 -F ~/.lima/"$VM"/ssh.config lima-"$VM" \
        'sudo shutdown -p now' </dev/null 2>/dev/null || true

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

    # Don't save a new snapshot here — the first-boot snapshot is the
    # only reliable clean state.  Post-test snapshots can include stale
    # IPC segments, modified files, or incomplete shutdown state.

    trap - EXIT INT TERM
    exit "$status"
}

trap cleanup EXIT INT TERM

# ── check for pre-installed DragonFly QCOW2 ────────────────────────────────
#
# DragonFly BSD does not publish pre-installed cloud/VM images — only
# installer ISOs and raw .img files.  The installer cannot be used directly
# because (a) it boots into an installer prompt, not a login shell, and
# (b) Lima's 10-minute startup timeout is too short for TCG-emulated
# hardware probing during installer boot.
#
# A pre-installed DragonFly BSD QCOW2 must be created once by running the
# installer interactively in QEMU, installing to a QCOW2 disk, and
# configuring SSH + serial console.  Place the result at the path below.

if [ ! -f "$CACHED_QCOW2" ]; then
    echo "ERROR: Pre-installed DragonFly BSD QCOW2 not found at:"
    echo "       ${CACHED_QCOW2}"
    echo ""
    echo "DragonFly BSD does not provide cloud images.  A pre-installed image"
    echo "must be created manually.  See ci/README.md § DragonFly BSD CI for"
    echo "instructions on building the base image from the installer."
    exit 1
fi

# ── create VM if it doesn't exist ───────────────────────────────────────────

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/dragonfly-lima.yaml"
fi

# ── first-boot (one-time bootstrap via direct QEMU + serial console) ─────
#
# DragonFly BSD does not support cloud-init, and its kernel defaults to the
# VGA console (invisible under QEMU -display none).  dragonfly-first-boot.py
# launches QEMU directly with -nographic, interrupts the bootloader to set
# console=comconsole, performs initial setup (user, SSH key, boot-done rc.d
# service), persists the console setting in /boot/loader.conf, and halts.
# After first-boot, Lima can manage the VM normally.

_FIRST_BOOT_STAMP="${HOME}/.lima/${VM}/.first-boot-done"

if [ ! -f "$_FIRST_BOOT_STAMP" ]; then
    echo "==> Running first-boot setup (one-time)..."
    if ! python3 "${SCRIPT_DIR}/dragonfly-first-boot.py" "$VM"; then
        echo "ERROR: First-boot setup failed."
        echo "==> Cleaning up failed VM..."
        limactl stop --force "$VM" 2>/dev/null || true
        limactl delete --force "$VM" 2>/dev/null || true
        echo "Re-run this script to retry from a fresh VM."
        exit 1
    fi
    touch "$_FIRST_BOOT_STAMP"

    # Take initial clean snapshot after first-boot (VM was halted cleanly)
    qemu-img snapshot -c clean "$_DISK" 2>/dev/null || true

    echo "==> First-boot complete."
fi

# ── start VM ──────────────────────────────────────────────────────────────

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    # Revert to last clean snapshot so fsck never runs on boot
    if qemu-img snapshot -l "$_DISK" 2>/dev/null | grep -q '\bclean\b'; then
        echo "==> Reverting to clean snapshot..."
        qemu-img snapshot -a clean "$_DISK" 2>/dev/null || true
    fi

    echo "==> Starting VM '${VM}'..."
    limactl start "$VM"

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

# ── install Perl dependencies ───────────────────────────────────────────────

echo "==> Installing Perl dependencies via pkg and cpanm..."
limactl shell "$VM" -- sh -c "
    sudo pkg install -y perl5 p5-App-cpanminus gmake 2>&1

    sudo cpanm --notest ${OTHER_DEPS} 2>&1
    ${IPC_INSTALL} 2>&1
"

# ── copy source into VM ─────────────────────────────────────────────────────

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -c "rm -rf '${GUEST_REPO}'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"
# Strip macOS resource-fork files (._*).
limactl shell "$VM" -- sh -c "find '${GUEST_REPO}' -name '._*' -delete" \
    2>/dev/null || true

# ── clean up stale IPC from previous runs ────────────────────────────────────

echo "==> Cleaning up stale IPC segments/semaphores from previous runs..."
# DragonFly's ipcs -m format is: <shmid> <hex_key> <owner> ... (shmid in col 1).
# This differs from Linux (key in col 1, shmid in col 2) and BSD (m in col 1,
# shmid in col 2).  Use \$1 to grab the shmid.
limactl shell "$VM" -- sh -c "
    for id in \$(ipcs -m 2>/dev/null | awk '/${GUEST_USER}/ && \$1 ~ /^[0-9]+\$/ {print \$1}'); do
        ipcrm -m \$id 2>/dev/null || true
    done
    for id in \$(ipcs -s 2>/dev/null | awk '/${GUEST_USER}/ && \$1 ~ /^[0-9]+\$/ {print \$1}'); do
        ipcrm -s \$id 2>/dev/null || true
    done
" || true

# ── run tests ───────────────────────────────────────────────────────────────

# If running the default full suite, exclude tests that hang under TCG
if [ "$PROVE_ARGS" = "-v t" ] && [ -n "$SKIP_TESTS" ]; then
    _TEST_FILES=""
    for f in t/*.t; do
        _skip=0
        for s in $SKIP_TESTS; do
            [ "$f" = "$s" ] && _skip=1 && break
        done
        [ "$_skip" -eq 0 ] && _TEST_FILES="$_TEST_FILES $f"
    done
    PROVE_ARGS="-v${_TEST_FILES}"
    echo "==> Skipping under TCG: ${SKIP_TESTS}"
fi

_test_rc=0
if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in VM (XS)..."
    limactl shell "$VM" -- sh -c \
        "cd '${GUEST_REPO}' && perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}" \
        || _test_rc=$?
else
    echo "==> Running tests in VM (pure Perl)..."
    limactl shell "$VM" -- sh -c \
        "cd '${GUEST_REPO}' && ${TEST_ENV} PERL5LIB=lib prove -l ${PROVE_ARGS}" \
        || _test_rc=$?
fi

_VERSION=$(limactl shell "$VM" -- sh -c "perl -I'${GUEST_REPO}/lib' -M${TEST_MODULE} -e 'print qq(${TEST_MODULE} \${TEST_MODULE}::VERSION\n)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION=$(limactl shell "$VM" -- sh -c "perl -MIPC::Shareable -e 'print qq(\$IPC::Shareable::VERSION)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION="${_IPC_SHAREABLE_VERSION:-N/A}"
_OS_INFO=$(limactl shell "$VM" -- sh -c 'uname -a' 2>/dev/null)
_PERL_VERSION=$(limactl shell "$VM" -- sh -c "perl -e 'printf qq(%vd\n), \$^V'" 2>/dev/null)

echo ""
echo "==> Project: ${PROJECT}"
echo "==> Tested: ${_VERSION}"
echo "==> IPC::Shareable installed: ${_IPC_SHAREABLE_VERSION}"
echo "==> VM: ${VM}"
echo "==> OS Version: ${_OS_INFO}"
echo "==> Perl version: ${_PERL_VERSION}"
echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"

exit $_test_rc