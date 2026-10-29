variable "hosts" {
  type        = any
  description = "Hosts to configure: a map of names to addresses, or to host objects with an address and optional host_key, user, port, private_key_file, jump_hosts or os."

  validation {
    condition     = alltrue([for h in var.hosts : contains(["debian", "ubuntu", "rocky", "almalinux", "rhel", "centos", "fedora"], try(h.os, "debian"))])
    error_message = "A host object's os must be one of debian, ubuntu, rocky, almalinux, rhel, centos or fedora."
  }
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

variable "adguardhome_version" {
  type        = string
  default     = "0.107.79"
  description = "AdGuard Home release to install, without the leading v."

  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.]+)?$", var.adguardhome_version))
    error_message = "adguardhome_version is a release number without the leading v, such as \"0.107.79\"."
  }
}

variable "checksums" {
  type        = map(string)
  description = "SHA-256 of the release tarball for each architecture, from the release's checksums.txt. Change these with adguardhome_version."
  default = {
    amd64 = "c48f4a43000665484c5ec28177de11a004759b620dae8f77b2aabefc9ef3687f"
    arm64 = "3f7893c18e8aaadc456d0452839190561c306ca95175a2254958be80a769c1ae"
  }

  validation {
    condition     = alltrue([for c in values(var.checksums) : can(regex("^[0-9a-f]{64}$", c))])
    error_message = "Each checksum is a SHA-256 in lowercase hex."
  }
}

variable "admin_username" {
  type        = string
  default     = "admin"
  description = "User name for the web interface and the API."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", var.admin_username))
    error_message = "admin_username may use letters, digits, ., _ and -, up to 64 characters."
  }
}

variable "admin_password" {
  type        = string
  ephemeral   = true
  sensitive   = true
  description = "Password for the web interface and the API. It reaches the host in a root-only file, is hashed there with bcrypt, and never reaches the plan or state."

  validation {
    condition     = length(var.admin_password) >= 8 && length(var.admin_password) <= 72 && !strcontains(var.admin_password, "\n")
    error_message = "admin_password must be 8 to 72 characters on one line. bcrypt ignores anything past 72 bytes."
  }
}

variable "web_address" {
  type        = string
  default     = "127.0.0.1:3000"
  description = "Address and port of the web interface and the API. \"0.0.0.0:3000\" listens on every address."

  validation {
    condition     = can(regex("^(\\[[0-9A-Fa-f:.]+\\]|[0-9.]+):[0-9]{1,5}$", var.web_address))
    error_message = "web_address is IP:PORT, such as \"127.0.0.1:3000\", \"0.0.0.0:3000\" or \"[::1]:3000\"."
  }
}

variable "dns_bind_hosts" {
  type        = list(string)
  default     = ["0.0.0.0"]
  description = "Addresses AdGuard Home answers DNS on, port 53. \"0.0.0.0\" means every address, IPv4 and IPv6."

  validation {
    condition     = length(var.dns_bind_hosts) > 0 && alltrue([for a in var.dns_bind_hosts : can(cidrhost("${a}/${strcontains(a, ":") ? 128 : 32}", 0))])
    error_message = "Each of dns_bind_hosts must be an IPv4 or IPv6 address, such as \"0.0.0.0\" or \"192.168.1.2\"."
  }
}

variable "allowed_clients" {
  type        = list(string)
  default     = ["127.0.0.0/8", "::1/128", "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "100.64.0.0/10", "fc00::/7", "fe80::/10"]
  description = "Clients AdGuard Home answers, as addresses or CIDR networks. Everyone else is refused. The default is loopback and the private ranges. An empty list answers anyone who can reach port 53."

  validation {
    condition     = alltrue([for c in var.allowed_clients : can(cidrhost(strcontains(c, "/") ? c : "${c}/${strcontains(c, ":") ? 128 : 32}", 0))])
    error_message = "Each of allowed_clients must be an IP address or a CIDR network, such as \"192.168.1.0/24\"."
  }
}

variable "upstream_dns" {
  type        = list(string)
  default     = ["https://dns.quad9.net/dns-query", "https://cloudflare-dns.com/dns-query"]
  description = "Servers AdGuard Home forwards allowed queries to, in its upstream syntax: \"https://...\" for DNS over HTTPS, \"tls://...\" for DNS over TLS, or a plain address such as \"192.168.1.1\" or \"127.0.0.1:5335\". The default is Quad9 and Cloudflare over HTTPS."

  validation {
    condition     = length(var.upstream_dns) > 0 && alltrue([for u in var.upstream_dns : can(regex("^[^\\s'\"`$\\\\]+$", u))])
    error_message = "upstream_dns needs at least one server, each without spaces, quotes, backticks, $ or backslashes."
  }
}

variable "bootstrap_dns" {
  type        = list(string)
  default     = ["9.9.9.9", "149.112.112.112", "1.1.1.1", "1.0.0.1"]
  description = "Plain DNS servers, by address, that look up the names in upstream_dns, such as dns.quad9.net."

  validation {
    condition     = length(var.bootstrap_dns) > 0 && alltrue([for b in var.bootstrap_dns : can(regex("^[0-9A-Fa-f:.\\[\\]]+$", b))])
    error_message = "bootstrap_dns needs at least one server, each an IP address, optionally with a port, such as \"9.9.9.9\" or \"[2620:fe::fe]:53\"."
  }
}

variable "filters" {
  type = map(string)
  default = {
    "AdGuard DNS filter" = "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"
  }
  description = "Blocklists, names to URLs. Adblock-style lists, hosts files and plain domain lists all work."

  validation {
    condition     = alltrue([for u in values(var.filters) : can(regex("^https?://[^\\s'\"`$\\\\]+$", u))])
    error_message = "Each URL in filters must be http or https, without spaces, quotes, backticks, $ or backslashes."
  }
}

variable "user_rules" {
  type        = list(string)
  default     = []
  description = "Filtering rules of your own, in AdGuard's syntax, such as [\"||ads.example.com^\", \"@@||allowed.example.com^\"]."

  validation {
    condition     = alltrue([for r in var.user_rules : !strcontains(r, "\n")])
    error_message = "Each of user_rules is one rule on one line."
  }
}

variable "rewrites" {
  type        = map(string)
  default     = {}
  description = "DNS rewrites for local names, domains to an IP address or another domain, such as { \"nas.home.arpa\" = \"192.168.1.20\" }. A domain can start with *. to cover its subdomains."

  validation {
    condition     = alltrue([for d in keys(var.rewrites) : can(regex("^(\\*\\.)?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$", d))])
    error_message = "Each domain in rewrites must be a host name, optionally starting with *., such as \"nas.home.arpa\"."
  }

  validation {
    condition     = alltrue([for a in values(var.rewrites) : can(regex("^[A-Za-z0-9:.-]+$", a))])
    error_message = "Each answer in rewrites must be an IP address or a domain."
  }
}

variable "blocking_mode" {
  type        = string
  default     = "default"
  description = "How AdGuard Home answers a blocked query: \"default\" (0.0.0.0 or :: for Adblock-style rules, the rule's address for hosts-style ones), \"null_ip\", \"nxdomain\" or \"refused\"."

  validation {
    condition     = contains(["default", "null_ip", "nxdomain", "refused"], var.blocking_mode)
    error_message = "blocking_mode must be one of default, null_ip, nxdomain or refused."
  }
}
