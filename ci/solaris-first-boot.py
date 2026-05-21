#!/usr/bin/env python3
"""
ci/solaris-first-boot.py  –  one-time bootstrap for the OmniOS CE Lima VM.

Lima generates a cidata.iso with cloud-init user-data, but OmniOS CE does
not write Lima's boot-done marker (/var/run/lima-boot-done), so limactl
start hangs indefinitely.

This script fixes the problem via the QEMU serial console.  It is
idempotent and safe to re-run.

What it does:
  1. Waits for the VM's serial console socket to appear.
  2. Logs in as root (no password on the OmniOS cloud image).
  3. Installs sudo via pkg.
  4. Creates the 'solaris' user and installs Lima's SSH public key.
  5. Saves the Lima instance-id to /etc/lima/boot-done-id.
  6. Installs /lib/svc/method/lima_boot_done and imports an SMF manifest
     (site/lima_boot_done) that reads the saved id and writes
     /var/run/lima-boot-done on every subsequent boot.
  7. Writes the marker immediately for the current boot so limactl start
     detects it right away.

Usage:
    python3 ci/solaris-first-boot.py [VM_NAME]
    VM_NAME defaults to 'solaris-ipc'.
"""

import os
import socket
import subprocess
import sys
import time

VM = sys.argv[1] if len(sys.argv) > 1 else "solaris-ipc"
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


def wait_for(sock, marker, give_up_after=600, nudge_every=5):
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


# ── SMF method script and manifest installed inside the VM ─────────────────
#
# The method script reads the instance-id saved by this script and writes
# Lima's boot-done marker.  Using a saved id avoids needing to locate and
# mount the cidata ISO inside the VM (device paths vary by QEMU config).

BOOT_DONE_METHOD_LINES = [
    "#!/bin/sh",
    ". /etc/lima/boot-done-id 2>/dev/null",
    '[ -n "$INSTANCE_ID" ] && echo "$INSTANCE_ID" > /var/run/lima-boot-done',
    "exit 0",
]

BOOT_DONE_SMF_LINES = [
    "<?xml version='1.0'?>",
    "<!DOCTYPE service_bundle SYSTEM \"/usr/share/lib/xml/dtd/service_bundle.dtd.1\">",
    "<service_bundle type='manifest' name='lima-boot-done'>",
    "<service name='site/lima_boot_done' type='service' version='1'>",
    "<create_default_instance enabled='true'/>",
    "<single_instance/>",
    "<dependency name='network' grouping='require_all' restart_on='none' type='service'>",
    "<service_fmri value='svc:/milestone/network:default'/>",
    "</dependency>",
    "<exec_method type='method' name='start'"
    " exec='/lib/svc/method/lima_boot_done' timeout_seconds='30'/>",
    "<exec_method type='method' name='stop' exec=':true' timeout_seconds='30'/>",
    "<property_group name='startd' type='framework'>",
    "<propval name='duration' type='astring' value='transient'/>",
    "</property_group>",
    "<stability value='Unstable'/>",
    "<template><common_name>"
    "<loctext xml:lang='C'>Lima Boot Done Marker</loctext>"
    "</common_name></template>",
    "</service>",
    "</service_bundle>",
]


# ── main ───────────────────────────────────────────────────────────────────

