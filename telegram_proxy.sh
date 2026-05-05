#!/bin/bash
# ============================================================
#  Telegram MTProto Proxy — One-Click Installer & Manager
#  Deploy on any VPS for blazing-fast Telegram downloads
# ============================================================
#
#  One-liner install:
#    bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/telegram_proxy.sh)
#
#  Management (after install):
#    tgproxy status | start | stop | restart | logs | info | update | speedtest | uninstall
#
# ============================================================

set -euo pipefail

# ── Colors ───────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ───────────────────────────────────────────────────
CONTAINER_NAME="mtproto-proxy"
PROXY_PORT=443
CONFIG_DIR="/opt/mtproto"
SECRET_FILE="${CONFIG_DIR}/secret.txt"
MANAGER_PATH="/usr/local/bin/tgproxy"

# ── Helpers ──────────────────────────────────────────────────
info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[  OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

get_server_ip() {
    SERVER_IP=$(curl -s -4 --max-time 5 ifconfig.me 2>/dev/null \
             || curl -s -4 --max-time 5 icanhazip.com 2>/dev/null \
             || curl -s -4 --max-time 5 api.ipify.org 2>/dev/null \
             || echo "YOUR_SERVER_IP")
}

# ══════════════════════════════════════════════════════════════
#  INSTALL
# ══════════════════════════════════════════════════════════════
cmd_install() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║      ✈️  Telegram MTProto Proxy — Quick Installer       ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║   Optimized for India ↔ Mumbai / Singapore VPS links   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Root check
    if [ "$EUID" -ne 0 ]; then
        fail "Run as root:  sudo bash <(curl -fsSL URL)"
        exit 1
    fi

    install_docker
    install_tools
    generate_secret
    stop_existing
    setup_firewall
    optimize_network
    deploy_proxy
    install_manager

    sleep 3
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        ok "Proxy is up and running!"
        echo ""
        cmd_info
    else
        fail "Container didn't start. Logs:"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi
}

# ── Docker ───────────────────────────────────────────────────
install_docker() {
    if command -v docker &>/dev/null; then
        ok "Docker already installed"
        return
    fi
    info "Installing Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
    ok "Docker installed"
}

# ── Tools ────────────────────────────────────────────────────
install_tools() {
    if ! command -v xxd &>/dev/null; then
        info "Installing xxd..."
        apt-get update -qq && apt-get install -y -qq xxd 2>/dev/null || apt-get install -y -qq vim-common
    fi
}

# ── Secret ───────────────────────────────────────────────────
generate_secret() {
    mkdir -p "$CONFIG_DIR"
    if [ -f "$SECRET_FILE" ]; then
        SECRET=$(cat "$SECRET_FILE")
        ok "Using existing secret"
    else
        SECRET=$(head -c 16 /dev/urandom | xxd -ps)
        echo "$SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        ok "Generated new secret"
    fi
}

# ── Cleanup old container ────────────────────────────────────
stop_existing() {
    if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        info "Removing old container..."
        docker rm -f "$CONTAINER_NAME" &>/dev/null || true
        ok "Old container removed"
    fi
}

# ── Firewall ─────────────────────────────────────────────────
setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "$PROXY_PORT"/tcp comment "Telegram MTProto" &>/dev/null || true
        ok "Firewall: port ${PROXY_PORT} opened"
    else
        warn "ufw not found — ensure port ${PROXY_PORT} is open in your cloud panel"
    fi
}

# ── Network tuning ───────────────────────────────────────────
optimize_network() {
    info "Applying network optimizations (BBR + TCP tuning)..."
    cat > /etc/sysctl.d/99-mtproto.conf << 'SYSCTL'
# ── TCP buffers (16 MB max for big downloads) ──
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
# ── BBR congestion control ──
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# ── TCP Fast Open ──
net.ipv4.tcp_fastopen=3
# ── Connection handling ──
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
# ── Keepalive ──
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
# ── Reuse TIME_WAIT ──
net.ipv4.tcp_tw_reuse=1
SYSCTL
    sysctl --system &>/dev/null
    ok "BBR + TCP buffers + Fast Open enabled"
}

