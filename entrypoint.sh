#!/usr/bin/env bash
set -euo pipefail

: "${TS_AUTHKEY:?Set TS_AUTHKEY}"
: "${WG_CONF:?Set WG_CONF (e.g. /config/wg0.conf)}"

PROTON_DNS="${PROTON_DNS:-10.2.0.1}"

sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Bring up WireGuard (Proton)
mkdir -p /etc/wireguard
cp "$WG_CONF" /etc/wireguard/wg0.conf
wg-quick up wg0

# Start tailscaled
mkdir -p /var/lib/tailscale
tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/var/run/tailscale/tailscaled.sock &
sleep 1

# Tailscale exit node
tailscale up \
    --authkey="${TS_AUTHKEY}" \
    --hostname="${TS_HOSTNAME:-unraid-proton-exit}" \
    --advertise-exit-node \
    --accept-dns=false

# --- Firewall/NAT ---
# Default drop forwarding to avoid leaks
iptables -P FORWARD DROP

# Allow TS clients to go out via wg0 only; allow replies back
iptables -A FORWARD -i tailscale0 -o wg0 -j ACCEPT
iptables -A FORWARD -i wg0 -o tailscale0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# NAT out through VPN
iptables -t nat -A POSTROUTING -o wg0 -j MASQUERADE

# --- Force DNS through Proton (NetShield) ---
# Redirect any DNS from tailscale clients to Proton's in-tunnel DNS
iptables -t nat -A PREROUTING -i tailscale0 -p udp --dport 53 -j DNAT --to-destination "${PROTON_DNS}:53"
iptables -t nat -A PREROUTING -i tailscale0 -p tcp --dport 53 -j DNAT --to-destination "${PROTON_DNS}:53"

# Allow the redirected DNS traffic out wg0
iptables -A FORWARD -i tailscale0 -o wg0 -p udp -d "${PROTON_DNS}" --dport 53 -j ACCEPT
iptables -A FORWARD -i tailscale0 -o wg0 -p tcp -d "${PROTON_DNS}" --dport 53 -j ACCEPT

echo "Ready: exit node via Proton WireGuard. DNS forced to ${PROTON_DNS} (NetShield)."
exec tail -f /dev/null
