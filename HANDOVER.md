# Devbox mise and Tailscale handover

## Completion — 2026-10-10

The default Ubuntu 26.04 image now builds and verifies successfully. The
historical notes below describe the earlier unfinished session and are superseded
by this completion record.

- Packer build passed in 23 minutes 59 seconds.
- Artifact: `output/devbox.qcow2`, 20 GiB virtual size, 3.61 GiB on disk.
- `scripts/02-verify.sh output/devbox.qcow2 26.04` passed all checks.
- `qemu-img check output/devbox.qcow2` found no errors; image info reports
  `corrupt: false`.
- Final diff, Bash syntax, Packer formatting, and Packer syntax checks passed.
- Build log: `.tmp/build-current.log`; successful boot verification log:
  `.tmp/verify-current.log`.

The actual build exercised all mise installations successfully, including Azure,
Rust, and Pi. The verifier needed three corrections: pass its multiline user tool
check through `bash -s` with a quoted heredoc, keep temporary VM host keys in its
temporary directory, and use the host CPU with 4 GiB RAM. OpenCode's version check
consumed excessive memory with QEMU's generic CPU; it passed with the host CPU.
These verifier changes do not change the built image contents.

The installer submodule remains clean at the original pin. Changes remain
uncommitted; no commit or push was requested or performed.

## Objective and user decisions

Finish updating the Ubuntu developer VM image and validate the resulting image.

- Install the Tailscale CLI and enable its daemon, without authenticating it.
- Manage supported user-facing CLIs and runtimes through mise.
- Codex and Claude must use mise exclusively; do not invoke their standalone installers. Disable Claude's built-in updates.
- Remove tuicr entirely; the user does not use it.
- Keep Proton Pass CLI, Unikraft, and Nanos on their existing installer scripts.
- Keep OS packages, services, virtualization support, and sandbox dependencies in root-level provisioners.
- Complete a default Ubuntu 26.04 build, boot verification, and qcow2 structural checks when the execution environment permits.

The user explicitly asked to keep going until finished. They report working network access from their own shell and believe they already launched Codex in YOLO mode. Do not assume the host has a network problem based on failures from the agent's restricted execution environment.

## Repository state

Workspace: `/home/sherpa/packer-devbox-linux`.

There were no pre-existing tracked changes when this task began. All current changes are uncommitted task work; preserve them and review before further edits. No commits or pushes were requested or made.

The installer submodule was initially uninitialized. It is now initialized, clean, and detached at the original gitlink:

```text
a97026200c92db070d16632cc62aa6447fb688d0
```

No files inside `installer-scripts/` were edited, and the submodule pin was not changed.

Read `AGENTS.md` before continuing. Its mise section was updated to describe the new implementation.

## Implemented changes

### Packer template

`devbox.pkr.hcl` now uploads `scripts/devbox-tools.toml` to `/tmp/devbox-tools.toml`.

The root provisioner installs development dependencies, Stow, Codex sandbox dependencies, Tailscale, QEMU guest agent, Docker, QEMU/libvirt, and Unikraft. The existing standalone GitHub CLI, Packer, Terraform, AWS CLI, and Azure CLI installers are no longer invoked. Their HashiCorp repository helper upload was removed as unnecessary.

The user provisioner still runs through `sudo -u sherpa -i bash`. Its order is:

1. Existing mise installer.
2. New `scripts/install-mise-tools.sh`.
3. Existing Proton Pass CLI installer.
4. Existing Nanos installer.
5. Existing `setup-paths.sh`.

Standalone Rust, Astral tools, Codex, Claude, Herdr, OpenCode, Node/NVM, and Pi installers are no longer invoked. tuicr is no longer installed.

### Global mise tools

`scripts/devbox-tools.toml` selects:

