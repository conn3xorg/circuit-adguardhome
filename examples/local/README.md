# Local example

Applies circuit-adguardhome to a throwaway Rocky Linux 10 container with systemd. You need Conn3x and Podman.

AdGuard Home's service is sandboxed by systemd, which needs a privileged host container, and that's simplest with rootful Podman. On a Mac, use the Podman machine's root connection. On Linux, use `sudo podman`:

```sh
export CONTAINER_CONNECTION=podman-machine-default-root   # macOS
export PODMAN="sudo podman"                               # Linux
./up.sh
conn3x init
conn3x apply
conn3x plan
```

The second plan says `No changes.` To ask the new AdGuard Home something, install `dig` in the container and query it:

```sh
ssh -p 2222 -i id_ed25519 -o UserKnownHostsFile=known_hosts root@127.0.0.1
dnf -y install bind-utils
dig +short @127.0.0.1 doubleclick.net ads.example.org nas.home.arpa example.com
```

`doubleclick.net` and `ads.example.org` come back as `0.0.0.0`, `nas.home.arpa` as `192.168.1.20` and `example.com` as its real address. Give the blocklist a few seconds to download after the first apply. The API answers on port 3000 inside the container:

```sh
curl -u admin:correct-horse-battery http://127.0.0.1:3000/control/status
```

The example's password is `correct-horse-battery`, which you'd never keep on a real host.

`up.sh` listens on `127.0.0.1:2222`. Set `PORT` to use another port, and pass the same port to Conn3x with `-var port=PORT`. Set `CONTAINERFILE` to test another distro, such as one of the images in Conn3x's `test/images`, which CI uses.

`./down.sh` removes the container, its volumes, the key and the state.
