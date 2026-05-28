#!/bin/sh
# Run tests in a local FreeBSD VM (Lima template).
# Usage: ./ci/freebsd-test.sh [--project <name>] [--perl-version <ver>] [prove options]

set -e

VM="${VM:-freebsd-ipc}"
GUEST_USER="freebsd"
GUEST_HOME="/home/${GUEST_USER}.guest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HOST_REPO is resolved from --project below, after argument parsing,
# so that --project async-event-interval ships the aei repo (sibling
# of ipc-shareable) and --project ipc-shareable ships this repo.

PROJECT=""
PERL_VERSION=""
XS_MODE=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options] [prove options]

Options:
  -p, --project <name>   Project to test: ipc-shareable or async-event-interval
                         (required)
  -v, --perl-version <ver> Build and test with perlbrew Perl <ver> (e.g. 5.20.3).
                         Compiles Perl from source on the first run (10-20 min);
                         subsequent runs reuse the cached build.
  -x, --xs               Build and test with XS (default: pure Perl only,
                         ipc-shareable only)
  -h, --help             Show this help message and exit

Environment:
  VM=<name>        Target a different Lima VM (default: freebsd-ipc)

Prove options default to "-v t" (verbose, full suite) when not supplied.
Examples:
  $(basename "$0") -p ipc-shareable                     # full suite
  $(basename "$0") -p async-event-interval              # full suite, aei
  $(basename "$0") -p ipc-shareable -v 5.20.3           # full suite, Perl 5.20.3
  $(basename "$0") -p ipc-shareable t/85-clean.t        # single test file
  $(basename "$0") -p ipc-shareable t                   # full suite, no -v
EOF
}

_PROVE_ARGS=""
while [ $# -gt 0 ]; do
    case "$1" in
        -p|--project)   shift; PROJECT="$1"; shift ;;
        -v|--perl-version) shift; PERL_VERSION="$1"; shift ;;
        -x|--xs)        XS_MODE=1; shift ;;
        -h|--help)      usage; exit 0 ;;
        *)              _PROVE_ARGS="${_PROVE_ARGS} $1"; shift ;;
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
        TEST_ENV="ASYNC_TESTING=1"
        TEST_MODULE="IPC::Shareable"
        ;;
    async-event-interval)
        GUEST_REPO="${GUEST_HOME}/async-event-interval"
        OTHER_DEPS="Test::SharedFork Mock::Sub Parallel::ForkManager"
        IPC_INSTALL="sudo cpanm --reinstall --notest IPC::Shareable"
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
    limactl stop "$VM" >/dev/null 2>&1 || true
    trap - EXIT INT TERM
    exit "$status"
}

trap cleanup EXIT INT TERM

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "${SCRIPT_DIR}/freebsd-lima.yaml"
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    echo "==> Starting VM '${VM}'..."
    limactl start "$VM" &
    _LIMA_PID=$!

    # Lima's generated cloud-init YAML uses 1-space list indentation which
    # FreeBSD's flua YAML parser rejects.  On a fresh VM this means the
    # 'freebsd' SSH user and the boot-done marker are never created, and
    # 'limactl start' hangs indefinitely.  Poll for SSH; if it isn't
    # available after 60 s, run freebsd-first-boot.py via the serial console
    # to set up the user, install a persistent boot-done rc.d service, and
    # write the marker for this boot.  Subsequent starts will be fast.
    _SSH_OK=0
    for _I in $(seq 1 20); do
        if ssh -F ~/.lima/"$VM"/ssh.config lima-"$VM" true 2>/dev/null; then
            _SSH_OK=1; break
        fi
        sleep 3
    done

    if [ "$_SSH_OK" = "0" ]; then
        echo "==> SSH unavailable – running first-boot setup (one-time)..."
        python3 "${SCRIPT_DIR}/freebsd-first-boot.py" "$VM"
    fi

    # Wait for Lima to finish its startup sequence (should complete now that
    # SSH works and the boot-done marker exists).
    wait "$_LIMA_PID" || true

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

# Suppress FreeBSD daily tips (fortune freebsd-tips in .profile/.login).
ssh -F ~/.lima/"$VM"/ssh.config lima-"$VM" \
    'sed -i "" -e "/fortune freebsd-tips/s/^/#/" ~/.profile ~/.login' \
    2>/dev/null || true

# If sudo is missing (VM was set up before the first-boot script included the
# pkg install step), run first-boot again while the VM is still running so the
# serial console socket is available.
if ! limactl shell "$VM" -- sh -lc 'command -v sudo >/dev/null 2>&1'; then
    echo "==> sudo not found – running first-boot setup to install it..."
    python3 "${SCRIPT_DIR}/freebsd-first-boot.py" "$VM"
fi

echo "==> Installing FreeBSD packages..."
limactl shell "$VM" -- sh -lc "
    sudo pkg install -y perl5 p5-App-cpanminus gmake p5-ExtUtils-MakeMaker \\
        p5-Test-SharedFork p5-Mock-Sub
    sudo cpanm --notest ${OTHER_DEPS}
    ${IPC_INSTALL}
