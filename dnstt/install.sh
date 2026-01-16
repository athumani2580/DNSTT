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
    
    # Configure iptables
    echo -e "${YELLOW}Configuring firewall rules...${NC}"
    iptables -I INPUT -p udp --dport 5300 -j ACCEPT
    iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
    iptables-save > /etc/iptables/rules.v4
    
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
Description=DNSTT SlowDNS Tunnel Server
Wants=network.target
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=/root/dnstt
ExecStart=/root/dnstt/dnstt-server -udp :5300 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$target_port
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
    echo "DNS Port: 5300 (UDP)"
    echo ""
    echo -e "${YELLOW}Important:${NC}"
    echo "1. Make sure to use the public key above in your client configuration"
    echo "2. DNS queries on port 53 are redirected to port 5300"
    echo "3. Check if service is running with: systemctl status dnstt"
    echo ""
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
        echo "8. Back to main menu"
        echo ""
        
        read -p "Select option [1-8]: " choice
        
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
    echo "Version: 1.0"
    echo ""
    echo "1. Install SlowDNS (DNSTT)"
    echo "2. Manage SlowDNS Service"
    echo "3. Uninstall SlowDNS"
    echo "4. Exit"
    echo ""
    
    read -p "Select option [1-4]: " main_choice
    
    case $main_choice in
        1)
            install_slowdns
            echo ""
            echo -e "${YELLOW}Press Enter to return to main menu...${NC}"
            read
            ;;
        2)
            manage_slowdns
            ;;
        3)
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
        4)
            echo -e "${YELLOW}Goodbye!${NC}"
            exit 0
            ;;
        *)
            echo -e "${RED}Invalid option${NC}"
            sleep 1
            ;;
    esac
done
