#!/bin/bash
# Boot the output devbox image and verify all installed services are working.
# Uses a QEMU copy-on-write overlay so the original image is never modified.
set -euo pipefail

IMAGE="${1:-output/devbox.qcow2}"
EXPECTED_VERSION="${2:-26.04}"
SSH_PORT=2222

case "$EXPECTED_VERSION" in
  24.04|26.04) ;;
  *)
    echo "Error: expected version must be 24.04 or 26.04"
    exit 1
    ;;
esac

if [ ! -f "$IMAGE" ]; then
  echo "Error: image not found at $IMAGE"
  exit 1
fi

TMPDIR_WORK=$(mktemp -d)
OVERLAY=$(mktemp -u --suffix=.qcow2)
VERIFY_KEY="$TMPDIR_WORK/verify_key"
QEMU_PID_FILE="$TMPDIR_WORK/qemu.pid"

cleanup() {
  echo ""
  echo "Cleaning up..."
  if [ -f "$QEMU_PID_FILE" ]; then
    QEMU_PID=$(cat "$QEMU_PID_FILE")
    kill "$QEMU_PID" 2>/dev/null || true
    # Wait for qemu to actually exit
    for i in $(seq 1 10); do
      kill -0 "$QEMU_PID" 2>/dev/null || break
      sleep 1
    done
  fi
  rm -rf "$TMPDIR_WORK" "$OVERLAY"
}
trap cleanup EXIT

echo "=== devbox verification ==="
echo "Image: $IMAGE"
echo "Expected Ubuntu version: $EXPECTED_VERSION"
echo ""

# Generate a temporary SSH keypair for this verify session
ssh-keygen -t ed25519 -f "$VERIFY_KEY" -N "" -C "devbox-verify" -q

# Build a cloud-init seed ISO so cloud-init can configure the sherpa user on boot
cat > "$TMPDIR_WORK/user-data" << USERDATA
#cloud-config
users:
  - name: sherpa
    ssh_authorized_keys:
      - $(cat "${VERIFY_KEY}.pub")
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
ssh_pwauth: false
USERDATA

cat > "$TMPDIR_WORK/meta-data" << METADATA
instance-id: verify-$(date +%s)
local-hostname: devbox-verify
METADATA

genisoimage \
  -output "$TMPDIR_WORK/seed.iso" \
  -volid cidata \
  -joliet -rock \
  "$TMPDIR_WORK/user-data" \
  "$TMPDIR_WORK/meta-data" \
  2>/dev/null

echo "Created cloud-init seed ISO."

# Create a copy-on-write overlay — original image is never touched
qemu-img create \
  -f qcow2 \
  -b "$(realpath "$IMAGE")" \
  -F qcow2 \
  "$OVERLAY" \
  > /dev/null

echo "Created QEMU overlay."
echo "Booting VM on SSH port $SSH_PORT..."

qemu-system-x86_64 \
  -m 2048 \
  -smp 2 \
  -enable-kvm \
  -machine q35 \
  -drive "file=$OVERLAY,if=virtio,format=qcow2" \
  -drive "file=$TMPDIR_WORK/seed.iso,if=virtio,format=raw,readonly=on" \
  -netdev "user,id=net0,hostfwd=tcp::${SSH_PORT}-:22" \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial null \
  -monitor null \
  -daemonize \
  -pidfile "$QEMU_PID_FILE"

echo "VM started (PID $(cat "$QEMU_PID_FILE"))."
echo ""
echo "Waiting for SSH..."

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR -p $SSH_PORT -i $VERIFY_KEY"

for i in $(seq 1 60); do
  if ssh $SSH_OPTS sherpa@localhost "true" 2>/dev/null; then
    echo "SSH ready after ~$((i * 5))s."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "Error: timed out waiting for SSH."
    exit 1
  fi
  printf "."
  sleep 5
done

echo ""
echo "--- Running verification checks ---"
echo ""

ssh $SSH_OPTS sherpa@localhost "EXPECTED_VERSION='$EXPECTED_VERSION' bash -s" << 'CHECKS'
set -e

pass() { echo "[PASS] $1"; }
fail() { echo "[FAIL] $1"; exit 1; }

