variable "port" {
  type    = number
  default = 2222
}

module "caddy" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  # Plain HTTP on high ports, since a container has no public DNS name to
  # get a certificate for. :8080 proxies to the static site on :8081.
  sites = {
    ":8080" = { reverse_proxy = ["localhost:8081"], extra = "header X-Proxied-By caddy" }
    ":8081" = { root = "/srv/www" }
  }
}

# A page for the static site, and curl to fetch it with. It runs after the
# module, so its apt run doesn't overlap the module's.
circuit "content" {
  hosts = { box = "127.0.0.1" }

  ssh {
    user             = "root"
    port             = var.port
    private_key_file = "./id_ed25519"
    known_hosts_file = "./known_hosts"
  }

  step "curl" {
    package {
      name = "curl"
    }
    depends_on = [module.caddy]
  }

  step "index" {
    file {
      path    = "/srv/www/index.html"
      content = "Hello from Caddy.\n"
    }
  }
}