- Node.js LTS (including npm).
- Rust stable (including Cargo, using mise's rustup integration).
- Codex, Claude, GitHub CLI (`gh`), Packer, Terraform.
- AWS CLI (`aws-cli`), Azure CLI (`azure`).
- uv, ruff, ty, Herdr, OpenCode.
- Pi through `npm:@mariozechner/pi-coding-agent`.

CLI versions use `latest`; versions resolve during each image build, consistent with the previous installers. The manifest sets `DISABLE_UPDATES = "1"` for Claude.

`scripts/install-mise-tools.sh` copies that manifest to `~sherpa/.config/mise/config.toml`, runs `mise install` and `mise reshim`, and adds mise shim activation to `~/.profile`. The upstream mise installer provides interactive Bash activation in `.bashrc`. Login-shell shim activation is needed because Ubuntu's `.bashrc` returns early for noninteractive shells.

The script also exports `DISABLE_UPDATES=1` in `.profile` and `.bashrc`, and smoke-checks Node, npm, Rust, Cargo, Pi, Codex, and Claude through `mise exec`.

The initial `scripts/install-mise-agents.sh` was superseded and removed; use `scripts/install-mise-tools.sh`.

### Tailscale and sandbox dependencies

The existing pinned submodule already contains `install-tailscale.sh`; no submodule update was needed. It installs from the official apt repository and enables/starts `tailscaled`. Resolute's repository URL was reachable in the initial unrestricted environment.

`scripts/install-codex-sandbox.sh` preserves the former Codex installer's AppArmor/bubblewrap setup separately from CLI installation. Its namespace check runs as `sherpa`, even though the script runs through the root provisioner, so root privileges do not hide a user namespace restriction.

`scripts/01-cleanup.sh` stops `tailscaled` and removes its exact state files so cloned images start with fresh Tailscale state.

### Verification and documentation

`scripts/02-verify.sh` now checks Tailscale's CLI and active/enabled daemon. It checks every migrated CLI in a `sherpa` login shell, verifies resolution through mise shims and managed install paths, and checks Claude's update-disable environment.

Rust is checked separately because mise uses rustup proxies/toolchain storage. Verification also checks that NVM and tuicr are absent, and checks the retained Proton Pass, Nanos, and Unikraft tools.

`README.md` now includes the complete explicitly installed tool inventory, the mise migration, retained installers, and tuicr removal. The obsolete Azure apt fallback section was removed.

## Validation performed

These checks passed after the latest changes:

```sh
git diff --check
bash -n scripts/*.sh installer-scripts/shell/*.sh
packer fmt -check devbox.pkr.hcl
packer validate -syntax-only devbox.pkr.hcl
```

Python `tomllib` parsed the manifest successfully. The host's mise 2026.8.14 recognized the tool declarations using `mise config ls`. Its bundled registry includes all migrated shorthand tools. That host version maps `azure` to `pipx:azure-cli`; the newer registry documentation also lists a GitHub backend. The image's installer downloads current mise, so validate the backend/runtime behavior in the actual build, especially Azure and Pi.

`packer init devbox.pkr.hcl` succeeded earlier and installed QEMU plugin v1.1.7 under `~/.config/packer/plugins/`.

No final image has been produced. The latest migration has not been exercised in a VM; installation, shim resolution, Rust behavior, and boot checks remain to be validated.

## Build attempts and environment problem

The first build ran while agent execution had unrestricted filesystem/network access. The host then had `/dev/kvm`, approximately 14 GiB available RAM, and approximately 101 GiB free disk space. It downloaded the Ubuntu base image and provisioned successfully through:

- Development packages and Codex sandbox setup.
- Tailscale 1.104.1.
- Other root installers.
- Rust, Python tools, and Herdr using the earlier provisioner layout.

It failed after 10 minutes 48 seconds at the old tuicr installer: GitHub's releases API returned HTTP 403. This happened before mise-managed agent installation. tuicr is now removed, so that particular failure path is gone. Packer deleted the generated output directory on failure. The log is `.tmp/build.log`.

During the session, environment instructions changed to restricted filesystem/network access with no escalation allowed. Subsequent agent commands showed:

- `curl` could not resolve `mise.run` or other installer hosts.
- `/dev/kvm` was absent from the tool execution environment.
- A concrete retry failed immediately with `Failed to load source type` / `plugin exited before we could connect`.

The retry log is `.tmp/build-retry.log`. These observations concern the agent's execution environment, not the user's host connectivity. The user reports successfully pinging `mise.run` from their shell.

Do not work around active sandbox restrictions. Recheck actual tool capabilities in the new session; the user intends to restart with full access/YOLO.

## Continue from here

1. Read `AGENTS.md`; inspect `git status --short`, `git submodule status`, and submodule status. Preserve the current task changes.
2. Check DNS/download access and `/dev/kvm` from the agent's actual shell. If available, continue the authorized build without another permission question.
3. Review the implementation and run the inexpensive checks above. Review the global mise config, installation order, and verifier assumptions.
4. Reuse the existing ignored `.tmp/packer_key` and `.tmp/packer_key.pub` if present. Do not print or commit the private key. Generate a replacement only if missing.
5. Inspect any existing `output/` before retrying. At handover it did not exist. Never delete a broad or unresolved path.
6. Run:

   ```sh
   packer build \
     -var "ssh_public_key=$(cat .tmp/packer_key.pub)" \
     -var "ssh_private_key_file=.tmp/packer_key" \
     devbox.pkr.hcl
   ```

   Capture output in an ignored `.tmp/` log. Monitor provisioning and fix actual failures in this repository, without modifying the separate installer repository unless explicitly authorized.
7. Let disk zeroing and final qcow2 compression finish. The expected disk-full message during zeroing is intentional; active compression may be silent for many minutes.
8. Once built, run:

   ```sh
   scripts/02-verify.sh output/devbox.qcow2 26.04
   qemu-img check output/devbox.qcow2
   qemu-img info output/devbox.qcow2
   ```

9. Address failures, rerun necessary checks/builds, inspect final git status, and report the final image and verification outcome. Do not claim completion before the build and verifier pass.

The intended artifact is `output/devbox.qcow2`, with a 20 GiB virtual disk. Generated keys, caches, logs, and image outputs remain ignored. No commit or publishing step is authorized by the current request.
