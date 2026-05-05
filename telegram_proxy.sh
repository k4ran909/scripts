#!/bin/bash
# ============================================================
#  Telegram MTProto Proxy — One-Click Installer & Manager
#  Uses mtg v2 (native binary, ARM64 + AMD64 support)
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
MTG_VERSION="2.2.8"
MTG_BIN="/usr/local/bin/mtg"
CONFIG_DIR="/opt/mtproto"
SECRET_FILE="${CONFIG_DIR}/secret.txt"
PORT_FILE="${CONFIG_DIR}/port.txt"
CONFIG_FILE="${CONFIG_DIR}/config.toml"
MANAGER_PATH="/usr/local/bin/tgproxy"
SERVICE_NAME="mtg"
FAKETLS_DOMAIN="google.com"

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

get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64|amd64)   echo "amd64" ;;
        aarch64|arm64)  echo "arm64" ;;
        armv7*)         echo "armv7" ;;
        armv6*)         echo "armv6" ;;
        *)              fail "Unsupported architecture: $arch"; exit 1 ;;
    esac
}

find_free_port() {
    # Try 443 first, then 8443, then 2053, then 8880
    for port in 443 8443 2053 8880; do
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} " && \
           ! netstat -tlnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
    done
    # Random high port as last resort
    echo "$(shuf -i 10000-60000 -n 1)"
}

# ══════════════════════════════════════════════════════════════
#  INSTALL
# ══════════════════════════════════════════════════════════════
cmd_install() {
    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║       ✈️  Telegram MTProto Proxy — Quick Installer      ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║   Optimized for India ↔ Mumbai / Singapore VPS links   ║"
    echo "║   Native binary — supports ARM64 + AMD64               ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    if [ "$EUID" -ne 0 ]; then
        fail "Run as root:  sudo bash <(curl -fsSL URL)"
        exit 1
    fi

    local ARCH
    ARCH=$(get_arch)
    info "Detected architecture: ${BOLD}${ARCH}${NC}"

    install_mtg "$ARCH"
    generate_secret
    detect_port
    create_config
    optimize_network
    create_service
    setup_firewall
    install_manager

    # Start the service
    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" --now

    sleep 2
    if systemctl is-active --quiet "$SERVICE_NAME"; then
        ok "Proxy is up and running!"
        echo ""
        cmd_info
    else
        fail "Service didn't start. Checking logs:"
        journalctl -u "$SERVICE_NAME" --no-pager -n 20
        exit 1
    fi
}

# ── Download & install mtg binary ────────────────────────────
install_mtg() {
    local ARCH="$1"
    local DOWNLOAD_URL="https://github.com/9seconds/mtg/releases/download/v${MTG_VERSION}/mtg-${MTG_VERSION}-linux-${ARCH}.tar.gz"

    if [ -f "$MTG_BIN" ]; then
        local current_ver
        current_ver=$("$MTG_BIN" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || echo "unknown")
        if [ "$current_ver" = "$MTG_VERSION" ]; then
            ok "mtg v${MTG_VERSION} already installed"
            return
        fi
        info "Upgrading mtg from v${current_ver} to v${MTG_VERSION}..."
    else
        info "Downloading mtg v${MTG_VERSION} for ${ARCH}..."
    fi

    local TMP_DIR
    TMP_DIR=$(mktemp -d)
    curl -fsSL "$DOWNLOAD_URL" -o "${TMP_DIR}/mtg.tar.gz"
    tar -xzf "${TMP_DIR}/mtg.tar.gz" -C "$TMP_DIR"
    
    # Find the mtg binary in extracted files
    local MTG_EXTRACTED
    MTG_EXTRACTED=$(find "$TMP_DIR" -name "mtg" -type f ! -name "*.tar.gz" | head -1)
    
    if [ -z "$MTG_EXTRACTED" ]; then
        fail "Could not find mtg binary in archive"
        ls -la "$TMP_DIR"/
        rm -rf "$TMP_DIR"
        exit 1
    fi

    cp "$MTG_EXTRACTED" "$MTG_BIN"
    chmod +x "$MTG_BIN"
    rm -rf "$TMP_DIR"

    ok "mtg v${MTG_VERSION} installed at ${MTG_BIN}"
}

# ── Generate FakeTLS secret ──────────────────────────────────
generate_secret() {
    mkdir -p "$CONFIG_DIR"
    if [ -f "$SECRET_FILE" ]; then
        SECRET=$(cat "$SECRET_FILE")
        ok "Using existing secret"
    else
        info "Generating FakeTLS secret..."
        SECRET=$("$MTG_BIN" generate-secret --hex tls -t "$FAKETLS_DOMAIN")
        echo "$SECRET" > "$SECRET_FILE"
        chmod 600 "$SECRET_FILE"
        ok "Generated FakeTLS secret (disguised as ${FAKETLS_DOMAIN})"
    fi
}

