#!/bin/bash
set -euo pipefail

# Zero out free space so qemu-img convert can strip unused clusters cleanly.

dd if=/dev/zero of=/tmp/zeroes bs=4M status=none || true
rm -f /tmp/zeroes
sync
