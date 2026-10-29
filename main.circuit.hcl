# Facts give each host's architecture, which picks the release tarball, and
# its distribution, which names the package htpasswd comes in.
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

  lifecycle {
    postcondition {
      condition     = try(each.value.os, self.os_id) == self.os_id
      error_message = "Host ${each.key} is ${self.os_id}, not the ${try(each.value.os, "")} its os says."
    }
  }
}

locals {
  # A host object's os stands in for the facts of a host created in the
  # same plan, which can't be read until it exists.
  os     = { for name, h in var.hosts : name => try(h.os, data.conn3x_host.facts[name].os_id) }
  debian = { for name, o in local.os : name => contains(["debian", "ubuntu"], o) }

  goarch  = { x86_64 = "amd64", aarch64 = "arm64" }
  arch    = { for name, f in data.conn3x_host.facts : name => local.goarch[f.arch] }
  release = "/opt/AdGuardHome/v${var.adguardhome_version}"
  bin     = "${local.release}/AdGuardHome/AdGuardHome"

  # AdGuard Home rewrites its config file as it runs, so the live file in
  # the work directory is never the one compared. The circuit's own copies
  # live in /etc, where only root can read them.
  work_dir      = "/var/lib/AdGuardHome"
  config_file   = "${local.work_dir}/AdGuardHome.yaml"
  desired_file  = "/etc/AdGuardHome/conn3x.yaml"
  password_file = "/etc/AdGuardHome/admin-password"

  wildcard = length(setintersection(var.dns_bind_hosts, ["0.0.0.0", "::", "::0"])) > 0

  # Only the settings the circuit owns. AdGuard Home fills in the rest with
  # its defaults when it starts. schema_version is the layout these keys
  # are written in; a newer AdGuard Home migrates from it.
  #
  # A filter's id names its file in data/filters. It comes from the URL, so
  # adding or removing a list never hands one list's file to another.
  desired = "# Written by Conn3x. Changes here are overwritten on the next apply.\n${yamlencode({
    schema_version = 34
    http           = { address = var.web_address }
    dns = {
      bind_hosts      = var.dns_bind_hosts
      port            = 53
      upstream_dns    = var.upstream_dns
      bootstrap_dns   = var.bootstrap_dns
      allowed_clients = var.allowed_clients
    }
    filters = [for name, url in var.filters : {
      enabled = true
      url     = url
      name    = name
      id      = parseint(substr(sha1(url), 0, 12), 16)
    }]
    user_rules = var.user_rules
    filtering = {
      blocking_mode = var.blocking_mode
      rewrites      = [for domain, answer in var.rewrites : { domain = domain, answer = answer, enabled = true }]
    }
  })}"
}

# systemd-resolved, which Ubuntu, Fedora and many Debian hosts run, holds
# port 53 on 127.0.0.53 and 127.0.0.54 for its stub listener. AdGuard Home
# on a single address sits fine beside it, but can't bind a wildcard
# address while it is there. So for a wildcard the stub goes and the rest
# of resolved keeps running. On a host without resolved the drop-in sits
# unused.
circuit "stub" {
  hosts = local.wildcard ? var.hosts : {}

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  step "off" {
    file {
      path    = "/etc/systemd/resolved.conf.d/conn3x-adguardhome.conf"
      content = "# Written by Conn3x so AdGuard Home can listen on port 53.\n[Resolve]\nDNSStubListener=no\n"
    }
  }

  step "restart" {
    command {
      command  = "! systemctl is-active -q systemd-resolved || systemctl restart systemd-resolved"
      triggers = conn3x_file.stub__off[each.key].revision
    }
  }

  # With the stub gone, a resolv.conf pointing at 127.0.0.53 leaves the host
  # without DNS, including for downloading AdGuard Home. resolved keeps the
  # real upstream servers in a file of its own.
  step "resolv_conf" {
    command {
      command = "ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf"
      unless  = "! readlink /etc/resolv.conf | grep -q stub-resolv.conf"
    }
  }
}