# ── Detect available port ────────────────────────────────────
detect_port() {
    PROXY_PORT=$(find_free_port)
    echo "$PROXY_PORT" > "$PORT_FILE"
    
    if [ "$PROXY_PORT" = "443" ]; then
        ok "Using port 443 (ideal — looks like HTTPS)"
    else
        warn "Port 443 is in use. Using port ${PROXY_PORT} instead"
        info "Tip: Port 443 is best because it looks like normal HTTPS traffic"
    fi
}

# ── Create mtg config ────────────────────────────────────────
create_config() {
    info "Creating config..."
    cat > "$CONFIG_FILE" << EOF
# MTG v2 Configuration
# Auto-generated by telegram_proxy.sh

secret = "${SECRET}"

[network]
bind-to = "0.0.0.0:${PROXY_PORT}"

# Prefer direct IPv4 to Telegram servers for speed
prefer-ip = "prefer-ipv4"

# Buffer sizes for fast downloads
[network.tcp-buffer]
read = 65536
write = 65536

# TCP keepalive for stable mobile connections
[network.keep-alive]
disabled = false
idle = "10s"
interval = "10s"
count = 5

# Performance tuning
[performance]
# Use all available CPU cores
concurrency = 0
EOF
    ok "Config written to ${CONFIG_FILE}"
}

# ── Network tuning ───────────────────────────────────────────
optimize_network() {
    info "Applying network optimizations (BBR + TCP tuning)..."
    cat > /etc/sysctl.d/99-mtproto.conf << 'SYSCTL'
# TCP buffers (16 MB max for big downloads)
net.core.rmem_max=16777216
net.core.wmem_max=16777216
net.ipv4.tcp_rmem=4096 87380 16777216
net.ipv4.tcp_wmem=4096 65536 16777216
# BBR congestion control (great for long-distance links)
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
# TCP Fast Open
net.ipv4.tcp_fastopen=3
# Connection handling
net.core.somaxconn=4096
net.ipv4.tcp_max_syn_backlog=4096
# Keepalive
net.ipv4.tcp_keepalive_time=600
net.ipv4.tcp_keepalive_intvl=30
net.ipv4.tcp_keepalive_probes=5
# Reuse TIME_WAIT
net.ipv4.tcp_tw_reuse=1
SYSCTL
    sysctl --system &>/dev/null
    ok "BBR + TCP buffers + Fast Open enabled"
}

# ── Create systemd service ───────────────────────────────────
create_service() {
    info "Creating systemd service..."
    cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=MTProto Proxy (Telegram)
After=network.target

[Service]
Type=simple
ExecStart=${MTG_BIN} run ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535
StandardOutput=journal
StandardError=journal

# Security hardening
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadOnlyPaths=/
ReadWritePaths=${CONFIG_DIR}
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    ok "Systemd service created"
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

# ── Install manager command ──────────────────────────────────
install_manager() {
    info "Installing 'tgproxy' command..."
    
    # Save a local copy of this script
    local SELF_SCRIPT="${CONFIG_DIR}/telegram_proxy.sh"
    if [ -f "$0" ] && [ "$0" != "bash" ] && [ "$0" != "/dev/stdin" ]; then
        cp "$0" "$SELF_SCRIPT"
    else
        curl -fsSL "https://raw.githubusercontent.com/k4ran909/scripts/main/telegram_proxy.sh" \
            -o "$SELF_SCRIPT"
    fi
    chmod +x "$SELF_SCRIPT"
    
    cat > "$MANAGER_PATH" << 'MANAGER'
#!/bin/bash
exec bash /opt/mtproto/telegram_proxy.sh "$@"
MANAGER
    chmod +x "$MANAGER_PATH"
    ok "Installed! Use: ${BOLD}tgproxy${NC}${GREEN} [status|info|restart|logs|...]${NC}"
}

# ══════════════════════════════════════════════════════════════
#  MANAGEMENT COMMANDS
# ══════════════════════════════════════════════════════════════

cmd_status() {
    echo -e "${CYAN}${BOLD}═══ MTProto Proxy Status ═══${NC}"
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        echo -e "  ${GREEN}● RUNNING${NC}"
        echo ""
        # Show uptime and resource usage
        systemctl status "$SERVICE_NAME" --no-pager -l 2>/dev/null | grep -E "Active:|Memory:|CPU:|Main PID:" | sed 's/^/  /'
        echo ""
        # Show port
        if [ -f "$PORT_FILE" ]; then
            echo -e "  ${GREEN}Port:${NC} $(cat "$PORT_FILE")"
        fi
        # Show connections
        local PORT
        PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "443")
        local CONNS
        CONNS=$(ss -tn state established "( sport = :${PORT} )" 2>/dev/null | tail -n +2 | wc -l)
        echo -e "  ${GREEN}Active connections:${NC} ${CONNS}"
    else
        echo -e "  ${RED}● STOPPED${NC}"
        echo -e "  Use ${BOLD}tgproxy start${NC} to start"
    fi
}

