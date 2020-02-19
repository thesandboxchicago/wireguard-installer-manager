#!/bin/bash
# Secure WireGuard For CentOS, Debian, Ubuntu, Arch, Fedora, Redhat, Raspbian

# Function to check for root.
function root-check() {
  if [ "$EUID" -ne 0 ]; then
    echo "You need to run this script as root."
    exit
  fi
}

# Check for root
root-check

# Checking For Virtualization
function virt-check() {
  # Deny OpenVZ
  if [ "$(systemd-detect-virt)" == "openvz" ]; then
    echo "OpenVZ virtualization is not supported (yet)."
    exit
  fi
  # Deny LXC
  if [ "$(systemd-detect-virt)" == "lxc" ]; then
    echo "LXC virtualization is not supported (yet)."
    exit
  fi
}

# Virtualization Check
virt-check

# Detect Operating System
function dist-check() {
  if [ -e /etc/os-release ]; then
    # shellcheck disable=SC1091
    source /etc/os-release
    DISTRO=$ID
    # shellcheck disable=SC2034
    VERSION=$VERSION_ID
  else
    echo "Your distribution is not supported (yet)."
    exit
  fi
}

# Check Operating System
dist-check

# Headless Install
# Skips all questions and just get a client conf after install.
function headless-install() {
  if [ "$HEADLESS_INSTALL" == "y" ]; then
    # Set default choices so that no questions will be asked.
    SERVER_HOST_V4=${SERVER_HOST_V4:-y}
    SERVER_HOST_V6=${SERVER_HOST_V6:-y}
    SERVER_PUB_NIC=${SERVER_PUB_NIC:-y}
    PORT_CHOICE=${PORT_CHOICE:-1}
    NAT_CHOICE=${NAT_CHOICE:-1}
    MTU_CHOICE=${MTU_CHOICE:-1}
    SERVER_HOST=${SERVER_HOST:-1}
    DISABLE_HOST=${DISABLE_HOST:-1}
    CLIENT_ALLOWED_IP=${CLIENT_ALLOWED_IP:-1}
    INSTALL_UNBOUND=${INSTALL_UNBOUND:-y}
    CLIENT_NAME=${CLIENT_NAME:-client}
  fi
}

# No GUI
headless-install

