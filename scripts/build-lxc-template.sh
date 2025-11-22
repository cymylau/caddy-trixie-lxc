#!/usr/bin/env bash
set -euo pipefail

# Where to build the rootfs
ROOTFS="${ROOTFS:-/tmp/rootfs}"
TARBALL_NAME="${TARBALL_NAME:-debian-13-caddy-cloudflare_13.0-1_amd64.tar.gz}"

# Mirror for debootstrap
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"

echo "==> Installing build dependencies (debootstrap, etc)..."
sudo apt-get update
sudo apt-get install -y debootstrap ca-certificates curl git

echo "==> Creating rootfs directory at ${ROOTFS}..."
sudo rm -rf "${ROOTFS}"
sudo mkdir -p "${ROOTFS}"

echo "==> Running debootstrap for Debian 13 (trixie)..."
sudo debootstrap \
  --arch=amd64 \
  trixie \
  "${ROOTFS}" \
  "${DEBIAN_MIRROR}"

echo "==> Configuring basic system files in rootfs..."

# Minimal hostname
echo "caddy-trixie" | sudo tee "${ROOTFS}/etc/hostname" >/dev/null

# Basic hosts file
cat <<EOF | sudo tee "${ROOTFS}/etc/hosts" >/dev/null
127.0.0.1   localhost
127.0.1.1   caddy-trixie
::1         localhost ip6-localhost ip6-loopback
EOF

echo "==> Chroot: installing Caddy + Cloudflare DNS plugin and dependencies..."

sudo chroot "${ROOTFS}" bash -lc "
set -euo pipefail

apt-get update
apt-get install -y ca-certificates curl systemd systemd-sysv

# Create caddy user/group
if ! getent group caddy >/dev/null; then
  groupadd --system caddy
fi

if ! id caddy >/dev/null 2>&1; then
  useradd --system --gid caddy \
    --create-home --home-dir /var/lib/caddy \
    --shell /usr/sbin/nologin caddy
fi

mkdir -p /etc/caddy /var/log/caddy
chown -R caddy:caddy /etc/caddy /var/lib/caddy /var/log/caddy

# Download Caddy with Cloudflare DNS module (raw binary)
mkdir -p /tmp/caddy-install
cd /tmp/caddy-install

curl -fsSL \
  'https://caddyserver.com/api/download?os=linux&arch=amd64&p=github.com%2Fcaddy-dns%2Fcloudflare' \
  -o caddy

mv caddy /usr/local/bin/caddy
chmod +x /usr/local/bin/caddy

cd /
rm -rf /tmp/caddy-install

echo '==> Writing placeholder Caddyfile (inside chroot)...'

cat >/etc/caddy/Caddyfile <<'EOF_CF'
# Caddyfile placeholder
#
# This template intentionally does NOT define any sites.
# You should edit this file at runtime inside the container, e.g.:
#
#   nano /etc/caddy/Caddyfile
#
# Example for a Proxmox reverse proxy with Cloudflare DNS-01:
#
# proxmox.example.com {
#     tls {
#         # CLOUDFLARE_API_TOKEN must be set in the caddy.service Environment=
#         dns cloudflare {env.CLOUDFLARE_API_TOKEN}
#     }
#
#     reverse_proxy https://192.168.2.108:8006 {
#         transport http {
#             tls_insecure_skip_verify
#         }
#     }
# }
#
# After editing:
#   systemctl daemon-reload
#   systemctl enable --now caddy
EOF_CF

chown caddy:caddy /etc/caddy/Caddyfile

echo '==> Creating systemd service for Caddy...'

cat >/etc/systemd/system/caddy.service <<'EOF_SVC'
[Unit]
Description=Caddy web server (reverse proxy)
After=network-online.target
Wants=network-online.target

[Service]
User=caddy
Group=caddy
ExecStart=/usr/local/bin/caddy run --environ --config /etc/caddy/Caddyfile
ExecReload=/usr/local/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
LimitNPROC=512
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_BIND_SERVICE

# IMPORTANT:
#   Replace this value at runtime with a real Cloudflare API token
#   (inside the container), then:
#     systemctl daemon-reload
#     systemctl restart caddy
Environment=CLOUDFLARE_API_TOKEN=REPLACE_WITH_YOUR_TOKEN

[Install]
WantedBy=multi-user.target
EOF_SVC

echo '==> NOTE: Caddy service is installed but NOT enabled by default.'
echo '          You will enable it at runtime after providing a real Caddyfile.'

echo '==> Cleaning up apt caches inside rootfs...'
apt-get clean
rm -rf /var/lib/apt/lists/*
"

echo "==> Creating LXC template tarball: ${TARBALL_NAME}..."
sudo tar --numeric-owner -czpf "${TARBALL_NAME}" -C "${ROOTFS}" .

echo "==> Done. Generated template: ${TARBALL_NAME}"
