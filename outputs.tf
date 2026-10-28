output "caddyfile" {
  description = "The Caddyfile the circuit writes to /etc/caddy/Caddyfile."
  value       = local.caddyfile
}

output "version" {
  description = "The Caddy version the circuit installs."
  value       = local.version
}