# Wireguard Public Network Interface
WIREGUARD_PUB_NIC="wg0"
# Location For WG_CONFIG
WG_CONFIG="/etc/wireguard/$WIREGUARD_PUB_NIC.conf"
if [ ! -f "$WG_CONFIG" ]; then
  # Private Subnet Ipv4
  PRIVATE_SUBNET_V4=${PRIVATE_SUBNET_V4:-"10.8.0.0/24"}
  # Private Subnet Mask IPv4
  PRIVATE_SUBNET_MASK_V4=$(echo "$PRIVATE_SUBNET_V4" | cut -d "/" -f 2)
  # IPv4 Getaway
  GATEWAY_ADDRESS_V4="${PRIVATE_SUBNET_V4::-4}1"
  # Private Subnet Ipv6
  PRIVATE_SUBNET_V6=${PRIVATE_SUBNET_V6:-"fd42:42:42::0/64"}
  # Private Subnet Mask IPv6
  PRIVATE_SUBNET_MASK_V6=$(echo "$PRIVATE_SUBNET_V6" | cut -d "/" -f 2)
  # IPv6 Getaway
  GATEWAY_ADDRESS_V6="${PRIVATE_SUBNET_V6::-4}1"

  # Detect IPV4
  function detect-ipv4() {
    if type ping >/dev/null 2>&1; then
      PING="ping -c3 ipv4.google.com > /dev/null 2>&1"
    else
      PING6="ping -4 -c3 ipv4.google.com > /dev/null 2>&1"
    fi
    if eval "$PING"; then
      IPV4_SUGGESTION="y"
    else
      IPV4_SUGGESTION="n"
    fi
  }

  # Detect IPV4
  detect-ipv4

  # Test outward facing IPV4
  function test-connectivity-v4() {
    if [ "$SERVER_HOST_V4" == "" ]; then
      SERVER_HOST_V4="$(wget -qO- -t1 -T2 ipv4.icanhazip.com)"
        read -rp "System public IPV4 address is $SERVER_HOST_V4. Is that correct? [y/n]: " -e -i "$IPV4_SUGGESTION" CONFIRM
        if [ "$CONFIRM" == "n" ]; then
          echo "Aborted. Use environment variable SERVER_HOST_V4 to set the correct public IP address."
      fi
    fi
  }

  # Test IPV4 Connectivity
  test-connectivity-v4

  # Detect IPV6
  function detect-ipv6() {
    if type ping >/dev/null 2>&1; then
      PING6="ping6 -c3 ipv6.google.com > /dev/null 2>&1"
    else
      PING6="ping -6 -c3 ipv6.google.com > /dev/null 2>&1"
    fi
    if eval "$PING6"; then
      IPV6_SUGGESTION="y"
    else
      IPV6_SUGGESTION="n"
    fi
  }

  # Test IPV6 Connectivity
  detect-ipv6

  # Test outward facing IPV6
  function test-connectivity-v6() {
    if [ "$SERVER_HOST_V6" == "" ]; then
      SERVER_HOST_V6="$(wget -qO- -t1 -T2 ipv6.icanhazip.com)"
        read -rp "System public IPV6 address is $SERVER_HOST_V6. Is that correct? [y/n]: " -e -i "$IPV6_SUGGESTION" CONFIRM
        if [ "$CONFIRM" == "n" ]; then
          echo "Aborted. Use environment variable SERVER_HOST_V6 to set the correct public IP address."
      fi
    fi
  }

  # Test IPV6 Connectivity
  test-connectivity-v6

  # Detect public interface and pre-fill for the user
  function server-pub-nic() {
    if [ "$SERVER_PUB_NIC" == "" ]; then
      SERVER_PUB_NIC="$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)"
        read -rp "System public nic address is $SERVER_PUB_NIC. Is that correct? [y/n]: " -e -i y CONFIRM
        if [ "$CONFIRM" == "n" ]; then
          echo "Aborted. Use environment variable SERVER_PUB_NIC to set the correct public nic address."
        fi
      fi
  }

  # Run The Function
  server-pub-nic

  # Determine host port
  function set-port() {
    echo "What port do you want WireGuard server to listen to?"
    echo "   1) 51820 (Recommended)"
    echo "   2) Custom (Advanced)"
    echo "   3) Random [1024-65535]"
    until [[ "$PORT_CHOICE" =~ ^[1-3]$ ]]; do
      read -rp "Port choice [1-3]: " -e -i 1 PORT_CHOICE
    done
    # Apply port response
    case $PORT_CHOICE in
    1)
      SERVER_PORT="51820"
      ;;
    2)
      until [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] && [ "$SERVER_PORT" -ge 1 ] && [ "$SERVER_PORT" -le 65535 ]; do
        read -rp "Custom port [1-65535]: " -e -i 51820 SERVER_PORT
      done
      ;;
    3)
      SERVER_PORT=$(shuf -i1024-65535 -n1)
      echo "Random Port: $SERVER_PORT"
      ;;
    esac
  }

  # Set Port
  set-port

  # Determine Keepalive interval.
  function nat-keepalive() {
    echo "What do you want your keepalive interval to be?"
    echo "   1) 25 (Default)"
    echo "   2) 0"
    echo "   3) Custom (Advanced)"
    until [[ "$NAT_CHOICE" =~ ^[1-3]$ ]]; do
      read -rp "Nat Choice [1-3]: " -e -i 1 NAT_CHOICE
    done
    # Nat Choices
    case $NAT_CHOICE in
    1)
      NAT_CHOICE="25"
      ;;
    2)
      NAT_CHOICE="0"
      ;;
    3)
      until [[ "$NAT_CHOICE " =~ ^[0-9]+$ ]] && [ "$NAT_CHOICE " -ge 1 ] && [ "$NAT_CHOICE " -le 25 ]; do
        read -rp "Custom NAT [0-25]: " -e -i 25 NAT_CHOICE
      done
      ;;
    esac
  }

  # Keepalive
  nat-keepalive

  # Custom MTU or default settings
  function mtu-set() {
    echo "What MTU do you want to use?"
    echo "   1) 1280 (Recommended)"
    echo "   2) 1420"
    echo "   3) Custom (Advanced)"
    until [[ "$MTU_CHOICE" =~ ^[1-3]$ ]]; do
      read -rp "MTU choice [1-3]: " -e -i 1 MTU_CHOICE
    done
    case $MTU_CHOICE in
    1)
      MTU_CHOICE="1280"
      ;;
    2)
      MTU_CHOICE="1420"
      ;;
    3)
      until [[ "$MTU_CHOICE" =~ ^[0-9]+$ ]] && [ "$MTU_CHOICE" -ge 1 ] && [ "$MTU_CHOICE" -le 1500 ]; do
        read -rp "Custom MTU [1-1500]: " -e -i 1500 MTU_CHOICE
      done
      ;;
    esac
  }

  # Set MTU
  mtu-set

  # What ip version would you like to be available on this VPN?
  function ipvx-select() {
    echo "What IPv do you want to use to connect to WireGuard server?"
    echo "   1) IPv4 (Recommended)"
    echo "   2) IPv6 (Advanced)"
    until [[ "$SERVER_HOST" =~ ^[1-2]$ ]]; do
      read -rp "IP Choice [1-2]: " -e -i 1 SERVER_HOST
    done
    case $SERVER_HOST in
    1)
      SERVER_HOST="$SERVER_HOST_V4"
      ;;
    2)
      SERVER_HOST="[$SERVER_HOST_V6]"
      ;;
    esac
  }

  # IPv4 or IPv6 Selector
  ipvx-select

  # Do you want to disable IPv4 or IPv6 or leave them both enabled?
  function disable-ipvx() {
    echo "Do you want to disable IPv4 or IPv6 on the server?"
    echo "   1) No (Recommended)"
    echo "   2) IPV4"
    echo "   3) IPV6"
    until [[ "$DISABLE_HOST" =~ ^[1-3]$ ]]; do
      read -rp "Disable Host Choice [1-3]: " -e -i 1 DISABLE_HOST
    done
    case $DISABLE_HOST in
    1)
      DISABLE_HOST="$(
        echo "net.ipv4.ip_forward=1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv6.conf.all.forwarding=1" >>/etc/sysctl.d/wireguard.conf
        sysctl --system
      )"
      ;;
    2)
      DISABLE_HOST="$(
        echo "net.ipv4.conf.all.disable_ipv4=1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv4.conf.default.disable_ipv4=1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv6.conf.all.forwarding=1" >>/etc/sysctl.d/wireguard.conf
        sysctl --system
      )"
      ;;
    3)
      DISABLE_HOST="$(
        echo "net.ipv6.conf.all.disable_ipv6 = 1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv6.conf.default.disable_ipv6 = 1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv6.conf.lo.disable_ipv6 = 1" >>/etc/sysctl.d/wireguard.conf
        echo "net.ipv4.ip_forward=1" >>/etc/sysctl.d/wireguard.conf
        sysctl --system
      )"
      ;;
    esac
  }

  # Disable Ipv4 or Ipv6
  disable-ipvx

  # Would you like to allow connections to your LAN neighbors?
  function client-allowed-ip() {
    echo "What traffic do you want the client to forward to wireguard?"
    echo "   1) Everything (Recommended)"
    echo "   2) Exclude Private IPs (Allows LAN IP connections)"
    until [[ "$CLIENT_ALLOWED_IP" =~ ^[1-2]$ ]]; do
      read -rp "Client Allowed IP Choice [1-2]: " -e -i 1 CLIENT_ALLOWED_IP
    done
    case $CLIENT_ALLOWED_IP in
    1)
      CLIENT_ALLOWED_IP="0.0.0.0/0,::/0"
      ;;
    2)
      CLIENT_ALLOWED_IP="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, ::/0, 176.103.130.130/32, 176.103.130.131/32"
      ;;
    esac
  }

  # Traffic Forwarding
  client-allowed-ip

  # Would you like to install Unbound.
  function ask-install-dns() {
  if [ "$DNS_CHOICE" == "" ]; then
      echo "Which DNS do you want to use with the VPN?"
      echo "   1) AdGuard (Recommended)"
      echo "   2) Google"
      echo "   3) OpenDNS"
      echo "   4) Cloudflare"
      echo "   5) Verisign"
      echo "   6) Quad9"
      echo "   7) FDN"
      echo "   8) DNS.WATCH"
      echo "   9) Yandex Basic"
      echo "   10) Clean Browsing"
      read -rp "DNS [1-10]: " -e -i 1 DNS_CHOICE
      case $DNS_CHOICE in
      1)
        CLIENT_DNS="176.103.130.130,176.103.130.131,2a00:5a60::ad1:0ff,2a00:5a60::ad2:0ff"
        ;;
      2)
        CLIENT_DNS="8.8.8.8,8.8.4.4,2001:4860:4860::8888,2001:4860:4860::8844"
        ;;
      3)
        CLIENT_DNS="208.67.222.222,208.67.220.220,2620:119:35::35,2620:119:53::53"
        ;;
      4)
        CLIENT_DNS="1.1.1.1,1.0.0.1,2606:4700:4700::1111,2606:4700:4700::1001"
        ;;
      5)
        CLIENT_DNS="64.6.64.6,64.6.65.6,2620:74:1b::1:1,2620:74:1c::2:2"
        ;;
      6)
        CLIENT_DNS="9.9.9.9,149.112.112.112,2620:fe::fe,2620:fe::9"
        ;;
      7)
        CLIENT_DNS="80.67.169.40,80.67.169.12,2001:910:800::40,2001:910:800::12"
        ;;
      8)
        CLIENT_DNS="84.200.69.80,84.200.70.40,2001:1608:10:25::1c04:b12f,2001:1608:10:25::9249:d69b"
        ;;
      9)
        CLIENT_DNS="77.88.8.8,77.88.8.1,2a02:6b8::feed:0ff,2a02:6b8:0:1::feed:0ff"
        ;;
      10)
        CLIENT_DNS="185.228.168.9,185.228.169.9,2a0d:2a00:1::2,2a0d:2a00:2::2"
        ;;
      esac
    fi
  }

  # Ask To Install DNS
  ask-install-dns

  # What would you like to name your first WireGuard peer?
