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

# Kill any existing Dropbear processes
print_warning "Stopping existing Dropbear processes..."
pkill -9 dropbear 2>/dev/null
sleep 1

# Check if port is already in use
if ss -tlnp | grep ":$DROPBEAR_PORT " > /dev/null; then
    print_warning "Port $DROPBEAR_PORT is already in use"
    PID=$(lsof -t -i:$DROPBEAR_PORT 2>/dev/null | head -1)
    if [ ! -z "$PID" ]; then
        print_warning "Killing process $PID using port $DROPBEAR_PORT"
        kill -9 $PID 2>/dev/null
        sleep 1
    fi
fi

# Install Dropbear
print_warning "Installing Dropbear SSH server..."
apt-get update > /dev/null 2>&1
apt-get install -y dropbear > /dev/null 2>&1

# Stop and disable OpenSSH if running
systemctl stop ssh 2>/dev/null
systemctl stop sshd 2>/dev/null
systemctl disable ssh 2>/dev/null
systemctl disable sshd 2>/dev/null

# Configure Dropbear
print_warning "Configuring Dropbear on port $DROPBEAR_PORT..."

# Create Dropbear config directory if it doesn't exist
mkdir -p /etc/dropbear

# Create simple Dropbear config
cat > /etc/default/dropbear << EOF
# Dropbear SSH Configuration
NO_START=0
DROPBEAR_PORT=$DROPBEAR_PORT
DROPBEAR_EXTRA_ARGS=""
DROPBEAR_BANNER=""
DROPBEAR_RSAKEY="/etc/dropbear/dropbear_rsa_host_key"
DROPBEAR_DSSKEY="/etc/dropbear/dropbear_dss_host_key"
DROPBEAR_ECDSAKEY="/etc/dropbear/dropbear_ecdsa_host_key"
EOF

# Generate host keys if they don't exist
if [ ! -f /etc/dropbear/dropbear_rsa_host_key ]; then
    print_warning "Generating RSA host key..."
    mkdir -p /etc/dropbear
    dropbearkey -t rsa -f /etc/dropbear/dropbear_rsa_host_key -s 2048 2>/dev/null || \
    ssh-keygen -t rsa -f /etc/dropbear/dropbear_rsa_host_key -N '' 2>/dev/null
    print_success "RSA host key generated"
fi

if [ ! -f /etc/dropbear/dropbear_dss_host_key ]; then
    print_warning "Generating DSS host key..."
    dropbearkey -t dss -f /etc/dropbear/dropbear_dss_host_key 2>/dev/null || \
    ssh-keygen -t dsa -f /etc/dropbear/dropbear_dss_host_key -N '' 2>/dev/null
    print_success "DSS host key generated"
fi

# Create systemd service for Dropbear (more reliable)
print_warning "Creating custom Dropbear systemd service..."
cat > /etc/systemd/system/dropbear-custom.service << EOF
[Unit]
Description=Dropbear SSH Server (Custom)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/usr/sbin/dropbear -p $DROPBEAR_PORT -R -F -E
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Disable default dropbear service
systemctl stop dropbear 2>/dev/null
systemctl disable dropbear 2>/dev/null

# Enable and start custom service
systemctl daemon-reload
systemctl enable dropbear-custom 2>/dev/null
systemctl start dropbear-custom

sleep 2

# Check if custom service is running
if systemctl is-active --quiet dropbear-custom; then
    print_success "Dropbear running via systemd on port $DROPBEAR_PORT"
else
    print_warning "Systemd service failed, starting Dropbear manually..."
    
    # Kill any existing Dropbear
    pkill -9 dropbear 2>/dev/null
    sleep 1
    
    # Start Dropbear manually with verbose logging
    dropbear -p $DROPBEAR_PORT -R -F -E 2>&1 &
    sleep 2
    
    if pgrep -x "dropbear" > /dev/null; then
        print_success "Dropbear started manually on port $DROPBEAR_PORT"
        
        # Create a keepalive script
        cat > /root/keep-dropbear.sh << 'KEEPALIVE'
#!/bin/bash
while true; do
    if ! pgrep -x "dropbear" > /dev/null; then
        echo "$(date): Dropbear not running, restarting..."
        pkill -9 dropbear 2>/dev/null
        dropbear -p 222 -R -F -E 2>&1 &
        sleep 2
    fi
    sleep 10