# ── Deploy ───────────────────────────────────────────────────
deploy_proxy() {
    info "Pulling official Telegram MTProto proxy image..."
    docker pull telegrammessenger/proxy:latest

    # Prepare data files
    echo "$SECRET" > "${CONFIG_DIR}/proxy-secret"
    touch "${CONFIG_DIR}/proxy-multi.conf"
    touch "${CONFIG_DIR}/proxy-tag"

    info "Starting proxy container on port ${PROXY_PORT}..."
    docker run -d \
        --name "$CONTAINER_NAME" \
        --restart unless-stopped \
        -p "${PROXY_PORT}:443" \
        -v "${CONFIG_DIR}/proxy-multi.conf:/data/proxy-multi.conf" \
        -v "${CONFIG_DIR}/proxy-secret:/data/proxy-secret" \
        -v "${CONFIG_DIR}/proxy-tag:/data/proxy-tag" \
        -e SECRET="$SECRET" \
        --memory=512m \
        --cpus=1 \
        telegrammessenger/proxy:latest
    ok "Proxy container started"
}

# ── Install manager command ──────────────────────────────────
install_manager() {
    info "Installing 'tgproxy' management command..."
    SELF_URL="https://raw.githubusercontent.com/k4ran909/scripts/main/telegram_proxy.sh"
    cat > "$MANAGER_PATH" << MANAGER
#!/bin/bash
# Auto-generated management wrapper
exec bash <(curl -fsSL ${SELF_URL}) "\$@"
MANAGER
    # Also install a local copy for offline use
    cp "$0" "${CONFIG_DIR}/telegram_proxy.sh" 2>/dev/null || \
    curl -fsSL "$SELF_URL" -o "${CONFIG_DIR}/telegram_proxy.sh"
    
    # Make the manager use local copy (faster, works offline)
    cat > "$MANAGER_PATH" << 'OFFLINE'
#!/bin/bash
exec bash /opt/mtproto/telegram_proxy.sh "$@"
OFFLINE
    chmod +x "$MANAGER_PATH"
    chmod +x "${CONFIG_DIR}/telegram_proxy.sh"
    ok "Installed! Use: ${BOLD}tgproxy${NC}${GREEN} [status|info|restart|logs|...]${NC}"
}

# ══════════════════════════════════════════════════════════════
#  MANAGEMENT COMMANDS
# ══════════════════════════════════════════════════════════════

cmd_status() {
    echo -e "${CYAN}${BOLD}═══ MTProto Proxy Status ═══${NC}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "  ${GREEN}● RUNNING${NC}"
        docker stats "$CONTAINER_NAME" --no-stream \
            --format "  CPU: {{.CPUPerc}}  |  RAM: {{.MemUsage}}  |  Net: {{.NetIO}}" 2>/dev/null
        echo ""
        # Uptime
        docker ps --filter "name=${CONTAINER_NAME}" --format "  Uptime: {{.Status}}" 2>/dev/null
    else
        echo -e "  ${RED}● STOPPED${NC}"
    fi
}

cmd_start() {
    docker start "$CONTAINER_NAME" && ok "Started"
}

cmd_stop() {
    docker stop "$CONTAINER_NAME" && ok "Stopped"
}

cmd_restart() {
    docker restart "$CONTAINER_NAME" && ok "Restarted"
}

cmd_logs() {
    docker logs "$CONTAINER_NAME" --tail "${2:-50}"
}

cmd_follow() {
    docker logs -f "$CONTAINER_NAME"
}

