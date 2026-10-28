variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file or jump_hosts."
}

variable "ssh_user" {
  type        = string
  default     = "root"
  description = "User to log in as."
}

variable "ssh_port" {
  type        = number
  default     = 22
  description = "SSH port."
}

variable "ssh_private_key_file" {
  type        = string
  default     = null
  description = "Path to a private key. When null, Conn3x uses the SSH agent."
}

variable "ssh_known_hosts_file" {
  type        = string
  default     = null
  description = "known_hosts file to check host keys against. When null, ~/.ssh/known_hosts."
}

variable "ssh_become" {
  type        = bool
  default     = false
  description = "Run commands as root through sudo."
}


variable "sites" {
  type = map(object({
    reverse_proxy = optional(list(string), [])
    root          = optional(string)
    extra         = optional(string, "")
  }))
  default     = {}
  description = "Sites to serve, by site address such as \"example.com\" or \":8080\". Each proxies to reverse_proxy upstreams or serves files from root, plus any extra Caddyfile lines."

  validation {
    condition     = alltrue([for addr in keys(var.sites) : can(regex("^[^{}\\s][^{}\\n]*$", addr))])
    error_message = "Each site address must be a Caddy address such as \"example.com\", \"http://localhost\" or \":8080\", without braces or line breaks."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : length(s.reverse_proxy) == 0 || s.root == null])
    error_message = "A site takes reverse_proxy or root, not both. Put a more involved site together in extra."
  }

  validation {
    condition     = alltrue([for s in values(var.sites) : s.root == null || startswith(coalesce(s.root, "/"), "/")])
    error_message = "A site's root must be an absolute path, such as \"/srv/www\"."
  }

  validation {
    condition     = alltrue(flatten([for s in values(var.sites) : [for u in s.reverse_proxy : can(regex("^[^\\s{}]+$", u))]]))
    error_message = "Each reverse_proxy upstream must be one address, such as \"localhost:3000\", without spaces or braces."
  }
}

variable "email" {
  type        = string
  default     = null
  description = "Email address for the ACME account Caddy gets certificates with. Let's Encrypt uses it for expiry warnings."

  validation {
    condition     = var.email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", coalesce(var.email, "x@y.z")))
    error_message = "email must be an address such as \"admin@example.com\"."
  }
}
