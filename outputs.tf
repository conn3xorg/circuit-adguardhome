output "service" {
  description = "The systemd service that runs AdGuard Home on each host."
  value       = "AdGuardHome.service"
}

output "config_file" {
  description = "AdGuard Home's live config file on each host, which AdGuard Home rewrites as it runs."
  value       = local.config_file
}

output "web_url" {
  description = "URL of the web interface and the API, as seen from the host itself."
  value       = "http://${replace(replace(var.web_address, "0.0.0.0:", "127.0.0.1:"), "[::]:", "[::1]:")}"
}
