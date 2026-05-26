#!/usr/bin/env python3
"""
ci/dragonfly-first-boot.py  --  one-time bootstrap for the DragonFly BSD Lima VM.

DragonFly BSD does not support cloud-init, and its kernel defaults to using
the VGA console (not serial).  Since QEMU runs with `-display none`, the
kernel output is invisible and Lima can never detect a boot-done marker.

This script launches QEMU directly with `-nographic`, interrupts the
bootloader to set `console=comconsole`, then performs all initial setup
via the serial console.  Once complete it halts the VM so Lima can manage
subsequent boots.

What it does:
  1. Launches QEMU directly with -nographic and UEFI firmware.
  2. Waits for the DragonFly EFI bootloader menu on the serial console.
  3. Interrupts the auto-boot countdown and escapes to the loader prompt.
  4. Sets console=comconsole and boots into multi-user mode.
     Waits for the login prompt and logs in as root (blank password).
  5. Mounts filesystems, clears any root password, then configures:
     sudo, guest user, Lima SSH key, boot-done rc.d service.
  6. Writes console="comconsole" to /boot/loader.conf for future boots.
  7. Writes the boot-done marker and halts the VM.

Usage:
    python3 ci/dragonfly-first-boot.py [VM_NAME]
    VM_NAME defaults to 'dragonfly-ipc'.
"""

import os
import pty
import select
import shutil
import subprocess
import sys
import tempfile
import termios
import time

VM = sys.argv[1] if len(sys.argv) > 1 else "dragonfly-ipc"
LIMA_DIR = os.path.expanduser(f"~/.lima/{VM}")
DISK = os.path.join(LIMA_DIR, "disk")
CIDATA_ISO = os.path.join(LIMA_DIR, "cidata.iso")
SSH_PORT = 60233

GUEST_USER = "dragonfly"
GUEST_HOME = f"/home/{GUEST_USER}.guest"

QEMU_BIN = "/opt/homebrew/bin/qemu-system-x86_64"
OVMF_CODE = "/opt/homebrew/share/qemu/edk2-x86_64-code.fd"
OVMF_VARS_TEMPLATE = "/opt/homebrew/share/qemu/edk2-i386-vars.fd"


# ── helpers ────────────────────────────────────────────────────────────────

def get_lima_pubkey():
    with open(os.path.expanduser("~/.lima/_config/user.pub")) as f:
        return f.read().strip()


def get_instance_id():
    """Extract the cloud-init instance-id from cidata.iso.

    Reads the ISO bytes directly — the meta-data text is embedded
    literally and the ISO is only a few KB.  Avoids fragile hdiutil
    mount/detach which can fail on stale mounts or macOS restrictions.
    """
    iso = CIDATA_ISO
    if not os.path.exists(iso):
        return None
    with open(iso, "rb") as f:
        data = f.read().decode("utf-8", errors="ignore")
    for line in data.splitlines():
        if line.strip().startswith("instance-id:"):
            return line.split(":", 1)[1].strip()
    return None


def _read(fd, timeout=1.0):
    """Read available bytes from fd within *timeout* seconds."""
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        r, _, _ = select.select([fd], [], [], max(0, deadline - time.time()))
        if not r:
            break
        try:
            chunk = os.read(fd, 4096)
            if not chunk:
                break
            buf += chunk
        except (BlockingIOError, OSError):
            break
    return buf.decode("utf-8", errors="replace")


def _wait_for(fd, marker, timeout=300):
    """Read from fd until *marker* appears.  Returns all output read."""
    print(f"    waiting for {marker!r}", end="", flush=True)
    buf = ""
    start = time.time()
    while time.time() - start < timeout:
        buf += _read(fd, timeout=1.0)
        if marker in buf:
            # Extra read: the marker may have appeared in a DDB echo
            # of the command text, before the "No such command\ndb>"
            # response arrives.  A brief extra read catches that.
            buf += _read(fd, timeout=1.0)
            print(" ok")
            return buf
        if "db>" in buf:
            print(" KERNEL DEBUGGER")
            return buf
        print(".", end="", flush=True)
    print(" TIMED OUT")
    return buf


_CMD_COUNTER = 0


