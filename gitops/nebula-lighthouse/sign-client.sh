#!/usr/bin/env bash
# Mints a certificate + ready-to-use config.yml for one Nebula client node,
# signed by the CA in ./ca (created by seal-nebula-certs.sh).
#
# Output goes to ./clients/<name>/ -- which .gitignore excludes, because it
# contains that node's private key in the clear. Copy the directory to the
# node (scp, USB, password manager) and delete the local copy when done;
# nothing here belongs in git or in the cluster.
#
# Usage:  ./sign-client.sh <name> <overlay-ip>
#   e.g.  ./sign-client.sh laptop 10.10.0.10
#
# Overlay IPs must be unique and inside 10.10.0.0/24 (see configmap.yaml).
# 10.10.0.1 is the lighthouse itself.

set -euo pipefail

LIGHTHOUSE_OVERLAY_IP="10.10.0.1"
LIGHTHOUSE_PUBLIC="157.151.171.157:4242"   # matches gitops/nebula-lighthouse/deployment.yaml's hostPort
OVERLAY_MASK="24"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CA_DIR="$HERE/ca"

[ $# -eq 2 ] || { echo "usage: $(basename "$0") <name> <overlay-ip>" >&2; exit 1; }
NAME="$1"
IP="$2"

case "$IP" in
  10.10.0.*) ;;
  *) echo "error: $IP is outside the 10.10.0.0/$OVERLAY_MASK overlay." >&2; exit 1 ;;
esac
[ "$IP" != "$LIGHTHOUSE_OVERLAY_IP" ] || {
  echo "error: $IP is the lighthouse's own address." >&2; exit 1
}

command -v nebula-cert >/dev/null 2>&1 || {
  echo "error: nebula-cert not found. See seal-nebula-certs.sh for install." >&2
  exit 1
}
[ -f "$CA_DIR/ca.key" ] || {
  echo "error: no CA at $CA_DIR/ca.key. Run ./seal-nebula-certs.sh first," >&2
  echo "       or restore the CA from your backup." >&2
  exit 1
}

OUT_DIR="$HERE/clients/$NAME"
[ -e "$OUT_DIR" ] && { echo "error: $OUT_DIR already exists." >&2; exit 1; }
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

nebula-cert sign \
  -ca-crt "$CA_DIR/ca.crt" \
  -ca-key "$CA_DIR/ca.key" \
  -name "$NAME" \
  -ip "$IP/$OVERLAY_MASK" \
  -out-crt "$OUT_DIR/host.crt" \
  -out-key "$OUT_DIR/host.key"

cp "$CA_DIR/ca.crt" "$OUT_DIR/ca.crt"
chmod 600 "$OUT_DIR/host.key"

# Client config: the mirror image of the lighthouse's. am_lighthouse false,
# and the lighthouse listed in both static_host_map (how to reach it before
# anything is known) and lighthouse.hosts (who to ask about other peers).
cat > "$OUT_DIR/config.yml" <<EOF
pki:
  ca: /etc/nebula/ca.crt
  cert: /etc/nebula/host.crt
  key: /etc/nebula/host.key

static_host_map:
  "$LIGHTHOUSE_OVERLAY_IP": ["$LIGHTHOUSE_PUBLIC"]

lighthouse:
  am_lighthouse: false
  interval: 60
  hosts:
    - "$LIGHTHOUSE_OVERLAY_IP"

listen:
  host: 0.0.0.0
  # 0 = pick an ephemeral port. Correct for clients behind NAT; only the
  # lighthouse needs a fixed, forwarded port.
  port: 0

punchy:
  punch: true
  respond: true

relay:
  am_relay: false
  use_relays: true
  relays:
    - "$LIGHTHOUSE_OVERLAY_IP"

tun:
  disabled: false
  dev: nebula1
  drop_local_broadcast: false
  drop_multicast: false
  tx_queue: 500
  mtu: 1300
  routes: []
  unsafe_routes: []

logging:
  level: info
  format: text

firewall:
  conntrack:
    tcp_timeout: 12m
    udp_timeout: 3m
    default_timeout: 10m
  outbound:
    - port: any
      proto: any
      host: any
  inbound:
    # Any node holding a cert from this CA can reach this one. Tighten with
    # \`group: <name>\` once you have more than a couple of nodes.
    - port: any
      proto: icmp
      host: any
    - port: any
      proto: any
      host: any
EOF

echo "wrote $OUT_DIR/ (ca.crt, host.crt, host.key, config.yml)"
echo
echo "On the client, install nebula and:"
echo "  sudo mkdir -p /etc/nebula && sudo cp $OUT_DIR/* /etc/nebula/"
echo "  sudo nebula -config /etc/nebula/config.yml"
echo "  ping $LIGHTHOUSE_OVERLAY_IP    # the lighthouse allows inbound icmp"
echo
echo "Then delete the local copy -- it holds $NAME's private key:"
echo "  rm -rf $OUT_DIR"
