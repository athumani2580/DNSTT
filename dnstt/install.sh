#!/bin/bash

# Color definitions
YELLOW='\033[1;33m'
RED='\033[1;31m'
CYAN='\033[1;36m'
GREEN='\033[1;32m'
NC='\033[0m'

# Check if running as root
if [ "$(whoami)" != "root" ]; then
    echo -e "${RED}Error: This script must be run as root.${NC}"
    exit 1
fi

# Function to check if input is a number
is_number() {
    [[ $1 =~ ^[0-9]+$ ]]
}

# Function to configure iptables rules
configure_iptables() {
    echo -e "${YELLOW}Configuring firewall rules...${NC}"
    
    # Flush existing rules to start fresh
    iptables -F
    iptables -t nat -F
    
    # Allow all loopback (lo) traffic
    iptables -A INPUT -i lo -j ACCEPT
    iptables -A OUTPUT -o lo -j ACCEPT
    
    # Allow established connections
    iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
    
    # Allow SSH (optional, if you need SSH access)
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    
    # Allow ICMP (ping)
    iptables -A INPUT -p icmp -j ACCEPT
    
    # ALLOW ALL DNS TRAFFIC ON PORT 53 (TCP & UDP)
    echo -e "${GREEN}Allowing DNS port 53...${NC}"
    
    # UDP 53 from all sources to all destinations
    iptables -A INPUT -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
    iptables -A FORWARD -p udp --dport 53 -j ACCEPT
    
    # TCP 53 from all sources to all destinations
    iptables -A INPUT -p tcp --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
    iptables -A FORWARD -p tcp --dport 53 -j ACCEPT
    
    # ALLOW ALL SLOWDNS TRAFFIC ON PORT 5300 (TCP & UDP)
    echo -e "${GREEN}Allowing SlowDNS port 5300...${NC}"
    
    # UDP 5300 from all sources to all destinations
    iptables -A INPUT -p udp --dport 5300 -j ACCEPT
    iptables -A OUTPUT -p udp --dport 5300 -j ACCEPT
    iptables -A FORWARD -p udp --dport 5300 -j ACCEPT
    
    # TCP 5300 from all sources to all destinations
    iptables -A INPUT -p tcp --dport 5300 -j ACCEPT
    iptables -A OUTPUT -p tcp --dport 5300 -j ACCEPT
    iptables -A FORWARD -p tcp --dport 5300 -j ACCEPT
    
    # Specific rules for 127.0.0.1 (localhost)
    echo -e "${GREEN}Allowing localhost traffic...${NC}"
    
    # Localhost to port 53
    iptables -A INPUT -s 127.0.0.1 -p udp --dport 53 -j ACCEPT
    iptables -A INPUT -s 127.0.0.1 -p tcp --dport 53 -j ACCEPT
    
    # Localhost to port 5300
    iptables -A INPUT -s 127.0.0.1 -p udp --dport 5300 -j ACCEPT
    iptables -A INPUT -s 127.0.0.1 -p tcp --dport 5300 -j ACCEPT
    
    # NAT REDIRECT: Redirect incoming DNS (port 53) to SlowDNS (port 5300)
    echo -e "${GREEN}Setting up NAT redirect: 53 → 5300${NC}"
    iptables -t nat -A PREROUTING -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -A PREROUTING -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # NAT REDIRECT: Redirect localhost DNS to SlowDNS (optional)
    iptables -t nat -A OUTPUT -p udp --dport 53 -j REDIRECT --to-port 5300
    iptables -t nat -A OUTPUT -p tcp --dport 53 -j REDIRECT --to-port 5300
    
    # Allow all outgoing connections
    iptables -A OUTPUT -j ACCEPT
    
    # Default policies
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    
    # Save rules
    iptables-save > /etc/iptables/rules.v4
    
    echo -e "${GREEN}Firewall rules configured successfully!${NC}"
    echo ""
    echo -e "${YELLOW}Rules Summary:${NC}"
    echo "1. Port 53 (DNS) - ALLOW ALL (TCP/UDP)"
    echo "2. Port 5300 (SlowDNS) - ALLOW ALL (TCP/UDP)"
    echo "3. Localhost (127.0.0.1) - ALLOW ALL"
    echo "4. NAT Redirect: Port 53 → Port 5300"
    echo "5. Default: INPUT/FORWARD DROP, OUTPUT ACCEPT"
    echo ""
}

