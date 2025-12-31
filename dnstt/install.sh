echo -e "$NC"
        apt -y update && apt -y upgrade
        apt -y install iptables-persistent wget screen lsof
        rm -rf dnstt
        mkdir dnstt
        cd dnstt
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/dnstt-server
        chmod 755 dnstt-server
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.key
        wget https://raw.githubusercontent.com/ASHANTENNA/VPNScript/main/server.pub
        echo -e "$YELLOW"
        cat server.pub
        read -p "Copy the pubkey above and press Enter when done"
        read -p "Enter your Nameserver : " ns
        iptables -I INPUT -p udp --dport 5300 -j ACCEPT
        iptables -t nat -I PREROUTING -p udp --dport 53 -j REDIRECT --to-ports 5300
        iptables-save > /etc/iptables/rules.v4

        while true; do
            echo -e "$YELLOW"
            read -p "Target TCP Port : " target_port
            echo -e "$NC"
            if is_number "$target_port" && [ "$target_port" -ge 1 ] && [ "$target_port" -le 65535 ]; then
                break
            else
                echo -e "$YELLOW"
                echo "Invalid input. Please enter a valid number between 1 and 65535."
                echo -e "$NC"
            fi
        done

        echo -e "$YELLOW"
        read -p "Run in background or foreground service ? (b/f): " bind
        echo -e "$NC"
        if [ "$bind" = "b" ]; then
            screen -dmS slowdns ./dnstt-server -udp :5300 -privkey-file server.key $ns 127.0.0.1:$target_port
        else
            json_content=$(cat <<-EOF
[Unit]
Description=Daemonize DNSTT Tunnel Server
Wants=network.target
After=network.target
[Service]
ExecStart=/root/dnstt/dnstt-server -udp :5300 -privkey-file /root/dnstt/server.key $ns 127.0.0.1:$target_port
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
)
            echo "$json_content" > /etc/systemd/system/dnstt.service
            systemctl start dnstt
            systemctl enable dnstt
        fi

        lsof -i :5300
        echo -e "DNSTT installation completed"
        echo -e "$NC"
        exit 
