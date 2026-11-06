variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
}

# CI sets these to install an older release first, then upgrades to the
# circuit's own pin by applying again without them.
variable "adguardhome_version" {
  type    = string
  default = null
}

variable "checksums" {
  type    = map(string)
  default = null
}

module "adguardhome" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password      = var.admin_password
  adguardhome_version = var.adguardhome_version
  checksums           = var.checksums

  user_rules = ["||ads.example.org^"]
  rewrites = {
    "nas.home.arpa"     = "192.168.1.20"
    "printer.home.arpa" = "192.168.1.21"
  }
}

output "web_url" {
  value = module.adguardhome.web_url
}
