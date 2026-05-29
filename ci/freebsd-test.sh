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

. "${SCRIPT_DIR}/lock-vm.sh"
acquire_vm_lock

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

sigint_handler() {
    trap - EXIT INT TERM
    echo "==> Force-stopping VM '${VM}' (SIGINT)..."
    limactl stop --force "$VM" 2>/dev/null || true
    release_vm_lock
    exit 130
}

cleanup() {
    status=$?
    trap - EXIT INT TERM
    echo "==> Stopping VM '${VM}'..."
    limactl stop "$VM" >/dev/null 2>&1 || true
    release_vm_lock
    exit "$status"
}

trap sigint_handler INT
trap cleanup EXIT TERM

# Pick the Lima YAML by host arch. Two single-arch YAMLs because Lima 2.1.1
# does not auto-select an image entry when the top-level `arch:` is absent.
case "$(uname -m)" in
    arm64|aarch64) _LIMA_YAML="${SCRIPT_DIR}/freebsd-lima.yaml" ;;
    x86_64|amd64)  _LIMA_YAML="${SCRIPT_DIR}/freebsd-lima-x86_64.yaml" ;;
    *) echo "ERROR: unsupported host arch: $(uname -m)" >&2; exit 1 ;;
esac

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    echo "==> Creating VM '${VM}' from Lima template..."
    limactl create --name "$VM" --tty=false "$_LIMA_YAML"
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
else
    echo "==> VM '${VM}' is already running"
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
# Remove non-system-owned IPC (any user that isn't root/wheel/system) and
# also attempt root-owned cleanup since sudo invocations during testing
# may have created root-owned segments. Filtering by ${GUEST_USER} alone
# misses both other-user and root-owned leftovers.
limactl shell "$VM" -- sh -lc "
    for id in \$(ipcs -m 2>/dev/null | awk 'NR>3 && \$5 !~ /^(root|wheel|system)\$/ {print \$2}'); do
        ipcrm -m \$id 2>/dev/null || true
    done
    for id in \$(ipcs -s 2>/dev/null | awk 'NR>3 && \$5 !~ /^(root|wheel|system)\$/ {print \$2}'); do
        ipcrm -s \$id 2>/dev/null || true
    done
    sudo ipcs -m 2>/dev/null | awk 'NR>3 && \$5 == \"root\" {print \$2}' \
        | xargs -I{} sudo ipcrm -m {} 2>/dev/null || true
    sudo ipcs -s 2>/dev/null | awk 'NR>3 && \$5 == \"root\" {print \$2}' \
        | xargs -I{} sudo ipcrm -s {} 2>/dev/null || true
" || true

# IPC_DEBUG_DELTAS=1 swaps the single prove invocation for a per-file loop
# that snapshots ipcs counts before/after each .t and flags any file with a
# net-positive delta (leaked sem set or shm segment). Off by default.
if [ "${IPC_DEBUG_DELTAS:-0}" = "1" ]; then
    echo "==> IPC delta diagnostics enabled (per-file leak detection)"
fi

# Builds the remote command to run inside the VM. Honours PERL_VERSION (for
# perlbrew PATH), XS_MODE (build XS first then prove with -Iblib/arch), and
# IPC_DEBUG_DELTAS (wrap prove in a per-file loop).
_remote_test_cmd() {
    _path_setup=""
    _prove_extra=""
    _make_step=""
    if [ -n "$PERL_VERSION" ]; then
        _path_setup="PERL_BIN=\"\$HOME/perl5/perlbrew/perls/perl-${PERL_VERSION}/bin\"; PATH=\"\$PERL_BIN:\$PATH\"; "
    fi
    if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
        _make_step="perl Makefile.PL && make && "
        _prove_extra="-Iblib/arch "
    fi
    if [ "${IPC_DEBUG_DELTAS:-0}" = "1" ]; then
        # Per-file loop. Resolve the prove targets from PROVE_ARGS: if a
        # directory or glob, expand it; otherwise iterate the given files.
        printf '%s' "
            cd '${GUEST_REPO}' && ${_make_step}${TEST_ENV} PERL5LIB=lib ${_path_setup}sh -c '
                _fail=0
                _files=\$(for _a in ${PROVE_ARGS}; do
                    case \"\$_a\" in
                        -*) ;;
                        *) [ -d \"\$_a\" ] && find \"\$_a\" -name \"*.t\" | sort || echo \"\$_a\" ;;
                    esac
                done)
                for _t in \$_files; do
                    [ -f \"\$_t\" ] || continue
                    _bs=\$(ipcs -s 2>/dev/null | awk \"NR>3 && /[a-zA-Z]/{c++}END{print c+0}\")
                    _bm=\$(ipcs -m 2>/dev/null | awk \"NR>3 && /[a-zA-Z]/{c++}END{print c+0}\")
                    prove ${_prove_extra}-l -v \"\$_t\" || _fail=1
                    _as=\$(ipcs -s 2>/dev/null | awk \"NR>3 && /[a-zA-Z]/{c++}END{print c+0}\")
                    _am=\$(ipcs -m 2>/dev/null | awk \"NR>3 && /[a-zA-Z]/{c++}END{print c+0}\")
                    if [ \"\$_as\" -gt \"\$_bs\" ] || [ \"\$_am\" -gt \"\$_bm\" ]; then
                        echo \"IPC-DELTA LEAK: \$_t sem \$_bs->\$_as shm \$_bm->\$_am\" >&2
                    fi
                done
                exit \$_fail
            '
        "
    else
        printf '%s' "
            cd '${GUEST_REPO}' && ${_make_step}${TEST_ENV} PERL5LIB=lib ${_path_setup}prove -l ${_prove_extra}${PROVE_ARGS}
        "
    fi
}

_test_rc=0
if [ -n "$PERL_VERSION" ]; then
    if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
        echo "==> Building and running tests in VM with Perl ${PERL_VERSION} (XS)..."
    else
        echo "==> Running tests in VM with Perl ${PERL_VERSION} (pure Perl)..."
    fi
else
    if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
        echo "==> Building and running tests in VM (XS)..."
    else
        echo "==> Running tests in VM (pure Perl)..."
    fi
fi
limactl shell "$VM" -- sh -lc "$(_remote_test_cmd)" || _test_rc=$?

# Disable set -e for version probes: dash exits on failed $(...) under set -e,
# and the second probe is allowed to fail (system-installed IPC::Shareable may
# not exist).
set +e
_VERSION=$(limactl shell "$VM" -- sh -lc "perl -I'${GUEST_REPO}/lib' -M${TEST_MODULE} -e 'print qq(${TEST_MODULE} \$${TEST_MODULE}::VERSION\n)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION=$(limactl shell "$VM" -- sh -lc "perl -MIPC::Shareable -e 'print qq(\$IPC::Shareable::VERSION)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION="${_IPC_SHAREABLE_VERSION:-N/A}"
_OS_INFO=$(limactl shell "$VM" -- sh -lc 'uname -a' 2>/dev/null)
_PERL_VERSION=$(limactl shell "$VM" -- sh -lc "perl -e 'printf qq(%vd\n), \$^V'" 2>/dev/null)
set -e

echo ""
echo "==> Project: ${PROJECT}"
echo "==> Tested: ${_VERSION}"
echo "==> IPC::Shareable installed: ${_IPC_SHAREABLE_VERSION}"
echo "==> VM: ${VM}"
echo "==> OS Version: ${_OS_INFO}"
echo "==> Perl version: ${_PERL_VERSION}"
echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"

exit $_test_rc