function client-name() {
  if [ "$CLIENT_NAME" == "" ]; then
    echo "Lets name the WireGuard Peer, Only use words no special characters"
    # shellcheck disable=SC2162
    read -p "Client name: " -e CLIENT_NAME
  fi
}

  # Client Name
  client-name

  # Install WireGuard Server
function install-wireguard-server() {
  # Installation begins here.
  if [ "$DISTRO" == "ubuntu" ]; then
    apt-get install libelf-dev linux-headers-$(uname -r) build-essential pkg-config qrencode iptables git -y
  fi
  if [ "$DISTRO" == "debian" ]; then
    apt-get install libelf-dev linux-headers-$(uname -r) build-essential pkg-config qrencode iptables git -y
  fi
  if [ "$DISTRO" == "raspbian" ]; then
    apt-get install libelf-dev linux-headers-$(uname -r) build-essential pkg-config qrencode iptables git -y
  fi
  if [ "$DISTRO" == "arch" ]; then
    pacman -Syu
    pacman -Syu --noconfirm haveged qrencode iptables git
    pacman -Syu --noconfirm linux-headers base-devel pkg-config
  fi
  if [ "$DISTRO" = 'fedora' ]; then
    dnf update -y
    dnf install elfutils-libelf-devel kernel-devel pkg-config @development-tools qrencode git -y
  fi
  if [ "$DISTRO" == "centos" ]; then
    yum update -y
    yum install elfutils-libelf-devel kernel-devel pkgconfig "@Development Tools" qrencode git -y
  fi
  if [ "$DISTRO" == "redhat" ]; then
    yum update -y
    yum install elfutils-libelf-devel kernel-devel pkgconfig "@Development Tools" git -y
  fi
  }

  # Install WireGuard Server
  install-wireguard-server

  function wireguard-complier(){
      cd /tmp/
      mkdir wireguard-complier
      cd wireguard-complier
      git clone https://git.zx2c4.com/wireguard-linux-compat
      git clone https://git.zx2c4.com/wireguard-tools
      make -C wireguard-linux-compat/src -j$(nproc)
      make -C wireguard-linux-compat/src install
      make -C wireguard-tools/src -j$(nproc)
      make -C wireguard-tools/src install
  }
  
  # WireGuard Set Config
  function wireguard-setconf() {
    SERVER_PRIVKEY=$(wg genkey)
    SERVER_PUBKEY=$(echo "$SERVER_PRIVKEY" | wg pubkey)
    CLIENT_PRIVKEY=$(wg genkey)
    CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
    CLIENT_ADDRESS_V4="${PRIVATE_SUBNET_V4::-4}3"
    CLIENT_ADDRESS_V6="${PRIVATE_SUBNET_V6::-4}3"
    PRESHARED_KEY=$(wg genpsk)
    mkdir -p /etc/wireguard
    mkdir -p /etc/wireguard/clients
    touch $WG_CONFIG && chmod 600 $WG_CONFIG
    # Set Wireguard settings for this host and first peer.

    echo "# $PRIVATE_SUBNET_V4 $PRIVATE_SUBNET_V6 $SERVER_HOST:$SERVER_PORT $SERVER_PUBKEY $CLIENT_DNS $MTU_CHOICE $NAT_CHOICE $CLIENT_ALLOWED_IP
[Interface]
Address = $GATEWAY_ADDRESS_V4/$PRIVATE_SUBNET_MASK_V4,$GATEWAY_ADDRESS_V6/$PRIVATE_SUBNET_MASK_V6
ListenPort = $SERVER_PORT
PrivateKey = $SERVER_PRIVKEY
PostUp = iptables -A FORWARD -i $WIREGUARD_PUB_NIC -j ACCEPT; iptables -t nat -A POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE; ip6tables -A FORWARD -i $WIREGUARD_PUB_NIC -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE; iptables -A INPUT -s $PRIVATE_SUBNET_V4 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
PostDown = iptables -D FORWARD -i $WIREGUARD_PUB_NIC -j ACCEPT; iptables -t nat -D POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE; ip6tables -D FORWARD -i $WIREGUARD_PUB_NIC -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $SERVER_PUB_NIC -j MASQUERADE; iptables -D INPUT -s $PRIVATE_SUBNET_V4 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
SaveConfig = false
# $CLIENT_NAME start
[Peer]
PublicKey = $CLIENT_PUBKEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = $CLIENT_ADDRESS_V4/32,$CLIENT_ADDRESS_V6/128
# $CLIENT_NAME end" >$WG_CONFIG
    # shellcheck disable=SC2140
    echo "# $CLIENT_NAME
[Interface]
Address = $CLIENT_ADDRESS_V4/$PRIVATE_SUBNET_MASK_V4,$CLIENT_ADDRESS_V6/$PRIVATE_SUBNET_MASK_V6
DNS = $CLIENT_DNS
MTU = $MTU_CHOICE
PrivateKey = $CLIENT_PRIVKEY
[Peer]
AllowedIPs = $CLIENT_ALLOWED_IP
Endpoint = $SERVER_HOST:$SERVER_PORT
PersistentKeepalive = $NAT_CHOICE
PresharedKey = $PRESHARED_KEY
PublicKey = $SERVER_PUBKEY" >"/etc/wireguard/clients"/"$CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf
    # Generate QR Code
    # shellcheck disable=SC2140
    qrencode -t ansiutf8 -l L <"/etc/wireguard/clients"/"$CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf
    # Echo the file
    # shellcheck disable=SC2140,SC2027,SC2086
    echo "Client Config --> "/etc/wireguard/clients"/"$CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf"
    # Restart WireGuard
    if pgrep systemd-journal; then
      systemctl enable wg-quick@$WIREGUARD_PUB_NIC
      systemctl restart wg-quick@$WIREGUARD_PUB_NIC
    else
      service wg-quick@$WIREGUARD_PUB_NIC enable
      service wg-quick@$WIREGUARD_PUB_NIC restart
    fi
  }

  # Setting Up Wireguard Config
  wireguard-setconf

