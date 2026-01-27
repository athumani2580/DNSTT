#!/usr/bin/env bash
# Interactive Slipstream Client Launcher

# Prompt for domain and resolver
read -rp "Enter Slipstream domain [dns.testone.my-north-africa.com]: " DOMAIN
DOMAIN=${DOMAIN:-dns.testone.my-north-africa.com}

read -rp "Enter DNS resolver [1.1.1.1:53]: " RESOLVER
RESOLVER=${RESOLVER:-1.1.1.1:53}

# Run client in background with nohup
nohup ./slipstream-client \
  --congestion-control=cubic \
  --tcp-listen-port=5201 \
  --resolver="$RESOLVER" \
  --domain="$DOMAIN" \
  --keep-alive-interval=60 > client.log 2>&1 &

echo
echo "✅ Slipstream client started!"
echo "    Domain   : $DOMAIN"
echo "    Resolver : $RESOLVER"
echo "    Log file : client.log"
echo
echo "Check running process with: pgrep -a slipstream-client"
echo "View logs with: tail -f client.log"
echo "Stop client with: pkill -f slipstream-client"