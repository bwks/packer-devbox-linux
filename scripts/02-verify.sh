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
  -m 4096 \
  -cpu host \
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

SSH_OPTS="-o UserKnownHostsFile=$TMPDIR_WORK/known_hosts -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR -p $SSH_PORT -i $VERIFY_KEY"

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

# Tailscale (authentication is left to the image user)
tailscale version > /dev/null && pass "Tailscale CLI available" || fail "Tailscale CLI missing"
systemctl is-active --quiet tailscaled && pass "tailscaled.service active" || fail "tailscaled.service not active"
systemctl is-enabled --quiet tailscaled && pass "tailscaled.service enabled" || fail "tailscaled.service not enabled"

# User-scoped tools must resolve and run in a sherpa login shell.
sudo -u sherpa -i bash -c 'mise --version' > /dev/null && pass "mise available" || fail "mise missing"
for spec in gh:gh packer:packer terraform:terraform aws-cli:aws azure:az uv:uv ruff:ruff ty:ty herdr:herdr opencode:opencode codex:codex claude:claude node:node node:npm npm:@mariozechner/pi-coding-agent:pi; do
  tool="${spec%:*}"
  command_name="${spec##*:}"
  if sudo -u sherpa -i bash -s -- "$tool" "$command_name" <<'TOOL_CHECK'
    set -euo pipefail
    tool="$1"
    command_name="$2"
    mise where "$tool" > /dev/null
    managed="$(mise which "$command_name")"
    case "$managed" in
      "$HOME/.local/share/mise/installs/"*) ;;
      *) exit 1 ;;
    esac
    [ "$(readlink -f "$(command -v "$command_name")")" = "$(readlink -f "$HOME/.local/share/mise/shims/$command_name")" ]
    [ ! -e "$HOME/.local/bin/$command_name" ]
    case "$command_name" in
      az) az version > /dev/null ;;
      *) "$command_name" --version > /dev/null ;;
    esac
    [ "$DISABLE_UPDATES" = 1 ]
TOOL_CHECK
  then
    pass "$command_name managed by mise"
  else
    fail "$command_name unavailable or not managed by mise"
  fi
done

# Rust uses rustup proxies and toolchains rather than ordinary mise binaries.
sudo -u sherpa -i bash -c 'set -euo pipefail; mise where rust; rustc --version; cargo --version; mise exec -- rustup show active-toolchain' > /dev/null && pass "Rust and Cargo available through mise" || fail "Rust or Cargo missing"
sudo -u sherpa -i bash -c 'test ! -d "$HOME/.nvm"' && pass "NVM replaced by mise" || fail "legacy NVM installation remains"

# Tools retained on their existing installers.
sudo -u sherpa -i bash -c 'pass-cli --version' > /dev/null && pass "Proton Pass CLI available" || fail "Proton Pass CLI missing"
sudo -u sherpa -i bash -c '"$HOME/.ops/bin/ops" version' > /dev/null && pass "Nanos ops available" || fail "Nanos ops missing"
kraft version > /dev/null && pass "Unikraft kraft available" || fail "Unikraft kraft missing"
sudo -u sherpa -i bash -c '! command -v tuicr >/dev/null && test ! -e "$HOME/.local/bin/tuicr"' && pass "tuicr omitted" || fail "tuicr remains installed"
bwrap --unshare-user --unshare-net --uid 0 --gid 0 --ro-bind / / /bin/true && pass "Codex bubblewrap sandbox available" || fail "Codex bubblewrap sandbox unavailable"

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