# After WireGuard Install
else

  # Already installed what next?
  function wireguard-next-questions() {
    echo "Looks like Wireguard is already installed."
    echo "What do you want to do?"
    echo "   1) Show WireGuard Interface"
    echo "   2) Start WireGuard Interface"
    echo "   3) Stop WireGuard Interface"
    echo "   4) Add WireGuard Peer"
    echo "   5) Remove WireGuard Peer"
    echo "   6) Uninstall WireGuard Interface"
    echo "   7) Update this script"
    echo "   8) Exit"
    until [[ "$WIREGUARD_OPTIONS" =~ ^[1-8]$ ]]; do
      read -rp "Select an Option [1-8]: " -e -i 1 WIREGUARD_OPTIONS
    done
    case $WIREGUARD_OPTIONS in
    1)
      if pgrep systemd-journal; then
        wg show
      else
        sudo wg show
      fi
      ;;
    2)
      if pgrep systemd-journal; then
        systemctl start wg-quick@$WIREGUARD_PUB_NIC
      else
        service wg-quick@$WIREGUARD_PUB_NIC start
      fi
      ;;
    3)
      if pgrep systemd-journal; then
        systemctl stop wg-quick@$WIREGUARD_PUB_NIC
      else
        service wg-quick@$WIREGUARD_PUB_NIC stop
      fi
      ;;
    4)
      echo "Tell me a new name for the client config file. Use one word only, no special characters. (No Spaces)"
      read -rp "New client name: " -e NEW_CLIENT_NAME
      CLIENT_PRIVKEY=$(wg genkey)
      CLIENT_PUBKEY=$(echo "$CLIENT_PRIVKEY" | wg pubkey)
      PRESHARED_KEY=$(wg genpsk)
      PRIVATE_SUBNET_V4=$(head -n1 $WG_CONFIG | awk '{print $2}')
      PRIVATE_SUBNET_MASK_V4=$(echo "$PRIVATE_SUBNET_V4" | cut -d "/" -f 2)
      PRIVATE_SUBNET_V6=$(head -n1 $WG_CONFIG | awk '{print $3}')
      PRIVATE_SUBNET_MASK_V6=$(echo "$PRIVATE_SUBNET_V6" | cut -d "/" -f 2)
      SERVER_HOST=$(head -n1 $WG_CONFIG | awk '{print $4}')
      SERVER_PUBKEY=$(head -n1 $WG_CONFIG | awk '{print $5}')
      CLIENT_DNS=$(head -n1 $WG_CONFIG | awk '{print $6}')
      MTU_CHOICE=$(head -n1 $WG_CONFIG | awk '{print $7}')
      NAT_CHOICE=$(head -n1 $WG_CONFIG | awk '{print $8}')
      CLIENT_ALLOWED_IP=$(head -n1 $WG_CONFIG | awk '{print $9}')
      LASTIP4=$(grep "/32" $WG_CONFIG | tail -n1 | awk '{print $3}' | cut -d "/" -f 1 | cut -d "." -f 4)
      LASTIP6=$(grep "/128" $WG_CONFIG | tail -n1 | awk '{print $3}' | cut -d "/" -f 1 | cut -d "." -f 4)
      CLIENT_ADDRESS_V4="${PRIVATE_SUBNET_V4::-4}$((LASTIP4 + 1))"
      CLIENT_ADDRESS_V6="${PRIVATE_SUBNET_V6::-4}$((LASTIP6 + 1))"
      echo "# $NEW_CLIENT_NAME start
