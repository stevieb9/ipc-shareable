#!/bin/sh
# Run tests in a 32-bit i386 Linux environment via Lima/QEMU.
#
# The host VM is Debian 12 amd64 (no i386 cloud images exist for modern
# Debian).  An i386 debootstrap chroot is created inside the VM on the first
# run; subsequent runs reuse it.  Tests execute under systemd-nspawn so that
# /proc, /sys and /dev are available to the 32-bit Perl process.
#
# Usage: ./ci/linux-i386-test.sh [options] [prove options]

set -e

VM="${VM:-linux-i386}"
# i386 chroot path inside the VM
CHROOT="/opt/chroot-i386"

# BSD tar (macOS) honours --no-mac-metadata; GNU tar (Linux) rejects it.
case "$(uname -s)" in
    Darwin) TAR_NO_META='--no-mac-metadata' ;;
    *)      TAR_NO_META='' ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HOST_REPO is resolved from --project below, after argument parsing,
# so that --project async-event-interval ships the aei repo (sibling
# of ipc-shareable) and --project ipc-shareable ships this repo.

. "${SCRIPT_DIR}/lock-vm.sh"
acquire_vm_lock

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
  VM=<name>         Target a different Lima VM (default: linux-i386)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0") -p ipc-shareable               # full suite, ipc-shareable
  $(basename "$0") -p async-event-interval        # full suite, aei
  $(basename "$0") -p ipc-shareable t/24-clean.t  # single test file
  $(basename "$0") -p ipc-shareable -v t/24-clean.t  # verbose, single file
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
        CHROOT_REPO="${CHROOT}/opt/ipc-shareable"
        OTHER_DEPS="JSON String::CRC32 Test::SharedFork Mock::Sub Async::Event::Interval"
        IPC_INSTALL=""
        TEST_ENV="ASYNC_TESTING=1"
        TEST_MODULE="IPC::Shareable"
        ;;
    async-event-interval)
        CHROOT_REPO="${CHROOT}/opt/async-event-interval"
        OTHER_DEPS="Test::SharedFork Mock::Sub Parallel::ForkManager"
        IPC_INSTALL="sudo systemd-nspawn -D '${CHROOT}' cpanm --reinstall --notest --quiet IPC::Shareable"
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

sigint_handler() {
    trap - EXIT INT TERM
    echo "==> Force-stopping VM '${VM}' (SIGINT)..."
    limactl stop --force "$VM" 2>/dev/null || true
    release_vm_lock
    exit 130
}

cleanup() {
    trap - EXIT INT TERM
    status=$?
    echo "==> Stopping VM '${VM}'..."
    limactl stop "$VM" >/dev/null 2>&1 || true
    release_vm_lock
    exit "$status"
}

trap sigint_handler INT
trap cleanup EXIT TERM

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/linux-i386-lima.yaml"
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM"
    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
else
    echo "==> VM '${VM}' is already running"
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
    # has the correct test deps even when carried over from a previous project.
    sudo systemd-nspawn -D '${CHROOT}' cpanm --notest --quiet \\
        ${OTHER_DEPS}
    ${IPC_INSTALL}
"

echo "==> Copying source into i386 chroot..."
limactl shell "$VM" -- sh -lc "sudo rm -rf '${CHROOT_REPO}' && sudo mkdir -p '${CHROOT}/opt'"
COPYFILE_DISABLE=1 tar --no-xattrs ${TAR_NO_META} \
        -C "$(dirname "$HOST_REPO")" -czf - "$(basename "$HOST_REPO")" | \
    limactl shell "$VM" -- sudo tar -C "${CHROOT}/opt" -xzf - \
        --transform "s|^$(basename "$HOST_REPO")|${PROJECT}|"
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

_test_rc=0
if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in i386 chroot (32-bit Perl, XS)..."
    limactl shell "$VM" -- sh -lc "
        sudo systemd-nspawn -D '${CHROOT}' --quiet \
            sh -c 'cd /opt/${PROJECT} && perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}'" \
        || _test_rc=$?
else
    echo "==> Running tests in i386 chroot (32-bit Perl, pure Perl)..."
    limactl shell "$VM" -- sh -lc "
        sudo systemd-nspawn -D '${CHROOT}' --quiet \
            sh -c 'cd /opt/${PROJECT} && ${TEST_ENV} PERL5LIB=lib prove -l ${PROVE_ARGS}'" \
        || _test_rc=$?
fi

_VERSION=$(limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' --quiet \
        sh -c 'perl -I/opt/${PROJECT}/lib -M${TEST_MODULE} -e \"print qq(${TEST_MODULE} \\\$${TEST_MODULE}::VERSION\\n)\"'" 2>/dev/null)
_IPC_SHAREABLE_VERSION=$(limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' --quiet \
        sh -c 'perl -MIPC::Shareable -e \"print qq(\\\$IPC::Shareable::VERSION)\"'" 2>/dev/null)
_IPC_SHAREABLE_VERSION="${_IPC_SHAREABLE_VERSION:-N/A}"
_OS_INFO=$(limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' --quiet \
        sh -c 'uname -a'" 2>/dev/null)
_PERL_VERSION=$(limactl shell "$VM" -- sh -lc "
    sudo systemd-nspawn -D '${CHROOT}' --quiet \
        sh -c 'perl -e \"printf qq(%vd\\n), \\\$^V\"'" 2>/dev/null)

echo ""
echo "==> Project: ${PROJECT}"
echo "==> Tested: ${_VERSION}"
echo "==> IPC::Shareable installed: ${_IPC_SHAREABLE_VERSION}"
echo "==> VM: ${VM}"
echo "==> OS Version: ${_OS_INFO}"
echo "==> Perl version: ${_PERL_VERSION}"
echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"

exit $_test_rc
