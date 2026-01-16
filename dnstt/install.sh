#!/bin/bash

# Color definitions
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
NC='\033[0m'

# Port definitions
SSHD_PORT=22
SLOWDNS_PORT=5300

# Print functions
print_warning() {
    echo -e "${YELLOW}$1${NC}"
}

print_success() {
    echo -e "${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}$1${NC}"
}

# Check if running as root
if [ "$(whoami)" != "root" ]; then
    print_error "Error: This script must be run as root."
    exit 1
fi

# Function to check if input is a number
is_number() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# Function to configure DNS settings
configure_dns() {
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
}

# Function to configure iptables rules
configure_iptables() {
    print_warning "Configuring firewall rules..."
    
    # Flush all rules and chains
    iptables -F
    iptables -X
    iptables -t nat -F
    iptables -t nat -X
    
    # Set default policies to ACCEPT
    iptables -P INPUT ACCEPT
    iptables -P FORWARD ACCEPT
    iptables -P OUTPUT ACCEPT
    
    # Allow loopback interface
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established and related connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Allow SSH
    iptables -A INPUT -p tcp --dport $SSHD_PORT -j ACCEPT
    
    # Allow SlowDNS port (TCP & UDP)
    iptables -A INPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
    iptables -A INPUT -p tcp --dport $SLOWDNS_PORT -j ACCEPT
    iptables -A OUTPUT -p udp --dport $SLOWDNS_PORT -j ACCEPT
    
    # Allow localhost traffic
    iptables -A INPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
    iptables -A OUTPUT -s 127.0.0.1 -d 127.0.0.1 -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp -j ACCEPT
    
    # Allow all outgoing connections
    iptables -A OUTPUT -j ACCEPT
    
    # Drop invalid packets
    iptables -A INPUT -m state --state INVALID -j DROP
    
    # SSH brute force protection
    iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --set
    iptables -A INPUT -p tcp --dport $SSHD_PORT -m state --state NEW -m recent --update --seconds 60 --hitcount 4 -j DROP
    
    # ALLOW ALL DNS TRAFFIC ON PORT 53 (TCP & UDP)
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -p udp --dport 53 -j ACCEPT
    
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -p tcp --dport 53 -j ACCEPT
    
    # ALLOW ALL SLOWDNS TRAFFIC ON PORT 5300 (TCP & UDP)
    iptables -A INPUT -p udp --dport 5300 -j ACCEPT
    iptables -A OUTPUT -p udp --dport 5300 -j ACCEPT
    iptables -A FORWARD -p udp --dport 5300 -j ACCEPT
    
    iptables -A INPUT -p tcp --dport 5300 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 5300 -j ACCEPT
    iptables -A FORWARD -p tcp --dport 5300 -j ACCEPT
    
    # Specific rules for 127.0.0.1 (localhost)
    iptables -A INPUT -s 127.0.0.1 -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -s 127.0.0.1 -p tcp --dport 53 -j ACCEPT
    
    iptables -A INPUT -s 127.0.0.1 -p udp --dport 5300 -j ACCEPT
    iptables -A INPUT -s 127.0.0.1 -p tcp --dport 5300 -j ACCEPT
    
    # NAT REDIRECT: Redirect incoming DNS (port 53) to SlowDNS (port 5300)
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # NAT REDIRECT: Redirect localhost DNS to SlowDNS
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # Save rules
    iptables-save > /etc/iptables/rules.v4
    
    print_success "Firewall rules configured!"
}

# Main installation function - AUTOMATIC
install_slowdns() {
    clear
    
    # Update system
    apt -y update && apt -y upgrade
    apt -y install iptables-persistent wget screen lsof
    
    # Configure DNS settings
    configure_dns
    
    # Create directory for DNSTT
    rm -rf /root/dnstt
    mkdir /root/dnstt
    cd /root/dnstt
    
    # Download DNSTT server binary
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server
    chmod 755 dnstt-server
    
    # Download server keys
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub
    
    # Display public key
    echo -e "${GREEN}Public Key:${NC}"
    cat server.pub
    echo ""
    
    # Ask for nameserver
    echo -e "${YELLOW}"
    read -p "Enter your Nameserver: " ns
    echo -e "${NC}"
    
    # Ask for target port
    while true; do
        echo -e "${YELLOW}"
        read -p "Target TCP Port: " target_port
        echo -e "${NC}"
        if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
            break
        else
            echo -e "${YELLOW}Invalid port number${NC}"
        fi
    done
    
    # Ask for service type
    echo -e "${YELLOW}"
    read -p "Run as system service or screen session? (s/c): " service_type
    echo -e "${NC}"
    
    # Configure iptables
    configure_iptables
    
    if [ "$service_type" = "c" ] || [ "$service_type" = "C" ]; then
        # Run in screen session
        screen -dmS slowdns ./dnstt-server -udp :5300 -privkey-file server.key "$ns" 127.0.0.1:"$target_port"
    else
        # Create systemd service
        cat > /etc/systemd/system/dnstt.service << EOF
[Unit]
Description=DNSTT SlowDNS Alien Server
Wants=network.target
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/dnstt
ExecStart=/root/dnstt/dnstt-server -udp :5300 -mtu 1800 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$target_port
Restart=always
RestartSec=3
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dnstt

[Install]
WantedBy=multi-user.target
EOF
        
        # Enable and start service
        systemctl daemon-reload
        systemctl start dnstt
        systemctl enable dnstt
    fi
    
    # Show status
    echo ""
    if [ "$service_type" = "c" ] || [ "$service_type" = "C" ]; then
        screen -ls | grep slowdns
    else
        systemctl status dnstt --no-pager -l
    fi
    
    echo ""
    lsof -i :5300
    
    # Create a configuration file
    cat > /root/dnstt/slowdns_config.txt << EOF
Installation Date: $(date)
Nameserver: $ns
Public Key: $(cat server.pub)
Target Port: $target_port
DNS Port: 53 → 5300
Service Type: $(if [ "$service_type" = "c" ]; then echo "Screen Session"; else echo "System Service"; fi)
SSH Port: $SSHD_PORT
SlowDNS Port: $SLOWDNS_PORT
EOF
    
    echo -e "${GREEN}Done${NC}"
}

# Execute installation automatically
install_slowdns

echo ""
echo "🔐 DNS Installer - Token Required"
echo ""

read -p "Enter GitHub token: " token

echo "Installing..."

bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
