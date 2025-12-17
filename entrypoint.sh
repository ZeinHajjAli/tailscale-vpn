#!/usr/bin/env bash

set -euo pipefail

: "${TS_AUTHKEY:?Set TS_AUTHKEY}"
: "${WG_CONF:?Set WG_CONF (e.g. /config/wg0.conf)}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null || true

# Bring up WireGuard (Proton)
mkdir -p /etc/wireguard
cp "$WG_CONF" /etc/wireguard/wg0.conf
wg-quick up wg0

# Basic "killswitch": if wg0 drops, don't leak via eth0
# Only allow forwarding from tailscale0 -> wg0, and established back.
iptables -P FORWARD DROP
iptables -A FORWARD -i tailscale0 -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT out through VPN
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# Start tailscaled
mkdir -p /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 1

# Bring up Tailscale as an exit node
TS_ARGS=(
    --authkey="${TS_AUTHKEY}"
    --hostname="${TS_HOSTNAME:-unraid-proton-exit}"
    --advertise-exit-node
    --accept-dns=false
)

# Optional: force exit-node clients to use specific DNS
# e.g. your own resolver over VPN, or Proton-provided DNS if you know it.
if [[ -n "${TS_DNS:-}" ]]; then
    TS_ARGS+=( --dns="${TS_DNS}" )
fi

tailscale up "${TS_ARGS[@]}"

echo "Ready: Tailscale exit node via Proton WireGuard is up."
exec tail -f /dev/null