cmd_info() {
    [ ! -f "$SECRET_FILE" ] && { fail "Not installed. Run installer first."; exit 1; }
    SECRET=$(cat "$SECRET_FILE")
    get_server_ip

    # FakeTLS secret: prefix ee + secret + hex("www.google.com")
    FAKETLS="ee${SECRET}7777772e676f6f676c652e636f6d"
    DD="dd${SECRET}"

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              📱  TELEGRAM PROXY DETAILS                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "${NC}"
    echo -e "  ${GREEN}Server :${NC}  ${SERVER_IP}"
    echo -e "  ${GREEN}Port   :${NC}  ${PROXY_PORT}"
    echo -e "  ${GREEN}Secret :${NC}  ${DD}"
    echo ""
    echo -e "  ${YELLOW}━━━ Quick Connect Links (tap on phone) ━━━${NC}"
    echo ""
    echo -e "  ${GREEN}★ FakeTLS (Best — fastest & hardest to block):${NC}"
    echo -e "  ${BOLD}tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKETLS}${NC}"
    echo ""
    echo -e "  ${GREEN}Obfuscated:${NC}"
    echo -e "  tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${DD}"
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Manual: Settings → Data & Storage → Proxy → MTProto   ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Save to file for easy reference
    cat > "${CONFIG_DIR}/connection_info.txt" << EOF
Telegram MTProto Proxy
======================
Server: ${SERVER_IP}
Port:   ${PROXY_PORT}
Secret: ${DD}

FakeTLS Link: tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${FAKETLS}
Obfuscated:   tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${DD}
EOF
}

cmd_update() {
    info "Updating proxy..."
    docker pull telegrammessenger/proxy:latest
    SECRET=$(cat "$SECRET_FILE")
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    deploy_proxy
    sleep 2
    ok "Updated to latest version"
    cmd_status
}

cmd_speedtest() {
    echo -e "${CYAN}${BOLD}═══ VPS Speed Test ═══${NC}"
    if ! command -v speedtest-cli &>/dev/null; then
        info "Installing speedtest-cli..."
        pip3 install speedtest-cli 2>/dev/null || apt-get install -y -qq speedtest-cli
    fi
    speedtest-cli --simple
}

cmd_uninstall() {
    echo -e "${RED}${BOLD}⚠  This will completely remove the Telegram proxy${NC}"
    read -rp "Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "Cancelled."; exit 0; }

    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
    rm -rf "$CONFIG_DIR"
    rm -f "$MANAGER_PATH"
    rm -f /etc/sysctl.d/99-mtproto.conf
    sysctl --system &>/dev/null
    ok "Proxy uninstalled & cleaned up"
}

cmd_help() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       ✈️  Telegram MTProto Proxy — Commands             ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║                                                          ║"
    echo "║  install     First-time setup (auto-detected)            ║"
    echo "║  status      Show proxy status & resource usage          ║"
    echo "║  info        Show connection details & quick-links       ║"
    echo "║  start       Start the proxy                             ║"
    echo "║  stop        Stop the proxy                              ║"
    echo "║  restart     Restart the proxy                           ║"
    echo "║  logs        Show recent logs (last 50 lines)            ║"
    echo "║  follow      Tail logs in real-time                       ║"
    echo "║  update      Pull latest image & recreate                ║"
    echo "║  speedtest   Test VPS network speed                      ║"
    echo "║  uninstall   Remove everything                           ║"
    echo "║  help        Show this message                           ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════
#  ROUTER — auto-install if no args, otherwise run command
# ══════════════════════════════════════════════════════════════
main() {
    local cmd="${1:-}"
    
    # No args = install (first-time use via curl pipe)
    if [ -z "$cmd" ]; then
        cmd_install
        return
    fi

    case "$cmd" in
        install)    cmd_install ;;
        status)     cmd_status ;;
        info)       cmd_info ;;
        start)      cmd_start ;;
        stop)       cmd_stop ;;
        restart)    cmd_restart ;;
        logs)       cmd_logs "$@" ;;
        follow)     cmd_follow ;;
        update)     cmd_update ;;
        speedtest)  cmd_speedtest ;;
        uninstall)  cmd_uninstall ;;
        help|*)     cmd_help ;;
    esac
}

main "$@"