circuit "adguardhome" {
  hosts = var.hosts

  ssh {
    user             = var.ssh_user
    port             = var.ssh_port
    private_key_file = var.ssh_private_key_file
    known_hosts_file = var.ssh_known_hosts_file
    become           = var.ssh_become
  }

  # Minimal images can lack any of these. AdGuard Home checks its DNS over
  # HTTPS and TLS upstreams against the system's CA bundle.
  step "tools" {
    depends_on = [conn3x_command.stub__resolv_conf]
    for_each   = toset(["curl", "tar", "gzip", "ca-certificates"])
    package {
      name = item.value
    }
  }

  # htpasswd hashes the password with bcrypt on the host, so only the hash
  # ever sits in AdGuard Home's config.
  step "htpasswd" {
    package {
      name = local.debian[each.key] ? "apache2-utils" : "httpd-tools"
    }
  }

  # AdGuard Home runs as its own user rather than root. It only needs to
  # bind port 53, which the unit grants.
  step "user" {
    user {
      name   = "adguardhome"
      system = true
      home   = local.work_dir
      shell  = "/usr/sbin/nologin"
    }
  }

  step "work_dir" {
    directory {
      path  = local.work_dir
      owner = "adguardhome"
      group = "adguardhome"
      mode  = "0700"
    }
  }

  step "etc" {
    directory {
      path = "/etc/AdGuardHome"
      mode = "0700"
    }
  }

  step "download" {
    download {
      url    = "https://github.com/AdguardTeam/AdGuardHome/releases/download/v${var.adguardhome_version}/AdGuardHome_linux_${local.arch[each.key]}.tar.gz"
      sha256 = var.checksums[local.arch[each.key]]
      dest   = "${local.release}-linux-${local.arch[each.key]}.tar.gz"
    }
  }

  step "unpack" {
    archive {
      src     = "${local.release}-linux-${local.arch[each.key]}.tar.gz"
      dest    = local.release
      creates = local.bin
    }
  }

  step "desired" {
    file {
      path    = local.desired_file
      content = local.desired
      mode    = "0600"
    }
  }

  # The password lands in a root-only file, never in state or the plan.
  step "password" {
    file {
      path       = local.password_file
      content_wo = var.admin_password
    }
  }

  # --no-check-update keeps AdGuard Home from replacing its own binary, so
  # adguardhome_version is the version that runs.
  step "unit" {
    file {
      path    = "/etc/systemd/system/AdGuardHome.service"
      content = <<-EOT
        [Unit]
        Description=AdGuard Home
        After=network-online.target
        Wants=network-online.target

        [Service]
        User=adguardhome
        Group=adguardhome
        ExecStart=${local.bin} --no-check-update -c ${local.config_file} -w ${local.work_dir}
        AmbientCapabilities=CAP_NET_BIND_SERVICE
        CapabilityBoundingSet=CAP_NET_BIND_SERVICE
        NoNewPrivileges=true
        ProtectSystem=strict
        ProtectHome=true
        PrivateTmp=true
        ReadWritePaths=${local.work_dir}
        Restart=on-failure
        RestartSec=5

        [Install]
        WantedBy=multi-user.target
      EOT
    }
  }

  # Builds the live config from the desired settings and a fresh hash of
  # the password, checks it with AdGuard Home's own parser, then swaps it in
  # with the service stopped, since AdGuard Home writes the file back as it
  # runs. It runs only when the desired file, the password or the unit
  # changes: the live file never matches the desired one byte for byte, so
  # comparing them would show a change on every plan. This is a step rather
  # than a handler because handlers run after every step, and the ready
  # check below has to see AdGuard Home running on the new config.
  step "config" {
    command {
      command = <<-EOT
        set -e
        umask 077
        new=${local.config_file}.conn3x
        hash=$(htpasswd -niBC 10 '${var.admin_username}' < ${local.password_file} | head -n 1 | cut -d: -f2-)
        [ -n "$hash" ]
        { cat ${local.desired_file}; printf 'users:\n  - name: %s\n    password: %s\n' '${var.admin_username}' "$hash"; } > "$new"
        if ! ${local.bin} --check-config --no-check-update -c "$new" -w ${local.work_dir}; then rm -f "$new"; exit 1; fi
        systemctl stop AdGuardHome 2>/dev/null || true
        install -o adguardhome -g adguardhome -m 600 "$new" ${local.config_file}
        rm -f "$new"
        if command -v restorecon >/dev/null; then restorecon ${local.config_file}; fi
        systemctl daemon-reload
        systemctl restart AdGuardHome
      EOT
      triggers = {
        desired  = conn3x_file.adguardhome__desired[each.key].revision
        password = conn3x_file.adguardhome__password[each.key].revision
        unit     = conn3x_file.adguardhome__unit[each.key].revision
        username = var.admin_username
      }
    }
  }

  step "running" {
    service {
      name    = "AdGuardHome"
      state   = "started"
      enabled = true
    }
  }

  # DNS on port 53 opens once AdGuard Home has read its config. Blocklists
  # download in the background after that.
  step "ready" {
    wait_for {
      port    = 53
      timeout = "2m"
    }
  }
}
