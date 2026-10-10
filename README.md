# packer-devbox

Packer template that builds a base Ubuntu 26.04 or 24.04 developer VM as a qcow2 image. Ubuntu 26.04 LTS is the default.

## What's included

| Tool | Details |
|------|---------|
| Docker Engine | CE, CLI, Buildx, Compose plugin |
| QEMU/KVM + libvirt | For running nested VMs |
| GitHub CLI | `gh` managed by mise |
| Rust | Stable toolchain managed by mise through rustup |
| Python tools | `uv`, `ruff`, `ty` managed by mise |
| Codex | CLI managed exclusively by mise; AppArmor and bubblewrap sandbox dependencies via apt |
| Claude Code | CLI managed exclusively by mise; built-in updates disabled |
| Herdr | CLI managed by mise |
| mise | Tool version manager via official installer; global tools selected in `scripts/devbox-tools.toml` |
| Tailscale | CLI and enabled `tailscaled` service via official apt repository; run `sudo tailscale up` to connect |
| Packer and Terraform | Managed by mise |
| AWS CLI | v2 managed by mise |
| Azure CLI | Managed by mise |
| Node.js and npm | Latest LTS managed by mise; replaces NVM |
| OpenCode | AI coding agent managed by mise |
| Pi | Coding agent managed by mise’s npm backend (`@mariozechner/pi-coding-agent`) |
| Unikraft | `kraft` CLI (kraftkit) via official apt repository |
| Nanos | `ops` CLI via official installer |
| QEMU guest agent | Enabled `qemu-guest-agent` service |
| Proton Pass CLI | Terminal access to Proton Pass vaults and secrets via official installer |
| GNU Stow | Symlink manager via apt |
| Build and disk tools | `build-essential`, `pkg-config`, `libssl-dev`, `libvirt-dev`, `genisoimage`, `mtools`, `e2fsprogs`, `unzip` |
| VM support | `qemu-utils`, libvirt clients, `bridge-utils`, `virtinst`, OVMF firmware |

The build copies `scripts/devbox-tools.toml` to `~sherpa/.config/mise/config.toml` and installs its tools as `sherpa`. It selects Node.js LTS, Rust stable, and the latest CLI releases during each build. Update these tools with `mise upgrade`. Login shells expose mise shims, and interactive Bash uses mise activation. Claude's built-in updates are disabled; mise manages its updates.

Proton Pass CLI, Unikraft, and Nanos retain their existing installers. System packages and services also retain their root-level installers. tuicr is no longer included.

The default user is `sherpa`. It is pre-added to the `docker`, `libvirt`, and `kvm` groups. Cloud-init runs on first boot so SSH keys, passwords, and any further configuration are set by the user.

## Prerequisites

- QEMU/KVM (`qemu-system-x86_64`, `/dev/kvm`)
- Packer ≥ 1.10
- `ssh-keygen`

Ubuntu 26.04 LTS is supported through April 2031. Its cloud images require an AMD64v3-capable CPU; use the Ubuntu 24.04 build option on older x86-64 hosts. See the [Ubuntu 26.04 release notes](https://documentation.ubuntu.com/release-notes/26.04/) for compatibility details.

## Build

Clone the repo with submodules:

```sh
gh repo clone bwks/packer-devbox-linux -- --recurse-submodules && cd packer-devbox-linux
```

Install the QEMU plugin (one-time):

```sh
packer init devbox.pkr.hcl
```

Generate a temporary build keypair and run Packer:

```sh
ssh-keygen -t ed25519 -f /tmp/packer_key -N "" -C "packer-build"

packer build \
  -var "ssh_public_key=$(cat /tmp/packer_key.pub)" \
  -var "ssh_private_key_file=/tmp/packer_key" \
  devbox.pkr.hcl
```

The Ubuntu 26.04 cloud image is downloaded and cached in `packer_cache/` on first run.

To build Ubuntu 24.04 instead:

```sh
packer build \
  -var "ubuntu_version=24.04" \
  -var "ssh_public_key=$(cat /tmp/packer_key.pub)" \
  -var "ssh_private_key_file=/tmp/packer_key" \
  devbox.pkr.hcl
```

Output: `output/devbox.qcow2` (~20 GB sparse qcow2)

## Using the image

Boot with your own cloud-init user-data to configure the `sherpa` user:

```yaml
#cloud-config
users:
  - name: sherpa
    ssh_authorized_keys:
      - ssh-ed25519 AAAA...yourkey
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
```

Pass it as a seed ISO:

```sh
cloud-localds seed.iso user-data
qemu-system-x86_64 \
  -enable-kvm -m 4096 -smp 4 \
  -drive file=output/devbox.qcow2,if=virtio \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=net0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=net0
```

Then SSH in:

```sh
ssh -p 2222 sherpa@localhost
```

## Verifying an image

The verification script boots a copy-on-write overlay and checks the Ubuntu version, first-boot initialization, services, and installed tools:

```sh
scripts/02-verify.sh output/devbox.qcow2 26.04
```

Pass `24.04` as the second argument when verifying a Noble image.

## Updating installer scripts

The installer scripts are a git submodule tracking the `main` branch. To pull the latest:

```sh
git submodule update --remote installer-scripts && git add installer-scripts && git commit -m "bump installer-scripts"
```
