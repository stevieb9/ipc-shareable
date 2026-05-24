#!/usr/bin/env python3
"""
ci/openbsd-first-boot.py  --  one-time bootstrap for the OpenBSD Lima VM.

The generic/openbsd7 Vagrant box (Roboxes) is a pre-installed OpenBSD 7.4
image with BIOS/MBR boot. Lima's legacyBIOS mode uses SeaBIOS which boots
the image correctly, but prior to first-boot setup there is no serial
getty and the Lima SSH key isn't installed.

This script:
  1. Launches QEMU directly with -nographic (don't touch the bootloader;
     it auto-boots after 5 seconds).
  2. Polls for SSH availability on the forwarded port.
  3. Connects as vagrant (password "vagrant") via SSH_ASKPASS.
  4. Writes setup script to /tmp, then executes via doas/sudo with password
     piped.  Installs:
     - Lima SSH public key for vagrant
     - sudo NOPASSWD access for vagrant
     - /etc/rc.local entry (boot-done marker, idomatic OpenBSD one-shot)
     - Serial console (set tty com0 in /etc/boot.conf, enable getty on tty00)
  5. Writes the boot-done marker for the current boot.
  6. Halts the VM so Lima can take over on the next start.

Usage:
    python3 ci/openbsd-first-boot.py [VM_NAME]
"""

import os
import pty
import select
import subprocess
import sys
import tempfile
import termios
import time
import tty

VM = sys.argv[1] if len(sys.argv) > 1 else "openbsd-ipc"
LIMA_DIR = os.path.expanduser(f"~/.lima/{VM}")
DISK = os.path.join(LIMA_DIR, "disk")
CIDATA_ISO = os.path.join(LIMA_DIR, "cidata.iso")
SSH_PORT = 60222

GUEST_USER = "vagrant"
GUEST_HOME = f"/home/{GUEST_USER}"

QEMU_BIN = "/opt/homebrew/bin/qemu-system-x86_64"

# Content appended to /etc/rc.local (idiomatic OpenBSD way for one-shot boot
# commands — simpler than an rc.d service which requires a daemon variable).
BOOT_DONE_RC_LOCAL = r"""# Lima boot-done marker
ln -sf /var/run /run 2>/dev/null
for dev in /dev/cd0a /dev/cd0c; do
  [ -e "$dev" ] || continue
  mkdir -p /mnt/lima-cidata
  mount_cd9660 -o ro "$dev" /mnt/lima-cidata 2>/dev/null && break
done
IID=$(grep -m1 "^instance-id:" /mnt/lima-cidata/meta-data 2>/dev/null | awk '{print $2}')
[ -n "$IID" ] && echo "$IID" > /var/run/lima-boot-done
umount /mnt/lima-cidata 2>/dev/null; true
"""


def get_lima_pubkey():
    with open(os.path.expanduser("~/.lima/_config/user.pub")) as f:
        return f.read().strip()


def get_instance_id():
    iso = CIDATA_ISO
    mnt = "/tmp/_lima_cidata_openbsd"
    os.makedirs(mnt, exist_ok=True)
    try:
        subprocess.run(
            ["hdiutil", "attach", iso, "-mountpoint", mnt,
             "-readonly", "-quiet"],
            check=True, capture_output=True,
        )
        with open(f"{mnt}/meta-data") as f:
            for line in f:
                if line.startswith("instance-id:"):
                    return line.split(":", 1)[1].strip()
    finally:
        subprocess.run(["hdiutil", "detach", mnt, "-quiet"],
                       capture_output=True)
    return None


# -- SSH helpers using SSH_ASKPASS for password auth ------------------------

def _make_askpass(tmpdir):
    """Create an SSH_ASKPASS script that echoes the vagrant password."""
    path = os.path.join(tmpdir, "askpass.sh")
    with open(path, "w") as f:
        f.write("#!/bin/sh\necho vagrant\n")
    os.chmod(path, 0o755)
    return path


def _ssh_env(askpass):
    return {
        **os.environ,
        "DISPLAY": "dummy",
        "SSH_ASKPASS": askpass,
        "SSH_ASKPASS_REQUIRE": "force",
    }


def _ssh_base_args():
    return [
        "ssh", "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=5",
        "-o", "PreferredAuthentications=password",
        "-o", "PasswordAuthentication=yes",
        "-p", str(SSH_PORT),
        f"{GUEST_USER}@127.0.0.1",
    ]


def wait_for_ssh(env, timeout=600):
    """Poll until password-authenticated SSH succeeds."""
    print(f"    waiting for SSH on port {SSH_PORT}", end="", flush=True)
    start = time.time()
    while time.time() - start < timeout:
        try:
            r = subprocess.run(
                _ssh_base_args() + ["true"],
                env=env, capture_output=True, timeout=15,
            )
            if r.returncode == 0:
                print(" ok")
                return True
        except Exception:
            pass
        print(".", end="", flush=True)
        time.sleep(10)
    print(" TIMEOUT")
    return False


