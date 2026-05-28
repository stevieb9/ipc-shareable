#!/bin/sh
# Run tests in a local OmniOS CE VM (Lima/QEMU).
#
# Targets the CPAN smoker platform:
#   osname=solaris, osvers=2.11, archname=i86pc-solaris-64
#
# Usage: ./ci/solaris-test.sh [options] [prove options]

set -e

VM="${VM:-solaris-ipc}"
GUEST_USER="solaris"
GUEST_HOME="/export/home/${GUEST_USER}.guest"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# HOST_REPO is resolved from --project below, after argument parsing,
# so that --project async-event-interval ships the aei repo (sibling
# of ipc-shareable) and --project ipc-shareable ships this repo.

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
  VM=<name>         Target a different Lima VM (default: solaris-ipc)

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
        GUEST_REPO="${GUEST_HOME}/ipc-shareable"
        OTHER_DEPS="String::CRC32 JSON Test::SharedFork Mock::Sub Async::Event::Interval"
        IPC_INSTALL=""
        TEST_ENV="ASYNC_TESTING=1"
        TEST_MODULE="IPC::Shareable"
        ;;
    async-event-interval)
        GUEST_REPO="${GUEST_HOME}/async-event-interval"
        OTHER_DEPS="JSON Test::SharedFork Mock::Sub Parallel::ForkManager"
        IPC_INSTALL="sudo env MAKE=gmake cpanm --reinstall --notest IPC::Shareable"
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

# ── timeout helpers ─────────────────────────────────────────────────────────
# macOS lacks GNU timeout; these poll-based wrappers work everywhere.

_timeout_run() {
    # $1 = timeout seconds, remaining args = command to run.
    # Returns the command's exit status, or 124 on timeout.
    _timeout=$1; shift
    "$@" &
    _pid=$!
    _elapsed=0
    while kill -0 $_pid 2>/dev/null; do
        sleep 5
        _elapsed=$((_elapsed + 5))
        if [ $_elapsed -ge $_timeout ]; then
            echo "ERROR: Command timed out after ${_timeout}s" >&2
            kill $_pid 2>/dev/null || true
            wait $_pid 2>/dev/null || true
            return 124
        fi
    done
    wait $_pid
}

_wait_with_timeout() {
    # $1 = timeout seconds, $2 = PID to wait for.
    # Returns the PID's exit status, or 124 on timeout.
    _timeout=$1; _pid=$2
    _elapsed=0
    while kill -0 $_pid 2>/dev/null; do
        sleep 5
        _elapsed=$((_elapsed + 5))
        if [ $_elapsed -ge $_timeout ]; then
            echo "ERROR: Timed out waiting for PID $_pid after ${_timeout}s" >&2
            kill $_pid 2>/dev/null || true
            wait $_pid 2>/dev/null || true
            return 124
        fi
    done
    wait $_pid
}

