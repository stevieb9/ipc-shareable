# CI Test Runners

Scripts for running IPC::Shareable tests inside local VMs via
[Lima](https://lima-vm.io/) and QEMU.

The scripts accept a `--project` flag so the same VM infrastructure can test
either IPC::Shareable or [Async::Event::Interval](https://github.com/stevieb9/async-event-interval).
The `async-event-interval` repo's `ci/` directory contains thin wrappers that
delegate here with `--project async-event-interval`.

## Contents

- [Lima basics](#lima-basics)
- [Unified test runner (`vm-tests.sh`)](#unified-test-runner-vm-testssh)
- [FreeBSD CI](#freebsd-ci)
- [OpenBSD CI](#openbsd-ci)
- [Linux i386 CI](#linux-i386-ci)
- [OmniOS CE (Solaris) CI](#omnios-ce-solaris-ci)
- [DragonFly BSD CI](#dragonfly-bsd-ci)
- [Technical Information](#technical-information)

## Lima basics

[Lima](https://lima-vm.io/) launches Linux (and experimentally, non-Linux) VMs
on macOS and Linux via QEMU, with automatic file sharing and port forwarding.
On macOS Apple Silicon it uses HVF; on Linux it uses KVM.

### Host setup

**macOS**:

```sh
brew install lima qemu
```

**Linux (Debian/Ubuntu)**:

```sh
sudo apt-get install -y qemu-system-x86 qemu-utils xorriso ovmf
# Add yourself to the kvm group (log out / back in after):
sudo usermod -aG kvm "$USER"

# Lima itself: install the latest release tarball
LIMA_VER=$(curl -fsSL https://api.github.com/repos/lima-vm/lima/releases/latest \
    | grep tag_name | cut -d'"' -f4)
curl -fsSL "https://github.com/lima-vm/lima/releases/download/${LIMA_VER}/lima-${LIMA_VER#v}-Linux-x86_64.tar.gz" \
    | sudo tar -C /usr/local -xzf -
```

`xorriso` is mandatory on Linux: Lima 2.x falls back to `genisoimage` when
it's missing and then crashes during cidata.iso generation (the `--norock`
flag is unsupported by `genisoimage`). `vm-tests.sh` checks for this up
front and exits with the install command if missing.

### Migration to a new Linux machine

After completing **Host setup** above, a fresh Linux x86_64 host needs the
steps below before `./ci/vm-tests.sh` runs end-to-end against all VMs.
These extend Host setup; they aren't replacements. Validated against
Lima 2.1.1 on Ubuntu 22.04 x86_64 — newer Lima versions may need
re-validation if cidata or hostagent behaviour shifts.

#### Sibling repo layout

`*-test.sh` computes `HOST_REPO` via `${SCRIPT_DIR}/../..`. Both
`ipc-shareable` and `async-event-interval` must live as siblings under a
shared parent directory, e.g.

```
~/repos/ipc-shareable/
~/repos/async-event-interval/
```

A flat layout (one repo only) will not work — even if you only intend to
test ipc-shareable, the runners look for the aei repo when running aei
tests inside the VMs.

#### DragonFly base image (operator-supplied)

DragonFly has no public cloud image; the Lima qcow2 must be supplied by
the operator. If you have a working DragonFly Lima VM on another host:

```sh
# From a host that already has the DragonFly cache:
scp ~/.lima/_cache/dragonfly64.qcow2 newhost:~/.lima/_cache/
```

The image is ~778 MB. Building one from scratch is covered under
"Building the DragonFly BSD base image" further below.

#### OmniOS qcow2 pre-bake (one-time, mandatory)

A freshly downloaded `omnios-r151058.cloud.vmdk` will not complete
first-boot on Linux KVM in any reasonable time — ZFS does a slow device
path re-discovery because the pool was last accessed by the OmniOS
build host on a different `/devices` layout. The fix is to import and
re-export the pool on Linux, which updates the pool's hostid and
device-path metadata so OmniOS's next boot recognises the disks
immediately.

Required apt package beyond Host setup:

```sh
sudo apt-get install -y zfsutils-linux
```

Trigger the initial VMDK→qcow2 conversion by running solaris-test.sh
once; it will hang on first-boot but the cached qcow2 will be in
place. Ctrl-C after you see `==> Reverting to clean snapshot...` and
the VM start, then `limactl delete --force solaris-ipc` to clean up.

```sh
./ci/solaris-test.sh -p ipc-shareable t/00-base.t   # let it download+convert, then Ctrl-C
limactl delete --force solaris-ipc
```

Then pre-bake the cached image:

```sh
# Defensive backup
cp ~/.lima/_cache/omnios-r151058.qcow2 ~/.lima/_cache/omnios-r151058.qcow2.bak

sudo modprobe nbd max_part=16
sudo qemu-nbd --connect=/dev/nbd0 ~/.lima/_cache/omnios-r151058.qcow2
sudo mkdir -p /mnt/omnios
sudo zpool import -f -R /mnt/omnios rpool   # -f: pool last accessed by OmniOS
sudo zpool export rpool                      # exports clean with Linux as last-host
sudo qemu-nbd --disconnect /dev/nbd0
sudo rmdir /mnt/omnios
```

**Critical: do NOT edit any files inside the pool.** Modifying
`/etc/system` (or any boot-archive file) changes the checksum OmniOS
uses to validate the cached boot archive. The next boot detects the
mismatch, auto-rebuilds the archive, and triggers a reboot — which
won't recover cleanly on KVM. The import/export-only approach updates
pool metadata without touching any file.

After the pre-bake, re-run `./ci/solaris-test.sh -p ipc-shareable
t/00-base.t` — first-boot should complete cleanly within a few
minutes.

#### Optional: libguestfs accessibility

If you anticipate inspecting guest filesystems with `guestfish` /
`virt-edit` for diagnostics, Debian/Ubuntu's `/boot/vmlinuz-*` is
`-rw-------` by default (root-only), which trips libguestfs's
supermin appliance build with a cryptic `cp: cannot open
'/boot/vmlinuz-*' for reading: Permission denied`. The user running
libguestfs needs read access:

```sh
sudo chmod 644 /boot/vmlinuz-*
```

Not required for the OmniOS pre-bake above (`qemu-nbd` doesn't go
through libguestfs). May need re-applying after kernel package
upgrades.

### Commands

```bash
limactl list                         # show all VMs and their status
limactl create --name <name> <yaml>  # create a VM from a template
limactl start <name>                 # start a VM
limactl stop <name>                  # clean shutdown (ACPI)
limactl stop --force <name>          # force-stop (SIGKILL to QEMU)
limactl shell <name>                 # open a shell inside the VM
limactl shell <name> -- <cmd>        # run a command inside the VM
limactl delete <name>                # delete VM and its disk image
```

### Directory layout

| Path | Purpose |
|------|---------|
| `~/.lima/<name>/lima.yaml` | VM instance config (editable between starts) |
| `~/.lima/<name>/ssh.config` | SSH config for `ssh -F` or `scp -F` |
| `~/.lima/<name>/disk` | VM disk image (QCOW2 on QEMU) |
| `~/.lima/<name>/serial.log` | Serial console log |
| `~/.lima/<name>/serial.sock` | QEMU serial console Unix socket |
| `~/.lima/_config/user` | SSH private key for all Lima VMs |
| `~/.lima/_config/user.pub` | SSH public key |
| `~/.lima/_cache/` | Downloaded image cache (shared across VMs) |

### SSH

Lima generates an SSH keypair at `~/.lima/_config/user*` and injects the public
key into each guest. Use the per-VM `ssh.config` to connect:

```bash
ssh -F ~/.lima/<name>/ssh.config lima-<name>
scp -F ~/.lima/<name>/ssh.config -r <src> lima-<name>:<dst>
```

`limactl shell <name>` wraps this with the correct flags automatically.

### Templates (`ci/*-lima.yaml`)

Each template declares the OS, architecture, CPU/memory/disk resources, and
the base disk image. `limactl create` copies the template into
`~/.lima/<name>/lima.yaml` and provisions the disk. After creation, you can
edit the VM's YAML directly (e.g. to bump CPUs) and `limactl start` will pick
up the changes.

### VM defaults and reuse

Default VM names (`freebsd-ipc`, `openbsd-ipc`, `linux-i386`, `solaris-ipc`,
`dragonfly-ipc`) are shared across projects. Each test script installs any
extra CPAN deps the project needs on top of what is already present,
idempotently — the same provisioned VM instances can test either project
without re-downloading base images or re-running first-boot bootstraps.

To use isolated VMs instead, set `VM=<name>` when invoking any script:

```bash
VM=freebsd-ipc2 ./ci/freebsd-test.sh
```

### Testing other projects

Every script accepts `--project`:

```bash
./ci/vm-tests.sh -p async-event-interval     # test aei on all VMs
./ci/freebsd-test.sh -p async-event-interval t/15-interval.t
```

The `--project` flag (or `-p`) is mandatory and controls the guest repo path,
CPAN dependencies, and test invocation. Valid values: `ipc-shareable`, `async-event-interval`.

The `async-event-interval` repo's `ci/` directory contains thin wrappers that
delegate here automatically, passing `--project async-event-interval` so you
never need to type `-p`. From that repo:

```bash
./ci/vm-tests.sh              # all VMs
./ci/vm-tests.sh -f           # FreeBSD only
./ci/freebsd-test.sh t/15-interval.t   # single test file
```

## Unified test runner (`vm-tests.sh`)

Runs tests on one or more VMs sequentially and prints a summary with failed
test details.

```bash
./ci/vm-tests.sh [options] [prove options]
```

### Options

| Flag | Description |
|------|-------------|
| `-p`, `--project <name>` | Project to test: `ipc-shareable` or `async-event-interval` (required) |
| `-f`, `--freebsd` | Run FreeBSD tests |
| `-l`, `--linux` | Run 32-bit Linux (i386) tests |
| `-o`, `--openbsd` | Run OpenBSD tests |
| `-s`, `--solaris` | Run Solaris/OmniOS tests |
| `-d`, `--dragonfly` | Run DragonFly BSD tests |
| `-a`, `--all` | Run all VMs (default) |
| `-k`, `--keep-logs` | Keep log files after the run |
| `-x`, `--xs` | Build and test with XS (default: pure Perl only, ipc-shareable only) |
| `-D`, `--display` | Write output to stdout instead of log files |
| `-h`, `--help` | Print usage and exit |

Prove options are forwarded to each VM test script (default: `-v t`).

### Examples

```bash
./ci/vm-tests.sh -p ipc-shareable                         # all VMs, ipc-shareable
./ci/vm-tests.sh -p async-event-interval -s               # Solaris only, aei
./ci/vm-tests.sh -p ipc-shareable -f -l t/20-lock.t      # FreeBSD + Linux, single test
./ci/vm-tests.sh -p ipc-shareable -ks                     # Solaris only, keep logs
```

### Output

Each VM's output is logged to `/tmp/vm-tests-<timestamp>/<label>.log`.
Logs are deleted on exit unless `-k` is passed. After all VMs finish, a
summary table shows PASS/FAIL per VM, and failed test details are extracted
from each log.

---

## FreeBSD CI

Local FreeBSD testing via Lima and QEMU.

### One-time VM setup

The test script creates and provisions the VM automatically on first run.
To create it manually:

```bash
limactl create --name freebsd-ipc ci/freebsd-lima.yaml
limactl start freebsd-ipc
```

`freebsd-lima.yaml` defines a FreeBSD 14.3 aarch64 VM (2 CPUs, 2 GiB RAM,
20 GiB disk). Perl packages and CPAN dependencies are installed by the test
script at runtime.

### Logging into the VM

```bash
limactl shell freebsd-ipc
```

Or with SSH directly:

```bash
ssh -F ~/.lima/freebsd-ipc/ssh.config lima-freebsd-ipc
```

### Shutting down the VM

```bash
limactl stop freebsd-ipc
```

To permanently remove the VM and its disk image:

```bash
limactl delete freebsd-ipc
```

### Running the test suite

`freebsd-test.sh` starts the VM (if not already running), copies the source,
runs the test suite, then stops the VM automatically on exit — whether the
tests pass, fail, or the script is interrupted.

```bash
./ci/freebsd-test.sh [options] [prove options]
```

**Options:**

- `-p`, `--project <name>` — Project to test: `ipc-shareable` or
  `async-event-interval` (required).
- `-v`, `--perl-version <ver>` — Build and test with a specific Perl version
  managed by perlbrew (e.g. `5.20.3`). Compiles Perl from source on the
  first run (10-20 min); subsequent runs reuse the cached build. Useful
  for reproducing failures reported against older Perl versions.
  (FreeBSD only.)
- `-x`, `--xs` — Build and test with XS (default: pure Perl only,
  ipc-shareable only)
- `-h`, `--help` — Print usage and exit.

Prove's `-v` (verbose) is the default. Pass individual test files to
override the default `-v t`:

```bash
./ci/freebsd-test.sh -p ipc-shareable t/85-clean.t                # single test file
./ci/freebsd-test.sh -p ipc-shareable t                           # whole suite, no -v
./ci/freebsd-test.sh -p async-event-interval t/15-interval.t      # aei, single file
./ci/freebsd-test.sh -p ipc-shareable -v 5.20.3 t/85-clean.t     # single file, Perl 5.20.3
```

To target a different (already-created) Lima VM, set the `VM` variable:

```bash
VM=my-other-freebsd ./ci/freebsd-test.sh
```

**`IPC_DEBUG_DELTAS=1`** swaps the single `prove` invocation for a per-file
loop that snapshots `ipcs -s` / `ipcs -m` counts before and after each `.t`
file and emits an `IPC-DELTA LEAK:` line on stderr for any file with a
net-positive delta. Off by default — enable when chasing a per-file
semaphore or shared-memory leak:

```bash
IPC_DEBUG_DELTAS=1 ./ci/freebsd-test.sh -p async-event-interval
```

> **Note:** If the VM does not yet exist, `freebsd-test.sh` will create it
> from `ci/freebsd-lima.yaml` automatically. The first run is slower for
> two reasons:
>
> 1. The disk image is downloaded (~770 MB, cached after the first download).
> 2. Lima's cloud-init YAML is incompatible with FreeBSD's built-in YAML
>    parser, so user/SSH setup must be done via the serial console instead.
>    `freebsd-test.sh` detects this automatically and runs
>    `ci/freebsd-first-boot.py`, which logs in through the QEMU serial
>    console, creates the SSH user, and installs a small rc.d service that
>    writes Lima's boot-done marker on every subsequent boot. This one-time
>    setup takes a few minutes. After it completes, later starts are fast.

---

## OpenBSD CI

Local OpenBSD testing via Lima and QEMU. Targets the CPAN smoker platform:

- `osname=openbsd`, `osvers=7.8`, `archname=OpenBSD.amd64-openbsd`

OpenBSD does not publish pre-built cloud images, so this setup uses the
`generic/openbsd7` Vagrant box (Roboxes). The QCOW2 is extracted once and
cached at `~/.lima/_cache/openbsd7.qcow2`.

Lima has no OpenBSD OS type. The config uses `os:FreeBSD` so that Lima waits
for the file-based boot-done marker instead of the Linux guest agent.
`openbsd-first-boot.py` bootstraps the VM via the QEMU serial console and
installs an rc.d service that writes the marker on every subsequent boot.

### One-time VM setup

Done automatically by `openbsd-test.sh`. To do it manually:

```bash
limactl create --name openbsd-ipc ci/openbsd-lima.yaml
limactl start openbsd-ipc
```

> **Note:** The first run downloads the Vagrant box (~1.1 GB) and extracts the
> QCOW2. This is cached in `~/.lima/_cache/` for subsequent runs. The first
> boot also runs `openbsd-first-boot.py` via the serial console to install the
> Lima SSH key and the boot-done rc.d service (one-time, takes ~1-2 minutes).

### Logging into the VM

```bash
limactl shell openbsd-ipc
```

Or with SSH directly:

```bash
ssh -F ~/.lima/openbsd-ipc/ssh.config lima-openbsd-ipc
```

### Shutting down the VM

```bash
limactl stop openbsd-ipc
limactl delete openbsd-ipc       # also removes disk image
```

### Running the test suite

`openbsd-test.sh` follows the same lifecycle as `freebsd-test.sh`: create VM
if absent, start it, run first-boot setup on the first run, copy source, run
tests, stop the VM on exit.

```bash
./ci/openbsd-test.sh [options] [prove options]
```

**Options:**

- `-p`, `--project <name>` — Project to test: `ipc-shareable` or
  `async-event-interval` (required).
- `-x`, `--xs` — Build and test with XS (default: pure Perl only,
  ipc-shareable only)
- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/openbsd-test.sh -p ipc-shareable t/85-clean.t
./ci/openbsd-test.sh -p async-event-interval t/15-interval.t
./ci/openbsd-test.sh -p ipc-shareable t

VM=my-other-openbsd ./ci/openbsd-test.sh
```

> **Note:** The first run is slow for two reasons:
>
> 1. The Vagrant box is downloaded (~1.1 GB; the extracted QCOW2 is cached
>    at `~/.lima/_cache/openbsd7.qcow2` for subsequent runs).
> 2. The first boot runs `openbsd-first-boot.py` via the QEMU serial console
>    to install the Lima SSH key and a persistent boot-done rc.d service.
>    Subsequent starts are fast.
>
> **Crash recovery:** After a crash (kernel panic, force-stop), OpenBSD runs
> fsck at boot, which is slow under QEMU TCG emulation. The test script
> mitigates this in two ways:
>
> - On shutdown, it SSHs in and runs `doas shutdown -h now` before falling
>   back to `limactl stop`, so the filesystem is almost always clean.
> - After every clean shutdown, it saves a `qemu-img` snapshot on the VM's
>   QCOW2 disk. On the next start, the snapshot is reverted so that the
>   filesystem is never dirty, regardless of how the previous run ended.
> - During `limactl start`, the serial console log is monitored and a warning
>   is printed if fsck is detected (in case both mitigations fail).
>
> If the snapshot itself becomes corrupted, delete and recreate the VM:
> ```bash
> limactl stop --force openbsd-ipc; limactl delete openbsd-ipc
> # Then re-run the test script — it will recreate and provision automatically:
> ./ci/openbsd-test.sh
> ```

---

## Linux i386 CI

Local 32-bit Linux testing via Lima and QEMU.

Modern Debian and Ubuntu no longer publish i386 cloud images, so this setup
uses a Debian 12 (Bookworm) amd64 host VM. On the first run,
`linux-i386-test.sh` creates an i386 debootstrap chroot inside the VM and
installs 32-bit Perl + dependencies there. Tests run inside the chroot via
`systemd-nspawn`. The x86_64 kernel (even when QEMU-emulated on Apple
Silicon) natively executes 32-bit i386 binaries, so this exercises real
32-bit Perl with 32-bit integers and pointers.

The chroot is preserved between runs; only the source tree is re-copied.

### One-time VM setup

Done automatically by `linux-i386-test.sh`. To do it manually:

```bash
limactl create --name linux-i386 ci/linux-i386-lima.yaml
limactl start linux-i386
```

### Logging into the VM

```bash
limactl shell linux-i386
```

Or with SSH directly:

```bash
ssh -F ~/.lima/linux-i386/ssh.config lima-linux-i386
```

To get a shell inside the i386 chroot:

```bash
limactl shell linux-i386 -- sudo systemd-nspawn -D /opt/chroot-i386
```

### Shutting down the VM

```bash
limactl stop linux-i386
limactl delete linux-i386       # also removes disk image
```

### Running the test suite

`linux-i386-test.sh` follows the same lifecycle as `freebsd-test.sh`: create
VM if absent, start it, set up the i386 chroot on the first run, copy source,
run tests in the chroot, stop the VM on exit.

```bash
./ci/linux-i386-test.sh [options] [prove options]
```

**Options:**

- `-p`, `--project <name>` — Project to test: `ipc-shareable` or
  `async-event-interval` (required).
- `-x`, `--xs` — Build and test with XS (default: pure Perl only,
  ipc-shareable only)
- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/linux-i386-test.sh -p ipc-shareable t/85-clean.t
./ci/linux-i386-test.sh -p async-event-interval t/15-interval.t
./ci/linux-i386-test.sh -p ipc-shareable t

VM=my-other-linux ./ci/linux-i386-test.sh
```

> **Note:** The first run is slow (~5-10 min) because it downloads the amd64
> VM image, runs debootstrap to build the i386 chroot, and installs Perl
> packages via cpanm. Subsequent runs only re-copy the source and are much
> faster.

---

## OmniOS CE (Solaris) CI

Local Solaris testing via Lima and QEMU. Targets the CPAN smoker platform:

- `osname=solaris`, `osvers=2.11`, `archname=i86pc-solaris-64`
- `uname: SunOS 5.11 omnios-r151034`

OmniOS CE is the closest freely available match (illumos kernel, same SysV
IPC implementation). The VM runs OmniOS r151058 (current stable).

Lima has no illumos/Solaris OS type. The config uses `os:FreeBSD` so that
Lima waits for the file-based boot-done marker instead of the Linux guest
agent. `solaris-first-boot.py` bootstraps the VM via the QEMU serial console
and installs an SMF service that writes the marker on every subsequent boot.

OmniOS is x86-64 only. On Apple Silicon, QEMU emulates x86-64 via TCG
(software emulation) — the first boot takes 10-20 minutes. Subsequent
starts are much faster once the boot-done SMF service is installed.

### One-time VM setup

Done automatically by `solaris-test.sh`. Manual creation is not recommended:
the OmniOS image is a VMDK, which Lima cannot resize directly. The script
handles this by downloading the VMDK, converting it to QCOW2 (cached at
`~/.lima/_cache/omnios-r151058.qcow2`), and passing a rewritten YAML to
`limactl create`. Running `limactl create` with `solaris-lima.yaml` directly
will fail at the disk-resize step.

### Logging into the VM

```bash
limactl shell solaris-ipc
```

Or with SSH directly:

```bash
ssh -F ~/.lima/solaris-ipc/ssh.config lima-solaris-ipc
```

### Shutting down the VM

```bash
limactl stop solaris-ipc
limactl delete solaris-ipc       # also removes disk image
```

### Running the test suite

`solaris-test.sh` follows the same lifecycle as `freebsd-test.sh`: create VM
if absent, start it, run first-boot setup on the first run, copy source, run
tests, stop the VM on exit.

```bash
./ci/solaris-test.sh [options] [prove options]
```

**Options:**

- `-p`, `--project <name>` — Project to test: `ipc-shareable` or
  `async-event-interval` (required).
- `-x`, `--xs` — Build and test with XS (default: pure Perl only,
  ipc-shareable only)
- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/solaris-test.sh -p ipc-shareable t/85-clean.t
./ci/solaris-test.sh -p async-event-interval t/15-interval.t
./ci/solaris-test.sh -p ipc-shareable t

VM=my-other-solaris ./ci/solaris-test.sh
```

> **Note:** The first run is slow because it:
>
> 1. Downloads the OmniOS VMDK (~1 GB) and converts it to QCOW2 (one-time;
>    cached at `~/.lima/_cache/omnios-r151058.qcow2` for subsequent runs).
> 2. Boots via QEMU TCG emulation (10-20 min on Apple Silicon).
> 3. Runs `solaris-first-boot.py` via the serial console to create the SSH
>    user, install sudo, and set up the SMF boot-done service.
> 4. Installs `runtime/perl`, GCC, and CPAN dependencies via `pkg` + `cpanm`.
>
> **Unclean shutdown:** The test script avoids unclean shutdowns by issuing
> `sudo shutdown -i5 -g0 -y` via SSH and waiting up to 5 minutes for the VM
> to power off before falling back to `limactl stop`.
>
> Two additional mitigations protect against the case where the VM crashes
> (kernel panic, OOM) and SSH shutdown isn't possible:
>
> - `solaris-first-boot.py` writes `set zfs:zfs_scan_legacy = 0` to
>   `/etc/system`, suppressing the full ZFS device scan that would otherwise
>   run after an unclean shutdown (and take hours under TCG emulation).
> - After every clean shutdown, the test script saves a `qemu-img` snapshot
>   on the VM's QCOW2 disk. On the next start, the snapshot is reverted so
>   that the ZFS pool is never dirty, regardless of how the previous run
>   ended.
>
> If the snapshot or QCOW2 cache becomes corrupted, delete both and let the
> script re-download:
> ```bash
> limactl stop --force solaris-ipc; limactl delete solaris-ipc
> rm -f ~/.lima/_cache/omnios-r151058.qcow2
> ./ci/solaris-test.sh
> ```
>
> If the GCC package name has changed in a newer OmniOS release, adjust the
> `pkg install` line in `solaris-test.sh` (try `pkg search gcc` inside the VM).

---

## DragonFly BSD CI

Local DragonFly BSD testing via Lima and QEMU. Targets the CPAN smoker platform:

- `osname=dragonfly`, `archname=x86_64-dragonfly`

**Important:** DragonFly BSD does NOT publish pre-installed cloud/VM images.
The release `.img` and `.iso` files are installers, not bootable systems.
A pre-installed QCOW2 must be created once before the test scripts can be
used. See [Building the base image](#building-the-dragonfly-bsd-base-image) below.

DragonFly BSD is x86-64 only. On Apple Silicon, QEMU emulates x86-64 via TCG
(software emulation) — expect slow boots (~40 seconds to SSH on an installed
system; the installer itself is much slower due to hardware probing).

DragonFly BSD 6.x uses UEFI boot (EFI System Partition). The Lima config
must NOT set `legacyBIOS: true` — that forces SeaBIOS which cannot chainload
the DragonFly EFI bootloader. Lima's default EDK2/OVMF firmware works.

Lima has no DragonFly OS type. The config uses `os:FreeBSD` so that Lima waits
for the file-based boot-done marker instead of the Linux guest agent.
`dragonfly-first-boot.py` bootstraps the VM via the QEMU serial console and
installs an rc.d service that writes the marker on every subsequent boot.

DragonFly does NOT support cloud-init, so all initial setup (user creation,
SSH key installation, boot-done service) is done once by
`dragonfly-first-boot.py` via the QEMU serial console.

### Building the DragonFly BSD base image

DragonFly BSD does not provide pre-installed cloud images. You must create
a base QCOW2 once by running the installer in QEMU interactively:

1. Download the latest release image:

   ```bash
   curl -o /tmp/dfly.img.bz2 \
     https://mirror-master.dragonflybsd.org/iso-images/dfly-x86_64-6.4.2_REL.img.bz2
   bunzip2 /tmp/dfly.img.bz2
   ```

2. Create a QCOW2 target disk for the installation:

   ```bash
   qemu-img create -f qcow2 ~/.lima/_cache/dragonfly64.qcow2 20G
   ```

3. Boot the installer with both the installer image and the target QCOW2:

   ```bash
   cp /opt/homebrew/share/qemu/edk2-i386-vars.fd /tmp/dfly-vars.fd
   qemu-system-x86_64 \
     -m 2048 \
     -cpu max,-avx512vl,-pdpe1gb \
     -machine q35,vmport=off \
     -accel tcg,thread=multi \
     -smp 2 \
     -drive if=pflash,format=raw,readonly=on,file=/opt/homebrew/share/qemu/edk2-x86_64-code.fd \
     -drive if=pflash,format=raw,file=/tmp/dfly-vars.fd \
     -drive file=/tmp/dfly.img,if=ide,format=raw \
     -drive file=~/.lima/_cache/dragonfly64.qcow2,if=ide,format=qcow2 \
     -vga std
   ```

4. In the installer:
   - Select the 20 GB target disk for installation
   - Choose a minimal install (no X11, no games)
   - **Enable serial console**: at the loader prompt before booting the
     installed system, add `console=comconsole` to kernel parameters
   - Enable sshd: add `sshd_enable="YES"` to `/etc/rc.conf`
   - Set up a root password (or leave blank for password-less root)

5. After installation completes, shut down and the QCOW2 at
   `~/.lima/_cache/dragonfly64.qcow2` is ready.

### One-time VM setup

Once the base QCOW2 exists, everything else is automatic. To do it manually:

```bash
limactl create --name dragonfly-ipc ci/dragonfly-lima.yaml
limactl start dragonfly-ipc
```

> **Note:** The first boot runs `dragonfly-first-boot.py` via the serial
> console to create the dragonfly user, install sudo, install the Lima SSH
> key, and set up the boot-done rc.d service (one-time, takes ~1-2 minutes).

### Logging into the VM

```bash
limactl shell dragonfly-ipc
```

Or with SSH directly:

```bash
ssh -F ~/.lima/dragonfly-ipc/ssh.config lima-dragonfly-ipc
```

### Shutting down the VM

```bash
limactl stop dragonfly-ipc
limactl delete dragonfly-ipc       # also removes disk image
```

### Running the test suite

`dragonfly-test.sh` follows the same lifecycle as `openbsd-test.sh`: create VM
if absent, start it, run first-boot setup on the first run, copy source, run
tests, stop the VM on exit.

```bash
./ci/dragonfly-test.sh [options] [prove options]
```

**Options:**

- `-p`, `--project <name>` — Project to test: `ipc-shareable` or
  `async-event-interval` (required).
- `-x`, `--xs` — Build and test with XS (default: pure Perl only,
  ipc-shareable only)
- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/dragonfly-test.sh -p ipc-shareable t/85-clean.t
./ci/dragonfly-test.sh -p async-event-interval t/15-interval.t
./ci/dragonfly-test.sh -p ipc-shareable t

VM=my-other-dragonfly ./ci/dragonfly-test.sh
```

> **Note:** The first run runs `dragonfly-first-boot.py` via the QEMU serial
> console to create the SSH user, install sudo, and set up the persistent
> boot-done rc.d service. This takes ~1-2 minutes. Subsequent starts are fast.
>
> **TCG skip list:** Several tests hang under QEMU TCG emulation because they
> use `SIGALRM` + `sleep` for parent/child synchronization, and signal
> delivery under software emulation is too slow to win the race reliably.
> When running the default full suite (`-v t`), the script automatically
> excludes these tests:
>
> - `t/28-ipchv.t` — hash variable operations with forked children
> - `t/30-ipcref.t` — nested reference synchronization
> - `t/38-lsync.t` — lock synchronization between processes
> - `t/66-protected_persist.t` — protected segment persistence with forks
> - `t/85-clean.t` — cleanup with concurrent processes
>
> To run a skipped test explicitly: `./ci/dragonfly-test.sh t/38-lsync.t`
>
> **Crash recovery:** After first-boot completes, the script takes a
> `qemu-img` snapshot (`clean`). On subsequent runs, it reverts to this
> snapshot before booting so fsck never runs. Post-test snapshots are NOT
> saved — the first-boot snapshot is the only reliable clean state because
> post-test snapshots can include stale IPC segments or incomplete shutdown
> state. If the snapshot becomes corrupted:
> ```bash
> limactl stop --force dragonfly-ipc; limactl delete --force dragonfly-ipc
> rm -f ~/.lima/dragonfly-ipc/.first-boot-done
> ./ci/dragonfly-test.sh
> ```

---

## Technical Information

Reference for diagnosing and rebuilding VMs. This section covers the
internal mechanics that are not obvious from the scripts alone.

### Lima boot-done mechanism

Lima considers a VM "ready" when a file at a specific path contains the
instance-id that Lima wrote to `cidata.iso` for that start. Lima generates
a **new instance-id on every `limactl start`**, so the boot-done script
inside the VM must read the current id from the cidata ISO — not from a
saved file.

**What Lima checks**: The hostagent SSHes into the VM and runs a boot script
that does `cat /run/lima-boot-done` (note: `/run`, not `/var/run`) and
compares the contents to the expected instance-id. If they don't match,
Lima retries every ~3 seconds for 10 minutes, then gives up with
`did not receive an event with the "running" status`.

**How to read the expected instance-id from the host** (portable across
macOS and Linux — `cidata.iso` may be ~10 KB on macOS or ~281 MB on
Linux, so prefer streaming with `grep -aoE` over mounting):

```bash
grep -aoE 'instance-id: [a-zA-Z0-9_-]+' ~/.lima/<VM>/cidata.iso | head -1
```

```python
import subprocess, os
iso = os.path.expanduser("~/.lima/<VM>/cidata.iso")
r = subprocess.run(
    ["grep", "-aoE", "instance-id: [a-zA-Z0-9_-]+", iso],
    capture_output=True, check=True,
)
iid = r.stdout.decode("utf-8", errors="ignore").splitlines()[0].split(":", 1)[1].strip()
```

**How to check what the VM wrote**:

```bash
ssh -F ~/.lima/<VM>/ssh.config lima-<VM> 'cat /run/lima-boot-done; cat /var/run/lima-boot-done'
```

**How to check what Lima is seeing** (debug log):

```bash
cat ~/.lima/<VM>/ha.stderr.log | tail -20
# Look for the boot-done script trace showing the cat and comparison
```

### Per-OS boot-done implementation

Each OS handles the boot-done marker differently because each has different
init systems and device path conventions.

#### FreeBSD

- **Init**: rc.d service (`/etc/rc.d/lima_boot_done`, enabled via
  `lima_boot_done_enable="YES"` in `/etc/rc.conf`).
- **Cidata device**: `/dev/iso9660/cidata` or `/dev/iso9660/CIDATA`.
- **Mount**: `mount_cd9660 -o ro`.
- **Marker path**: `/var/run/lima-boot-done` (FreeBSD symlinks `/run` →
  `/var/run`, so Lima's check of `/run/lima-boot-done` works).
- **Source**: `freebsd-first-boot.py`, `BOOT_DONE_RC_LINES`.

#### OpenBSD

- **Init**: `/etc/rc.local` snippet (idiomatic OpenBSD one-shot).
- **Cidata device**: `/dev/cd0a` or `/dev/cd1a`.
- **Mount**: `mount_cd9660 -o ro`.
- **Marker path**: `/var/run/lima-boot-done` (OpenBSD symlinks `/run` →
  `/var/run`).
- **Source**: `openbsd-first-boot.py`, `BOOT_DONE_RC_LOCAL`.

#### Linux i386

- **Init**: Lima's standard cloud-init (Linux guest agent handles
  boot-done natively). No custom boot-done script needed.
- **Marker path**: `/run/lima-boot-done` (Linux has `/run` as tmpfs).

#### Solaris / OmniOS CE

- **Init**: SMF transient service (`svc:/site/lima_boot_done:default`).
  Manifest at `/var/svc/manifest/site/lima_boot_done.xml`, method script
  at `/lib/svc/method/lima_boot_done`.
- **Cidata device**: `/dev/dsk/c1t0d0s0` (vioscsi SCSI CD-ROM, slice 0).
  Found via `prtconf -D | grep cdrom` — the device path is
  `/pci@0,0/pci1af4,8@2/iport@iport0/cdrom@0,0`.
- **Mount**: `mount -F hsfs -o ro` (HSFS is the illumos ISO9660 filesystem).
- **Marker path**: Must write to **both** `/var/run/lima-boot-done` AND
  `/run/lima-boot-done`. OmniOS does not have `/run` by default (it is not
  a symlink to `/var/run` like on FreeBSD/OpenBSD), so the method script
  must `mkdir -p /run` and write a second copy there. Lima checks `/run`
  only.
- **Source**: `solaris-first-boot.py`, `BOOT_DONE_METHOD_LINES`.

#### DragonFly BSD

- **Init**: rc.d service (`/usr/local/etc/rc.d/lima_boot_done`, enabled via
  `lima_boot_done_enable="YES"` in `/etc/rc.conf`).
- **Cidata device**: `/dev/cd0`.
- **Mount**: `mount_cd9660 -o ro`.
- **Marker path**: `/var/run/lima-boot-done` and `/run/lima-boot-done`.
  DragonFly symlinks `/run` → `/var/run`, so both paths work — the script
  writes to both for safety.
- **Source**: `dragonfly-first-boot.py`, `BOOT_DONE_RC_LINES`.

### Diagnosing a stuck `limactl start`

If `limactl start <VM>` hangs past the SSH phase:

1. **Check if SSH works**:
   ```bash
   ssh -F ~/.lima/<VM>/ssh.config lima-<VM> true && echo OK
   ```
2. **Check the marker**:
   ```bash
   ssh -F ~/.lima/<VM>/ssh.config lima-<VM> 'cat /run/lima-boot-done 2>&1; cat /var/run/lima-boot-done 2>&1'
   ```
3. **Check what Lima expects** (portable; works on macOS and Linux):
   ```bash
   grep -aoE 'instance-id: [a-zA-Z0-9_-]+' ~/.lima/<VM>/cidata.iso | head -1
   ```
4. **Check the hostagent debug log**:
   ```bash
   tail -20 ~/.lima/<VM>/ha.stderr.log
   # Look for the [ '' = iid-XXXXXXXXXX ] comparison — empty LHS means
   # the marker file is missing or at the wrong path.
   ```
5. **Fix it live** (while the VM is still running):
   ```bash
   # Write the correct marker so the blocked limactl start completes
   IID=$(grep -aoE 'instance-id: [a-zA-Z0-9_-]+' ~/.lima/<VM>/cidata.iso | head -1 | awk '{print $2}')
   ssh -F ~/.lima/<VM>/ssh.config lima-<VM> "sudo sh -c 'mkdir -p /run; echo $IID > /run/lima-boot-done; echo $IID > /var/run/lima-boot-done'"
   ```

### Crash recovery and QCOW2 snapshots

OpenBSD and Solaris VMs run x86_64 under QEMU TCG emulation on Apple Silicon.
After an unclean shutdown (kernel panic, OOM kill, force-stop), boot-time
filesystem checks that take seconds on bare metal are magnified 10-100x:

- **OpenBSD**: FFS fsck traverses filesystem metadata. Under TCG this can
  take tens of minutes.
- **Solaris/OmniOS**: ZFS performs a full pool device scan. Under TCG this
  can take **hours**.

The test scripts for these VMs use a QCOW2 snapshot strategy to avoid ever
booting a dirty filesystem:

**How it works:**

1. On shutdown, the script SSHs into the VM and issues a clean OS-level
   shutdown (`doas shutdown -h now` for OpenBSD, `sudo shutdown -i5 -g0 -y`
   for Solaris). It polls until the VM powers off.
2. If the VM stops cleanly, `qemu-img snapshot -c clean` saves a named
   snapshot on `~/.lima/<VM>/disk`. The snapshot captures the filesystem in
   a clean (fsck'd / ZFS-exported) state.
3. On the next `limactl start`, the script runs `qemu-img snapshot -a clean`
   to revert to the last clean snapshot before booting. The filesystem is
   never marked dirty, so fsck and ZFS scans never run.
4. If the VM crashed and the script had to force-stop, no snapshot is saved —
   the previous clean snapshot is reverted on the next start instead.

This means that even after a hard crash, the VM boots from the last
known-clean state. The only cost is that any filesystem changes made during
the crashed run (test output, core dumps, package installs) are discarded.
Since the scripts re-copy the source tree and re-install packages idempotently
on every run, this is harmless.

**First-boot snapshot:**

After `*-first-boot.py` completes successfully, the test script takes an
initial snapshot. The first-boot script halts the VM cleanly (via the guest
OS's own shutdown), so the filesystem is already clean.

**Manual snapshot management:**

```bash
# List snapshots
qemu-img snapshot -l ~/.lima/openbsd-ipc/disk

# Revert to a snapshot (VM must be stopped)
qemu-img snapshot -a clean ~/.lima/openbsd-ipc/disk

# Delete a snapshot
qemu-img snapshot -d clean ~/.lima/openbsd-ipc/disk
```

**Additional Solaris mitigation:**

Beyond snapshots, `solaris-first-boot.py` writes `set zfs:zfs_scan_legacy = 0`
to `/etc/system` inside the VM. This kernel parameter disables the legacy ZFS
pool scan at import time, so even if the VM boots a dirty pool (e.g. before
the first snapshot exists), ZFS won't spend hours scanning. This parameter
takes effect on the next boot after first-boot completes.

### Rebuilding a VM from scratch

If a VM's disk is corrupted or you need a clean slate:

```bash
limactl stop --force <VM> 2>/dev/null
limactl delete <VM>
# For Solaris and DragonFly, also delete the first-boot sentinel if it exists:
rm -f ~/.lima/<VM>/.first-boot-done
# Then run the test script — it will recreate and provision automatically:
./ci/<os>-test.sh
```

For Solaris specifically, if the QCOW2 cache is corrupted (e.g. after a
force-kill during boot that left ZFS dirty):

```bash
rm -f ~/.lima/_cache/omnios-r151058.qcow2
# The test script will re-download and re-convert from the VMDK.
```

For DragonFly BSD, if the QCOW2 cache needs rebuilding:

```bash
rm -f ~/.lima/_cache/dragonfly64.qcow2
# DragonFly BSD does NOT provide pre-installed images — you must rebuild the
# QCOW2 manually by running the installer in QEMU. The test script will exit
# with an error if the cached QCOW2 is missing. See § Building the DragonFly
# BSD base image above for the step-by-step interactive install procedure.
```

### Expected boot times (Apple Silicon, M-series)

| VM            | Arch    | Emulation | Boot → SSH | Boot → Ready |
|---------------|---------|-----------|------------|--------------|
| freebsd-ipc   | aarch64 | Native    | ~6s        | ~7s          |
| linux-i386    | x86_64  | TCG       | ~24s       | ~29s         |
| openbsd-ipc   | x86_64  | TCG       | ~32s       | ~33s         |
| dragonfly-ipc | x86_64  | TCG       | ~40s       | ~42s         |
| solaris-ipc   | x86_64  | TCG       | ~56s       | ~58s         |

FreeBSD is fastest because it runs natively on Apple Silicon (aarch64,
hardware virtualisation). The other four use QEMU TCG (software x86_64
emulation). Solaris is slowest due to the illumos boot sequence (SMF
dependency resolution, ZFS pool import). DragonFly BSD boots faster than
Solaris but slower than OpenBSD due to its device probing sequence.

### Solaris-specific quirks

- **No `/run` directory.** OmniOS uses `/var/run` exclusively. Any script
  that writes a marker, PID file, or socket to `/run` must also create the
  directory and write a copy there if Lima or another tool expects it.
- **HSFS for ISO9660.** Use `mount -F hsfs`, not `mount -t iso9660`.
- **Shutdown must use `shutdown -i5 -g0 -y`**, not `poweroff` or `halt`.
  The ACPI powerdown (`limactl stop`) also works but is slower under TCG.
  Always prefer the SSH shutdown path to ensure ZFS gets a clean export.
- **`pkg install` is idempotent** — already-installed packages are skipped.
  GCC is currently `developer/gcc14`; if OmniOS bumps the version, use
  `pkg search gcc` inside the VM to find the new package name.
- **`cpanm` may land outside `$PATH`** on OmniOS. The test script searches
  `/usr/perl5` and `/opt` for the binary and symlinks it to `/usr/bin/cpanm`.
- **`gmake` required for CPAN XS builds.** OmniOS's `/usr/bin/make` is not
  GNU make. Pass `MAKE=gmake` to `cpanm` or `perl Makefile.PL`.

### DragonFly-specific quirks

- **x86_64 only.** DragonFly BSD does not support aarch64. All testing
  requires QEMU TCG emulation on Apple Silicon.
- **No cloud-init support.** All user creation and SSH key setup is done
  via the serial console by `dragonfly-first-boot.py`.
- **`pkg` for packages.** DragonFly uses the same `pkg` command as FreeBSD
  (DPorts). Install Perl deps with `sudo pkg install -y perl5 p5-App-cpanminus gmake`.
- **rc.d in `/usr/local/etc/rc.d/`.** User-installed services go in
  `/usr/local/etc/rc.d/`, not `/etc/rc.d/` (which is for base system services).
- **`gmake` required for CPAN XS builds.** DragonFly's `/usr/bin/make` is BSD
  make, not GNU make. Pass `MAKE=gmake` or use `gmake` directly.
- **UEFI boot required — "XMMNNOO" symptom.** DragonFly BSD 6.x images
  contain an EFI System Partition (MBR type `0xEF`). Setting `legacyBIOS: true`
  in the Lima YAML forces SeaBIOS firmware, which produces exactly 7 bytes of
  garbled output (`XMMNNOO`) in `serial.log` and zero CPU activity — the VM
  will never boot. Lima's default EDK2/OVMF firmware works correctly. The
  firmware files are at `/opt/homebrew/share/qemu/edk2-x86_64-code.fd` and
  `/opt/homebrew/share/qemu/edk2-i386-vars.fd` (Apple Silicon Homebrew paths).
- **Console routing: serial vs virtio.** During UEFI boot, the bootloader
  output goes to the serial port (`serial.log`). After the kernel takes over,
  output goes to the **virtio console** (`serialv.log`), not the serial port.
  This means `dragonfly-first-boot.py` monitoring `serial.log` for `login:`
  will NOT see the login prompt on an unconfigured installed system. The
  installed system must be configured with `console=comconsole` in
  `/boot/loader.conf` to route kernel output to the serial port. Without this,
  the first-boot script cannot detect when the VM is ready for setup.
  **Important:** The `loader.conf` check must use `grep -qF 'console="comconsole"'`
  (exact fixed string), not `grep -q console` — the latter matches any line
  containing the word "console" (e.g. comments, unrelated settings), causing
  the append to be silently skipped.
- **`boot -s` (single-user mode) is silently ignored.** DragonFly's EFI
  bootloader accepts `boot -s` without error but does not set the single-user
  flag. The kernel boots into multi-user mode regardless. Do not rely on
  `boot -s` — boot normally and log in as root. This also means `init=/bin/sh`
  cannot be used: the shell becomes PID 1, and any child process exit triggers
  a kernel panic (`exit1()` → `sys_exit()` → panic on PID 1).
- **Root shell is csh.** DragonFly's default root login shell is `/bin/csh`.
  csh does not support fd redirection (`2>/dev/null` creates a file named `2`),
  brace grouping (`{ }` gives "Ambiguous output redirect"), or `2>&1`.
  After logging in, immediately run `exec /bin/sh` to switch to a POSIX shell
  before issuing any setup commands.
- **`/bin/sh` does not support `-l`.** DragonFly's `/bin/sh` rejects the `-l`
  (login shell) flag with "Illegal option -l". Lima internally passes `-l` to
  the user's login shell. The workaround is a wrapper script at
  `/usr/local/bin/sh-lima` that strips `-l` and execs `/bin/sh`:
  ```sh
  #!/bin/sh
  case "$1" in -l) shift ;; esac
  exec /bin/sh "$@"
  ```
  The guest user is created with `-s /usr/local/bin/sh-lima` so Lima's SSH
  shell invocation works. The test script must also use `sh -c` (not `sh -lc`)
  for all `limactl shell` commands.
- **Serial UART FIFO drops heredoc delimiters under TCG.** QEMU's emulated
  serial UART has a small FIFO buffer. When writing long heredocs via
  `_send_wait()`, the closing delimiter (e.g. `EOF`) can be dropped under
  slow TCG emulation, leaving the shell stuck in continuation mode. The
  first-boot script works around this by writing the boot-done rc.d service
  line-by-line using `printf '%s\n' '...' >> file` instead of a heredoc.
- **sshd privilege separation requires manual setup.** DragonFly's base
  install may not have the `sshd` user or a properly configured `/var/empty`.
  The first-boot script creates the `sshd` user (`pw useradd sshd -d /var/empty
  -s /usr/sbin/nologin`), rebuilds the password database (`pwd_mkdb
  /etc/master.passwd`), and sets permissions on `/var/empty` (`chmod 755`,
  `chown root:wheel`). Without this, sshd exits immediately with a privsep
  error ("Connection reset by peer" on the client side). Use `ssh-keygen -A`
  to generate all standard host keys.
- **QEMU user-mode networking (SLIRP).** The VM uses QEMU's built-in user-mode
  network stack: gateway `10.0.2.2`, guest IP `10.0.2.15`, DNS `10.0.2.3`.
  During first-boot (before rc.conf is configured), a static IP is set with
  `ifconfig vtnet0 10.0.2.15 netmask 255.255.255.0 up` and `route add default
  10.0.2.2`. For persistence across Lima-managed reboots, `ifconfig_vtnet0="DHCP"`
  is written to `/etc/rc.conf`.
- **`shutdown -p` required (not `-h`).** `shutdown -h` halts the CPU but does
  not send ACPI power-off to QEMU — the process stays running indefinitely.
  Use `shutdown -p now` to actually power off the VM. Also set
  `sendmail_enable="NONE"` in `/etc/rc.conf` to avoid a ~30s sendmail stop
  delay during shutdown.
- **`shmid_ds` struct layout varies.** DragonFly's `shmid_ds` struct (from
  `sys/shm.h`) may or may not include `__shm_*timensec` fields depending
  on the kernel version. With nanosecond fields, the struct is ~108 bytes;
  without, ~88 bytes. `SharedMem.pm` detects this at runtime via
  `length($data) > 96` and uses the appropriate `unpack` template. Without
  this, `shmctl(IPC_STAT)` returns `undef` for time fields (e.g. `ctime`),
  causing `t/05-shm_stat.t` to fail.
- **No pre-installed images exist.** DragonFly BSD publishes only installer
  `.img` and `.iso` files at `https://mirror-master.dragonflybsd.org/iso-images/`.
  There are NO cloud images, Vagrant boxes, or third-party VM images. The
  `.img` files contain a DOS/MBR partition table: partition 1 is the EFI
  System Partition (type `0xEF`, ~126 MB), partition 2 is the DragonFly BSD
  root (type `0x6C`, active, ~1.8 GB). These images boot into an ncurses
  installer, not a login shell. The installer's TCG hardware probing takes
  >10 minutes, exceeding Lima's startup timeout. A pre-installed QCOW2 must
  be built once interactively before any automation can work.
- **ipcs format differs from Linux/BSD.** DragonFly's `ipcs -m` output puts
  the shmid in column 1: `<shmid> <hex_key> <owner> <perms> <bytes> <nattch>`.
  Linux puts the key in column 1 and shmid in column 2; FreeBSD/OpenBSD prefix
  with a type letter (`m`). IPC cleanup scripts must use `$1` (not `$2`) to
  extract the shmid on DragonFly. The parser in `Shareable.pm` uses the regex
  `^\s*(\d+)\s+(0x[0-9a-fA-F]+)\s+/` to match this format.
- **DDB (kernel debugger) detection.** Under TCG emulation, certain operations
  can trigger a kernel panic that drops into DragonFly's DDB debugger instead
  of halting. The first-boot script monitors for `db>` prompts in the serial
  output and aborts immediately if detected, rather than hanging on a marker
  that will never arrive.