# Token-based installer function
install_with_token() {
    clear
    echo -e "${YELLOW}"
    echo "🔐 DNS Installer - Token Required"
    echo -e "${NC}"
    echo ""
    read -p "Enter GitHub token: " token
    
    if [ -z "$token" ]; then
        echo -e "${RED}Token cannot be empty!${NC}"
        sleep 2
        return
    fi
    
    echo -e "${YELLOW}Installing with token...${NC}"
    
    # Download and run the external script with token authentication
    bash <(curl -s -H "Authorization: token $token" "https://raw.githubusercontent.com/athumani2580/DNS/main/slowdns/con.sh")
    
    echo ""
    echo -e "${YELLOW}Press Enter to return to main menu...${NC}"
    read
}

# Main installation function
install_slowdns() {
    echo -e "${YELLOW}Installing DNSTT (SlowDNS)...${NC}"
    
    # Update system
    apt -y update && apt -y upgrade
    apt -y install iptables-persistent wget screen lsof
    
    # Create directory for DNSTT
    rm -rf /root/dnstt
    mkdir /root/dnstt
    cd /root/dnstt
    
    # Download DNSTT server binary
    echo -e "${YELLOW}Downloading DNSTT server...${NC}"
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/dnstt-server
    chmod 755 dnstt-server
    
    # Download server keys
    echo -e "${YELLOW}Downloading server keys...${NC}"
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.key
    wget -q https://raw.githubusercontent.com/athumani2580/DNSTT/main/server.pub
    
    # Display public key
    echo -e "${GREEN}Public Key:${NC}"
    cat server.pub
    echo ""
    
    # Get nameserver from user
    while true; do
        echo -e "${YELLOW}"
        read -p "Enter your Nameserver (e.g., ns.example.com): " ns
        echo -e "${NC}"
        if [ ! -z "$ns" ]; then
            break
        fi
    done
    
    # Get target port
    while true; do
        echo -e "${YELLOW}"
        read -p "Target TCP Port (where traffic will be forwarded): " target_port
        echo -e "${NC}"
        if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
            break
        else
            echo -e "${YELLOW}Invalid input. Please enter a valid number between 1 and 65535.${NC}"
        fi
    done
    
    # Configure comprehensive iptables rules
    configure_iptables
    
    # Ask for service type
    echo -e "${YELLOW}"
    read -p "Run as system service or in screen session? (s/c): " service_type
    echo -e "${NC}"
    
    if [ "$service_type" = "c" ] || [ "$service_type" = "C" ]; then
        # Run in screen session
        echo -e "${YELLOW}Starting DNSTT in screen session...${NC}"
        screen -dmS slowdns ./dnstt-server -udp :5300 -privkey-file server.key "$ns" 127.0.0.1:"$target_port"
        echo -e "${GREEN}DNSTT started in screen session 'slowdns'${NC}"
    else
        # Create systemd service
        echo -e "${YELLOW}Creating systemd service...${NC}"
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
        
        echo -e "${GREEN}DNSTT service created and started${NC}"
    fi
    
    # Show status
    echo ""
    echo -e "${GREEN}=== Installation Complete ===${NC}"
    echo ""
    echo -e "${YELLOW}Service Status:${NC}"
    if [ "$service_type" = "c" ] || [ "$service_type" = "C" ]; then
        screen -ls | grep slowdns
    else
        systemctl status dnstt --no-pager -l
    fi
    
    echo ""
    echo -e "${YELLOW}Listening Ports:${NC}"
    lsof -i :5300
    
    echo ""
    echo -e "${GREEN}Configuration Summary:${NC}"
    echo "Nameserver: $ns"
    echo "Public Key: $(cat server.pub)"
    echo "Target Port: $target_port"
    echo "DNS Port: 53 → 5300 (Redirected)"
    echo "SlowDNS Port: 5300"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "1. Make sure to use the public key above in your client configuration"
    echo "2. DNS queries on port 53 are redirected to port 5300"
    echo "3. Ports 53 and 5300 are fully open for all traffic"
    echo "4. Check if service is running with: systemctl status dnstt"
    echo ""
}