# Operating system and first-boot initialization
. /etc/os-release
[ "$VERSION_ID" = "$EXPECTED_VERSION" ] && pass "Ubuntu $EXPECTED_VERSION" || fail "expected Ubuntu $EXPECTED_VERSION, found $VERSION_ID"
cloud-init status --wait 2>&1 | grep -q "status: done" && pass "cloud-init completed" || fail "cloud-init did not complete cleanly"
[ -s /etc/machine-id ] && pass "machine-id regenerated" || fail "machine-id was not regenerated"
[ ! -e /etc/sudoers.d/packer-sherpa ] && pass "temporary build sudo rule removed" || fail "temporary build sudo rule remains"

# Docker
systemctl is-active --quiet docker && pass "docker.service active" || fail "docker.service not active"
docker --version | grep -q "Docker version" && pass "docker CLI available" || fail "docker CLI missing"
id sherpa | grep -q "docker" && pass "sherpa in docker group" || fail "sherpa not in docker group"

# libvirt / KVM
systemctl is-active --quiet libvirtd && pass "libvirtd.service active" || fail "libvirtd.service not active"
id sherpa | grep -q "libvirt" && pass "sherpa in libvirt group" || fail "sherpa not in libvirt group"
id sherpa | grep -q "kvm" && pass "sherpa in kvm group" || fail "sherpa not in kvm group"

# GitHub CLI
gh --version | grep -q "gh version" && pass "gh CLI available" || fail "gh CLI missing"

# Cloud CLIs
aws --version 2>&1 | grep -q "aws-cli" && pass "AWS CLI available" || fail "AWS CLI missing"
az version > /dev/null && pass "Azure CLI available" || fail "Azure CLI missing"

# Node.js (installed under sherpa via NVM)
bash -lc 'export NVM_DIR="$HOME/.nvm"; . "$NVM_DIR/nvm.sh"; node --version; npm --version' > /dev/null && pass "Node.js and npm available" || fail "Node.js or npm missing"

# Coding agents (installed under sherpa)
~/.local/bin/codex --version > /dev/null && pass "Codex CLI available" || fail "Codex CLI missing"
~/.local/bin/herdr --version > /dev/null && pass "Herdr available" || fail "Herdr missing"
~/.local/bin/tuicr --version > /dev/null && pass "tuicr available" || fail "tuicr missing"
bwrap --unshare-user --unshare-net --uid 0 --gid 0 --ro-bind / / /bin/true && pass "Codex bubblewrap sandbox available" || fail "Codex bubblewrap sandbox unavailable"

# Python tools (installed under sherpa)
sudo -u sherpa -i bash -c 'uv --version' | grep -q "uv" && pass "uv available" || fail "uv missing"
sudo -u sherpa -i bash -c 'ruff --version' | grep -q "ruff" && pass "ruff available" || fail "ruff missing"

# Rust (installed under sherpa)
sudo -u sherpa -i bash -c 'source ~/.cargo/env && rustc --version' | grep -q "rustc" && pass "rustc available" || fail "rustc missing"
sudo -u sherpa -i bash -c 'source ~/.cargo/env && cargo --version' | grep -q "cargo" && pass "cargo available" || fail "cargo missing"

# Build dependencies
dpkg -l build-essential | grep -q "^ii" && pass "build-essential installed" || fail "build-essential missing"
dpkg -l libssl-dev | grep -q "^ii" && pass "libssl-dev installed" || fail "libssl-dev missing"
stow --version | grep -q "GNU Stow" && pass "GNU Stow available" || fail "GNU Stow missing"

echo ""
echo "All checks passed."
CHECKS

echo ""
echo "Shutting down verify VM..."
ssh $SSH_OPTS sherpa@localhost "sudo shutdown -P now" 2>/dev/null || true

# Give it a moment to shut down
for i in $(seq 1 15); do
  QEMU_PID=$(cat "$QEMU_PID_FILE" 2>/dev/null || echo "")
  [ -z "$QEMU_PID" ] && break
  kill -0 "$QEMU_PID" 2>/dev/null || break
  sleep 1
done

echo "Done."
