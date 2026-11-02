#!/bin/sh
# First-boot installation of the log relay, run by the per-boot launcher until
# /var/lib/lz-obs.done exists. Needs ALLOY_VERSION (may be empty).
set -eu

md() { # metadata only answers from a source port < 1024; random, or TIME_WAIT
  curl -fsS --max-time 10 --local-port "$(shuf -i 600-1000 -n1)-1023" "$@"
}
md_retry() {
  for _ in 1 2 3 4 5 6 7 8 9 10; do md "$@" && return 0; sleep 2; done
  return 1
}
URL=http://169.254.42.42/user_data/lz_secrets

# 1. Cockpit token: store it root-only, then remove it from the metadata.
mkdir -p /etc/alloy
if [ ! -s /etc/alloy/cockpit.env ]; then
  umask 077
  md_retry "$URL" > /etc/alloy/cockpit.env.tmp
  grep -q '^COCKPIT_TOKEN=' /etc/alloy/cockpit.env.tmp
  mv /etc/alloy/cockpit.env.tmp /etc/alloy/cockpit.env
  md_retry -X DELETE "$URL" > /dev/null
  umask 022
fi

# 2. Alloy from the official Grafana apt repository.
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq curl gnupg ca-certificates nftables
mkdir -p /etc/apt/keyrings
curl -fsSL https://apt.grafana.com/gpg.key | gpg --dearmor --yes -o /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update -qq
apt-get install -y -qq "alloy${ALLOY_VERSION:+=$ALLOY_VERSION}"

install -o root -g alloy -m 0640 /opt/lz-obs/config.alloy /etc/alloy/config.alloy
chown root:alloy /etc/alloy/cockpit.env
chmod 0640 /etc/alloy/cockpit.env

# Port 514 is privileged: the capability is simpler and safer than running as root.
mkdir -p /etc/systemd/system/alloy.service.d
cat > /etc/systemd/system/alloy.service.d/lz-obs.conf <<'UNIT'
[Service]
EnvironmentFile=/etc/alloy/cockpit.env
AmbientCapabilities=CAP_NET_BIND_SERVICE
# The private IP may come after alloy at boot: retry the bind.
Restart=always
RestartSec=5
UNIT
systemctl daemon-reload
systemctl enable alloy
systemctl restart alloy

# 3. Firewall last, once the install no longer needs new inbound paths.
nft -c -f /opt/lz-obs/nftables.conf
install -m 0644 /opt/lz-obs/nftables.conf /etc/nftables.conf
systemctl enable nftables
systemctl restart nftables

sleep 5
systemctl is-active --quiet alloy
touch /var/lib/lz-obs.done
