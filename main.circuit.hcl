# Facts give each host's family and architecture: Debian and Ubuntu install
# Caddy from its apt repository, the Red Hat family from the release archive.
data "conn3x_host" "facts" {
  for_each = var.hosts

  ssh {
    host             = try(each.value.address, each.value)
    host_key         = try(each.value.host_key, null)
    user             = try(each.value.user, var.ssh_user)
    port             = try(each.value.port, var.ssh_port)
    private_key_file = try(each.value.private_key_file, var.ssh_private_key_file)
    jump_hosts       = try(each.value.jump_hosts, null)
    known_hosts_file = var.ssh_known_hosts_file
  }
}

locals {
  version = "2.11.7"

  # SHA-256 of each release archive. Caddy publishes SHA-512 sums; these were
  # computed from archives that matched them.
  archive_sha256 = {
    amd64 = "727b91701a392de6ebc5027509f548bf39979e5216340d0faed8fa5e69c84f8b"
    arm64 = "d8fc6d179a5d283028a472a5618564f6ad8a86fed513e64f032b3b0b7cc45e42"
  }
  goarch = { x86_64 = "amd64", aarch64 = "arm64" }

  deb_hosts = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "debian" }
  rpm_hosts = { for name, h in var.hosts : name => h if data.conn3x_host.facts[name].os_family == "redhat" }

  caddyfile = join("\n", concat(
    var.email == null ? [] : ["{\n\temail ${var.email}\n}\n"],
    [for addr, s in var.sites : join("\n", concat(
      ["${addr} {"],
      length(s.reverse_proxy) > 0 ? ["\treverse_proxy ${join(" ", s.reverse_proxy)}"] : [],
      s.root != null ? ["\troot * ${s.root}", "\tfile_server"] : [],
      [for l in compact(split("\n", s.extra)) : "\t${trimspace(l)}"],
      ["}\n"],
    ))],
  ))
}

# Caddy's own apt repository, signed with the key in files/caddy-deb.asc. One
# suite serves every Debian and Ubuntu release.
circuit "caddy_deb" {
  hosts = local.deb_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "repo" {
    repository {
      name       = "caddy-stable"
      url        = "https://dl.cloudsmith.io/public/caddy/stable/deb/debian"
      key        = file("${path.module}/files/caddy-deb.asc")
      suites     = ["any-version"]
      components = ["main"]
    }
  }

  # Pins Caddy at the circuit's version, so apt upgrade leaves it there.
  # A pin rather than apt-mark hold: Conn3x reads a held package as not
  # installed, so a package step on it never settles.
  step "pin" {
    file {
      path    = "/etc/apt/preferences.d/caddy"
      content = "Package: caddy\nPin: version ${local.version}\nPin-Priority: 1001\n"
    }
  }

  step "caddy" {
    package {
      name    = "caddy"
      version = local.version
    }
  }
}

# On the Red Hat family, Caddy's packages live in a COPR repository, which
# builds on volunteer time and can trail the release by weeks, with no way to
# pin an exact version. The release archive is the same build on Fedora and
# Rocky, checked against a pinned SHA-256, so the circuit sets up what the
# package would: the caddy user, the binary at /usr/bin/caddy and Caddy's own
# unit file from files/caddy.service.
circuit "caddy_rpm" {
  hosts = local.rpm_hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "tar" {
    package {
      name = "tar"
    }
  }

  step "group" {
    group {
      name   = "caddy"
      system = true
    }
  }

  step "user" {
    user {
      name   = "caddy"
      group  = "caddy"
      home   = "/var/lib/caddy"
      shell  = "/usr/sbin/nologin"
      system = true
    }
  }

  step "archive" {
    download {
      url    = "https://github.com/caddyserver/caddy/releases/download/v${local.version}/caddy_${local.version}_linux_${local.goarch[data.conn3x_host.facts[each.key].arch]}.tar.gz"
      dest   = "/opt/caddy/caddy_${local.version}_linux_${local.goarch[data.conn3x_host.facts[each.key].arch]}.tar.gz"
      sha256 = local.archive_sha256[local.goarch[data.conn3x_host.facts[each.key].arch]]
    }
  }

  step "unpacked" {
    archive {
      src     = "/opt/caddy/caddy_${local.version}_linux_${local.goarch[data.conn3x_host.facts[each.key].arch]}.tar.gz"
      dest    = "/opt/caddy/${local.version}"
      creates = "/opt/caddy/${local.version}/caddy"
    }
  }

  step "binary" {
    link {
      path   = "/usr/bin/caddy"
      target = "/opt/caddy/${local.version}/caddy"
    }
  }

  step "config_dir" {
    directory {
      path = "/etc/caddy"
    }
  }

  step "unit" {
    file {
      path    = "/etc/systemd/system/caddy.service"
      content = file("${path.module}/files/caddy.service")
    }
  }
}

circuit "caddy" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Restarts Caddy when the pinned version or the unit file changes, so the
  # new binary and unit run.
  step "upgraded" {
    command {
      command  = "systemctl daemon-reload && systemctl try-restart caddy"
      triggers = { version = local.version, unit = filesha256("${path.module}/files/caddy.service") }
    }
    depends_on = [conn3x_package.caddy_deb__caddy, conn3x_file.caddy_rpm__unit]
  }

  # The rendered Caddyfile lands beside the live one first.
  step "candidate" {
    file {
      path    = "/etc/caddy/Caddyfile.conn3x"
      content = local.caddyfile
    }
  }

  # Copies the candidate over the live Caddyfile only once caddy validate
  # accepts it, so a bad site never reaches the running server. Also puts
  # it back after a hand edit to the live file.
  step "caddyfile" {
    command {
      command  = "caddy validate --config /etc/caddy/Caddyfile.conn3x --adapter caddyfile && cp /etc/caddy/Caddyfile.conn3x /etc/caddy/Caddyfile"
      unless   = "[ \"$(sha256sum < /etc/caddy/Caddyfile.conn3x)\" = \"$(sha256sum < /etc/caddy/Caddyfile)\" ]"
      triggers = { caddyfile = sha256(local.caddyfile) }
    }
    notify = [handler.reload]
  }

  step "running" {
    service {
      name    = "caddy"
      state   = "started"
      enabled = true
    }
  }

  handler "reload" {
    service {
      name   = "caddy"
      action = "reload"
    }
  }
}
