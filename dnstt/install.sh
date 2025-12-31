#!/bin/bash

# ============================================
# SLOWDNS INSTALLATION SCRIPT
# Version: 1.0
# Author: VPN Script
# ============================================

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print colored output
print_message() {
    echo -e "${2}${1}${NC}"
}

# Function to disable IPv6
disable_ipv6() {
    print_message "Disabling IPv6..." "$YELLOW"
    
    # Disable IPv6 in sysctl
    cat >> /etc/sysctl.conf << EOF
# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    # Apply sysctl changes
    sysctl -p
    
    # Disable IPv6 in grub (for persistence after reboot)
    if [ -f /etc/default/grub ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&ipv6.disable=1 /' /etc/default/grub
        sed -i 's/GRUB_CMDLINE_LINUX="/&ipv6.disable=1 /' /etc/default/grub
        update-grub 2>/dev/null || true
    fi
    
    # Disable IPv6 modules
    cat >> /etc/modprobe.d/disable-ipv6.conf << EOF
# Disable IPv6
install ipv6 /bin/true
blacklist ipv6
alias net-pf-10 off
alias ipv6 off
options ipv6 disable=1
EOF
    
    print_message "IPv6 disabled successfully!" "$GREEN"
}

# Main script execution
main() {
    # Check if running as root
    if [ "$EUID" -ne 0 ]; then
        print_message "Please run as root (use sudo)" "$RED"
        exit 1
    fi
    
    # Show script header
    print_message "======================================" "$GREEN"
    print_message "      SLOWDNS INSTALLATION SCRIPT     " "$GREEN"
    print_message "======================================" "$GREEN"
    echo ""
    
    # Set fixed values
    TARGET_PORT="22"
    
    # Install dependencies
    print_message "Updating system packages..." "$BLUE"
    apt -y update && apt -y upgrade
    
    print_message "Installing required packages..." "$BLUE"
    apt -y install iptables-persistent wget screen lsof
    
    # Disable IPv6
    disable_ipv6
    
    # Disable systemd-resolved
    print_message "Disabling systemd-resolved..." "$YELLOW"
    
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    pkill -9 systemd-resolved 2>/dev/null
    
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    
    # Make resolv.conf immutable to prevent changes
    chattr +i /etc/resolv.conf 2>/dev/null || true
    
    # Clean up and create directory
    rm -rf /root/dnstt
    mkdir -p /root/dnstt
    cd /root/dnstt || exit 1
    
    # Download SlowDNS files
    print_message "Downloading SlowDNS server files..." "$BLUE"
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub
    
    # Set permissions
    chmod 755 dnstt-server
    
    # Display public key
    print_message "=== YOUR PUBLIC KEY ===" "$YELLOW"
    cat server.pub
    print_message "=================================" "$YELLOW"
    echo ""
    read -p "Copy the public key above and press Enter when done"
    
    # Get nameserver
    read -p "Enter your Nameserver (e.g., ns1.yourdomain.com): " ns
    
    # Configure iptables for SlowDNS
    print_message "Configuring firewall rules..." "$BLUE"
    iptables -I INPUT -p udp --dport 5300 -j ACCEPT
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
    iptables-save > /etc/iptables/rules.v4
    
    print_message "Using target UDP port: $TARGET_PORT" "$GREEN"
    print_message "Using systemd service (foreground mode)" "$GREEN"
    
    # Create systemd service - Using UDP
    print_message "Creating systemd service for SlowDNS..." "$BLUE"
    
    cat > /etc/systemd/system/dnstt.service << EOF
[Unit]
Description=DNSTT Tunnel Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/dnstt
ExecStart=/root/dnstt/dnstt-server -udp :5300 -privkey-file /root/dnstt/server.key $ns udp://127.0.0.1:$TARGET_PORT
Restart=always
RestartSec=3
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dnstt

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd and start service
    systemctl daemon-reload
    systemctl start dnstt
    systemctl enable dnstt
    
    print_message "SlowDNS service created and started!" "$GREEN"
    print_message "To check status: systemctl status dnstt" "$YELLOW"
    print_message "To view logs: journalctl -u dnstt -f" "$YELLOW"
    
    # Verify installation
    print_message "Verifying SlowDNS installation..." "$BLUE"
    sleep 2
    
    if lsof -i :5300 > /dev/null 2>&1; then
        print_message "SlowDNS is running on port 5300!" "$GREEN"
    else
        print_message "Warning: SlowDNS might not be running. Check manually." "$RED"
    fi
    
    print_message "======================================" "$GREEN"
    print_message "Installation completed!" "$GREEN"
    print_message "Target UDP port: $TARGET_PORT" "$BLUE"
    print_message "Nameserver: $ns" "$BLUE"
    print_message "Service: systemd (dnstt)" "$BLUE"
    print_message "IPv6: Disabled" "$BLUE"
    print_message "======================================" "$GREEN"
    
    print_message "System reboot is recommended for IPv6 changes to take full effect!" "$YELLOW"
    
    exit 0
}

# Run main function
main
