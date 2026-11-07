# This example uses the bpg/proxmox provider
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.94.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }
}

# vCluster Platform injects node details into var.vcluster automatically at
# runtime. You do not define this externally — it is provided by the Platform.
variable "vcluster" {
  type = any
}

# Credentials (PROXMOX_VE_ENDPOINT, PROXMOX_VE_USERNAME, PROXMOX_VE_PASSWORD or
# PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE) are injected from the Kubernetes
# Secret that has the label terraform.vcluster.com/provider matching the
# NodeProvider name. No endpoint or credentials are hardcoded here.
provider "proxmox" {
  ssh {
    agent = true
  }
}

# This gives us a random value for our VM and hostname
resource "random_string" "vm_name_suffix" {
  length  = 8
  special = false
  upper   = false
  numeric = true
}

# We need to create a cloud-config file to hold our UserData. Snippets
# need to be enabled on the datastore.
resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "locallab"

  # We are going to set the hostname of the VM here, this will be used
  # as the node name when it is checked in. Also, for testing we enable the
  # ubuntu user with ubuntu as the password so we can ssh/console. In production
  # this should be disabled and you would use an ssh-key.
  source_raw {
    data = <<-EOT
      #cloud-config
      hostname: "vcluster-${var.vcluster.nodeClaim.metadata.name}"
      chpasswd:
        expire: false
        users:
        - {name: ubuntu, password: ubuntu, type: text}
      ssh_pwauth: true

      ${replace(var.vcluster.userData, "#cloud-config", "")}
    EOT
    # Note: replace() strips the "#cloud-config" header from the Platform-injected
    # userData so the two cloud-config documents can be merged inline. This works
    # for non-conflicting top-level keys; if both documents define the same key
    # (e.g. runcmd), the last occurrence wins. Consider a proper cloud-init merge
    # strategy if you need to combine runcmd or other list keys.

    # We give the filename a custom name so that we don't re-use the same file with the same
    # hostname. If it has the same hostname then it will join the node but it will run into issues
    # because the node name was already used.
    file_name = "${var.vcluster.nodeClaim.metadata.name}-user-data-cloud-config.yaml"
  }
}

# Here we create the VM with vcluster- and the values we defined earlier.
resource "proxmox_virtual_environment_vm" "ubuntu_vms" {

  name      = "vcluster-${var.vcluster.nodeClaim.metadata.name}-${random_string.vm_name_suffix.result}"
  node_name = "locallab"

  initialization {

    # We tell the VM where the userdata is. It is using the ID of the file created above.
    user_data_file_id = proxmox_virtual_environment_file.user_data_cloud_config.id

    # for this demo we just use DHCP, but you could configure static IP addresses if needed.
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
  }

  # We want to use the CPU/Memory defined in the nodeType, so we use the vCluster variable to set this.
  # The nodetypes will be created in vCluster Platform when we create the provider.
  cpu {
    cores = var.vcluster.nodeType.spec.resources.cpu
    type  = "host"
  }

  # We specify Megabytes in vCluster Platform which will add an M to the amount, we need to trim that value
  # so that we get the correct value the provider expects.
  memory {
    dedicated = trim(var.vcluster.nodeType.spec.resources.memory, "M")
  }

  # This is where we specify the disk size and the cloud image to use. In this
  # example we downloaded the noble-server image and uploaded it to the local datastore.
  # The VM itself will be installed on the local-lvm datastore.
  disk {
    datastore_id = "local-lvm"
    file_id      = "local:iso/noble-server-cloudimg-amd64.img"
    interface    = "virtio0"
    iothread     = true
    discard      = "on"
    size         = 120
  }

  network_device {
    bridge = "vmbr0"
  }
}