[Peer]
PublicKey = $CLIENT_PUBKEY
PresharedKey = $PRESHARED_KEY
AllowedIPs = $CLIENT_ADDRESS_V4/32,$CLIENT_ADDRESS_V6/128
# $NEW_CLIENT_NAME end" >>$WG_CONFIG
      # shellcheck disable=SC2140
      echo "# $NEW_CLIENT_NAME
[Interface]
Address = $CLIENT_ADDRESS_V4/$PRIVATE_SUBNET_MASK_V4,$CLIENT_ADDRESS_V6/$PRIVATE_SUBNET_MASK_V6
DNS = $CLIENT_DNS
MTU = $MTU_CHOICE
PrivateKey = $CLIENT_PRIVKEY
[Peer]
AllowedIPs = $CLIENT_ALLOWED_IP
Endpoint = $SERVER_HOST$SERVER_PORT
PersistentKeepalive = $NAT_CHOICE
PresharedKey = $PRESHARED_KEY
PublicKey = $SERVER_PUBKEY" >"/etc/wireguard/clients"/"$NEW_CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf
      # shellcheck disable=SC2140
      qrencode -t ansiutf8 -l L <"/etc/wireguard/clients"/"$NEW_CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf
      # shellcheck disable=SC2140,SC2027,SC2086
      echo "Client config --> "/etc/wireguard/clients"/"$NEW_CLIENT_NAME"-$WIREGUARD_PUB_NIC.conf"
      # Restart WireGuard
      if pgrep systemd-journal; then
        systemctl restart wg-quick@$WIREGUARD_PUB_NIC
      else
        service wg-quick@$WIREGUARD_PUB_NIC restart
      fi
      ;;
    5)
      # Remove User
      echo "Which WireGuard User Do You Want To Remove?"
      # shellcheck disable=SC2002
      cat $WG_CONFIG | grep start | awk '{ print $2 }'
      read -rp "Type in Client Name : " -e REMOVECLIENT
      read -rp "Are you sure you want to remove $REMOVECLIENT ? (y/n): " -n 1 -r
      if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo
        # shellcheck disable=SC1117
        sed -i "/\# $REMOVECLIENT start/,/\# $REMOVECLIENT end/d" $WG_CONFIG
        # shellcheck disable=SC2086
        rm /etc/wireguard/clients/$REMOVECLIENT-$WIREGUARD_PUB_NIC.conf
      fi
      if pgrep systemd-journal; then
        systemctl restart wg-quick@$WIREGUARD_PUB_NIC
      else
        service wg-quick@$WIREGUARD_PUB_NIC restart
      fi
      echo "Client named $REMOVECLIENT has been removed."
      ;;
    6)
      # Uninstall Wireguard and purging files
      # shellcheck disable=SC2034
      read -rp "Do you really want to remove Wireguard? [y/n]:" -e -i n REMOVE_WIREGUARD
    if [ "$REMOVE_WIREGUARD" = "y" ]; then
      # Stop WireGuard
      wg-quick down $WIREGUARD_PUB_NIC
      if [ "$DISTRO" == "centos" ]; then
        yum remove wireguard qrencode haveged unbound unbound-host -y
      elif [ "$DISTRO" == "debian" ]; then
        apt-get remove --purge wireguard qrencode haveged unbound unbound-host -y
        sed -i 's|deb http://deb.debian.org/debian/ unstable main||' /etc/apt/sources.list.d/unstable.list
      elif [ "$DISTRO" == "ubuntu" ]; then
        apt-get remove --purge wireguard qrencode haveged unbound unbound-host -y
      elif [ "$DISTRO" == "raspbian" ]; then
        apt-key del 04EE7237B7D453EC
        apt-get remove --purge wireguard qrencode haveged unbound unbound-host dirmngr -y
        sed -i 's|deb http://deb.debian.org/debian/ unstable main||' /etc/apt/sources.list.d/unstable.list
      elif [ "$DISTRO" == "arch" ]; then
        pacman -Rs wireguard qrencode haveged unbound unbound-host -y
      elif [ "$DISTRO" == "fedora" ]; then
        dnf remove wireguard qrencode haveged unbound unbound-host -y
        rm /etc/yum.repos.d/wireguard.repo
      elif [ "$DISTRO" == "redhat" ]; then
        yum remove wireguard qrencode haveged unbound unbound-host -y
        rm /etc/yum.repos.d/wireguard.repo
      fi
      # Removing Wireguard Files
      rm -rf /etc/wireguard
      # Removing Wireguard User Config Files
      rm -rf /etc/wireguard/clients
      # Removing system wireguard config
      rm -f /etc/sysctl.d/wireguard.conf
      # Removing wireguard config
      rm -f /etc/wireguard/$WIREGUARD_PUB_NIC.conf
      # Removing Unbound Files
      rm -rf /etc/unbound
      # Removing Unbound Config
      rm -f /etc/unbound/unbound.conf
      # Removing Haveged Config
      rm -f /etc/default/haveged
      # Remove localhost as the resolver
      sed -i "s|nameserver 127.0.0.1||" /etc/resolv.conf
      # Going back to the old nameservers
      sed -i "s|#nameserver|nameserver|" /etc/resolv.conf
      sed -i "s|#search|search|" /etc/resolv.conf
    fi
      ;;
    7) ## Update the script
    wget -O /etc/wireguard/wireguard-server.sh https://raw.githubusercontent.com/complexorganizations/wireguard-install/master/wireguard-server.sh
    sleep 3
    chmod +x /etc/wireguard/wireguard-server.sh
    bash /etc/wireguard/wireguard-server.sh
      ;;
    8)
      exit
      ;;
    esac
  }

  # Running Questions Command
  wireguard-next-questions
fi
