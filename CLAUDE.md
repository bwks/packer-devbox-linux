# CLAUDE.md — packer-devbox

## What this repo is

A Packer/QEMU template that builds a base Ubuntu 24.04 developer VM as a qcow2 image. The default user is `sherpa`.

## Repo structure

```
devbox.pkr.hcl          # Main Packer template
http/                   # Cloud-init templates (user-data, meta-data)
scripts/                # Build-time scripts (run by Packer)
  00-zero-disk.sh       # Zero free space before sparsification
  01-cleanup.sh         # Lock ubuntu user, reset cloud-init/machine-id
  02-verify.sh          # Boot image and verify installed tools (not called by Packer)
installer-scripts/      # Git submodule — shell installers for each tool
```

## Git

- Always use `gh auth setup-git` if git push fails due to auth
- Use `gh api user` to get name/email if git identity is missing
- The submodule `installer-scripts` must be initialised: `git submodule update --init`
- When cloning: `git clone --recurse-submodules`

## Building

The build host needs at least 8 GB RAM. The Claude Code installer (`install-claudecode.sh`) requires ~6 GB inside the VM and will be OOM-killed if less is available.

```sh
# One-time plugin install
packer init devbox.pkr.hcl

# Generate a temporary build keypair
ssh-keygen -t ed25519 -f /tmp/packer_key -N "" -C "packer-build"

# Build
packer build \
  -var "ssh_public_key=$(cat /tmp/packer_key.pub)" \
  -var "ssh_private_key_file=/tmp/packer_key" \
  devbox.pkr.hcl
```

Output: `output/devbox.qcow2`

If the build fails and leaves a stale `output/` directory, remove it before retrying: `rm -rf output/`

## Packer provisioner order

1. Create `sherpa` user
2. Root-level installers (docker, virt, gh, rust, dev-deps) — `sudo bash`
3. User-level installers (python-dev, claudecode, setup-paths) — `sudo -u sherpa -i bash`
4. `scripts/00-zero-disk.sh` — zero free space
5. `scripts/01-cleanup.sh` — lock ubuntu user, reset cloud-init
6. Post-processor: sparsify/compress image with `qemu-img convert`

## Scripts numbering convention

Scripts in `scripts/` are prefixed `NN-` in execution order. `02-verify.sh` is a standalone verification script, not called by Packer.

## Updating installer scripts (submodule)

```sh
git submodule update --remote installer-scripts
git add installer-scripts
git commit -m "bump installer-scripts"
```
