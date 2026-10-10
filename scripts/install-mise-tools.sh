#!/bin/bash
set -euo pipefail

# Install user-scoped CLIs and runtimes from the image's global mise config.
export PATH="$HOME/.local/bin:$PATH"
mkdir -p "$HOME/.config/mise"
install -m 0644 /tmp/devbox-tools.toml "$HOME/.config/mise/config.toml"
mise install
mise reshim

# Login shells also need shims: Ubuntu's bashrc exits early when noninteractive.
PROFILE="$HOME/.profile"
ACTIVATION='eval "$(~/.local/bin/mise activate bash --shims)"'
if ! grep -qF "$ACTIVATION" "$PROFILE"; then
  printf '\n# mise tools in login shells\n%s\n' "$ACTIVATION" >> "$PROFILE"
fi

# Claude must leave updates to mise rather than installing its own binaries.
SETTING='export DISABLE_UPDATES=1'
for profile in "$HOME/.profile" "$HOME/.bashrc"; do
  if ! grep -qF "$SETTING" "$profile"; then
    printf '\n# Coding agents are updated through mise\n%s\n' "$SETTING" >> "$profile"
  fi
done

# Exercise runtime-backed commands as well as standalone binaries.
mise exec -- node --version
mise exec -- npm --version
mise exec -- rustc --version
mise exec -- cargo --version
mise exec -- pi --version
mise exec -- codex --version
mise exec -- claude --version