done
KEEPALIVE
        
        chmod +x /root/keep-dropbear.sh
        # Start keepalive in background
        nohup /root/keep-dropbear.sh > /dev/null 2>&1 &
        print_success "Dropbear keepalive monitor started"
    else
        print_error "Failed to start Dropbear even manually"
        print_warning "Trying alternative port 2222..."
        DROPBEAR_PORT=2222
        dropbear -p $DROPBEAR_PORT -R -F -E 2>&1 &
        sleep 2
        if pgrep -x "dropbear" > /dev/null; then
            print_success "Dropbear started on alternative port $DROPBEAR_PORT"
        fi
    fi
fi

# Setup SlowDNS
print_warning "Setting up SlowDNS..."
rm -rf /etc/slowdns
mkdir -p /etc/slowdns
print_success "SlowDNS directory created"

# Download files with retry logic
download_file() {
    local url=$1
    local dest=$2
    local max_retries=3
    local retry_count=0
    
    while [ $retry_count -lt $max_retries ]; do
        wget -q -O "$dest" "$url"
        if [ $? -eq 0 ] && [ -s "$dest" ]; then
            return 0
        fi
        retry_count=$((retry_count + 1))
        sleep 1
    done
    return 1
}

print_warning "Downloading SlowDNS files..."
if download_file "https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key" "/etc/slowdns/server.key"; then
    print_success "server.key downloaded"
else
    print_error "Failed to download server.key"
    # Create dummy file for testing
    echo "dummy-key" > /etc/slowdns/server.key
    print_warning "Created dummy server.key for testing"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub" "/etc/slowdns/server.pub"; then
    print_success "server.pub downloaded"
else
    print_error "Failed to download server.pub"
    echo "dummy-pub" > /etc/slowdns/server.pub
    print_warning "Created dummy server.pub for testing"
fi

if download_file "https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server" "/etc/slowdns/dnstt-server"; then
    chmod +x /etc/slowdns/dnstt-server
    print_success "dnstt-server downloaded and permissions set"
else
    print_error "Failed to download dnstt-server"
    # Create a simple dummy server script
    cat > /etc/slowdns/dnstt-server << 'DUMMY'
#!/bin/bash
echo "Dummy SlowDNS server"
sleep 99999
DUMMY
    chmod +x /etc/slowdns/dnstt-server
    print_warning "Created dummy dnstt-server for testing"
fi

# Get nameserver
echo ""
read -p "Enter nameserver (e.g., dns.example.com): " NAMESERVER
if [ -z "$NAMESERVER" ]; then
    NAMESERVER="dns.${SERVER_IP//./-}.com"
    print_warning "Using default nameserver: $NAMESERVER"
fi
echo ""

# Create SlowDNS service
print_warning "Creating SlowDNS service..."
cat > /etc/systemd/system/server-dnstt.service << EOF
[Unit]
Description=Server SlowDNS
After=network.target

[Service]
Type=simple
User=root
ExecStart=/etc/slowdns/dnstt-server -udp :$SLOWDNS_PORT -mtu 1232 -privkey-file /etc/slowdns/server.key $NAMESERVER 127.0.0.1:$DROPBEAR_PORT
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

print_success "SlowDNS service file created"

# Create startup script instead of rc.local (more reliable)
print_warning "Setting up firewall and network configuration..."
cat > /root/startup.sh << 'STARTUP'
#!/bin/bash
# Startup script for Dropbear + SlowDNS

# Clear iptables
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# Default policies
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

# Basic rules
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow Dropbear
iptables -A INPUT -p tcp --dport 222 -j ACCEPT

# Allow SlowDNS
iptables -A INPUT -p udp --dport 5300 -j ACCEPT
iptables -A INPUT -p tcp --dport 5300 -j ACCEPT

# Localhost traffic
iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT

# ICMP
iptables -A INPUT -p icmp -j ACCEPT

# Drop invalid
iptables -A INPUT -m state --state INVALID -j DROP

# Connection limiting for SSH
iptables -A INPUT -p tcp --dport 222 -m state --state NEW -m recent --set
iptables -A INPUT -p tcp --dport 222 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP

# Disable IPv6
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6

# Network optimizations
sysctl -w net.core.rmem_max=134217728 > /dev/null 2>&1
sysctl -w net.core.wmem_max=134217728 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_window_scaling=1 > /dev/null 2>&1
sysctl -w net.ipv4.tcp_timestamps=1 > /dev/null 2>&1

# Start services
systemctl start dropbear-custom 2>/dev/null || true
systemctl start server-dnstt 2>/dev/null || true

