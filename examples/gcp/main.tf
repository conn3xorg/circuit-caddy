terraform {
  required_providers {
    google = { source = "hashicorp/google", version = "~> 7.0" }
    tls    = { source = "hashicorp/tls", version = "~> 4.0" }
  }
}

variable "project" {
  type        = string
  description = "Google Cloud project to create everything in."
}

variable "admin_cidrs" {
  type        = list(string)
  description = "Addresses allowed to reach SSH, such as [\"203.0.113.7/32\"]. Ports 80 and 443 are open to everyone."

  validation {
    condition     = length(var.admin_cidrs) > 0 && alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "Give at least one address or network in CIDR form, such as \"203.0.113.7/32\"."
  }
}

variable "email" {
  type        = string
  default     = null
  description = "Email address for the Let's Encrypt account. Optional."
}

variable "name" {
  type        = string
  default     = "web"
  description = "Name of the instance, its network and its firewall rules."
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "machine_type" {
  type    = string
  default = "e2-micro"
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "ssh_user" {
  type        = string
  default     = "conn3x"
  description = "User cloud-init creates, with your key and sudo. Conn3x logs in as this user."
}

variable "ssh_public_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519.pub"
}

variable "ssh_private_key_file" {
  type    = string
  default = "~/.ssh/id_ed25519"
}

variable "staging" {
  type        = bool
  default     = true
  description = "Get the certificate from Let's Encrypt's staging server, which browsers don't trust. Set false for a trusted one."
}

provider "google" {
  project = var.project
  region  = join("-", slice(split("-", var.zone), 0, 2))
}

# The instance's SSH host key, made here and installed by cloud-init, so
# Conn3x can check it on the very first connection.
resource "tls_private_key" "host" {
  algorithm = "ED25519"
}

# A network of its own, so the default network's allow-SSH-from-anywhere
# rule doesn't apply.
resource "google_compute_network" "web" {
  name                    = var.name
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "web" {
  name          = var.name
  network       = google_compute_network.web.id
  ip_cidr_range = "10.10.0.0/24"
}

resource "google_compute_firewall" "ssh" {
  name          = "${var.name}-ssh"
  network       = google_compute_network.web.id
  source_ranges = var.admin_cidrs

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "web" {
  name          = "${var.name}-web"
  network       = google_compute_network.web.id
  source_ranges = ["0.0.0.0/0"]

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }
}

resource "google_compute_instance" "web" {
  name         = var.name
  zone         = var.zone
  machine_type = var.machine_type
  labels       = var.labels

  boot_disk {
    initialize_params {
      image  = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      type   = "pd-standard"
      size   = 10
      labels = var.labels
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.web.id

    # An ephemeral public address. It stays the same across reboots, and
    # goes when the instance does.
    access_config {}
  }

  metadata = {
    # Keys added to the whole project don't get onto this instance.
    block-project-ssh-keys = true

    user-data = "#cloud-config\n${yamlencode({
      ssh_deletekeys = true
      ssh_keys = {
        ed25519_private = tls_private_key.host.private_key_openssh
        ed25519_public  = tls_private_key.host.public_key_openssh
      }
      users = [{
        name                = var.ssh_user
        shell               = "/bin/bash"
        sudo                = "ALL=(ALL) NOPASSWD:ALL"
        ssh_authorized_keys = [trimspace(file(pathexpand(var.ssh_public_key_file)))]
      }]
    })}"
  }
}

locals {
  ip   = google_compute_instance.web.network_interface[0].access_config[0].nat_ip
  site = "${local.ip}.sslip.io"

  # The instance doesn't exist at plan time, so os stands in for the facts
  # the circuits would otherwise read from it.
  hosts = {
    web = {
      address  = local.ip
      host_key = tls_private_key.host.public_key_openssh
      os       = "ubuntu"
    }
  }
}

# The circuits run side by side, as the user cloud-init made, through sudo.
module "baseline" {
  source = "github.com/conn3xorg/circuit-baseline?ref=v0.1.0"

  hosts                = local.hosts
  ssh_user             = var.ssh_user
  ssh_become           = true
  ssh_private_key_file = var.ssh_private_key_file
}

module "hardening" {
  source = "github.com/conn3xorg/circuit-hardening?ref=v0.1.0"

  hosts                = local.hosts
  ssh_user             = var.ssh_user
  ssh_become           = true
  ssh_private_key_file = var.ssh_private_key_file

  # ufw sets log_martians to 0 each time it starts, from
  # /etc/ufw/sysctl.conf, so the two would undo each other on every apply.
  sysctl = {
    "net.ipv4.conf.all.log_martians"     = null
    "net.ipv4.conf.default.log_martians" = null
  }
}

module "firewall" {
  source = "github.com/conn3xorg/circuit-firewall?ref=v0.2.0"

  hosts                = local.hosts
  ssh_user             = var.ssh_user
  ssh_become           = true
  ssh_private_key_file = var.ssh_private_key_file

  allow = [{ port = "80/tcp" }, { port = "443/tcp" }]
}

module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.2.0"

  hosts                = local.hosts
  ssh_user             = var.ssh_user
  ssh_become           = true
  ssh_private_key_file = var.ssh_private_key_file

  email = var.email
  sites = {
    (local.site) = {
      extra = <<-EOT
        respond "Hello from Google Cloud."
        ${var.staging ? "tls {\nca https://acme-staging-v02.api.letsencrypt.org/directory\n}" : ""}
      EOT
    }
  }
}

output "ip" {
  value = local.ip
}

output "url" {
  value = "https://${local.site}"
}

# IdentitiesOnly, because circuit-hardening allows four tries at
# authentication, and an agent with more keys can use them up first.
output "ssh" {
  value = "ssh -o IdentitiesOnly=yes -i ${pathexpand(var.ssh_private_key_file)} ${var.ssh_user}@${local.ip}"
}