cleanup() {
    status=$?
    echo "==> Shutting down VM '${VM}' cleanly..."
    # Issue a clean shutdown via SSH so ZFS pool is marked clean.
    # TCG emulation is slow — the guest may need minutes to sync+halt.
    ssh -o ConnectTimeout=10 -F ~/.lima/"$VM"/ssh.config lima-"$VM" \
        'sudo shutdown -i5 -g0 -y 2>/dev/null' \
        </dev/null 2>/dev/null || true
    # Wait for the VM to actually power off (poll for up to 5 min).
    echo "==> Waiting for VM to power off..."
    _clean_shutdown=0
    for _i in $(seq 1 30); do
        limactl list 2>/dev/null | grep -q "^${VM}[[:space:]].*Running" || {
            _clean_shutdown=1; break; }
        sleep 10
    done
    # If still running, let limactl stop send ACPI; last resort force.
    if [ "$_clean_shutdown" -eq 0 ]; then
        limactl list 2>/dev/null | grep -q "^${VM}[[:space:]].*Running" && {
            echo "==> VM still running, asking Lima to stop..."
            limactl stop "$VM" >/dev/null 2>&1 || true
            sleep 30
        }
    fi
    limactl list 2>/dev/null | grep -q "^${VM}[[:space:]].*Running" && {
        echo "==> Force-stopping VM..."
        limactl stop --force "$VM" >/dev/null 2>&1 || true
        _clean_shutdown=0
    }
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

# Lima cannot resize VMDK images (qemu-img resize -f vmdk fails).  Download the
# OmniOS cloud VMDK once, convert it to QCOW2, and cache the result so that
# subsequent runs skip the download+convert step entirely.
_prepare_disk_image() {
    _VMDK_URL="https://downloads.omnios.org/media/stable/omnios-r151058.cloud.vmdk"
    _QCOW2_CACHE="${HOME}/.lima/_cache/omnios-r151058.qcow2"

    mkdir -p "${HOME}/.lima/_cache"

    if [ ! -f "$_QCOW2_CACHE" ]; then
        _VMDK_TMP="$(mktemp /tmp/omnios-XXXXXX.vmdk)"
        echo "==> Downloading OmniOS VMDK (one-time, ~1 GB)..." >&2
        curl -L --progress-bar --retry 3 -o "$_VMDK_TMP" "$_VMDK_URL"
        echo "==> Converting VMDK to QCOW2 (one-time)..." >&2
        qemu-img convert -f vmdk -O qcow2 "$_VMDK_TMP" "$_QCOW2_CACHE"
        rm -f "$_VMDK_TMP"
    fi

    echo "$_QCOW2_CACHE"
}

if ! limactl list 2>/dev/null | awk '{print $1}' | grep -qx "$VM"; then
    _QCOW2="$(_prepare_disk_image)"
    echo "==> Creating VM '${VM}' from Lima template..."
    _TEMP_YAML="$(mktemp /tmp/solaris-lima-XXXXXX.yaml)"
    # Rewrite the images section to point at the local QCOW2 instead of the
    # remote VMDK, and drop the arch/digest sub-keys (not needed for file://).
    python3 - "${SCRIPT_DIR}/solaris-lima.yaml" "$_QCOW2" > "$_TEMP_YAML" <<'PYEOF'
import sys, re
yaml_file, qcow2_path = sys.argv[1], sys.argv[2]
with open(yaml_file) as f:
    lines = f.readlines()
out = []
skip_image_subkeys = False
for line in lines:
    if re.match(r'  - location:', line):
        out.append(f'  - location: "file://{qcow2_path}"\n')
        skip_image_subkeys = True
        continue
    if skip_image_subkeys and re.match(r'    (arch|digest):', line):
        continue
    skip_image_subkeys = False
    out.append(line)
sys.stdout.write(''.join(out))
PYEOF
    limactl create --name "$VM" --tty=false "$_TEMP_YAML"
    rm -f "$_TEMP_YAML"
fi

if ! limactl list | grep -q "^${VM}[[:space:]].*Running"; then
    _DISK="${HOME}/.lima/${VM}/disk"

    # Revert to last clean snapshot so ZFS never scans on boot
    if qemu-img snapshot -l "$_DISK" 2>/dev/null | grep -q '\bclean\b'; then
        echo "==> Reverting to clean snapshot..."
        qemu-img snapshot -a clean "$_DISK" 2>/dev/null || true
    fi

    echo "==> Starting VM '${VM}'..."
    limactl start "$VM" &
    _LIMA_PID=$!

    # OmniOS cloud images do not run Lima's cloud-init, so SSH and the
    # boot-done marker are set up via the serial console.
    #
    # Strategy: poll both SSH and the serial log.  If "login:" appears
    # in the serial log, the VM has booted far enough for first-boot.py
    # to work — run it immediately instead of waiting for SSH to time out.
    # A ZFS device scan after unclean shutdown can add hours; if we see the
    # scan notice, we skip the VM wait and proceed straight to first-boot
    # (the serial console will be available once the scan finishes).
    _SSH_OK=0
    _SERIAL_LOG="${HOME}/.lima/${VM}/serial.log"
    _SSH_ELAPSED=0
    _SCAN_WARNED=0
    echo "==> Waiting for SSH (monitoring serial console)..."
    for _I in $(seq 1 600); do
        if ssh -F ~/.lima/"$VM"/ssh.config lima-"$VM" true 2>/dev/null; then
            _SSH_OK=1; break
        fi
        sleep 10
        _SSH_ELAPSED=$(( _SSH_ELAPSED + 10 ))
        # If the serial log shows a login prompt, the VM is ready for first-boot.
        if [ -f "$_SERIAL_LOG" ] && grep -q 'login:' "$_SERIAL_LOG" 2>/dev/null; then
            echo "    ...login prompt detected on serial console ($(( _SSH_ELAPSED / 60 )) min)"
            break
        fi
        # Warn once about an in-progress ZFS scan (known to be very slow on TCG).
        if [ "$_SCAN_WARNED" = "0" ] && [ -f "$_SERIAL_LOG" ] \
            && grep -q 'Performing full ZFS device scan' "$_SERIAL_LOG" 2>/dev/null
        then
            echo "    ...ZFS pool scan in progress (unclean shutdown); this may take hours on TCG"
            _SCAN_WARNED=1
        fi
        # Print a progress dot every 60 s so the terminal doesn't look hung.
        [ $(( _SSH_ELAPSED % 60 )) -eq 0 ] && printf "    ...%d min elapsed\n" $(( _SSH_ELAPSED / 60 ))
    done

    if [ "$_SSH_OK" = "0" ]; then
        echo "==> SSH not up — running first-boot setup (one-time)..."
        python3 "${SCRIPT_DIR}/solaris-first-boot.py" "$VM"
    fi

    # If sudo is missing the VM predates the first-boot install step; redo it.
    # This must run before _write_boot_done since that uses sudo over SSH.
    if ! limactl shell "$VM" -- sh -lc 'command -v sudo >/dev/null 2>&1'; then
        echo "==> sudo not found – running first-boot setup..."
        python3 "${SCRIPT_DIR}/solaris-first-boot.py" "$VM"
    fi

    # Lima generates a fresh instance-id on each start.  Write it to the
    # boot-done marker so limactl start (running in the background) exits.
    _write_boot_done() {
        _IID=$(python3 -c "
import os, subprocess
iso = os.path.expanduser('~/.lima/${VM}/cidata.iso')
mnt = '/tmp/_iid_mnt'
os.makedirs(mnt, exist_ok=True)
subprocess.run(['hdiutil','attach',iso,'-mountpoint',mnt,'-readonly','-quiet'], check=True)
with open(f'{mnt}/meta-data') as f:
    for line in f:
        if line.startswith('instance-id:'):
            print(line.split(':',1)[1].strip())
subprocess.run(['hdiutil','detach',mnt,'-quiet'])
" 2>/dev/null)
        [ -n "$_IID" ] && ssh -F ~/.lima/"$VM"/ssh.config lima-"$VM" \
            "sudo sh -c 'echo ${_IID} > /var/run/lima-boot-done && echo INSTANCE_ID=${_IID} > /etc/lima/boot-done-id'" \
            2>/dev/null || true
    }
    _write_boot_done

    _wait_with_timeout 6000 "$_LIMA_PID" || true

    limactl list | grep -q "^${VM}[[:space:]].*Running" || {
        echo "ERROR: VM '${VM}' is not Running after start"; exit 1; }
fi

echo "==> Installing OmniOS packages and CPAN deps..."
_timeout_run 1200 limactl shell "$VM" -- sh -lc '
    set -e
    # System packages (pkg is idempotent for already-installed packages)
    sudo pkg install --accept -q \
        runtime/perl developer/gcc14 developer/build/gnu-make \
        web/curl 2>&1 | grep -v "^$" || true

    # Ensure cc is in PATH (OmniOS gcc14 installs as gcc, not cc)
    export PATH=/usr/gcc/14/bin:/usr/gnu/bin:/usr/bin:$PATH
    command -v cc >/dev/null 2>&1 || {
        for _cc in gcc cc; do
            _found=$(find /usr/gcc -name "$_cc" -type f 2>/dev/null | head -1)
            [ -n "$_found" ] && sudo ln -sf "$_found" /usr/bin/cc && break
        done
    }

    # cpanm (skip if already installed)
    command -v cpanm >/dev/null 2>&1 || {
        curl -sL https://cpanmin.us -o /tmp/cpanm.pl
        sudo perl /tmp/cpanm.pl App::cpanminus
        # cpanm may land outside PATH on OmniOS; find and symlink it
        CPANM=$(find /usr/perl5 /opt -name cpanm -type f 2>/dev/null | head -1)
        [ -n "$CPANM" ] && sudo ln -sf "$CPANM" /usr/bin/cpanm
    }

    # CPAN deps — use gmake so ExtUtils::MakeMaker gets GNU make.
    sudo env MAKE=gmake cpanm --notest ${OTHER_DEPS} 2>&1 || true
    ${IPC_INSTALL} 2>&1 || true
'

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
if [ "$PROJECT" = "ipc-shareable" ] && [ $XS_MODE -eq 1 ]; then
    echo "==> Building and running tests in VM (XS)..."
    _timeout_run 2400 limactl shell "$VM" -- sh -lc "
        export PATH=/usr/gnu/bin:/usr/bin:\$PATH
        cd '${GUEST_REPO}' && perl Makefile.PL && make && ${TEST_ENV} PERL5LIB=lib prove -l -Iblib/arch ${PROVE_ARGS}
    " || _test_rc=$?
else
    echo "==> Running tests in VM (pure Perl)..."
    _timeout_run 1800 limactl shell "$VM" -- sh -lc "
        export PATH=/usr/gnu/bin:/usr/bin:\$PATH
        cd '${GUEST_REPO}' && ${TEST_ENV} PERL5LIB=lib prove -l ${PROVE_ARGS}
    " || _test_rc=$?
fi

_VERSION=$(limactl shell "$VM" -- sh -lc "perl -I'${GUEST_REPO}/lib' -M${TEST_MODULE} -e 'print qq(${TEST_MODULE} \${TEST_MODULE}::VERSION\n)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION=$(limactl shell "$VM" -- sh -lc "perl -MIPC::Shareable -e 'print qq(\$IPC::Shareable::VERSION)'" 2>/dev/null)
_IPC_SHAREABLE_VERSION="${_IPC_SHAREABLE_VERSION:-N/A}"
_OS_INFO=$(limactl shell "$VM" -- sh -lc 'uname -a' 2>/dev/null)
_PERL_VERSION=$(limactl shell "$VM" -- sh -lc "perl -e 'printf qq(%vd\n), \$^V'" 2>/dev/null)

echo ""
echo "==> Project: ${PROJECT}"
echo "==> Tested: ${_VERSION}"
echo "==> IPC::Shareable installed: ${_IPC_SHAREABLE_VERSION}"
echo "==> VM: ${VM}"
echo "==> OS Version: ${_OS_INFO}"
echo "==> Perl version: ${_PERL_VERSION}"
echo "==> Mode: $( [ $XS_MODE -eq 1 ] && echo 'XS' || echo 'pure Perl' )"

exit $_test_rc
