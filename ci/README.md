# CI Test Runners

Scripts for running IPC::Shareable tests inside local VMs via
[Lima](https://lima-vm.io/) and QEMU.

## Contents

- [Lima basics](#lima-basics)
- [Unified test runner (`vm-tests.sh`)](#unified-test-runner-vm-testssh)
- [FreeBSD CI](#freebsd-ci)
- [OpenBSD CI](#openbsd-ci)
- [Linux i386 CI](#linux-i386-ci)
- [OmniOS CE (Solaris) CI](#omnios-ce-solaris-ci)

## Lima basics

[Lima](https://lima-vm.io/) launches Linux (and experimentally, non-Linux) VMs
on macOS via QEMU, with automatic file sharing and port forwarding.

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

## Unified test runner (`vm-tests.sh`)

Runs tests on one or more VMs sequentially and prints a summary with failed
test details.

```bash
./ci/vm-tests.sh [options] [prove options]
```

### Options

| Flag | Description |
|------|-------------|
| `-f`, `--freebsd` | Run FreeBSD tests |
| `-l`, `--linux` | Run 32-bit Linux (i386) tests |
| `-o`, `--openbsd` | Run OpenBSD tests |
| `-s`, `--solaris` | Run Solaris/OmniOS tests |
| `-a`, `--all` | Run all VMs (default) |
| `-k`, `--keep-logs` | Keep log files after the run |
| `-h`, `--help` | Print usage and exit |

Prove options are forwarded to each VM test script (default: `-v t`).

### Examples

```bash
./ci/vm-tests.sh                       # all VMs, full suite
./ci/vm-tests.sh -s                    # Solaris only
./ci/vm-tests.sh -f -l t/20-lock.t     # FreeBSD + Linux, single test
./ci/vm-tests.sh -ks                   # Solaris only, keep logs
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

Create and start the VM from the project's Lima template:

```bash
limactl create --name freebsd-ipc ci/freebsd-lima.yaml
limactl start freebsd-ipc
```

`freebsd-lima.yaml` provisions a FreeBSD 14.3 aarch64 VM with the base Perl
packages pre-installed.

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

- `--german` — Run tests with `LC_ALL=de_DE.ISO8859-1` (German locale).
  Useful for reproducing failures reported by CPAN smokers running on
  German-locale FreeBSD systems.
- `--perl-version <ver>` — Build and test with a specific Perl version
  managed by perlbrew (e.g. `5.20.3`). Compiles Perl from source on the
  first run (10-20 min); subsequent runs reuse the cached build. Useful
  for reproducing failures reported against older Perl versions.
- `-h`, `--help` — Print usage and exit.

By default this runs `prove -l -v t` inside the VM. Pass your own prove
arguments to override:

```bash
./ci/freebsd-test.sh t/85-clean.t                     # single test file
./ci/freebsd-test.sh -v t/85-clean.t                  # verbose, single file
./ci/freebsd-test.sh t                                # whole suite, no -v
./ci/freebsd-test.sh --german                         # full suite, German locale
./ci/freebsd-test.sh --german --perl-version 5.20.3   # German locale + Perl 5.20.3
./ci/freebsd-test.sh --perl-version 5.20.3 t/85-clean.t  # single file, Perl 5.20.3
```

To target a different (already-created) Lima VM, set the `VM` variable:

```bash
VM=my-other-freebsd ./ci/freebsd-test.sh
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

- `-x`, `--xs` — Build and test with XS (default: pure Perl only)
- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/openbsd-test.sh t/85-clean.t
./ci/openbsd-test.sh t

VM=my-other-openbsd ./ci/openbsd-test.sh
```

> **Note:** The first run is slow for two reasons:
>
> 1. The Vagrant box is downloaded (~1.1 GB; the extracted QCOW2 is cached
>    at `~/.lima/_cache/openbsd7.qcow2` for subsequent runs).
> 2. The first boot runs `openbsd-first-boot.py` via the QEMU serial console
>    to install the Lima SSH key and a persistent boot-done rc.d service.
>    Subsequent starts are fast.

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

- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/linux-i386-test.sh t/85-clean.t
./ci/linux-i386-test.sh t

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

- `-h`, `--help` — Print usage and exit.

Same prove argument override syntax applies:

```bash
./ci/solaris-test.sh t/85-clean.t
./ci/solaris-test.sh t

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
> **Unclean shutdown warning:** Always let the script stop the VM. Killing
> QEMU or force-deleting the VM triggers a full ZFS device scan on next boot,
> which can take hours under TCG emulation. If this happens, delete the
> QCOW2 cache (`~/.lima/_cache/omnios-r151058.qcow2`) and let the script
> re-download the image.
>
> If the GCC package name has changed in a newer OmniOS release, adjust the
> `pkg install` line in `solaris-test.sh` (try `pkg search gcc` inside the VM).
