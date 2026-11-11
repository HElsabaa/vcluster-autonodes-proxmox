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
# runtime via a generated __vcluster__variables.tf file. We must NOT declare
# the "vcluster" variable here, or OpenTofu errors with a duplicate declaration.

# Credentials (PROXMOX_VE_ENDPOINT, PROXMOX_VE_USERNAME, PROXMOX_VE_PASSWORD or
# PROXMOX_VE_API_TOKEN, PROXMOX_VE_INSECURE) are injected from the Kubernetes
# Secret that has the label terraform.vcluster.com/provider matching the
# NodeProvider name. No endpoint or credentials are hardcoded here.
# SSH is required by the provider to upload cloud-init snippet files to the
# Proxmox node (the REST API cannot upload snippets). Credentials come from the
# PROXMOX_VE_SSH_USERNAME / PROXMOX_VE_SSH_PASSWORD env vars injected from the
# Kubernetes secret. agent is disabled since the loft pod has no SSH agent.
provider "proxmox" {
  ssh {
    agent = false
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
      write_files:
      - path: /root/bundle-join.sh
        permissions: "0755"
        content: |
          #!/bin/sh
          # Join using the Kubernetes bundle served by the vCluster control plane instead of GitHub.
          # The join script already knows that URL (REPOSITORY_URL) and only falls back to it when
          # github.com is unreachable. Here we fetch it ourselves and pass --bundle-path.
          set -u
          R=$(grep -m1 '^REPOSITORY_URL=' /root/join.sh | cut -d'"' -f2)
          V=$(grep -m1 '^KUBERNETES_VERSION=' /root/join.sh | cut -d'"' -f2)
          A=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
          echo "Fetching Kubernetes bundle $V ($A) from the vCluster control plane..."
          if curl -fsSLk --retry 5 --retry-delay 3 --max-time 300 -o /root/k8s-bundle.tar.gz "$R/$V/kubernetes-$V-$A.tar.gz"; then
            exec sh /root/join.sh --force-join --bundle-path /root/k8s-bundle.tar.gz
          fi
          echo "Bundle download failed, falling back to the default join (GitHub)..."
          exec sh /root/join.sh --force-join

      ${replace(replace(var.vcluster.userData, "#cloud-config", ""), "| sh -s -- --force-join", "-o /root/join.sh && /root/bundle-join.sh")}
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
