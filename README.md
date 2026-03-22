# packer-devbox

Packer template that builds a base Ubuntu 24.04 developer VM as a qcow2 image.

## What's included

| Tool | Details |
|------|---------|
| Docker Engine | CE, CLI, Buildx, Compose plugin |
| QEMU/KVM + libvirt | For running nested VMs |
| GitHub CLI | `gh` via official apt repo |
| Rust | Stable toolchain via rustup |
| Python tools | `uv`, `ruff`, `ty` via Astral installers |
| Claude Code | CLI via official installer |
| Build dependencies | `build-essential`, `pkg-config`, `libssl-dev`, `libvirt-dev`, etc. |

The default user is `sherpa`. It is pre-added to the `docker`, `libvirt`, and `kvm` groups. Cloud-init runs on first boot so SSH keys, passwords, and any further configuration are set by the user.

## Prerequisites

- QEMU/KVM (`qemu-system-x86_64`, `/dev/kvm`)
- Packer ≥ 1.10
- `ssh-keygen`

Install the QEMU plugin (one-time):

```sh
packer init devbox.pkr.hcl
```

## Build

```sh
# Generate a temporary build keypair and run Packer
make build
```

The Ubuntu 24.04 cloud image is downloaded and cached in `packer_cache/` on first run.

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

## Updating installer scripts

The installer scripts are a git submodule. To pull the latest:

```sh
git submodule update --remote installer-scripts
git add installer-scripts
git commit -m "bump installer-scripts"
```
