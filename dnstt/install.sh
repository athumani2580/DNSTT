#!/bin/bash

# Color Codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_message() {
    echo -e "${2}${1}${NC}"
}

is_number() {
    local num=$1
    [[ $num =~ ^[0-9]+$ ]]
}

validate_port() {
    local port=$1
    if is_number "$port" && [ "$port" -ge 1 ] && [ "$port" -le 65535 ]; then
        return 0
    else
        return 1
    fi
}

check_port() {
    local port=$1
    if lsof -i :$port > /dev/null 2>&1; then
        return 0
    else
        return 1
    fi
}

install_dependencies() {
    print_message "Installing dependencies..." "$BLUE"
    apt -y update && apt -y upgrade
    apt -y install iptables-persistent wget screen lsof dnsutils
}

disable_ipv6() {
    print_message "Disabling IPv6..." "$YELLOW"
    
    echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6
    sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null 2>&1
    
    cat >> /etc/sysctl.conf << EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    sysctl -p > /dev/null 2>&1
    
    if [ -f /etc/default/grub ]; then
        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/&ipv6.disable=1 /' /etc/default/grub
        sed -i 's/GRUB_CMDLINE_LINUX="/&ipv6.disable=1 /' /etc/default/grub
        update-grub 2>/dev/null || true
    fi
    
    cat >> /etc/modprobe.d/disable-ipv6.conf << EOF
install ipv6 /bin/true
blacklist ipv6
alias net-pf-10 off
alias ipv6 off
options ipv6 disable=1
EOF
}

configure_iptables() {
    print_message "Configuring iptables..." "$BLUE"
    
    iptables -t nat -F
    iptables -F INPUT
    
    iptables -I INPUT -p udp --dport 5300 -j ACCEPT
    iptables -I INPUT -p tcp --dport 5300 -j ACCEPT
    
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -I PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    iptables -t nat -I OUTPUT -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -I OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    iptables-save > /etc/iptables/rules.v4
}

disable_systemd_resolved() {
    print_message "Disabling systemd-resolved..." "$YELLOW"
    
    systemctl stop systemd-resolved 2>/dev/null
    systemctl disable systemd-resolved 2>/dev/null
    systemctl mask systemd-resolved 2>/dev/null
    
    systemctl stop dnsmasq 2>/dev/null
    systemctl disable dnsmasq 2>/dev/null
    systemctl stop bind9 2>/dev/null
    systemctl disable bind9 2>/dev/null
    systemctl stop named 2>/dev/null
    systemctl disable named 2>/dev/null
    
    pkill -9 systemd-resolved 2>/dev/null
    pkill -9 dnsmasq 2>/dev/null
    pkill -9 named 2>/dev/null
    
    if check_port 53; then
        fuser -k 53/udp 2>/dev/null
        fuser -k 53/tcp 2>/dev/null
    fi
    
    rm -f /etc/resolv.conf
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf
    
    chattr +i /etc/resolv.conf 2>/dev/null || true
}

configure_openssh() {
    print_message "Configuring OpenSSH..." "$YELLOW"
    
    SSHD_PORT="22"
    current_port=$(grep -E "^Port\s+[0-9]+" /etc/ssh/sshd_config | awk '{print $2}' 2>/dev/null || echo "22")
    
    if [ "$current_port" != "22" ]; then
        SSHD_PORT="$current_port"
    else
        read -p "Change SSH port from 22? (y/n): " change_ssh
        
        if [[ "$change_ssh" =~ ^[Yy]$ ]]; then
            while true; do
                read -p "Enter new SSH port (not 5300): " ssh_port
                
                if validate_port "$ssh_port"; then
                    if [ "$ssh_port" -eq 5300 ]; then
                        print_message "Port 5300 reserved for SlowDNS" "$RED"
                        continue
                    fi
                    SSHD_PORT="$ssh_port"
                    break
                else
                    print_message "Invalid port" "$RED"
                fi
            done
        fi
    fi
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup 2>/dev/null
    
    cat > /etc/ssh/sshd_config << EOF
Port $SSHD_PORT
Protocol 2
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords no
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
ClientAliveInterval 60
ClientAliveCountMax 3
AllowTcpForwarding yes
GatewayPorts yes
Compression delayed
Subsystem sftp /usr/lib/openssh/sftp-server
MaxSessions 100
MaxStartups 100:30:200
LoginGraceTime 30
UseDNS no
EOF
    
    iptables -I INPUT -p tcp --dport "$SSHD_PORT" -j ACCEPT
    iptables-save > /etc/iptables/rules.v4
    
    systemctl restart sshd
    systemctl enable sshd > /dev/null 2>&1
}

install_slowdns() {
    print_message "Installing SlowDNS..." "$BLUE"
    
    TARGET_PORT="22"
    
    rm -rf /root/dnstt
    mkdir -p /root/dnstt
    cd /root/dnstt || exit 1
    
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub
    
    chmod 755 dnstt-server
    
    print_message "Public Key:" "$YELLOW"
    cat server.pub
    read -p "Copy key and press Enter"
    
    read -p "Enter Nameserver: " ns
    
    systemctl stop dnstt 2>/dev/null
    
    configure_iptables
    
    timeout 5 ./dnstt-server -udp :5300 -privkey-file server.key $ns 127.0.0.1:$TARGET_PORT &
    test_pid=$!
    sleep 2
    
    if check_port 5300; then
        kill $test_pid 2>/dev/null
        sleep 1
    else
        kill $test_pid 2>/dev/null
    fi
    
    cat > /etc/systemd/system/dnstt.service << EOF
[Unit]
Description=DNSTT Tunnel Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/dnstt
ExecStart=/root/dnstt/dnstt-server -udp :5300 -mtu 1800 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$TARGET_PORT
Restart=always
RestartSec=3
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=dnstt

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl start dnstt
    systemctl enable dnstt
    
    sleep 3
}

test_dns() {
    print_message "Testing DNS..." "$BLUE"
    
    if timeout 3 dig @127.0.0.1 -p 5300 google.com +short >/dev/null 2>&1; then
        print_message "Port 5300 working" "$GREEN"
    else
        print_message "Port 5300 failed" "$RED"
    fi
    
    if timeout 3 dig @127.0.0.1 google.com +short >/dev/null 2>&1; then
        print_message "Port 53 working" "$GREEN"
    else
        print_message "Port 53 failed" "$RED"
    fi
}

main() {
    if [ "$EUID" -ne 0 ]; then
        print_message "Run as root" "$RED"
        exit 1
    fi
    
    install_dependencies
    configure_openssh
    disable_ipv6
    disable_systemd_resolved
    install_slowdns
    test_dns
}

main
