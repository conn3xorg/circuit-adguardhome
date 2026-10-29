variable "port" {
  type    = number
  default = 2222
}

variable "admin_password" {
  type      = string
  default   = "correct-horse-battery"
  ephemeral = true
}

module "adguardhome" {
  source = "../.."

  hosts                = { box = "127.0.0.1" }
  ssh_port             = var.port
  ssh_private_key_file = "./id_ed25519"
  ssh_known_hosts_file = "./known_hosts"

  admin_password = var.admin_password

  user_rules = ["||ads.example.org^"]
  rewrites = {
    "nas.home.arpa"     = "192.168.1.20"
    "printer.home.arpa" = "192.168.1.21"
  }
}

output "web_url" {
  value = module.adguardhome.web_url
}
