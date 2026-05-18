#!/usr/bin/env python3
"""
ci/freebsd-first-boot.py  –  one-time bootstrap for the FreeBSD Lima VM.

Lima generates cloud-init user-data with 1-space YAML list indentation.
FreeBSD's built-in 'flua' YAML parser requires 2-space indentation and
rejects the file, so neither the SSH user nor Lima's boot-done marker are
ever created by cloud-init.

This script fixes both problems via the QEMU serial console, which works
even before SSH is available.  It is idempotent and safe to run again.

What it does:
  1. Waits for the VM's serial console socket to appear.
  2. Logs in as root (no password on the FreeBSD cloud image).
  3. Creates the 'freebsd' user and installs Lima's SSH public key.
  4. Installs /etc/rc.d/lima_boot_done, which reads the instance-id from
     the cidata.iso and writes /var/run/lima-boot-done on every boot so
     that subsequent 'limactl start' calls complete in seconds.
  5. Writes the marker immediately for the current boot.

Usage:
    python3 ci/freebsd-first-boot.py [VM_NAME]
    VM_NAME defaults to 'freebsd-ipc'.
"""

import os
import socket
import subprocess
import sys
import time

VM = sys.argv[1] if len(sys.argv) > 1 else "freebsd-ipc"
LIMA_DIR = os.path.expanduser(f"~/.lima/{VM}")
SERIAL_SOCK = os.path.join(LIMA_DIR, "serial.sock")


# ── helpers ────────────────────────────────────────────────────────────────

def get_lima_pubkey():
    with open(os.path.expanduser("~/.lima/_config/user.pub")) as f:
        return f.read().strip()


def get_instance_id():
    """Mount the cidata.iso and extract the cloud-init instance-id."""
    iso = os.path.join(LIMA_DIR, "cidata.iso")
    mnt = "/tmp/_lima_cidata_setup"
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


def drain(sock, timeout=1.5):
    """Read whatever is available on the socket within timeout seconds."""
    buf = b""
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            sock.settimeout(min(0.25, deadline - time.time()))
            chunk = sock.recv(4096)
            buf += chunk
        except (socket.timeout, BlockingIOError):
            break
    return buf.decode("utf-8", errors="replace")


def run(sock, cmd, delay=1.0):
    sock.settimeout(None)
    sock.sendall((cmd + "\n").encode())
    time.sleep(delay)
    return drain(sock)


def wait_for(sock, marker, give_up_after=480, nudge_every=5):
    print(f"    waiting for {marker!r}", end="", flush=True)
    buf = ""
    start = time.time()
    last_nudge = start
    while time.time() - start < give_up_after:
        buf += drain(sock, timeout=1.0)
        if marker in buf:
            print(" ok")
            return buf
        if time.time() - last_nudge >= nudge_every:
            sock.sendall(b"\n")
            last_nudge = time.time()
            print(".", end="", flush=True)
    print(" TIMED OUT")
    return buf


# ── rc.d script installed inside the VM ────────────────────────────────────

# Written as individual lines so we can send them over the serial console
# without worrying about heredoc quoting edge-cases.
BOOT_DONE_RC_LINES = [
    "#!/bin/sh",
    "# PROVIDE: lima_boot_done",
    "# REQUIRE: NETWORKING",
    "# BEFORE: LOGIN",
    ". /etc/rc.subr",
    "name=lima_boot_done",
    "rcvar=lima_boot_done_enable",
    'start_cmd="${name}_start"',
    "lima_boot_done_start()",
    "{",
    "  for dev in /dev/iso9660/cidata /dev/iso9660/CIDATA; do",
    '    [ -e "$dev" ] || continue',
    "    mkdir -p /mnt/lima-cidata",
    '    mount_cd9660 -o ro "$dev" /mnt/lima-cidata 2>/dev/null && break',
    "  done",
    "  IID=$(grep -m1 '^instance-id:' /mnt/lima-cidata/meta-data "
    "2>/dev/null | awk '{print $2}')",
    '  [ -n "$IID" ] && echo "$IID" > /var/run/lima-boot-done',
    "  umount /mnt/lima-cidata 2>/dev/null; true",
    "}",
    "load_rc_config $name",
    'run_rc_command "$1"',
]