"

if [ -n "$PERL_VERSION" ]; then
    echo "==> Setting up Perl ${PERL_VERSION} via perlbrew (compiles from source on first run)..."
    limactl shell "$VM" -- sh -lc "
        set -e
        sudo pkg install -y gcc gmake curl

        if [ ! -x \"\$HOME/perl5/perlbrew/bin/perlbrew\" ]; then
            # Install system-wide so App::perlbrew is in the system perl @INC.
            # Avoids the curl|bash installer (requires bash, external URL).
            sudo cpanm --notest App::perlbrew
            # init creates the directory skeleton but does not place the binary;
            # copy it from where cpanm installed it to the expected stable path.
            perlbrew init
            cp \"\$(command -v perlbrew)\" \"\$HOME/perl5/perlbrew/bin/perlbrew\"
        fi

        PERLBREW=\"\$HOME/perl5/perlbrew/bin/perlbrew\"

        if ! \"\$PERLBREW\" list | grep -qF '${PERL_VERSION}'; then
            echo '==> Compiling perl-${PERL_VERSION} — this takes 10-20 minutes...'
            \"\$PERLBREW\" install perl-${PERL_VERSION} --notest -j 2
        fi

        PERL_BIN=\"\$HOME/perl5/perlbrew/perls/perl-${PERL_VERSION}/bin\"

        if [ ! -x \"\$PERL_BIN/cpanm\" ]; then
            curl -fsSL https://cpanmin.us -o /tmp/_cpanm_bootstrap.pl
            \"\$PERL_BIN/perl\" /tmp/_cpanm_bootstrap.pl App::cpanminus
            rm -f /tmp/_cpanm_bootstrap.pl
        fi

        \"\$PERL_BIN/cpanm\" --notest ${OTHER_DEPS}
        [ \"${PROJECT}\" = async-event-interval ] && \\
            \"\$PERL_BIN/cpanm\" --reinstall --notest IPC::Shareable
    "
fi

echo "==> Copying source into VM..."
limactl shell "$VM" -- sh -lc "rm -rf '${GUEST_REPO}'"
scp -F ~/.lima/"$VM"/ssh.config -r "$HOST_REPO" "lima-${VM}:${GUEST_HOME}/"
# Strip macOS resource-fork files (._*).
limactl shell "$VM" -- sh -lc "find '${GUEST_REPO}' -name '._*' -delete" 2>/dev/null || true

echo "==> Cleaning up stale IPC segments/semaphores from previous runs..."
limactl shell "$VM" -- sh -lc "
    for id in \$(ipcs -m 2>/dev/null | awk '/${GUEST_USER}/ {print \$2}'); do
        ipcrm -m \$id 2>/dev/null || true
    done
    for id in \$(ipcs -s 2>/dev/null | awk '/${GUEST_USER}/ {print \$2}'); do
        ipcrm -s \$id 2>/dev/null || true
    done
" || true

_test_rc=0
if [ -n "$PERL_VERSION" ]; then
    if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
        echo "==> Building and running tests in VM with Perl ${PERL_VERSION} (XS)..."
        limactl shell "$VM" -- sh -lc "
            PERL_BIN=\"\$HOME/perl5/perlbrew/perls/perl-${PERL_VERSION}/bin\"
            cd '${GUEST_REPO}' && PATH=\"\$PERL_BIN:\$PATH\" perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib PATH=\"\$PERL_BIN:\$PATH\" prove -l -Iblib/arch ${PROVE_ARGS}
        " || _test_rc=$?
    else
        echo "==> Running tests in VM with Perl ${PERL_VERSION} (pure Perl)..."
        limactl shell "$VM" -- sh -lc "
            PERL_BIN=\"\$HOME/perl5/perlbrew/perls/perl-${PERL_VERSION}/bin\"
            cd '${GUEST_REPO}' && ${TEST_ENV} PERL5LIB=lib PATH=\"\$PERL_BIN:\$PATH\" prove -l ${PROVE_ARGS}
        " || _test_rc=$?
    fi
else
    if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
        echo "==> Building and running tests in VM (XS)..."
        limactl shell "$VM" -- sh -lc "cd '${GUEST_REPO}' && perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}" \
            || _test_rc=$?
    else
        echo "==> Running tests in VM (pure Perl)..."
        limactl shell "$VM" -- sh -lc "cd '${GUEST_REPO}' && ${TEST_ENV} PERL5LIB=lib prove -l ${PROVE_ARGS}" \
            || _test_rc=$?
    fi
fi

_VERSION=$(limactl shell "$VM" -- sh -lc "perl -I'${GUEST_REPO}/lib' -M${TEST_MODULE} -e 'print qq(${TEST_MODULE} \$${TEST_MODULE}::VERSION\n)'" 2>/dev/null)
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
