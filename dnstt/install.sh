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

# Function to check if port is in use
check_port() {
    local port=$1
    if lsof -i :$port > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

# Function to configure iptables properly
configure_iptables() {
    print_message "Configuring iptables for DNS redirection..." "$BLUE"
    
    # Remove any existing rules first
    iptables -t nat -F
    iptables -F INPUT
    
    # Allow DNS traffic on port 5300
    iptables -I INPUT -p udp --dport 5300 -j ACCEPT
    iptables -I INPUT -p tcp --dport 5300 -j ACCEPT
    
    # Redirect incoming DNS traffic from external sources
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -I PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # CRITICAL: Redirect local DNS traffic (127.0.0.1) - OUTPUT chain
    iptables -t nat -I OUTPUT -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -I OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # Save rules
    iptables-save > /etc/iptables/rules.v4
    
    print_message "Iptables configured with OUTPUT chain rules!" "$GREEN"
}

# Function to test DNS
test_dns() {
    print_message "Testing DNS configuration..." "$BLUE"
    
    # Test 1: Check if dnstt-server is listening
    print_message "1. Checking if dnstt-server is listening..." "$YELLOW"
    if check_port 5300; then
        print_message "   ✓ dnstt-server is listening on port 5300" "$GREEN"
        lsof -i :5300
    else
        print_message "   ✗ dnstt-server is NOT listening on port 5300" "$RED"
    fi
    
    # Test 2: Check iptables rules
    print_message "2. Checking iptables rules..." "$YELLOW"
    echo "NAT OUTPUT rules (for local traffic):"
    iptables -t nat -L OUTPUT -n -v
    echo ""
    echo "NAT PREROUTING rules (for external traffic):"
    iptables -t nat -L PREROUTING -n -v
    
    # Test 3: Test DNS query to port 5300 directly
    print_message "3. Testing DNS query to port 5300 (direct)..." "$YELLOW"
    result=$(dig @127.0.0.1 -p 5300 google.com +short +time=2 +tries=1 2>&1)
    if echo "$result" | grep -q "connection refused"; then
        print_message "   ✗ DNS query to port 5300 failed" "$RED"
        echo "   Error: $result"
    elif [ -n "$result" ]; then
        print_message "   ✓ DNS query to port 5300 works" "$GREEN"
        echo "   Response: $result"
    else
        print_message "   ⚠ DNS query to port 5300 timed out" "$YELLOW"
    fi
    
    # Test 4: Test DNS query to port 53 (should redirect to 5300)
    print_message "4. Testing DNS query to port 53 (should redirect)..." "$YELLOW"
    result=$(dig @127.0.0.1 google.com +short +time=3 +tries=2 2>&1)
    if echo "$result" | grep -q "connection refused"; then
        print_message "   ✗ DNS query to port 53 failed" "$RED"
        echo "   Error: $result"
    elif [ -n "$result" ]; then
        print_message "   ✓ DNS query to port 53 works (redirected to 5300)" "$GREEN"
        echo "   Response: $result"
    else
        print_message "   ⚠ DNS query to port 53 timed out" "$YELLOW"
    fi
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
    apt -y install iptables-persistent wget screen lsof dnsutils
    
    # Disable IPv6
    disable_ipv6
    
    # Disable systemd-resolved and stop any DNS services
    print_message "Stopping DNS services..." "$YELLOW"
    
    # Stop all possible DNS services
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    
    systemctl stop dnsmasq 2>/dev/null
    systemctl disable dnsmasq 2>/dev/null
    
    systemctl stop bind9 2>/dev/null
    systemctl disable bind9 2>/dev/null
    
    systemctl stop named 2>/dev/null
    systemctl disable named 2>/dev/null
    
    # Kill any processes using port 53
    pkill -9 systemd-resolved 2>/dev/null
    pkill -9 dnsmasq 2>/dev/null
    pkill -9 named 2>/dev/null
    
    # Check if port 53 is still in use
    if check_port 53; then
        print_message "Warning: Port 53 is still in use!" "$RED"
        lsof -i :53
        print_message "Killing processes on port 53..." "$YELLOW"
        fuser -k 53/udp 2>/dev/null
        fuser -k 53/tcp 2>/dev/null
    fi
    
    # Set DNS resolvers
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
    wget -q https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/dnstt-server
    wget -q https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.key
    wget -q https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.pub
    
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
    
    # Stop any existing dnstt service
    systemctl stop dnstt 2>/dev/null
    
    # Configure iptables
    configure_iptables
    
    print_message "Using target port: $TARGET_PORT" "$GREEN"
    print_message "Using systemd service (foreground mode)" "$GREEN"
    
    # Test the dnstt-server command
    print_message "Testing dnstt-server..." "$BLUE"
    timeout 5 ./dnstt-server -udp :5300 -privkey-file server.key $ns 127.0.0.1:$TARGET_PORT &
    test_pid=$!
    sleep 2
    
    if check_port 5300; then
        print_message "✓ dnstt-server test successful" "$GREEN"
        kill $test_pid 2>/dev/null
        sleep 1
    else
        print_message "✗ dnstt-server test failed" "$RED"
        kill $test_pid 2>/dev/null
    fi
    
    # Create systemd service
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
ExecStart=/root/dnstt/dnstt-server -udp :5300 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$TARGET_PORT
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
    
    # Wait for service to start
    print_message "Waiting for service to start..." "$BLUE"
    sleep 3
    
    # Check service status
    systemctl status dnstt --no-pager
    
    # Run comprehensive tests
    test_dns
    
    print_message "======================================" "$GREEN"
    print_message "Installation completed!" "$GREEN"
    print_message "Target port: $TARGET_PORT" "$BLUE"
    print_message "Nameserver: $ns" "$BLUE"
    print_message "Service: systemd (dnstt)" "$BLUE"
    print_message "IPv6: Disabled" "$BLUE"
    print_message "======================================" "$GREEN"
    
    print_message "IMPORTANT: Local DNS queries (127.0.0.1:53) should now work!" "$YELLOW"
    print_message "Test with: dig @127.0.0.1 google.com" "$YELLOW"
    print_message "Or test with: nslookup google.com 127.0.0.1" "$YELLOW"
    
    print_message "System reboot is recommended for IPv6 changes to take full effect!" "$YELLOW"
    
    exit 0
}

# Run main function
main
