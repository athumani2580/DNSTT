#!/usr/bin/env bash
# Autoscript by Mahboub Million (hardened edition)

set -euo pipefail

# --- Require root ---
if [[ ${EUID:-0} -ne 0 ]]; then
  echo "Please run as root (sudo)." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# --- Packages ---
apt-get update
apt-get upgrade -y
apt-get install -y --no-install-recommends \
  ca-certificates curl wget openssl net-tools screen iptables-persistent dos2unix
  

update-ca-certificates >/dev/null 2>&1 || true

# --- Inputs ---
read -p "Record A Domain For Certificate (default: a.domain.com): " -e -i a.domain.com cert
read -p "NS Domain (default: ns.domain.com): " -e -i ns.domain.com DnsNS
read -p "Ports to forward (comma-separated, e.g. 22,443,80): " -e -i 22 PORTS

# Basic domain sanity (very light check)
if ! [[ "$cert" =~ ^[A-Za-z0-9.-]+$ ]]; then echo "Invalid cert domain '$cert'." >&2; exit 1; fi
if ! [[ "$DnsNS" =~ ^[A-Za-z0-9.-]+$ ]]; then echo "Invalid NS domain '$DnsNS'." >&2; exit 1; fi

# --- Paths & constants ---
BASE_DIR="/root/slipstream"
CERT_DIR="$BASE_DIR/certs"
BIN="/usr/local/bin/slipstream-server-v0.0.2"
BIN_URL="https://raw.githubusercontent.com/Mahboub-power-is-back/quic_over_dns/main/slipstream-server-v0.0.2"
KEY_PATH="$CERT_DIR/key.pem"
CERT_PATH="$CERT_DIR/cert.pem"
DNS_PORT=5300

# Optional integrity pin: export SLIPSTREAM_SHA256="abcdef..."
PIN_SHA256="${SLIPSTREAM_SHA256:-}"

umask 077
mkdir -p "$CERT_DIR"

# --- Certificate (self-signed with SAN) ---
if [[ ! -s "$KEY_PATH" || ! -s "$CERT_PATH" ]]; then
  openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
    -keyout "$KEY_PATH" -out "$CERT_PATH" \
    -subj "/CN=$cert" \
    -addext "subjectAltName=DNS:$cert"
  chmod 600 "$KEY_PATH"
fi

# --- Install server binary if missing ---
if [[ ! -x "$BIN" ]]; then
  echo "Downloading slipstream server binary..."
  curl -fsSL --proto '=https' --tlsv1.2 "$BIN_URL" -o "$BIN"
  chmod +x "$BIN"

  if [[ -n "$PIN_SHA256" ]]; then
    dl_sha="$(sha256sum "$BIN" | awk '{print $1}')"
    if [[ "$dl_sha" != "$PIN_SHA256" ]]; then
      echo "Binary SHA256 mismatch! expected=$PIN_SHA256 got=$dl_sha" >&2
      exit 1
    fi
  fi
fi

# --- Build target addresses from ports ---
IFS=',' read -r -a PORT_ARR <<< "$PORTS"
TARGET_ARGS=()
DEDUP=()
for raw in "${PORT_ARR[@]}"; do
  p="$(echo "$raw" | xargs)"
  [[ -z "$p" ]] && continue
  if [[ "$p" =~ ^[0-9]+$ ]] && (( p > 0 && p < 65536 )); then
    [[ -n "${DEDUP[$p]:-}" ]] && continue
    DEDUP[$p]=1
    TARGET_ARGS+=( "--target-address=127.0.0.1:${p}" )
  else
    echo "Skipping invalid port: $p" >&2
  fi