# Function to show firewall status
show_firewall_status() {
    echo -e "${YELLOW}=== Firewall Rules Status ===${NC}"
    echo ""
    echo -e "${CYAN}INPUT Chain Rules:${NC}"
    iptables -L INPUT -n --line-numbers
    echo ""
    echo -e "${CYAN}OUTPUT Chain Rules:${NC}"
    iptables -L OUTPUT -n --line-numbers
    echo ""
    echo -e "${CYAN}FORWARD Chain Rules:${NC}"
    iptables -L FORWARD -n --line-numbers
    echo ""
    echo -e "${CYAN}NAT PREROUTING Rules:${NC}"
    iptables -t nat -L PREROUTING -n --line-numbers
    echo ""
    echo -e "${CYAN}Listening Ports:${NC}"
    netstat -tulpn | grep -E ':53|:5300'
    echo ""
    echo -e "${YELLOW}Press Enter to continue...${NC}"
    read
}

# Management function
manage_slowdns() {
    while true; do
        clear
        echo -e "${CYAN}=== SlowDNS Management ===${NC}"
        echo ""
        echo "1. Start DNSTT service"
        echo "2. Stop DNSTT service"
        echo "3. Restart DNSTT service"
        echo "4. Check service status"
        echo "5. View logs"
        echo "6. Kill screen session (if running in screen)"
        echo "7. Show public key"
        echo "8. Show firewall status"
        echo "9. Reset firewall rules"
        echo "10. Back to main menu"
        echo ""
        
        read -p "Select option [1-10]: " choice
        
        case $choice in
            1)
                systemctl start dnstt
                echo -e "${GREEN}DNSTT service started${NC}"
                sleep 2
                ;;
            2)
                systemctl stop dnstt
                echo -e "${YELLOW}DNSTT service stopped${NC}"
                sleep 2
                ;;
            3)
                systemctl restart dnstt
                echo -e "${GREEN}DNSTT service restarted${NC}"
                sleep 2
                ;;
            4)
                echo -e "${YELLOW}Service Status:${NC}"
                systemctl status dnstt --no-pager -l
                echo ""
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            5)
                echo -e "${YELLOW}Service Logs:${NC}"
                journalctl -u dnstt -n 20 --no-pager
                echo ""
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            6)
                screen -X -S slowdns quit
                echo -e "${YELLOW}Screen session 'slowdns' killed${NC}"
                sleep 2
                ;;
            7)
                echo -e "${GREEN}Public Key:${NC}"
                cat /root/dnstt/server.pub 2>/dev/null || echo "Public key not found"
                echo ""
                echo -e "${YELLOW}Press Enter to continue...${NC}"
                read
                ;;
            8)
                show_firewall_status
                ;;
            9)
                echo -e "${YELLOW}Resetting firewall rules...${NC}"
                configure_iptables
                sleep 2
                ;;
            10)
                break
                ;;
            *)
                echo -e "${RED}Invalid option${NC}"
                sleep 1
                ;;
        esac
    done
}

# Main menu
while true; do
    clear
    echo -e "${YELLOW}SlowDNS (DNSTT) Installer${NC}"
    echo "Version: 2.1"
    echo ""
    echo "1. Install SlowDNS (DNSTT) - Standard"
    echo "2. Install SlowDNS with Token"
    echo "3. Manage SlowDNS Service"
    echo "4. Configure Firewall Only"
    echo "5. Uninstall SlowDNS"
    echo "6. Exit"
    echo ""
    
    read -p "Select option [1-6]: " main_choice
    
    case $main_choice in
        1)
            install_slowdns
            echo ""
            echo -e "${YELLOW}Press Enter to return to main menu...${NC}"
            read
            ;;
        2)
            install_with_token
            ;;
        3)
            manage_slowdns
            ;;
        4)
            configure_iptables
            echo ""
            echo -e "${YELLOW}Press Enter to return to main menu...${NC}"
            read
            ;;
        5)
            echo -e "${YELLOW}Uninstalling SlowDNS...${NC}"
            systemctl stop dnstt 2>/dev/null
            systemctl disable dnstt 2>/dev/null
            rm -f /etc/systemd/system/dnstt.service
            screen -X -S slowdns quit 2>/dev/null
            rm -rf /root/dnstt
            systemctl daemon-reload
            echo -e "${GREEN}SlowDNS uninstalled successfully${NC}"
            sleep 2
            ;;
        6)
            echo -e "${YELLOW}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            ;;
    esac
done
