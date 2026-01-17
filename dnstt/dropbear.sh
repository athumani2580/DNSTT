#!/bin/bash

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# SSH Port Configuration
DROPBEAR_PORT=222
SLOWDNS_PORT=5300

# Functions
print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root: sudo bash $0${NC}"
        exit 1
    fi
}

# Check root
check_root

echo "=================================================================="
echo "                 Dropbear SlowDNS Installation"
echo "=================================================================="

# Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    SERVER_IP=$(hostname -I | awk '{print $1}')
fi

# Install Dropbear
print_warning "Installing Dropbear SSH server..."
apt-get update > /dev/null 2>&1
apt-get install -y dropbear > /dev/null 2>&1

# Stop OpenSSH if running
systemctl stop sshd 2>/dev/null
systemctl disable sshd 2>/dev/null

# Configure Dropbear
print_warning "Configuring Dropbear on port $DROPBEAR_PORT..."

# Backup existing config
cp /etc/default/dropbear /etc/default/dropbear.backup 2>/dev/null

# Create Dropbear config
cat > /etc/default/dropbear << EOF
# Dropbear SSH Configuration
NO_START=0

# Port to listen on
DROPBEAR_PORT=$DROPBEAR_PORT

# Additional ports to listen on (optional)
# DROPBEAR_EXTRA_ARGS="-p 2222"

# Path to host keys
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"

# Disable password logins (set to "yes" to enable password authentication)
DROPBEAR_PASSWORD=yes

# Banner file (optional)
DROPBEAR_BANNER="/etc/dropbear/banner"

# Enable X11 forwarding
DROPBEAR_X11FWD=no

# Idle timeout in seconds (0 = no timeout)
DROPBEAR_IDLE_TIMEOUT=0

# Keepalive interval in seconds (0 = disabled)
DROPBEAR_KEEPALIVE=0

# Maximum number of authentication attempts
DROPBEAR_MAX_AUTH_TRIES=3

# Enable/disable MOTD
DROPBEAR_MOTD=no

# Enable reverse DNS lookups
DROPBEAR_REVERSE_DNS=no

# Additional options
DROPBEAR_EXTRA_ARGS=""
EOF

# Generate host keys if they don't exist
if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
    print_warning "Generating RSA host key..."
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 > /dev/null 2>&1
    print_success "RSA host key generated"
fi

if [ ! -f /etc/dropbear/dropbear_dss_host_key ]; then
    print_warning "Generating DSS host key..."
    dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key > /dev/null 2>&1
    print_success "DSS host key generated"
fi

# Start Dropbear
systemctl restart dropbear
sleep 2

if systemctl is-active --quiet dropbear; then
    print_success "Dropbear configured and running on port $DROPBEAR_PORT"
else
    print_error "Dropbear failed to start"
    # Try manual start
    dropbear -p $DROPBEAR_PORT -R -B
    if [ $? -eq 0 ]; then
        print_success "Dropbear started manually on port $DROPBEAR_PORT"
    fi
fi

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files
print_warning "Downloading SlowDNS files..."
wget -q -O /etc/slowdns/server.key "https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key"
if [ $? -eq 0 ]; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
fi

wget -q -O /etc/slowdns/server.pub "https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub"
if [ $? -eq 0 ]; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
fi

wget -q -O /etc/slowdns/dnstt-server "https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server"
if [ $? -eq 0 ]; then
    print_success "dnstt-server downloaded"
else
    print_error "Failed to download dnstt-server"
fi

chmod +x /etc/slowdns/dnstt-server
print_success "File permissions set"

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
echo ""

# Create SlowDNS service with MTU 1232
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-dnstt.service << EOF
[Unit]
Description=Server SlowDNS ALIEN
Documentation=https://man himself
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/etc/slowdns/dnstt-server -udp :$SLOWDNS_PORT -mtu 1232 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Startup config with iptables
print_warning "Setting up iptables and startup configuration..."
cat > /etc/rc.local <<-END
#!/bin/sh -e
systemctl start dropbear

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -j ACCEPT
iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A OUTPUT -j ACCEPT
iptables -A INPUT -m state --state INVALID -j DROP

iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport $DROPBEAR_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1

exit 0
END

chmod +x /etc/rc.local
systemctl enable rc-local > /dev/null 2>&1
systemctl start rc-local.service > /dev/null 2>&1
print_success "Startup configuration set"

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
echo "net.ipv6.conf.default.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Disable systemd-resolved and set custom DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
systemctl mask systemd-resolved 2>/dev/null
pkill -9 systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
chattr +i /etc/resolv.conf 2>/dev/null || true
print_success "DNS configured with Google and Cloudflare DNS servers"

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill dnstt-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-dnstt > /dev/null 2>&1
systemctl start server-dnstt

sleep 3

if systemctl is-active --quiet server-dnstt; then
    print_success "SlowDNS service started"
    
    # Test SlowDNS
    print_warning "Testing SlowDNS functionality..."
    sleep 2
    
    if timeout 3 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
        print_success "SlowDNS is listening on port $SLOWDNS_PORT"
    else
        print_error "SlowDNS not responding on port $SLOWDNS_PORT"
        
        # Try direct start
        pkill dnstt-server 2>/dev/null
        /etc/slowdns/dnstt-server -udp :$SLOWDNS_PORT -mtu 1232 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT &
        sleep 2
        
        if pgrep -x "dnstt-server" > /dev/null; then
            print_success "SlowDNS started directly"
        else
            print_error "Failed to start SlowDNS"
        fi
    fi
else
    print_error "SlowDNS service failed to start"
fi

# Test SSH connection
print_warning "Testing Dropbear SSH connection..."
if timeout 5 bash -c "echo > /dev/tcp/127.0.0.1/$DROPBEAR_PORT" 2>/dev/null; then
    print_success "Dropbear SSH port $DROPBEAR_PORT is accessible"
else
    print_error "Dropbear SSH port $DROPBEAR_PORT is not accessible"
fi

echo ""
echo "=================================================================="
print_success "           Dropbear SlowDNS Installation Completed!"
echo "=================================================================="

# Show connection info
echo ""
echo "📋 Connection Information:"
echo "=========================="
echo "Server IP: $SERVER_IP"
echo "SSH Port: $DROPBEAR_PORT (Dropbear)"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "Nameserver: $NAMESERVER"
echo "MTU: 1232"
echo ""
echo "🔧 Services Status:"
echo "=========================="
if systemctl is-active --quiet dropbear; then
    echo -e "Dropbear: ${GREEN}Running${NC}"
else
    echo -e "Dropbear: ${RED}Stopped${NC}"
fi

if systemctl is-active --quiet server-dnstt; then
    echo -e "SlowDNS: ${GREEN}Running${NC}"
else
    echo -e "SlowDNS: ${RED}Stopped${NC}"
fi

# Check if token is needed for additional installation
echo ""
read -p "Do you want to install DNS converter? (y/n): " install_dns
if [[ "$install_dns" == "y" || "$install_dns" == "Y" ]]; then
    read -p "Enter GitHub token: " token
    if [ ! -z "$token" ]; then
        echo "Installing DNS converter..."
        bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
    else
        print_warning "No token provided, skipping DNS converter installation"
    fi
fi

echo ""
echo "✅ Installation completed!"
echo "Use: ssh root@$NAMESERVER -p $DROPBEAR_PORT"
echo ""
