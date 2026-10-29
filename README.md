# circuit-adguardhome

A Conn3x circuit that runs [AdGuard Home](https://adguard.com/adguard-home/overview.html) on your hosts, so every device that asks it for DNS gets ads and trackers answered with `0.0.0.0`. The TV, the phones and the guest's laptop all get it, because they all ask the same server.

AdGuard Home comes from its official GitHub release, checked against a pinned SHA-256, and runs as a systemd service under a user of its own. You give it a password, the upstream servers it should ask, its blocklists and the local names your network answers to, such as `nas.home.arpa`, and it lands the same way on Debian, Ubuntu, Fedora and Rocky Linux. There's no setup wizard to click through: the circuit writes the config, and AdGuard Home starts ready.

## Usage

```hcl
variable "adguard_password" {
  type      = string
  ephemeral = true
}

module "adguardhome" {
  source = "github.com/conn3xorg/circuit-adguardhome?ref=v0.1.0"

  hosts                = { dns = "192.168.1.2" }
  ssh_private_key_file = "~/.ssh/id_ed25519"

  admin_password = var.adguard_password

  rewrites = {
    "nas.home.arpa"     = "192.168.1.20"
    "printer.home.arpa" = "192.168.1.21"
  }
}
```

Then run `conn3x init` and `conn3x apply -var adguard_password=...`. A second `conn3x plan` says `No changes.` Point your router's DHCP at the host's address as the DNS server, and devices move over as their leases renew.

The web interface listens on `127.0.0.1:3000`, so from your laptop you reach it through SSH:

```sh
ssh -L 3000:127.0.0.1:3000 root@192.168.1.2
```

and open `http://127.0.0.1:3000`. Set `web_address = "0.0.0.0:3000"` to open it on the network instead.

For hosts created in the same plan, pass host objects with the host key you generated and the `os` they run, so Conn3x checks the key without a known_hosts entry and knows the distribution before it can read it:

```hcl
hosts = {
  for name, d in digitalocean_droplet.dns : name => {
    address  = d.ipv4_address
    host_key = tls_private_key.host[name].public_key_openssh
    os       = "ubuntu"
  }
}
```

To try it on a throwaway container first, see [examples/local](examples/local).

### Don't run an open resolver

A DNS server that answers anyone on the internet gets used to amplify attacks on other people. AdGuard Home listens on every address by default, so the circuit sets `allowed_clients` to loopback and the private ranges: `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, Tailscale's `100.64.0.0/10`, and IPv6's `fc00::/7` and `fe80::/10`. Anyone else gets no answer over UDP and `REFUSED` over TCP. If your clients come from somewhere else, list them; an empty list answers everyone, which you only want behind a firewall.

On a cloud server, a firewall on port 53 is still a good idea. See [circuit-firewall](https://github.com/conn3xorg/circuit-firewall).

## How the config stays put

AdGuard Home keeps its settings in `AdGuardHome.yaml` and rewrites that file as it runs: it fills in every default, reorders keys and saves changes made in the web interface. A circuit that wrote the file directly would find it changed on every plan.

So the circuit never compares that file. It writes the settings it owns to `/etc/AdGuardHome/conn3x.yaml`, which AdGuard Home never touches, and only when that file, the password or the unit changes does it rebuild the live config:

1. Hashes the password with bcrypt on the host, using `htpasswd`.
2. Puts the desired settings and the user together in a new file, and checks it with `AdGuardHome --check-config`. If the check fails, the running config stays as it was and the apply stops.
3. Stops AdGuard Home, puts the new file in place, and starts it again. AdGuard Home fills in its defaults on the way up.

That keeps the second plan clean, and it means the circuit's inputs always win. The flip side: when you change an input, the whole file is rebuilt, and anything set in the web interface since the last change goes back to AdGuard Home's default. Between changes, the web interface is yours. Query logs, statistics and downloaded blocklists live in `data/` and aren't touched.

AdGuard Home's HTTP API could set each setting instead. But then every plan would have to log in and read each one back, and nothing could be set until the service was already up on a config of its own.

## What it does

On each host, in order:

1. If `dns_bind_hosts` has a wildcard, such as the default `0.0.0.0`, writes `/etc/systemd/resolved.conf.d/conn3x-adguardhome.conf` with `DNSStubListener=no` and restarts `systemd-resolved` if it's running. Its stub listener holds port 53 on `127.0.0.53` and `127.0.0.54`, and AdGuard Home can't bind a wildcard while it does. resolved keeps running for everything else. If `/etc/resolv.conf` points at the stub, it's pointed at `/run/systemd/resolve/resolv.conf`, which lists the real upstream servers, so the host keeps its own DNS. On a host without resolved, such as Rocky Linux, the drop-in sits unused. With specific addresses only, resolved is left alone.
2. Installs `curl`, `tar`, `gzip`, `ca-certificates`, and `htpasswd` from `apache2-utils` or `httpd-tools`.
3. Creates the system user `adguardhome`, with `/var/lib/AdGuardHome` as its home and AdGuard Home's work directory.
4. Downloads `AdGuardHome_linux_ARCH.tar.gz` for `adguardhome_version` from GitHub, checks its SHA-256 against `checksums`, and unpacks it to `/opt/AdGuardHome/vVERSION`. Versions sit side by side, so an upgrade never overwrites the binary that's running.
5. Writes the desired settings to `/etc/AdGuardHome/conn3x.yaml` and the password to `/etc/AdGuardHome/admin-password`, both root-only.
6. Writes `/etc/systemd/system/AdGuardHome.service`. AdGuard Home runs as `adguardhome` with only `CAP_NET_BIND_SERVICE`, can write nothing but its work directory, and runs with `--no-check-update`, so it never replaces itself and the version you pinned is the one that runs.
7. Rebuilds `/var/lib/AdGuardHome/AdGuardHome.yaml` and restarts AdGuard Home, as above, when something changed.
8. Enables the service and waits for port 53.

The blocklists download in the background once AdGuard Home is up.

### What it doesn't do

- It doesn't open port 53 or the web port in a firewall.
- It doesn't set up DHCP, DNS over HTTPS or TLS for clients, or encryption for the web interface. Those need certificates and choices the circuit can't make for you; set them in the web interface, and remember they reset when an input changes.
- It doesn't manage clients, blocked services, safe search or parental controls.
- It doesn't make AdGuard Home the host's own resolver.
- Deleting the module leaves AdGuard Home, its user, its files and the resolved drop-in in place.

## Inputs

| Name | Type | Default | Description |
| --- | --- | --- | --- |
| `hosts` | any | Required | Hosts to configure, by name. Each value is an address, such as `"192.168.1.2"`, or a host object such as `{ address = "192.168.1.2", host_key = "ssh-ed25519 AAAA..." }`. A host object can also set `user`, `port`, `private_key_file`, `jump_hosts` and `os`. The two forms can be mixed. |
| `ssh_user` | string | `"root"` | User to log in as. |
| `ssh_port` | number | `22` | SSH port. |
| `ssh_private_key_file` | string | `null` | Path to a private key. When null, Conn3x uses the SSH agent. |
| `ssh_known_hosts_file` | string | `null` | known_hosts file to check host keys against. When null, `~/.ssh/known_hosts`. Not used for a host object with `host_key`. |
| `ssh_become` | bool | `false` | Run commands as root through sudo. Set it when `ssh_user` isn't root. |
| `admin_password` | string | Required | Password for the web interface and the API, 8 to 72 characters. Ephemeral and sensitive: it reaches a root-only file on the host, is hashed there, and never reaches the plan or state. Changing it rebuilds the config. |
| `admin_username` | string | `"admin"` | User name for the web interface and the API. |
| `adguardhome_version` | string | `"0.107.79"` | AdGuard Home release to install, without the leading `v`. |
| `checksums` | map(string) | SHA-256 of v0.107.79 | SHA-256 of the release tarball, by architecture: `amd64` and `arm64`. Take them from the release's `checksums.txt`, and change them with `adguardhome_version`. |
| `web_address` | string | `"127.0.0.1:3000"` | Address and port of the web interface and the API. `"0.0.0.0:3000"` listens on every address. |
| `dns_bind_hosts` | list(string) | `["0.0.0.0"]` | Addresses AdGuard Home answers DNS on, on port 53. `"0.0.0.0"` means every address, IPv4 and IPv6, and turns off resolved's stub listener. |
| `allowed_clients` | list(string) | Loopback and private ranges | Clients AdGuard Home answers, as addresses or CIDR networks. An empty list answers everyone. |
| `upstream_dns` | list(string) | Quad9 and Cloudflare over HTTPS | Servers AdGuard Home forwards allowed queries to, in its own syntax: `"https://..."` for DNS over HTTPS, `"tls://..."` for DNS over TLS, or a plain address such as `"127.0.0.1:5335"` for a local Unbound. |
| `bootstrap_dns` | list(string) | `["9.9.9.9", "149.112.112.112", "1.1.1.1", "1.0.0.1"]` | Plain DNS servers that look up the names in `upstream_dns`. |
| `filters` | map(string) | AdGuard DNS filter | Blocklists, names to URLs. Adblock-style lists, hosts files and plain domain lists all work. |
| `user_rules` | list(string) | `[]` | Rules of your own in AdGuard's syntax, such as `"\|\|ads.example.com^"` to block or `"@@\|\|example.com^"` to allow. |
| `rewrites` | map(string) | `{}` | Local names, domains to an IP address or another domain, such as `{ "nas.home.arpa" = "192.168.1.20" }`. `"*.lab.home.arpa"` covers subdomains. |
| `blocking_mode` | string | `"default"` | How a blocked query is answered: `default` (`0.0.0.0` or `::` for Adblock-style rules, the listed address for hosts-file ones), `null_ip`, `nxdomain` or `refused`. |

## Outputs

| Name | Description |
| --- | --- |
| `service` | The systemd service that runs AdGuard Home, `AdGuardHome.service`. |
| `config_file` | The live config file, `/var/lib/AdGuardHome/AdGuardHome.yaml`. |
| `web_url` | URL of the web interface from the host itself, such as `http://127.0.0.1:3000`. |

## Requirements

Requires Conn3x v0.6.7 or later, systemd, and amd64 or arm64 hosts. Each host needs to reach its package mirror, GitHub, the upstream servers and the blocklists' servers. AdGuard Home is light: a 1 GB host is plenty for a home network.

## Tested on

Rocky Linux 10, Fedora 45, Ubuntu 24.04 and Debian 13. CI applies [examples/local](examples/local) to each on amd64 and checks that the second plan has no changes. Then it asks AdGuard Home over `dig` for `doubleclick.net`, which the AdGuard DNS filter blocks, and `ads.example.org`, which the example's own rule blocks, and expects `0.0.0.0` for both; for `example.com`, which has to resolve normally; and for `nas.home.arpa`, which has to come back as the example's `192.168.1.20`. It checks that `/control/status` accepts the example's password and turns down a wrong one. The same checks passed by hand on all four in containers on arm64.

They also passed on Ubuntu 24.04 and Rocky Linux 10 droplets with 1 GB of memory. On Ubuntu, resolved's stub went, the host kept its own DNS, and AdGuard Home took port 53 on every address. From outside, a UDP query got no answer, a TCP query got `REFUSED`, and the web port didn't answer. After a reboot AdGuard Home came back, the checks passed again and the plan had no changes. Changing a rewrite and `blocking_mode = "nxdomain"` rebuilt the config, the new answers came back, and the plan after was clean. So was changing the password, after which only the new one logged in.

Upgrading from one `adguardhome_version` to the next hasn't been tried yet.

## License

MPL-2.0. See [LICENSE](LICENSE). AdGuard Home itself is under the GPL-3.0.