def _send_wait(fd, cmd, timeout=120):
    """Send a command and wait for a unique completion marker.

    Writes the command and a SEPARATE 'echo <marker>' line so the marker
    only appears in the output AFTER the main command finishes executing.
    This avoids false matches on the terminal echo of the command line itself
    (which would contain the marker if we used '; echo <marker>' inline).
    """
    global _CMD_COUNTER
    _CMD_COUNTER += 1
    marker = f"__CMD_{_CMD_COUNTER}_DONE__"
    # Write the main command first
    os.write(fd, (cmd + "\n").encode())
    time.sleep(0.5)
    # Then write the marker on its own line — shell won't read this
    # until after the main command finishes
    os.write(fd, f"echo {marker}\n".encode())
    out = _wait_for(fd, marker, timeout=timeout)
    if "db>" in out:
        sys.exit(f"[first-boot] FATAL: VM panicked — kernel debugger (DDB) detected.\n"
                 f"[first-boot] Output: {out[-300:]!r}")
    return out, marker in out


# ── rc.d boot-done script installed inside the VM ──────────────────────────

BOOT_DONE_RC_LINES = [
    "#!/bin/sh",
    "# PROVIDE: lima_boot_done",
    "# REQUIRE: NETWORKING",
    "# BEFORE: LOGIN",
    ". /etc/rc.subr",
    "name=lima_boot_done",
    "rcvar=lima_boot_done_enable",
    'start_cmd="${name}_start"',
    'stop_cmd=":"',
    "lima_boot_done_start()",
    "{",
    "  CIDATA_DEV=/dev/cd0",
    "  MNT=/tmp/.lima-cidata",
    '  mkdir -p "$MNT" 2>/dev/null',
    '  if mount_cd9660 -o ro "$CIDATA_DEV" "$MNT" 2>/dev/null; then',
    "    IID=$(awk '/^instance-id:/{print $2}'"
    " \"$MNT/meta-data\" 2>/dev/null)",
    '    umount "$MNT" 2>/dev/null',
    '    if [ -n "$IID" ]; then',
    '      echo "$IID" > /var/run/lima-boot-done',
    "      mkdir -p /run 2>/dev/null",
    '      echo "$IID" > /run/lima-boot-done',
    "    fi",
    "  fi",
    '  rmdir "$MNT" 2>/dev/null',
    "}",
    "load_rc_config $name",
    'run_rc_command "$1"',
]


# ── bootloader interaction ─────────────────────────────────────────────────

def interact_with_bootloader(fd):
    """Interrupt the DragonFly EFI bootloader and set console=comconsole.

    The bootloader outputs the menu to the serial port and then starts a
    10-second auto-boot countdown (which renders to VGA, not serial — so
    we cannot detect it via serial output).  We use a timer: wait for the
    bootloader to appear, pause for the menu to render, then repeatedly
    send Escape to cancel the countdown before it expires.  After
    interrupting, we select option 9 (loader prompt), set the console,
    and boot.
    """
    print("[first-boot] Waiting for DragonFly EFI bootloader...")
    buf = ""
    start = time.time()

    while "DragonFly EFI" not in buf:
        if time.time() - start > 180:
            sys.exit("ERROR: bootloader never appeared on serial console")
        buf += _read(fd, timeout=1.0)

    print("[first-boot] Bootloader detected (%.0fs)." % (time.time() - start))

    # The menu renders over ~2 s, then a 10 s countdown begins.  Under TCG
    # the emulated seconds are stretched, giving us more real time.
    # We pause briefly for the menu, then spam Escape to interrupt the
    # countdown before it expires (wherever it currently is).
    time.sleep(3.0)

    print("[first-boot] Interrupting auto-boot countdown...")
    for _ in range(5):
        os.write(fd, b"\x1b")
        time.sleep(0.3)
    os.write(fd, b" ")
    time.sleep(0.5)
    _read(fd, timeout=1.0)  # drain

    # Select option 9: "Escape to loader prompt"
    print("[first-boot] Selecting 'Escape to loader prompt' (option 9)...")
    time.sleep(0.3)
    os.write(fd, b"9")
    time.sleep(0.5)
    os.write(fd, b"\r")
    time.sleep(1.5)
    buf = _read(fd, timeout=2.0)

    print(f"[first-boot] After menu selection: {buf[-200:]!r}")

    # Set console=comconsole and boot normally (multi-user).
    # DragonFly's bootloader ignores "boot -s", so don't waste time
    # waiting for a single-user prompt that never comes.
    print("[first-boot] Setting console=comconsole, booting...")
    os.write(fd, b"set console=comconsole\r")
    time.sleep(0.6)
    os.write(fd, b"boot\r")
    time.sleep(0.6)

    print("[first-boot] Kernel booting — waiting for login prompt...")
    buf = _wait_for(fd, "login:", timeout=300)

    os.write(fd, b"\n")
    time.sleep(1)
    buf += _read(fd, timeout=2.0)
    return buf