def main():
    ssh_key = get_lima_pubkey()
    iid = get_instance_id()
    if not iid:
        sys.exit("ERROR: cannot read instance-id from cidata.iso")

    print(f"[first-boot] VM={VM}  iid={iid}")
    print(f"[first-boot] SSH key: {ssh_key[:50]}...")

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

    # OmniOS TCG boot is slow — allow up to 10 minutes
    print("[first-boot] Waiting for VM to boot (TCG is slow)...")
    # Accept either a login prompt (fresh boot) or root shell (re-run)
    out = wait_for(sock, "login:", give_up_after=120)
    if "login:" not in out:
        # Might already be at a root shell from a previous run
        out2 = drain(sock)
        if "root@" in out or "root@" in out2:
            print("    (already at root shell, skipping login)")
        else:
            print("    (no root shell yet, waiting longer for login...)")
            out = wait_for(sock, "login:", give_up_after=480)

    print("[first-boot] Logging in as root...")
    sock.sendall(b"root\n")
    time.sleep(2)
    out = drain(sock)
    # Some OmniOS builds prompt for a password even though it is blank
    if "assword" in out:
        sock.sendall(b"\n")
        time.sleep(1)
        drain(sock)

    out = run(sock, "echo PING", delay=2.0)
    if "PING" not in out:
        sock.sendall(b"\n")
        time.sleep(1)
        out = run(sock, "echo PING", delay=2.0)
    if "PING" not in out:
        sys.exit(f"[first-boot] ERROR: no shell after login. Got: {out!r}")
    print("[first-boot] Got root shell.")

    print("[first-boot] Installing sudo...")
    run(sock, "pkg install --accept -q system/management/sudo 2>&1 | tail -3",
        delay=120.0)

    user_cmds = [
        "mkdir -p /export/home",
        "id solaris >/dev/null 2>&1 || {"
        " useradd -d /export/home/solaris.guest -m -s /bin/sh solaris"
        " && passwd -N solaris; }",
        "passwd -s solaris 2>&1 | grep -q LK && passwd -d solaris 2>&1 || true",
        "mkdir -p /export/home/solaris.guest/.ssh",
        f'printf "%s\\n" "{ssh_key}"'
        " > /export/home/solaris.guest/.ssh/authorized_keys",
        "chmod 700 /export/home/solaris.guest/.ssh",
        "chmod 600 /export/home/solaris.guest/.ssh/authorized_keys",
        "chown -R solaris /export/home/solaris.guest",
        "grep -q '^solaris ' /etc/sudoers 2>/dev/null"
        " || echo 'solaris ALL=(ALL) NOPASSWD: ALL' >> /etc/sudoers",
    ]
    print("[first-boot] Creating solaris user...")
    for cmd in user_cmds:
        print(f"[first-boot]   {cmd[:80]}")
        run(sock, cmd, delay=1.2)

    # Save the instance-id so the SMF service can write the marker on each boot
    print("[first-boot] Saving instance-id for boot service...")
    run(sock, "mkdir -p /etc/lima", delay=0.5)
    run(sock, f'printf "INSTANCE_ID=%s\\n" "{iid}" > /etc/lima/boot-done-id',
        delay=0.5)

    # Install the SMF method script
    print("[first-boot] Installing /lib/svc/method/lima_boot_done...")
    sock.sendall(b"cat > /lib/svc/method/lima_boot_done << 'EOF_LIMA_METHOD'\n")
    time.sleep(0.2)
    for line in BOOT_DONE_METHOD_LINES:
        sock.sendall((line + "\n").encode())
        time.sleep(0.03)
    sock.sendall(b"EOF_LIMA_METHOD\n")
    time.sleep(1.0)
    drain(sock)

    run(sock, "chmod 555 /lib/svc/method/lima_boot_done", delay=0.5)

    # Install and import the SMF manifest
    print("[first-boot] Installing SMF manifest...")
    run(sock, "mkdir -p /var/svc/manifest/site", delay=0.5)
    sock.sendall(
        b"cat > /var/svc/manifest/site/lima_boot_done.xml << 'EOF_LIMA_SMF'\n"
    )
    time.sleep(0.2)
    for line in BOOT_DONE_SMF_LINES:
        sock.sendall((line + "\n").encode())
        time.sleep(0.03)
    sock.sendall(b"EOF_LIMA_SMF\n")
    time.sleep(1.0)
    drain(sock)

    print("[first-boot] Importing SMF manifest...")
    run(sock, "svccfg import /var/svc/manifest/site/lima_boot_done.xml",
        delay=10.0)

    # Write the boot-done marker for the current boot
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