cmd_start() {
    systemctl start "$SERVICE_NAME" && ok "Started"
}

cmd_stop() {
    systemctl stop "$SERVICE_NAME" && ok "Stopped"
}

cmd_restart() {
    systemctl restart "$SERVICE_NAME" && ok "Restarted"
}

cmd_logs() {
    local lines="${2:-50}"
    journalctl -u "$SERVICE_NAME" --no-pager -n "$lines"
}

cmd_follow() {
    journalctl -u "$SERVICE_NAME" -f
}

cmd_info() {
    [ ! -f "$SECRET_FILE" ] && { fail "Not installed. Run installer first."; exit 1; }
    SECRET=$(cat "$SECRET_FILE")
    PROXY_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "443")
    get_server_ip

    echo -e "${CYAN}${BOLD}"
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║              📱  TELEGRAM PROXY DETAILS                 ║"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo -e "${NC}"
    echo -e "  ${GREEN}Server :${NC}  ${SERVER_IP}"
    echo -e "  ${GREEN}Port   :${NC}  ${PROXY_PORT}"
    echo -e "  ${GREEN}Secret :${NC}  ${SECRET}"
    echo ""
    echo -e "  ${YELLOW}━━━ Quick Connect (tap on your phone) ━━━${NC}"
    echo ""
    echo -e "  ${GREEN}★ FakeTLS Link (Best — fast & stealthy):${NC}"
    echo -e "  ${BOLD}tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}${NC}"
    echo ""
    echo -e "  ${GREEN}HTTPS Link (for sharing):${NC}"
    echo -e "  https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}"
    echo ""
    echo -e "${CYAN}${BOLD}"
    echo "╠══════════════════════════════════════════════════════════╣"
    echo "║  Manual: Settings → Data & Storage → Proxy → MTProto   ║"
    echo "║  Server: ${SERVER_IP}"
    echo "║  Port:   ${PROXY_PORT}"
    echo "║  Secret: ${SECRET}"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # Save to file
    cat > "${CONFIG_DIR}/connection_info.txt" << EOF
Telegram MTProto Proxy
======================
Server: ${SERVER_IP}
Port:   ${PROXY_PORT}
Secret: ${SECRET}

FakeTLS Link:
tg://proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}

HTTPS Link:
https://t.me/proxy?server=${SERVER_IP}&port=${PROXY_PORT}&secret=${SECRET}

Manual Setup:
  Settings → Data & Storage → Proxy → Add Proxy → MTProto
  Server: ${SERVER_IP}
  Port:   ${PROXY_PORT}
  Secret: ${SECRET}
EOF
    ok "Connection info also saved to ${CONFIG_DIR}/connection_info.txt"
}

cmd_update() {
    info "Updating mtg..."
    local ARCH
    ARCH=$(get_arch)
    
    # Stop service
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    
    # Re-download
    install_mtg "$ARCH"
    
    # Restart
    systemctl start "$SERVICE_NAME"
    ok "Updated to mtg v${MTG_VERSION}"
    cmd_status
}

cmd_speedtest() {
    echo -e "${CYAN}${BOLD}═══ VPS Speed Test ═══${NC}"
    if ! command -v speedtest-cli &>/dev/null; then
        info "Installing speedtest-cli..."
        pip3 install speedtest-cli 2>/dev/null || apt-get install -y -qq speedtest-cli 2>/dev/null
    fi
    if command -v speedtest-cli &>/dev/null; then
        speedtest-cli --simple
    else
        # Fallback: simple curl-based test
        info "Running curl-based download test..."
        curl -o /dev/null -w "Download speed: %{speed_download} bytes/sec\n" \
            https://speed.hetzner.de/100MB.bin 2>/dev/null || echo "Speed test failed"
    fi
}

cmd_uninstall() {
    echo -e "${RED}${BOLD}⚠  This will completely remove the Telegram proxy${NC}"
    read -rp "Continue? (y/N): " confirm
    [[ ! "$confirm" =~ ^[yY]$ ]] && { echo "Cancelled."; exit 0; }

    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    systemctl daemon-reload
    rm -f "$MTG_BIN"
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
    echo "║  status      Show proxy status & connections             ║"
    echo "║  info        Show connection details & quick-links       ║"
    echo "║  start       Start the proxy                             ║"
    echo "║  stop        Stop the proxy                              ║"
    echo "║  restart     Restart the proxy                           ║"
    echo "║  logs        Show recent logs (last 50 lines)            ║"
    echo "║  follow      Tail logs in real-time                       ║"
    echo "║  update      Download latest mtg binary                  ║"
    echo "║  speedtest   Test VPS network speed                      ║"
    echo "║  uninstall   Remove everything                           ║"
    echo "║  help        Show this message                           ║"
    echo "║                                                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ══════════════════════════════════════════════════════════════
#  ROUTER
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
