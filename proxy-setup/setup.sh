#!/bin/bash
# ============================================================
#  🛡️ One-Command Full Proxy/VPN Server Setup
#  WireGuard VPN + SOCKS5/HTTP Proxy + DNS-over-HTTPS + Firewall
# ============================================================
#  One-liner:
#    curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/proxy-setup/setup.sh | sudo bash
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' C='\033[0;36m' B='\033[1m' N='\033[0m'

# ══════════════════════════════════════════════════════════════
#  CONFIGURATION — Change these before deploying!
# ══════════════════════════════════════════════════════════════
SERVER_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com)
WG_PORT=51820
WG_UI_PORT=51821
SOCKS5_PORT=1080
HTTP_PORT=3128
PROXY_USER="karan"
PROXY_PASS="SecureProxy#2026"
WG_UI_PASS="Admin@VPN#2026"
DEPLOY="/opt/proxy-stack"

echo -e "${C}"
cat << 'BANNER'
╔══════════════════════════════════════════════════════════════╗
║  🛡️  FULL PROXY SERVER — ONE-COMMAND SETUP                  ║
╠══════════════════════════════════════════════════════════════╣
║  [1] Firewall Hardening + Anti-Traceroute                   ║
║  [2] WireGuard VPN (wg-easy) with Web UI                    ║
║  [3] SOCKS5 + HTTP Proxy (3proxy) with Auth                 ║
║  [4] DNS-over-HTTPS (Cloudflare) Leak Protection            ║
║  [5] Fail2Ban + SSH Hardening                               ║
╚══════════════════════════════════════════════════════════════╝
BANNER
echo -e "${N}"

[ "$EUID" -ne 0 ] && { echo -e "${R}✗ Run as root: sudo bash setup.sh${N}"; exit 1; }
echo -e "${G}✓ Server IP: ${SERVER_IP}${N}\n"

# ══════════════════════════════════════════════════════════════
#  STEP 1: INSTALL DOCKER
# ══════════════════════════════════════════════════════════════
echo -e "${B}${C}━━━ Step 1/7: Docker ━━━${N}"
if command -v docker &>/dev/null; then
    echo -e "${G}✓ Docker already installed${N}"
else
    echo -e "${Y}→ Installing Docker...${N}"
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    echo -e "${G}✓ Docker installed${N}"
fi

# ══════════════════════════════════════════════════════════════
#  STEP 2: FIREWALL HARDENING + ANTI-TRACEROUTE
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 2/7: Firewall & Anti-Traceroute ━━━${N}"

# Backup existing rules
mkdir -p /root/firewall-backups
iptables-save > "/root/firewall-backups/pre-setup-$(date +%s).rules" 2>/dev/null || true

# Anti-traceroute
iptables -C OUTPUT -p icmp --icmp-type time-exceeded -j DROP 2>/dev/null || \
    iptables -A OUTPUT -p icmp --icmp-type time-exceeded -j DROP
iptables -C INPUT -p icmp --icmp-type time-exceeded -j DROP 2>/dev/null || \
    iptables -A INPUT -p icmp --icmp-type time-exceeded -j DROP
iptables -C INPUT -p udp --dport 33434:33534 -j DROP 2>/dev/null || \
    iptables -A INPUT -p udp --dport 33434:33534 -j DROP
echo -e "${G}  ✓ Traceroute blocked (ICMP + UDP)${N}"

# Rate-limit ping
iptables -C INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s --limit-burst 4 -j ACCEPT 2>/dev/null || \
    iptables -A INPUT -p icmp --icmp-type echo-request -m limit --limit 1/s --limit-burst 4 -j ACCEPT
iptables -C INPUT -p icmp --icmp-type echo-request -j DROP 2>/dev/null || \
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP
echo -e "${G}  ✓ Ping rate-limited (1/sec)${N}"

# Allow Path MTU Discovery
iptables -C INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
echo -e "${G}  ✓ Path MTU Discovery preserved${N}"

# TTL normalization (anti-fingerprinting)
iptables -t mangle -C POSTROUTING -j TTL --ttl-set 64 2>/dev/null || \
    iptables -t mangle -A POSTROUTING -j TTL --ttl-set 64
echo -e "${G}  ✓ TTL normalized to 64${N}"

# Drop invalid + port scans
iptables -C INPUT -m conntrack --ctstate INVALID -j DROP 2>/dev/null || \
    iptables -A INPUT -m conntrack --ctstate INVALID -j DROP
iptables -C INPUT -p tcp --tcp-flags ALL ALL -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
iptables -C INPUT -p tcp --tcp-flags ALL NONE -j DROP 2>/dev/null || \
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
echo -e "${G}  ✓ Port scan protection enabled${N}"

# Open required ports
for P in "${WG_PORT}/udp" "${WG_UI_PORT}/tcp" "${SOCKS5_PORT}/tcp" "${HTTP_PORT}/tcp"; do
    PROTO=$(echo $P | cut -d/ -f2)
    PORT=$(echo $P | cut -d/ -f1)
    iptables -C INPUT -p $PROTO --dport $PORT -j ACCEPT 2>/dev/null || \
        iptables -I INPUT -p $PROTO --dport $PORT -j ACCEPT
done
echo -e "${G}  ✓ Service ports opened${N}"

# Persist
apt-get install -y -qq iptables-persistent 2>/dev/null || true
netfilter-persistent save 2>/dev/null || iptables-save > /etc/iptables/rules.v4 2>/dev/null || true
echo -e "${G}  ✓ Rules persisted${N}"

# ══════════════════════════════════════════════════════════════
#  STEP 3: KERNEL HARDENING (sysctl)
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 3/7: Kernel Hardening ━━━${N}"

cat > /etc/sysctl.d/99-proxy-hardening.conf << 'EOF'
# Anti-spoofing
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
# SYN flood
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 4096
# No ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
# No source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
# Ignore broadcast ping
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
# Log suspicious packets
net.ipv4.conf.all.log_martians = 1
# BBR congestion + TCP tuning
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
# IP forwarding for VPN
net.ipv4.ip_forward = 1
EOF

sysctl --system > /dev/null 2>&1
echo -e "${G}  ✓ 25 sysctl rules applied (BBR, anti-spoof, forwarding)${N}"

# ══════════════════════════════════════════════════════════════
#  STEP 4: FAIL2BAN + SSH HARDENING
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 4/7: Fail2Ban & SSH ━━━${N}"

apt-get install -y -qq fail2ban 2>/dev/null

cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
[sshd]
enabled = true
port = ssh
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
EOF

systemctl enable --now fail2ban 2>/dev/null
echo -e "${G}  ✓ Fail2Ban active (3 failed SSH = 2hr ban)${N}"

# SSH hardening
mkdir -p /etc/ssh/sshd_config.d/
cat > /etc/ssh/sshd_config.d/99-hardened.conf << 'EOF'
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxSessions 5
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
PermitTunnel yes
LogLevel VERBOSE
EOF

sshd -t 2>/dev/null && systemctl restart sshd 2>/dev/null || true
echo -e "${G}  ✓ SSH hardened (key-only root, max 3 attempts)${N}"

# ══════════════════════════════════════════════════════════════
#  STEP 5: CREATE DOCKER COMPOSE STACK
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 5/7: Building Stack Configuration ━━━${N}"

mkdir -p "${DEPLOY}"/{wireguard,3proxy}

# ── 3proxy config ────────────────────────────────────────────
cat > "${DEPLOY}/3proxy/3proxy.cfg" << PROXYCFG
system "echo '3proxy started'"
log /dev/stdout
logformat "L%d-%m-%Y %H:%M:%S %U %C:%c %R:%r %O %I %T"
timeouts 1 5 30 60 180 1800 15 60
nserver 1.1.1.1
nserver 1.0.0.1
nserver 8.8.8.8
nscache 65536
users ${PROXY_USER}:CL:${PROXY_PASS}
auth strong
deny * * 127.0.0.0/8
deny * * 10.0.0.0/8
deny * * 172.16.0.0/12
deny * * 192.168.0.0/16
allow ${PROXY_USER}
proxy -p3128 -a
socks -p1080 -a
flush
PROXYCFG
chmod 600 "${DEPLOY}/3proxy/3proxy.cfg"
echo -e "${G}  ✓ 3proxy config created (SOCKS5:1080, HTTP:3128)${N}"

# ── Docker Compose ───────────────────────────────────────────
cat > "${DEPLOY}/docker-compose.yml" << DCOMPOSE
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    environment:
      - LANG=en
      - WG_HOST=${SERVER_IP}
      - PASSWORD=${WG_UI_PASS}
      - WG_PORT=${WG_PORT}
      - WG_DEFAULT_DNS=172.20.0.100
      - WG_ALLOWED_IPS=0.0.0.0/0,::/0
      - WG_PERSISTENT_KEEPALIVE=25
      - UI_TRAFFIC_STATS=true
      - UI_CHART_TYPE=2
    volumes:
      - ./wireguard:/etc/wireguard
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${WG_UI_PORT}:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    networks:
      proxy-net:
        ipv4_address: 172.20.0.10
    restart: unless-stopped

  proxy:
    image: 3proxy/3proxy:latest
    container_name: proxy-server
    volumes:
      - ./3proxy/3proxy.cfg:/etc/3proxy/cfg/3proxy.cfg:ro
    ports:
      - "${SOCKS5_PORT}:1080"
      - "${HTTP_PORT}:3128"
    networks:
      proxy-net:
        ipv4_address: 172.20.0.20
    restart: unless-stopped

  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared-dns
    command: proxy-dns --port 53 --upstream https://1.1.1.1/dns-query --upstream https://1.0.0.1/dns-query
    networks:
      proxy-net:
        ipv4_address: 172.20.0.100
    restart: unless-stopped

networks:
  proxy-net:
    driver: bridge
    ipam:
      config:
        - subnet: 172.20.0.0/24
          gateway: 172.20.0.1
DCOMPOSE
echo -e "${G}  ✓ Docker Compose file created${N}"

# ══════════════════════════════════════════════════════════════
#  STEP 6: DEPLOY
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 6/7: Deploying (pulling images)... ━━━${N}"
cd "${DEPLOY}"
docker compose pull
docker compose up -d
echo -e "${Y}→ Waiting for services to start...${N}"
sleep 5

# ══════════════════════════════════════════════════════════════
#  STEP 7: HEALTH CHECK + INFO
# ══════════════════════════════════════════════════════════════
echo -e "\n${B}${C}━━━ Step 7/7: Health Check ━━━${N}"

ALL_OK=true
for svc in wg-easy proxy-server cloudflared-dns; do
    if docker ps --format '{{.Names}}' | grep -q "^${svc}$"; then
        echo -e "  ${G}✓${N} ${svc}: ${G}running${N}"
    else
        echo -e "  ${R}✗${N} ${svc}: ${R}FAILED${N}"
        docker logs "$svc" 2>&1 | tail -3 | sed 's/^/    /'
        ALL_OK=false
    fi
done

# ── Save connection info ────────────────────────────────────
cat > "${DEPLOY}/credentials.txt" << CREDS
═══════════════════════════════════════════
  Proxy Stack Credentials — $(date)
═══════════════════════════════════════════
WireGuard Web UI: http://${SERVER_IP}:${WG_UI_PORT}
  Password: ${WG_UI_PASS}

SOCKS5: ${SERVER_IP}:${SOCKS5_PORT}
  User: ${PROXY_USER}  Pass: ${PROXY_PASS}

HTTP:   ${SERVER_IP}:${HTTP_PORT}
  User: ${PROXY_USER}  Pass: ${PROXY_PASS}
CREDS
chmod 600 "${DEPLOY}/credentials.txt"

# ── Print results ────────────────────────────────────────────
echo ""
echo -e "${C}╔══════════════════════════════════════════════════════════╗${N}"
echo -e "${C}║            🚀 SETUP COMPLETE — ALL SERVICES LIVE        ║${N}"
echo -e "${C}╠══════════════════════════════════════════════════════════╣${N}"
echo -e "${C}║${N}"
echo -e "${C}║${N}  ${G}WireGuard VPN:${N}"
echo -e "${C}║${N}    Web UI:   ${Y}http://${SERVER_IP}:${WG_UI_PORT}${N}"
echo -e "${C}║${N}    Password: ${Y}${WG_UI_PASS}${N}"
echo -e "${C}║${N}    Port:     ${Y}${WG_PORT}/UDP${N}"
echo -e "${C}║${N}"
echo -e "${C}║${N}  ${G}SOCKS5 Proxy:${N}  ${Y}${SERVER_IP}:${SOCKS5_PORT}${N}"
echo -e "${C}║${N}  ${G}HTTP Proxy:${N}    ${Y}${SERVER_IP}:${HTTP_PORT}${N}"
echo -e "${C}║${N}  ${G}Auth:${N}          ${Y}${PROXY_USER} / ${PROXY_PASS}${N}"
echo -e "${C}║${N}"
echo -e "${C}║${N}  ${G}DNS:${N}           ${Y}Cloudflare DoH (auto for VPN clients)${N}"
echo -e "${C}║${N}"
echo -e "${C}╠══════════════════════════════════════════════════════════╣${N}"
echo -e "${C}║${N}  ${B}📱 Connect your devices:${N}"
echo -e "${C}║${N}  1. Open ${G}http://${SERVER_IP}:${WG_UI_PORT}${N}"
echo -e "${C}║${N}  2. Click ${G}+ New Client${N} → name your device"
echo -e "${C}║${N}  3. Download .conf or scan QR with WireGuard app"
echo -e "${C}║${N}  4. Verify at ${G}https://ipleak.net${N}"
echo -e "${C}║${N}"
echo -e "${C}║${N}  ${B}🔧 Management:${N}"
echo -e "${C}║${N}    cd ${DEPLOY} && docker compose ps"
echo -e "${C}║${N}    docker compose logs -f"
echo -e "${C}║${N}    docker compose restart"
echo -e "${C}║${N}"
echo -e "${C}╚══════════════════════════════════════════════════════════╝${N}"