# ── VM setup via serial console ────────────────────────────────────────────

def setup_vm(fd, ssh_key, iid):
    """In single-user mode, /sbin/init is PID 1 and has dropped to a
    root shell (a child process).  Verify we have the shell, mount
    filesystems, and perform all first-boot configuration."""

    # Verify we have a working root shell
    print("[first-boot] Checking for root shell or login prompt...")
    os.write(fd, b"\n")
    time.sleep(1.5)
    initial = _read(fd, timeout=2.0)

    if "login:" in initial:
        # Ended up at a login prompt — try password-less root login
        print("[first-boot] Got login prompt, trying root with blank password...")
        os.write(fd, b"root\n")
        time.sleep(2)
        out = _read(fd, timeout=2.0)
        if "assword" in out or "Password" in out:
            os.write(fd, b"\n")
            time.sleep(1)
            _read(fd, timeout=1.0)
        out, ok = _send_wait(fd, "echo PING", timeout=30)
        if not ok or "PING" not in out:
            sys.exit(f"[first-boot] ERROR: root login failed (image has a"
                     f" root password set). Rebuild the QCOW2 without a"
                     f" password, or use the installer ISO to blank it."
                     f" Output: {out[-300:]!r}")
        print("[first-boot] Got root shell.")
    else:
        print("[first-boot] At root shell (single-user mode).")

    # DragonFly's default root shell is csh, which doesn't support
    # fd redirection (2>/dev/null) or { } grouping.  Switch to sh.
    print("[first-boot] Switching to /bin/sh...")
    _send_wait(fd, "exec /bin/sh", timeout=10)

    # Mount filesystems read-write (single-user starts with / ro)
    print("[first-boot] Mounting filesystems...")
    _send_wait(fd, "mount -u / 2>&1 || true", timeout=120)
    _send_wait(fd, "mount -a 2>&1 || true", timeout=120)

    # Bring up networking — static IP for QEMU user-mode network
    # (10.0.2.0/24).  dhclient is unreliable in single-user mode.
    print("[first-boot] Configuring network...")
    _send_wait(fd, "mkdir -p /var/run /var/empty", timeout=10)
    _send_wait(fd, "ifconfig lo0 127.0.0.1 up", timeout=10)
    _send_wait(fd, "ifconfig vtnet0 10.0.2.15 netmask 255.255.255.0 up", timeout=10)
    _send_wait(fd, "route add default 10.0.2.2 2>&1 || true", timeout=10)
    _send_wait(fd, "echo 'nameserver 10.0.2.3' > /etc/resolv.conf", timeout=10)

    # Verify we have a working shell
    out, ok = _send_wait(fd, "echo PING", timeout=30)
    if not ok or "PING" not in out:
        os.write(fd, b"\n")
        time.sleep(1)
        out, ok = _send_wait(fd, "echo PING", timeout=30)
    if not ok or "PING" not in out:
        sys.exit(f"[first-boot] ERROR: no root shell. Got: {out[-300:]!r}")
    print("[first-boot] Got working shell.")

    # Clear any root password so future multi-user boots work
    print("[first-boot] Clearing root password...")
    _send_wait(fd, "echo '' | pw usermod root -h 0", timeout=15)

    # Persist serial console setting so Lima-managed boots use it
    print("[first-boot] Writing /boot/loader.conf...")
    _send_wait(fd,
               'grep -q console /boot/loader.conf 2>/dev/null'
               ' && echo "console=comconsole (already set)"'
               ' || echo \'console="comconsole"\' >> /boot/loader.conf',
               timeout=15)

    # Enable sshd and DHCP networking on boot — the runtime ifconfig
    # from earlier doesn't survive reboot, so Lima-managed boots need
    # DHCP in rc.conf for the interface to come up.
    print("[first-boot] Enabling sshd and network in rc.conf...")
    _send_wait(fd,
               "grep -q sshd_enable /etc/rc.conf 2>/dev/null"
               " || echo 'sshd_enable=\"YES\"' >> /etc/rc.conf",
               timeout=15)
    _send_wait(fd,
               "grep -q ifconfig_vtnet0 /etc/rc.conf 2>/dev/null"
               " || echo 'ifconfig_vtnet0=\"DHCP\"' >> /etc/rc.conf",
               timeout=15)

    # Generate all standard host keys (RSA, ECDSA, ED25519)
    print("[first-boot] Generating SSH host keys...")
    _send_wait(fd, "ssh-keygen -A 2>&1", timeout=300)

    # Tune sshd_config — don't touch HostKey lines (ssh-keygen -A
    # created keys matching the defaults in sshd_config)
    print("[first-boot] Configuring sshd...")
    _send_wait(fd,
               "grep -q '^UseDNS no' /etc/ssh/sshd_config 2>/dev/null"
               " || echo 'UseDNS no' >> /etc/ssh/sshd_config",
               timeout=15)
    _send_wait(fd,
               "grep -q '^GSSAPIAuthentication no' /etc/ssh/sshd_config 2>/dev/null"
               " || echo 'GSSAPIAuthentication no' >> /etc/ssh/sshd_config",
               timeout=15)
    _send_wait(fd,
               "grep -q '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null"
               " || echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config",
               timeout=15)

    # Privilege separation: sshd user + password DB rebuild + /var/empty
    _send_wait(fd,
               "pw user show sshd >/dev/null 2>&1"
               " || pw useradd sshd -d /var/empty -s /usr/sbin/nologin 2>/dev/null"
               " || true",
               timeout=15)
    _send_wait(fd, "pwd_mkdb /etc/master.passwd 2>&1 || true", timeout=30)
    _send_wait(fd, "chmod 755 /var/empty && chown root:wheel /var/empty", timeout=10)

    # Verify config
    out, _ = _send_wait(fd, "/usr/sbin/sshd -t -e 2>&1; echo SSHD_T=$?", timeout=15)
    if "SSHD_T=0" not in out:
        print(f"[first-boot] sshd config test: {out[-200:]!r}")

    print("[first-boot] Starting sshd...")
    _send_wait(fd, "/usr/sbin/sshd -e 2>/tmp/sshd.log", timeout=15)
    time.sleep(3)
    out, _ = _send_wait(fd,
                        "ps aux | grep '[s]shd' >/dev/null && echo SSHD_RUNNING"
                        " || echo SSHD_FAILED",
                        timeout=15)
    if "SSHD_FAILED" in out:
        out2, _ = _send_wait(fd, "cat /tmp/sshd.log 2>/dev/null", timeout=10)
        print(f"[first-boot] sshd failed to stay running: {out2[-300:]!r}")

    # Install sudo via pkg (long-running under TCG)
    print("[first-boot] Installing sudo...")
    _send_wait(fd, "pkg install -y sudo", timeout=300)

    # Create a /bin/sh wrapper that accepts -l (which DragonFly's
    # /bin/sh rejects).  Lima invokes the login shell with -l internally.
    SH_WRAPPER = "/usr/local/bin/sh-lima"
    print("[first-boot] Installing sh-lima wrapper...")
    _send_wait(fd, "mkdir -p /usr/local/bin", timeout=10)
    _send_wait(fd, f"echo '#!/bin/sh' > {SH_WRAPPER}", timeout=5)
    _send_wait(fd, f"echo 'case \"$1\" in -l) shift ;; esac' >> {SH_WRAPPER}",
               timeout=5)
    _send_wait(fd, f"echo 'exec /bin/sh \"$@\"' >> {SH_WRAPPER}", timeout=5)
    _send_wait(fd, f"chmod 755 {SH_WRAPPER}", timeout=5)

    # Create the guest user and install Lima SSH key
    user_cmds = [
        f"pw useradd -n {GUEST_USER} -m -d {GUEST_HOME} -s {SH_WRAPPER}"
        f" -G wheel 2>/dev/null || true",
        f"mkdir -p {GUEST_HOME}/.ssh",
        f'printf "%s\\n" "{ssh_key}" > {GUEST_HOME}/.ssh/authorized_keys',
        f"chmod 700 {GUEST_HOME}/.ssh",
        f"chmod 600 {GUEST_HOME}/.ssh/authorized_keys",
        f"chown -R {GUEST_USER}:{GUEST_USER} {GUEST_HOME}",
        f"grep -q '^{GUEST_USER} ' /usr/local/etc/sudoers 2>/dev/null"
        f" || echo '{GUEST_USER} ALL=(ALL) NOPASSWD: ALL'"
        f" >> /usr/local/etc/sudoers",
    ]
    print(f"[first-boot] Creating {GUEST_USER} user...")
    for cmd in user_cmds:
        print(f"[first-boot]   {cmd[:80]}")
        _send_wait(fd, cmd, timeout=20)

    # Install the persistent boot-done rc.d service line by line.
    # A heredoc would be simpler but QEMU's serial UART FIFO drops
    # the closing delimiter under slow TCG emulation, leaving the
    # shell stuck in continuation mode.
    rc_path = "/usr/local/etc/rc.d/lima_boot_done"
    print(f"[first-boot] Installing {rc_path}...")
    _send_wait(fd, "mkdir -p /usr/local/etc/rc.d", timeout=10)
    _send_wait(fd, f"printf '' > {rc_path}", timeout=5)
    for line in BOOT_DONE_RC_LINES:
        escaped = line.replace("'", "'\\''")
        _send_wait(fd, f"printf '%s\\n' '{escaped}' >> {rc_path}", timeout=10)
    _send_wait(fd, f"chmod 555 {rc_path}", timeout=10)
    _send_wait(fd,
               "grep -q lima_boot_done_enable /etc/rc.conf"
               " || echo 'lima_boot_done_enable=\"YES\"' >> /etc/rc.conf",
               timeout=15)

    # Write boot-done marker for current boot
    print(f"[first-boot] Writing boot-done marker ({iid})...")
    _send_wait(fd, f'echo "{iid}" > /var/run/lima-boot-done', timeout=10)
    _send_wait(fd, "mkdir -p /run", timeout=10)
    _send_wait(fd, f'echo "{iid}" > /run/lima-boot-done', timeout=10)

    # Verify boot-done marker
    print("[first-boot] Verifying boot-done marker...")
    out, ok = _send_wait(fd, "cat /var/run/lima-boot-done", timeout=15)
    if iid in out:
        print("[first-boot] Boot-done marker confirmed.")
    else:
        print(f"[first-boot] WARNING: could not verify marker: {out[-120:]!r}")

    # Verify sshd is actually running before SSH test
    print("[first-boot] Checking sshd process...")
    out, _ = _send_wait(fd, "ps aux | grep '[s]shd' || echo NO_SSHD", timeout=15)
    if "NO_SSHD" in out:
        print("[first-boot] WARNING: sshd does not appear to be running!")
    else:
        print(f"[first-boot] sshd running: {out[-150:]!r}")

    # Test SSH from the host before shutting down.
    lima_key = os.path.expanduser("~/.lima/_config/user")
    print(f"[first-boot] Testing SSH on port {SSH_PORT}...")
    ssh_ok = False
    ssh_err = ""
    for attempt in range(8):
        try:
            r = subprocess.run(
                ["ssh", "-o", "StrictHostKeyChecking=no",
                 "-o", "UserKnownHostsFile=/dev/null",
                 "-o", "ConnectTimeout=15",
                 "-o", "PasswordAuthentication=no",
                 "-o", "IdentitiesOnly=yes",
                 "-i", lima_key,
                 "-p", str(SSH_PORT),
                 f"{GUEST_USER}@127.0.0.1", "echo SSH_OK"],
                capture_output=True, timeout=25,
            )
            stdout = r.stdout.decode("utf-8", errors="replace")
            stderr = r.stderr.decode("utf-8", errors="replace")
            if "SSH_OK" in stdout:
                print("[first-boot] SSH test passed!")
                ssh_ok = True
                break
            ssh_err = stderr.strip() or stdout.strip()
        except subprocess.TimeoutExpired:
            ssh_err = "timeout"
        except Exception as e:
            ssh_err = str(e)
        print(f"    attempt {attempt+1}/8: {ssh_err[-120:]}", flush=True)
        time.sleep(8)
    if not ssh_ok:
        print("[first-boot] FATAL: SSH test failed — first-boot incomplete.")
        print("[first-boot] Syncing and halting VM...")
        _send_wait(fd, "sync; sync; sync", timeout=60)
        os.write(fd, b"halt -p\n")
        sys.exit(1)

    print("[first-boot] Setup complete. Powering off VM...")
    _send_wait(fd, "sync; sync; sync", timeout=60)
    os.write(fd, b"halt -p\n")
    print("[first-boot] Halt command sent.")