done
if [[ ${#TARGET_ARGS[@]} -eq 0 ]]; then
  echo "No valid ports provided. Exiting." >&2
  exit 1
fi

# --- Stop old screen session if running ---
screen -S slipstream -X quit || true

# --- Launch ---
screen -dmS slipstream "$BIN" \
  "${TARGET_ARGS[@]}" \
  --domain="$DnsNS" \
  --cert="$CERT_PATH" \
  --key="$KEY_PATH" \
  --dns-listen-port="$DNS_PORT"

# --- Firewall/NAT rules (idempotent) ---
add_rule() {
  local table="$1" chain="$2" proto="$3" dport="$4" target="$5" toports="$6"
  if ! iptables -t "$table" -C "$chain" -p "$proto" --dport "$dport" -j "$target" --to-ports "$toports" 2>/dev/null; then
    iptables -t "$table" -A "$chain" -p "$proto" --dport "$dport" -j "$target" --to-ports "$toports"
  fi
}

add_rule6() {
  local table="$1" chain="$2" proto="$3" dport="$4" target="$5" toports="$6"
  if command -v ip6tables >/dev/null 2>&1; then
    if ! ip6tables -t "$table" -C "$chain" -p "$proto" --dport "$dport" -j "$target" --to-ports "$toports" 2>/dev/null; then
      ip6tables -t "$table" -A "$chain" -p "$proto" --dport "$dport" -j "$target" --to-ports "$toports"
    fi
  fi
}

# External traffic -> PREROUTING
for proto in udp tcp; do
  add_rule nat PREROUTING "$proto" 53 REDIRECT "$DNS_PORT"
  add_rule6 nat PREROUTING "$proto" 53 REDIRECT "$DNS_PORT"
done

# Local host traffic -> OUTPUT
for proto in udp tcp; do
  if ! iptables -t nat -C OUTPUT -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null; then
    iptables -t nat -A OUTPUT -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    if ! ip6tables -t nat -C OUTPUT -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT" 2>/dev/null; then
      ip6tables -t nat -A OUTPUT -p "$proto" --dport 53 -j REDIRECT --to-ports "$DNS_PORT"
    fi
  fi
done

# Allow INPUT to DNS_PORT (in case a host firewall enforces policy)
for proto in udp tcp; do
  if ! iptables -C INPUT -p "$proto" --dport "$DNS_PORT" -j ACCEPT 2>/dev/null; then
    iptables -A INPUT -p "$proto" --dport "$DNS_PORT" -j ACCEPT
  fi
  if command -v ip6tables >/dev/null 2>&1; then
    if ! ip6tables -C INPUT -p "$proto" --dport "$DNS_PORT" -j ACCEPT 2>/dev/null; then
      ip6tables -A INPUT -p "$proto" --dport "$DNS_PORT" -j ACCEPT
    fi
  fi
done

# Persist firewall rules (best-effort)
netfilter-persistent save || true

# UFW (best-effort): allow 5300 if UFW is active/enforcing
if command -v ufw >/dev/null 2>&1; then
  if ufw status | grep -qi "Status: active"; then
    ufw allow 5300/udp || true
    ufw allow 5300/tcp || true
  fi
fi

echo "✅ Slipstream setup complete."
echo "   Domain (SAN): $cert"
echo "   NS Domain:    $DnsNS"
echo "   DNS listen:   $DNS_PORT (redirected from :53, incl. localhost + IPv6)"
echo "   Forwarding:   ${!DEDUP[@]}"
echo "   Screen sesh:  slipstream  (use: screen -r slipstream)"

# --- Optional systemd unit (commented). Save as /etc/systemd/system/slipstream.service ---
: <<'SYSTEMD_UNIT'
[Unit]
Description=Slipstream QUIC-over-DNS server
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/slipstream-server-v0.0.2 \
  --domain=REPLACE_WITH_NS_DOMAIN \
  --cert=/root/slipstream/certs/cert.pem \
  --key=/root/slipstream/certs/key.pem \
  --dns-listen-port=5300 \
  --target-address=127.0.0.1:22
Restart=on-failure
User=root
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
SYSTEMD_UNIT


