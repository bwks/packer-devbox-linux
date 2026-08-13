packer {
  required_plugins {
    qemu = {
      version = ">= 1.1.0"
      source  = "github.com/hashicorp/qemu"
    }
  }
}

variable "ssh_public_key" {
  type        = string
  description = "Temporary SSH public key injected via cloud-init for Packer build access"
}

variable "ssh_private_key_file" {
  type        = string
  default     = ".tmp/packer_key"
  description = "Path to the temporary SSH private key for Packer build access"
}

variable "ubuntu_version" {
  type        = string
  default     = "26.04"
  description = "Ubuntu Server LTS version to build"

  validation {
    condition     = contains(["24.04", "26.04"], var.ubuntu_version)
    error_message = "Ubuntu version must be one of: 24.04, 26.04."
  }
}

variable "output_dir" {
  type    = string
  default = "output"
}

variable "vm_name" {
  type    = string
  default = "devbox"
}

locals {
  ubuntu_codenames = {
    "24.04" = "noble"
    "26.04" = "resolute"
  }
  ubuntu_codename = local.ubuntu_codenames[var.ubuntu_version]
  ubuntu_url      = "https://cloud-images.ubuntu.com/${local.ubuntu_codename}/current/${local.ubuntu_codename}-server-cloudimg-amd64.img"
  ubuntu_checksum = "file:https://cloud-images.ubuntu.com/${local.ubuntu_codename}/current/SHA256SUMS"
}

source "qemu" "devbox" {
  # Base image
  iso_url      = local.ubuntu_url
  iso_checksum = local.ubuntu_checksum
  disk_image   = true

  # Output
  output_directory = var.output_dir
  vm_name          = "${var.vm_name}.qcow2"
  format           = "qcow2"
  disk_size        = "20G"

  # VM resources
  accelerator  = "kvm"
  machine_type = "q35"
  cpu_model    = "host"
  cpus         = 4
  memory       = 8192
  headless     = true

  # Expose the standard QEMU guest-agent channel while provisioning so the
  # installer can start and validate qemu-guest-agent inside the build VM.
  qemuargs = [
    ["-chardev", "null,id=qga0"],
    ["-device", "virtio-serial"],
    ["-device", "virtserialport,chardev=qga0,name=org.qemu.guest_agent.0"],
  ]

  # Cloud-init seed injected as a virtual CD-ROM (label must be "cidata")
  cd_content = {
    "user-data" = templatefile("${path.root}/http/user-data.pkrtpl.hcl", {
      ssh_public_key = var.ssh_public_key
    })
    "meta-data" = file("${path.root}/http/meta-data")
  }
  cd_label = "cidata"

  # SSH communicator — temporary keypair, ubuntu user created by cloud-init above
  ssh_username           = "ubuntu"
  ssh_private_key_file   = var.ssh_private_key_file
  ssh_timeout            = "20m"
  ssh_handshake_attempts = 50

  boot_wait        = "5s"
  shutdown_command = "sudo shutdown -P now"
}

build {
  name    = "devbox"
  sources = ["source.qemu.devbox"]

  # Create the sherpa user that installer scripts expect
  provisioner "shell" {
    inline = [
      "sudo useradd -m -s /bin/bash -G sudo sherpa",
      "sudo passwd -l sherpa",
      "echo 'sherpa ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/packer-sherpa >/dev/null",
      "sudo chmod 0440 /etc/sudoers.d/packer-sherpa",
      "sudo visudo -cf /etc/sudoers.d/packer-sherpa",
    ]
  }

  # Upload helper script that install-packer.sh and install-terraform.sh
  # expect to find in the same directory (Packer uploads scripts to /tmp/
  # individually, so SCRIPT_DIR-relative lookups need this in place).
  provisioner "file" {
    source      = "installer-scripts/shell/setup-hashicorp-repo.sh"
    destination = "/tmp/setup-hashicorp-repo.sh"
  }

  provisioner "shell" {
    inline = ["chmod +x /tmp/setup-hashicorp-repo.sh"]
  }

  # Root-level installers
  provisioner "shell" {
    execute_command = "sudo bash '{{.Path}}'"
    scripts = [
      "installer-scripts/shell/install-dev-dependencies.sh",
      "installer-scripts/shell/install-devtools.sh",
      "installer-scripts/shell/install-qemu-guest-agent.sh",
      "installer-scripts/shell/install-docker.sh",
      "installer-scripts/shell/install-virt.sh",
      "installer-scripts/shell/install-githubcli.sh",
      "installer-scripts/shell/install-packer.sh",
      "installer-scripts/shell/install-terraform.sh",
      "installer-scripts/shell/install-awscli.sh",
      "installer-scripts/shell/install-azurecli.sh",
      "installer-scripts/shell/install-unikraft.sh",
    ]
  }

  # User-level installers — run as sherpa with a full login environment
  provisioner "shell" {
    execute_command = "sudo -u sherpa -i bash '{{.Path}}'"
    scripts = [
      "installer-scripts/shell/install-rust.sh",
      "installer-scripts/shell/install-python-dev.sh",
      "installer-scripts/shell/install-codex.sh",
      "installer-scripts/shell/install-claudecode.sh",
      "installer-scripts/shell/install-herdr.sh",
      "installer-scripts/shell/install-opencode.sh",
      "installer-scripts/shell/install-nodejs.sh",
      "installer-scripts/shell/install-pi.sh",
      "installer-scripts/shell/install-nanos.sh",
      "installer-scripts/shell/setup-paths.sh",
    ]
  }

  # Zero out free space so qemu-img convert strips it cleanly
  provisioner "shell" {
    execute_command = "sudo bash '{{.Path}}'"
    script          = "scripts/00-zero-disk.sh"
  }

  # Lock the build-only ubuntu account, reset cloud-init for end-user first-boot
  provisioner "shell" {
    execute_command = "sudo bash '{{.Path}}'"
    script          = "scripts/01-cleanup.sh"
  }

  # Sparsify: strip zeroed clusters and compress
  post-processor "shell-local" {
    inline = [
      "echo 'Sparsifying output image...'",
      "qemu-img convert -O qcow2 -c -p '${var.output_dir}/${var.vm_name}.qcow2' '${var.output_dir}/${var.vm_name}.tmp.qcow2'",
      "mv '${var.output_dir}/${var.vm_name}.tmp.qcow2' '${var.output_dir}/${var.vm_name}.qcow2'",
      "echo ''",
      "echo 'Final image details:'",
      "qemu-img info '${var.output_dir}/${var.vm_name}.qcow2'",
    ]
  }
}