# ── main ───────────────────────────────────────────────────────────────────

def main():
    ssh_key = get_lima_pubkey()
    iid = get_instance_id()
    if not iid:
        # cidata.iso is generated by `limactl start`, which hasn't run yet.
        # Use a placeholder — the rc.d service reads the real instance-id
        # from the CD-ROM on every Lima-managed boot.
        iid = f"iid-{int(time.time())}"
        print(f"[first-boot] cidata.iso not found; using generated ID: {iid}")

    print(f"[first-boot] VM={VM}  iid={iid}")
    print(f"[first-boot] SSH key: {ssh_key[:50]}...")

    if not os.path.exists(DISK):
        sys.exit(f"ERROR: disk not found: {DISK}")

    if not os.path.exists(QEMU_BIN):
        sys.exit(f"ERROR: QEMU binary not found: {QEMU_BIN}")
    if not os.path.exists(OVMF_CODE):
        sys.exit(f"ERROR: OVMF code not found: {OVMF_CODE}")
    if not os.path.exists(OVMF_VARS_TEMPLATE):
        sys.exit(f"ERROR: OVMF vars template not found: {OVMF_VARS_TEMPLATE}")

    # Copy OVMF vars template — QEMU modifies it in place
    tmpdir = tempfile.mkdtemp(prefix="dragonfly-ovmf-")
    ovmf_vars = os.path.join(tmpdir, "OVMF_VARS.fd")
    shutil.copy2(OVMF_VARS_TEMPLATE, ovmf_vars)

    # ── Launch QEMU with -nographic ──────────────────────────────────────

    qemu_args = [
        QEMU_BIN,
        "-m", "2048",
        "-machine", "q35",
        "-accel", "tcg,thread=multi",
        "-smp", "1",
        "-drive", f"file={DISK},if=virtio",
        "-drive", f"if=pflash,format=raw,readonly=on,file={OVMF_CODE}",
        "-drive", f"if=pflash,format=raw,file={ovmf_vars}",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-boot", "order=c",
        "-nographic",
        "-no-reboot",
    ]

    print(f"[first-boot] Launching QEMU (ssh port {SSH_PORT})...")

    master_fd, slave_fd = pty.openpty()
    try:
        termios.tcsetwinsize(master_fd, (24, 80))
    except Exception:
        pass

    proc = subprocess.Popen(
        qemu_args,
        stdin=slave_fd,
        stdout=slave_fd,
        stderr=subprocess.PIPE,
        close_fds=True,
        preexec_fn=os.setsid,
    )
    os.close(slave_fd)

    print(f"[first-boot] QEMU PID: {proc.pid}")

    time.sleep(0.5)
    if proc.poll() is not None:
        stderr = proc.stderr.read().decode("utf-8", errors="replace")
        sys.exit(f"QEMU exited immediately (rc={proc.returncode}):\n{stderr}")

    try:
        # ── Interact with bootloader, then set up the VM ─────────────────

        interact_with_bootloader(master_fd)
        setup_vm(master_fd, ssh_key, iid)

        # Wait for QEMU to exit after halt
        print("[first-boot] Waiting for QEMU to exit...")
        try:
            proc.wait(timeout=120)
            print("[first-boot] QEMU exited normally.")
        except subprocess.TimeoutExpired:
            print("[first-boot] QEMU still running after halt, killing...")
            proc.kill()
            proc.wait(timeout=5)

    finally:
        if proc.poll() is None:
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
        os.close(master_fd)
        try:
            shutil.rmtree(tmpdir)
        except Exception:
            pass

    print("[first-boot] Setup complete. Lima can now manage this VM.")


if __name__ == "__main__":
    main()