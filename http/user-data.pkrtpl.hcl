#cloud-config
users:
  - name: ubuntu
    ssh_authorized_keys:
      - ${ssh_public_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash

ssh_pwauth: false

# Speed up cloud-init by skipping unnecessary modules
package_update: false
package_upgrade: false
