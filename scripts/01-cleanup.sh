#!/bin/bash
set -euo pipefail

# Lock the build-only ubuntu account, reset cloud-init and machine-id
# so the image is clean for end-user first-boot configuration.

# Remove the packer build key — ubuntu account won't be usable after reset
rm -f /home/ubuntu/.ssh/authorized_keys
passwd -l ubuntu
usermod -s /usr/sbin/nologin ubuntu

# Reset cloud-init so it runs fresh on first boot
cloud-init clean --logs --seed

# Clear machine-id so a new one is generated on first boot
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id

sync