def ssh_root_run(script, env, timeout=120):
    """Write script to file, then execute with doas/sudo.

    Writes the script to a temp file first so stdin (used for the password)
    is decoupled from the shell's command stream.  Any leftover bytes on
    stdin are harmless because sh reads commands from the file, not stdin.
    """
    # Step 1: write script to temp file inside the VM
    r = subprocess.run(
        _ssh_base_args() + ["tee", "/tmp/_lima_setup.sh"],
        env=env,
        input=script.encode(),
        capture_output=True, timeout=30,
    )
    if r.returncode != 0:
        return ("", r.stderr.decode("utf-8", errors="replace"), r.returncode)

    # Step 2: execute.  Pipe the password on stdin — if doas/sudo consumes
    # it, great; if not (e.g. requiretty), the leftover "vagrant\n" sits on
    # stdin of `sh file` harmlessly because sh reads from the file.
    for cmd in (
        ["doas", "sh", "/tmp/_lima_setup.sh"],
        ["sudo", "-S", "sh", "/tmp/_lima_setup.sh"],
    ):
        r = subprocess.run(
            _ssh_base_args() + cmd,
            env=env,
            input=b"vagrant\n",
            capture_output=True, timeout=timeout,
        )
        out = r.stdout.decode("utf-8", errors="replace")
        if "SETUP DONE" in out:
            break

    # clean up
    subprocess.run(
        _ssh_base_args() + ["rm", "-f", "/tmp/_lima_setup.sh"],
        env=env, capture_output=True, timeout=10,
    )

    return (out,
            r.stderr.decode("utf-8", errors="replace"),
            r.returncode)


# -- main --------------------------------------------------------------------

def main():
    ssh_key = get_lima_pubkey()
    iid = get_instance_id()
    if not iid:
        sys.exit("ERROR: cannot read instance-id from cidata.iso")

    print(f"[first-boot] VM={VM}  iid={iid}")

    if not os.path.exists(DISK):
        sys.exit(f"ERROR: disk not found: {DISK}")

    tmpdir = tempfile.mkdtemp()
    askpass = _make_askpass(tmpdir)
    env = _ssh_env(askpass)

    # ----- Stage 1: launch QEMU (don't touch bootloader) ------------------

    qemu_args = [
        QEMU_BIN,
        "-m", "2048",
        "-machine", "q35",
        "-accel", "tcg,thread=multi",
        "-smp", "2",
        "-drive", f"file={DISK},if=virtio",
        "-netdev", f"user,id=net0,hostfwd=tcp:127.0.0.1:{SSH_PORT}-:22",
        "-device", "virtio-net-pci,netdev=net0",
        "-boot", "order=c",
        "-nographic",
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
    os.close(master_fd)  # we don't need serial output
    print(f"[first-boot] QEMU PID: {proc.pid}")

    time.sleep(0.5)
    if proc.poll() is not None:
        stderr = proc.stderr.read().decode("utf-8", errors="replace")
        sys.exit(f"QEMU exited immediately (rc={proc.returncode}):\n{stderr}")

    try:
        # ----- Stage 2: wait for OpenBSD to boot -------------------------

        if not wait_for_ssh(env, timeout=600):
            sys.exit("[first-boot] ERROR: SSH never became available")

        print("[first-boot] Connected via SSH. Running setup...")

        # Build the setup script
        rc_local_escaped = BOOT_DONE_RC_LOCAL.replace("'", "'\\''")

        setup_script = fr"""set -e
echo "SETUP START"

# add Lima SSH key for vagrant
mkdir -p {GUEST_HOME}/.ssh
if ! grep -qF '{ssh_key}' {GUEST_HOME}/.ssh/authorized_keys 2>/dev/null; then
    printf '%s\n' '{ssh_key}' >> {GUEST_HOME}/.ssh/authorized_keys
fi
chmod 700 {GUEST_HOME}/.ssh
chmod 600 {GUEST_HOME}/.ssh/authorized_keys
chown -R {GUEST_USER}:{GUEST_USER} {GUEST_HOME}/.ssh 2>/dev/null || true

# sudo NOPASSWD for vagrant (so openbsd-test.sh can use 'sudo' without tty)
grep -q '^{GUEST_USER} ' /etc/sudoers 2>/dev/null || \
    echo '{GUEST_USER} ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers

# boot-done via rc.local (idiomatic OpenBSD one-shot boot script)
touch /etc/rc.local
chmod 755 /etc/rc.local
if ! grep -q 'lima-boot-done' /etc/rc.local 2>/dev/null; then
    printf '%s\n' '{rc_local_escaped}' >> /etc/rc.local
fi

# serial console: boot.conf + getty on tty00
echo 'set tty com0' > /etc/boot.conf
if grep -q '^tty00' /etc/ttys 2>/dev/null; then
    sed -i.bak 's/^tty00.*$/tty00\t"\/usr\/libexec\/getty std.9600"\tvt220\ton  secure/' /etc/ttys
    rm -f /etc/ttys.bak
else
    printf 'tty00\t"/usr/libexec/getty std.9600"\tvt220\ton  secure\n' >> /etc/ttys
fi

# write boot-done marker for current boot
echo '{iid}' > /var/run/lima-boot-done
echo "SETUP DONE"
sync
/sbin/halt -p &
"""

        out, err, rc = ssh_root_run(setup_script, env, timeout=120)
        print(f"[first-boot] Setup rc={rc}")
        if "SETUP DONE" in out:
            print("[first-boot] Setup completed successfully.")
        else:
            print(f"[first-boot] stdout: {out.strip()[-500:]}")
            if err:
                print(f"[first-boot] stderr: {err.strip()[-400:]}")

        # Wait for QEMU to exit after halt
        print("[first-boot] Waiting for QEMU to exit...")
        try:
            proc.wait(timeout=120)
            print("[first-boot] QEMU exited normally.")
        except subprocess.TimeoutExpired:
            print("[first-boot] QEMU still running, killing...")
            proc.kill()
            proc.wait(timeout=5)

    finally:
        if proc.poll() is None:
            try:
                proc.kill()
                proc.wait(timeout=5)
            except Exception:
                pass
        try:
            os.remove(askpass)
            os.rmdir(tmpdir)
        except Exception:
            pass

    print("[first-boot] Setup complete. Lima can now manage this VM.")


if __name__ == "__main__":
    main()
