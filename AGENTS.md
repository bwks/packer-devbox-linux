# AGENTS.md — packer-devbox-linux

## Purpose

This repository builds Ubuntu 26.04 or 24.04 developer VM images with
Packer and QEMU. Ubuntu 26.04 is the default. The final artifact is a
compressed qcow2 image, normally `output/devbox.qcow2`.

The image's primary user is `sherpa`. Packer initially connects as the
cloud-image `ubuntu` user, creates `sherpa`, runs system installers as root,
and runs user-scoped installers in a full `sherpa` login environment.

## Repository layout

- `devbox.pkr.hcl`: Packer variables, QEMU source, provisioners, and image
  compression.
- `http/`: cloud-init data used only during the Packer build.
- `installer-scripts/`: git submodule containing reusable tool installers.
- `scripts/00-zero-disk.sh`: fills free space with zeroes before compression.
- `scripts/01-cleanup.sh`: removes build credentials and resets first-boot
  state.
- `scripts/02-verify.sh`: boots a temporary overlay and verifies the finished
  image without modifying it.

## Working rules

- Preserve unrelated user changes. Inspect `git status --short` before and
  after editing.
- Use `rg` or `rg --files` for searches.
- Keep shell scripts compatible with Bash and retain `set -euo pipefail`.
- Run user-level installers through the existing
  `sudo -u sherpa -i bash` provisioner. Run package, service, and group changes
  through the root-level `sudo bash` provisioner.
- Place `setup-paths.sh` after user-level installers so their binary locations
  are available in future login shells.
- Add a check to `scripts/02-verify.sh` whenever an installed tool or required
  service is added. User-installed commands should be checked as `sherpa` in a
  login shell.
- Update the README's included-tools table when image contents change.
- Do not commit generated keys, Packer caches, or `output/`; these paths are
  ignored intentionally.
- Do not edit code inside `installer-scripts/` unless the task explicitly
  includes changing that separate repository. Prefer advancing the submodule
  to an upstream commit containing the required installer.

## Submodule workflow

Initialize the installer scripts after cloning:

```sh
git submodule update --init
```

Inspect both the superproject and submodule state before changing the pin:

```sh
git status --short
git submodule status
git -C installer-scripts status --short --branch
```

To adopt a known upstream installer commit:

```sh
git -C installer-scripts fetch origin main
git -C installer-scripts checkout <commit>
```

The resulting `installer-scripts` gitlink change is committed in this
repository. Do not leave the submodule at an unreviewed moving branch tip.

## Validation before building

Run the inexpensive checks first:

```sh
git diff --check
bash -n scripts/*.sh installer-scripts/shell/*.sh
packer init devbox.pkr.hcl
packer fmt -check devbox.pkr.hcl
packer validate -syntax-only devbox.pkr.hcl
```

`packer init` installs the required QEMU plugin in the user's Packer plugin
directory. It does not need to be repeated when the required plugin is already
installed.

## Building an image

The host needs working KVM/QEMU, at least 8 GiB of RAM, adequate disk space,
and network access for Ubuntu and tool installers. Generate a temporary key in
the ignored `.tmp/` directory:

```sh
mkdir -p .tmp
ssh-keygen -t ed25519 -f .tmp/packer_key -N "" -C "packer-build"

packer build \
  -var "ssh_public_key=$(cat .tmp/packer_key.pub)" \
  -var "ssh_private_key_file=.tmp/packer_key" \
  devbox.pkr.hcl
```

For Ubuntu 24.04, add `-var "ubuntu_version=24.04"`. Ubuntu 26.04 requires an
AMD64v3-capable host CPU.

Packer refuses to reuse a populated output directory. If a failed build leaves
`output/` behind, inspect it first, then remove only that exact generated
directory before retrying. Never remove a broad or unresolved path.

Expected build behavior:

- The first build downloads roughly 800 MiB into Packer's cache.
- Provisioning can take tens of minutes and downloads current tool releases.
- `00-zero-disk.sh` intentionally fills free space; its final `No space left on
  device` message is expected when the build continues to cleanup.
- The final `qemu-img convert -c` step can be silent and CPU-bound for many
  minutes. Do not interrupt it while `qemu-img` remains active and the temporary
  compressed image is growing.
- A successful default build produces `output/devbox.qcow2` with a 20 GiB
  virtual size and a much smaller compressed on-disk size.

## Verifying the result

Boot and test the finished image:

```sh
scripts/02-verify.sh output/devbox.qcow2 26.04
```

Use `24.04` as the second argument for a Noble image. The verifier creates a
copy-on-write overlay, waits for cloud-init, runs checks over SSH, shuts the VM
down, and removes its temporary files. It does not alter the source qcow2.

Also validate the qcow2 structure:

```sh
qemu-img check output/devbox.qcow2
qemu-img info output/devbox.qcow2
```

A task that changes image contents is complete only when static checks pass and,
when host resources permit, the image builds and the boot verifier passes. If a
full build cannot be run, state exactly which checks were run and why the image
was not built.

## Current mise integration

`installer-scripts/shell/install-mise.sh` installs mise for `sherpa` at
`~/.local/bin/mise` and configures shell activation. It is invoked from the
user-level provisioner in `devbox.pkr.hcl`. Verification runs `mise --version`
as `sherpa` through a login shell. The image includes the mise CLI but does not
preinstall language runtimes or create a global mise tool configuration.
