# circuit-caddy

A Conn3x circuit that installs Caddy, writes its Caddyfile from a map of sites, and keeps it running. Give it a domain and an upstream and you get a reverse proxy with a certificate Caddy fetches and renews itself. Give it a directory and it serves the files in it.

Every change to `sites` shows up in `conn3x plan` as a diff of the Caddyfile. The apply checks the new file with `caddy validate` before it touches the live one, so a typo fails the apply and the running server keeps its old config.

## Usage

```hcl
module "caddy" {
  source = "github.com/conn3xorg/circuit-caddy?ref=v0.1.0"

  hosts                = { edge = "203.0.113.10" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  email = "admin@example.com"
  sites = {
    "photos.example.com" = { reverse_proxy = ["localhost:2283"] }
    "git.example.com"    = { reverse_proxy = ["10.0.0.5:3000", "10.0.0.6:3000"] }
    "example.com" = {
      root  = "/srv/www"
      extra = <<-EOT
        encode zstd gzip
        header Cache-Control "public, max-age=3600"
      EOT
    }
  }
}
```

Then run `conn3x init` and `conn3x apply`. A second `conn3x plan` says `No changes.`

For a public name such as `photos.example.com`, Caddy gets a certificate from Let's Encrypt as soon as it loads the site, so the name's DNS has to point at the host and ports 80 and 443 have to be open. Opening them is up to you; the [firewall circuit](https://github.com/conn3xorg/circuit-firewall) can do it:

```hcl
module "firewall" {
  source = "github.com/conn3xorg/circuit-firewall?ref=v0.1.0"

  hosts = { edge = "203.0.113.10" }
  allow = [{ port = "80/tcp" }, { port = "443/tcp" }]
}
```

For hosts created in the same plan, pass host objects with the host key you generated, so Conn3x checks it without a known_hosts entry:

```hcl
hosts = {
  for name, d in digitalocean_droplet.app : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

## What it does

On each host, in order:

1. Installs Caddy 2.11.7.
   - On Debian and Ubuntu, from Caddy's own apt repository at `dl.cloudsmith.io/public/caddy/stable`, with the signing key in [files](files), copied from that repository. An apt pin in `/etc/apt/preferences.d/caddy` keeps `apt upgrade` from moving it off that version.
   - On Rocky Linux, Fedora and the rest of the Red Hat family, from the release archive on GitHub, checked against a pinned SHA-256. Caddy's RPMs come from a COPR repository that can trail releases and can't be pinned to an exact version, so the circuit does what the package would: it creates the `caddy` user and group with a home of `/var/lib/caddy`, links `/usr/bin/caddy` to the binary under `/opt/caddy`, and installs Caddy's own [unit file](files/caddy.service) as `/etc/systemd/system/caddy.service`.
2. Reloads systemd and restarts Caddy when the version the circuit pins or its unit file changes, so a new release of this circuit runs the new binary.
3. Renders the Caddyfile from `sites` and `email` to `/etc/caddy/Caddyfile.conn3x`.
4. Runs `caddy validate` on that file. If it passes, copies it to `/etc/caddy/Caddyfile`. If someone edits the live Caddyfile by hand, the next apply puts it back.
5. Starts Caddy now and at boot, and reloads it after the Caddyfile changes.

Each site renders as one block. `reverse_proxy` becomes a `reverse_proxy` line with every upstream, `root` becomes `root * PATH` and `file_server`, and each line of `extra` goes in as it is. A site with only `extra` works too, for anything the two shortcuts don't cover:

```hcl
"old.example.com" = { extra = "redir https://example.com{uri} permanent" }
```

The `caddyfile` output shows exactly what the circuit writes.

Before the circuit runs, the `conn3x_host` data source reads each host's family and architecture over SSH. The release archive is pinned for x86_64 and aarch64; another architecture on the Red Hat family fails the plan.

## What it doesn't cover

- Firewall ports. Open 80 and 443, or whatever your site addresses use, yourself or with the [firewall circuit](https://github.com/conn3xorg/circuit-firewall).
- The files a static site serves. Put them under `root` with your own steps, readable by the `caddy` user.
- Caddy plugins. The circuit installs the standard build.
- Choosing the Caddy version. It's pinned per release of this circuit.
- Removing Caddy. Deleting the module leaves Caddy installed and running.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"203.0.113.10"`, or a host object such as `{ address = "203.0.113.10", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file` and `jump_hosts`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `sites` | map(object) | `{}` | Sites to serve, by Caddy site address, such as `"example.com"`, `"http://localhost"` or `":8080"`. Each takes `reverse_proxy`, a list of upstreams such as `["localhost:3000"]`, or `root`, an absolute path to serve files from, but not both. `extra` is a string of further Caddyfile lines for the site. |
| `email` | string | `null` | Email address for the ACME account Caddy gets certificates with. |

## Outputs

| Name | Description |
| --- | --- |
| `caddyfile` | The Caddyfile the circuit writes to `/etc/caddy/Caddyfile`. |
| `version` | The Caddy version the circuit installs, such as `"2.11.7"`. |

## Requirements

Requires Conn3x v0.6.5 or later and systemd on each host, with outbound HTTPS to dl.cloudsmith.io on Debian and Ubuntu, or github.com on the Red Hat family.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64, checks that the second plan has no changes, and fetches a static page through a reverse proxy over plain HTTP. The CI containers run with SELinux off. The example was also applied by hand to a Rocky Linux 10 droplet with SELinux enforcing, where Caddy runs as `unconfined_service_t`: the second plan had no changes, the proxied page came back, and the audit log had no denials. The same held on Fedora 44 and AlmaLinux 10 droplets with SELinux enforcing, and again on both after a reboot. CI doesn't cover certificates, since a test container has no public DNS name. They were tried by hand on an Ubuntu 24.04 droplet, with a site named after its address through sslip.io: Caddy got a certificate from Let's Encrypt, the page came back over HTTPS, and the second plan had no changes.

## License

MPL-2.0. See [LICENSE](LICENSE). Caddy itself is Apache-2.0.