# ── main ───────────────────────────────────────────────────────────────────

def main():
    ssh_key = get_lima_pubkey()
    iid = get_instance_id()
    if not iid:
        sys.exit("ERROR: cannot read instance-id from cidata.iso")

    print(f"[first-boot] VM={VM}  iid={iid}")
    print(f"[first-boot] SSH key: {ssh_key[:50]}...")

    # Wait for the QEMU serial socket (appears as soon as QEMU starts)
    print("[first-boot] Waiting for serial socket", end="", flush=True)
    for _ in range(120):
        if os.path.exists(SERIAL_SOCK):
            break
        print(".", end="", flush=True)
        time.sleep(1)
    else:
        sys.exit("\n[first-boot] ERROR: serial socket never appeared")
    print(" ok")

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SERIAL_SOCK)

    # Wait for the FreeBSD login prompt
    print("[first-boot] Waiting for VM to boot...")
    wait_for(sock, "login:", give_up_after=480)

    # Log in as root (no password on the FreeBSD BASIC-CLOUDINIT image)
    print("[first-boot] Logging in as root...")
    sock.sendall(b"root\n")
    time.sleep(2)
    drain(sock)

    # Verify we have a shell prompt
    out = run(sock, "echo PING", delay=1.5)
    if "PING" not in out:
        sock.sendall(b"\n")          # try blank password if prompted
        time.sleep(1)
        out = run(sock, "echo PING", delay=1.5)
    if "PING" not in out:
        sys.exit(f"[first-boot] ERROR: no shell after login. Got: {out!r}")
    print("[first-boot] Got root shell.")

    # Install sudo (Lima's cloud-init was supposed to do this but couldn't)
    print("[first-boot] Installing sudo...")
    run(sock, "pkg install -y sudo", delay=60.0)

    # Create the freebsd user and install the Lima SSH key
    user_cmds = [
        "pw useradd -n freebsd -m -d /home/freebsd.guest -s /bin/sh"
        " -G wheel 2>/dev/null || true",
        "mkdir -p /home/freebsd.guest/.ssh",
        f'printf "%s\\n" "{ssh_key}" > /home/freebsd.guest/.ssh/authorized_keys',
        "chmod 700 /home/freebsd.guest/.ssh",
        "chmod 600 /home/freebsd.guest/.ssh/authorized_keys",
        "chown -R freebsd:freebsd /home/freebsd.guest",
        "grep -q '^freebsd ' /usr/local/etc/sudoers 2>/dev/null"
        " || echo 'freebsd ALL=(ALL) NOPASSWD: ALL'"
        " >> /usr/local/etc/sudoers",
    ]
    print("[first-boot] Creating freebsd user...")
    for cmd in user_cmds:
        print(f"[first-boot]   {cmd[:80]}")
        run(sock, cmd, delay=1.2)

    # Install the persistent boot-done rc.d service
    print("[first-boot] Installing /etc/rc.d/lima_boot_done...")
    sock.sendall(b"cat > /etc/rc.d/lima_boot_done << 'EOF_LIMA_RC'\n")
    time.sleep(0.2)
    for line in BOOT_DONE_RC_LINES:
        sock.sendall((line + "\n").encode())
        time.sleep(0.03)
    sock.sendall(b"EOF_LIMA_RC\n")
    time.sleep(1.0)
    drain(sock)

    run(sock, "chmod 555 /etc/rc.d/lima_boot_done", delay=0.8)
    run(sock,
        "grep -q lima_boot_done_enable /etc/rc.conf"
        " || echo 'lima_boot_done_enable=\"YES\"' >> /etc/rc.conf",
        delay=0.8)

    # Write the boot-done marker for the current boot so limactl start
    # detects it immediately.
    print(f"[first-boot] Writing boot-done marker ({iid})...")
    run(sock, f'echo "{iid}" > /var/run/lima-boot-done', delay=0.8)

    out = run(sock, "cat /var/run/lima-boot-done", delay=0.8)
    if iid in out:
        print("[first-boot] Boot-done marker confirmed.")
    else:
        print(f"[first-boot] WARNING: unexpected content: {out!r}")

    print("[first-boot] Setup complete.")
    sock.close()


if __name__ == "__main__":
    main()