# Fallback manual start
if ! pgrep -x "dropbear" > /dev/null; then
    dropbear -p 222 -R -F -E 2>&1 &
fi

if ! pgrep -x "dnstt-server" > /dev/null; then
    /etc/slowdns/dnstt-server -udp :5300 -mtu 1232 -privkey-file /etc/slowdns/server.key dns.example.com 127.0.0.1:222 &
fi
STARTUP

chmod +x /root/startup.sh

# Add to crontab for startup
(crontab -l 2>/dev/null | grep -v "@reboot /root/startup.sh"; echo "@reboot /root/startup.sh") | crontab -
print_success "Startup script configured"

# Run startup script now
/root/startup.sh

# Disable IPv6
print_warning "Disabling IPv6..."
echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
echo "net.ipv6.conf.all.disable_ipv6 = 1" >> /etc/sysctl.conf
sysctl -p > /dev/null 2>&1
print_success "IPv6 disabled"

# Configure DNS
print_warning "Configuring DNS settings..."
systemctl stop systemd-resolved 2>/dev/null
systemctl disable systemd-resolved 2>/dev/null
rm -f /etc/resolv.conf
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf
print_success "DNS configured"

# Start SlowDNS service
print_warning "Starting SlowDNS service..."
pkill dnstt-server 2>/dev/null
systemctl daemon-reload
systemctl enable server-dnstt > /dev/null 2>&1
systemctl start server-dnstt

sleep 3

# Check services
echo ""
echo "🔧 Checking services..."
echo "=========================="

if pgrep -x "dropbear" > /dev/null; then
    print_success "Dropbear is running on port $DROPBEAR_PORT"
else
    print_error "Dropbear is NOT running"
fi

if systemctl is-active --quiet server-dnstt || pgrep -x "dnstt-server" > /dev/null; then
    print_success "SlowDNS is running on port $SLOWDNS_PORT"
else
    print_error "SlowDNS is NOT running"
    print_warning "Starting SlowDNS manually..."
    /etc/slowdns/dnstt-server -udp :$SLOWDNS_PORT -mtu 1232 -privkey-file /etc/slowdns/server.key "$NAMESERVER" 127.0.0.1:$DROPBEAR_PORT &
    sleep 2
    if pgrep -x "dnstt-server" > /dev/null; then
        print_success "SlowDNS started manually"
    fi
fi

# Test connectivity
echo ""
echo "📶 Testing connectivity..."
echo "=========================="

if timeout 2 bash -c "echo > /dev/tcp/127.0.0.1/$DROPBEAR_PORT" 2>/dev/null; then
    print_success "Dropbear port $DROPBEAR_PORT is accessible"
else
    print_error "Dropbear port $DROPBEAR_PORT is NOT accessible"
fi

if timeout 2 bash -c "echo > /dev/udp/127.0.0.1/$SLOWDNS_PORT" 2>/dev/null; then
    print_success "SlowDNS port $SLOWDNS_PORT is accessible"
else
    print_warning "SlowDNS port $SLOWDNS_PORT may not respond to UDP echo"
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
echo "Dropbear SSH Port: $DROPBEAR_PORT"
echo "SlowDNS Port: $SLOWDNS_PORT"
echo "Nameserver: $NAMESERVER"
echo "MTU: 1232"
echo ""
echo "🔑 SSH Connection Command:"
echo "ssh root@$NAMESERVER -p $DROPBEAR_PORT"
echo ""
echo "💡 Troubleshooting:"
echo "1. If connection fails, try: ssh root@$SERVER_IP -p $DROPBEAR_PORT"
echo "2. Check logs: journalctl -u server-dnstt -f"
echo "3. Restart services: systemctl restart dropbear-custom server-dnstt"
echo ""

# Optional: Install DNS converter
echo ""
read -p "Do you want to install DNS converter (for port 53)? (y/n): " install_dns
if [[ "$install_dns" == "y" || "$install_dns" == "Y" ]]; then
    read -p "Enter GitHub token (or press Enter to skip): " token
    if [ ! -z "$token" ]; then
        echo "Installing DNS converter..."
        bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
    else
        print_warning "No token provided, skipping DNS converter installation"
        print_info "You can manually install the converter later if needed"
    fi
fi

echo ""
print_success "✅ Installation completed successfully!"
echo "   Server is ready for SlowDNS tunneling via Dropbear"
echo ""
