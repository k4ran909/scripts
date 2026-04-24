#!/usr/bin/env bash
# ============================================================================
#  Browser VPS Installer v2.2
#  One-line install: bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/br_install.sh)
#
#  Deploys a 24/7 desktop browser (KasmVNC) accessible from anywhere.
#  Supports: Chromium, Brave, Firefox, Mullvad Browser, Opera
#  Optional: Custom domain + free SSL via Caddy reverse proxy
# ============================================================================
set -Eeuo pipefail

# ── Colors & formatting ────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; MAGENTA='\033[0;35m'; BOLD='\033[1m'; DIM='\033[2m'
NC='\033[0m'

# ── Defaults ───────────────────────────────────────────────────────────────
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]:-$0}")"
CONFIG_FILE="${CONFIG_FILE:-.browser-config}"
EXPLICIT_CONFIG=0

LOG_FILE="browser_install_$(date +%Y%m%d_%H%M%S).log"
CONTAINER_NAME="${CONTAINER_NAME:-browser}"
DEFAULT_SHM="2gb"
PORT_HTTP="${PORT_HTTP:-${PORT_GUAC:-3000}}"
PORT_HTTPS="${PORT_HTTPS:-3001}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"
NETWORK_MODE="${NETWORK_MODE:-bridge}"
STARTUP_TIMEOUT=180
IP_FETCH_TIMEOUT=5
INTERACTIVE=0
FAILED=0
DOMAIN="${DOMAIN:-}"
USE_DNS=0

[[ -t 0 && -t 1 ]] && INTERACTIVE=1

# ── Logging ────────────────────────────────────────────────────────────────
log()  { printf "${CYAN}[INFO]${NC}  %s\n" "$*" | tee -a "$LOG_FILE"; }
ok()   { printf "${GREEN}[  OK]${NC}  %s\n" "$*" | tee -a "$LOG_FILE"; }
warn() { printf "${YELLOW}[WARN]${NC}  %s\n" "$*" | tee -a "$LOG_FILE"; }
die()  { FAILED=1; printf "${RED}[FAIL]${NC}  %s\n" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

# ── Cleanup trap ───────────────────────────────────────────────────────────
cleanup() {
  local rc=$?
  if (( rc != 0 && FAILED == 0 )); then
    warn "Installer exited with code ${rc}. Check ${LOG_FILE} for details."
  fi
}
trap cleanup EXIT

# ── Help ───────────────────────────────────────────────────────────────────
show_help() {
  cat <<EOF
${BOLD}Browser VPS Installer v2.2${NC}

${BOLD}Usage:${NC}
  $SCRIPT_NAME                        Interactive install
  $SCRIPT_NAME --config <file>        Use config file
  $SCRIPT_NAME -h | --help            Show this help

${BOLD}One-liner:${NC}
  bash <(curl -fsSL https://raw.githubusercontent.com/k4ran909/scripts/main/br_install.sh)

${BOLD}Config file / environment variables:${NC}
  BROWSER=3           1=Chromium 2=Brave 3=Firefox 4=Mullvad 5=Opera
  USERNAME=browser
  PASSWORD=your-password
  SHM_SIZE=2gb
  PORT_HTTP=3000       (HTTP / Guacamole port)
  PORT_HTTPS=3001      (HTTPS / KasmVNC port)
  TIMEZONE=Etc/UTC
  CONFIG_DIR=/opt/browser-firefox
  NETWORK_MODE=bridge  (bridge or host)
  PUID=1000
  PGID=1000
  WATCHTOWER=yes       (yes or no — auto-update images)
  DOMAIN=browser.example.com  (optional — custom domain with free SSL)
EOF
  exit 0
}

# ── Argument parsing ───────────────────────────────────────────────────────
parse_args() {
  while (( $# )); do
    case "$1" in
      -h|--help)       show_help ;;
      -c|--config)     shift; [[ $# -gt 0 ]] || die "Missing value for --config"
                       CONFIG_FILE="$1"; EXPLICIT_CONFIG=1 ;;
      -*)              die "Unknown option: $1" ;;
      *)               CONFIG_FILE="$1"; EXPLICIT_CONFIG=1 ;;
    esac
    shift
  done
}

# ── Load config file ──────────────────────────────────────────────────────
load_config() {
  if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading config from: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  elif (( EXPLICIT_CONFIG )); then
    die "Config file not found: $CONFIG_FILE"
  fi
}

# ── Banner ─────────────────────────────────────────────────────────────────
banner() {
  (( INTERACTIVE )) && clear 2>/dev/null || true
  printf "${MAGENTA}${BOLD}"
  cat <<'ART'

  ╔══════════════════════════════════════════════════╗
  ║       🌐  Browser VPS Installer  v2.2  🌐       ║
  ║    Deploy a 24/7 browser accessible anywhere     ║
  ╚══════════════════════════════════════════════════╝

ART
  printf "${NC}"
  printf "  ${DIM}Log file: %s${NC}\n\n" "$LOG_FILE"
}

# ── Root check ─────────────────────────────────────────────────────────────
ensure_root() {
  [[ "${EUID}" -eq 0 ]] || die "This script must run as root.  Use: sudo bash $SCRIPT_NAME"
}

# ── Install Docker if missing ─────────────────────────────────────────────
setup_docker() {
  log "Checking for Docker …"

  if ! command -v curl &>/dev/null; then
    die "'curl' is required but not found. Install it first: apt install curl"
  fi

  if ! command -v docker &>/dev/null; then
    log "Docker not found — installing via official script …"
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "Failed to download Docker installer"
    sh /tmp/get-docker.sh >>"$LOG_FILE" 2>&1 || die "Docker installation failed"
    rm -f /tmp/get-docker.sh
    command -v docker &>/dev/null || die "Docker command still not found after install"
    ok "Docker installed"
  else
    ok "Docker is already installed"
  fi

  # Make sure daemon is running and enabled on boot
  if ! docker info &>/dev/null; then
    if command -v systemctl &>/dev/null; then
      log "Starting Docker daemon …"
      systemctl start docker &>/dev/null || die "Failed to start Docker"
      systemctl enable docker &>/dev/null || true
      docker info &>/dev/null || die "Docker still not responding"
    else
      die "Docker daemon is not running. Start it manually and re-run."
    fi
  fi

  # Enable on boot for 24/7 stability
  if command -v systemctl &>/dev/null; then
    systemctl enable docker &>/dev/null 2>&1 || true
  fi

  ok "Docker is running (enabled on boot)"
}

# ── System resource check ─────────────────────────────────────────────────
check_resources() {
  log "Checking system resources …"
  if command -v free &>/dev/null; then
    local avail
    avail="$(free -m | awk 'NR==2 {print $7}')"
    if [[ "$avail" =~ ^[0-9]+$ ]] && (( avail < 1024 )); then
      warn "Low memory: ${avail}MB available. Recommend at least 1GB free for stable operation."
    else
      ok "Memory OK (${avail}MB available)"
    fi
  fi

  local disk_avail
  disk_avail="$(df -BM / 2>/dev/null | awk 'NR==2 {gsub("M",""); print $4}' || true)"
  if [[ "$disk_avail" =~ ^[0-9]+$ ]] && (( disk_avail < 2048 )); then
    warn "Low disk space: ${disk_avail}MB free on /. Browser images need ~1-2GB."
  fi
}

# ── Browser selection ──────────────────────────────────────────────────────
pick_browser() {
  local choice="${BROWSER:-}"

  if [[ -z "$choice" ]]; then
    echo ""
    printf "  ${BOLD}Select a browser to install:${NC}\n\n"
    printf "    ${GREEN}1)${NC}  Chromium         ${DIM}— Lightweight, open-source Chrome base${NC}\n"
    printf "    ${GREEN}2)${NC}  Brave            ${DIM}— Privacy-first, built-in ad blocker${NC}\n"
    printf "    ${GREEN}3)${NC}  Firefox          ${DIM}— Classic, extension-rich (recommended)${NC}\n"
    printf "    ${GREEN}4)${NC}  Mullvad Browser  ${DIM}— Tor-based maximum privacy${NC}\n"
    printf "    ${GREEN}5)${NC}  Opera            ${DIM}— Feature-packed with free built-in VPN${NC}\n"
    echo ""

    if (( INTERACTIVE )); then
      while true; do
        read -rp "$(printf "  ${CYAN}Enter choice [1-5] (default 3): ${NC}")" choice
        choice="${choice:-3}"
        [[ "$choice" =~ ^[1-5]$ ]] && break
        warn "Invalid input — enter a number between 1 and 5"
      done
    else
      choice="3"
      warn "Non-interactive mode → defaulting to Firefox"
    fi
  fi

  case "$choice" in
    1) IMAGE="lscr.io/linuxserver/chromium:latest";        BR_NAME="Chromium";        BR_SLUG="chromium"  ;;
    2) IMAGE="lscr.io/linuxserver/brave:latest";           BR_NAME="Brave";           BR_SLUG="brave"     ;;
    3) IMAGE="lscr.io/linuxserver/firefox:latest";         BR_NAME="Firefox";         BR_SLUG="firefox"   ;;
    4) IMAGE="lscr.io/linuxserver/mullvad-browser:latest"; BR_NAME="Mullvad Browser"; BR_SLUG="mullvad"   ;;
    5) IMAGE="lscr.io/linuxserver/opera:latest";           BR_NAME="Opera";           BR_SLUG="opera"     ;;
    *) die "Invalid browser choice: $choice" ;;
  esac

  CONFIG_DIR="${CONFIG_DIR:-/opt/${CONTAINER_NAME}-${BR_SLUG}}"
  SHM_SIZE="${SHM_SIZE:-$DEFAULT_SHM}"
  ok "Selected: $BR_NAME"
}

# ── Credentials ────────────────────────────────────────────────────────────
get_creds() {
  # Username
  if [[ -z "${USERNAME:-}" ]]; then
    if (( INTERACTIVE )); then
      echo ""
      read -rp "$(printf "  ${CYAN}Username [browser]: ${NC}")" USERNAME
      USERNAME="${USERNAME:-browser}"
    else
      USERNAME="browser"
      warn "USERNAME not set — using default: browser"
    fi
  fi

  # Password
  if [[ -z "${PASSWORD:-}" ]]; then
    if (( INTERACTIVE )); then
      while true; do
        read -rsp "$(printf "  ${CYAN}Password (min 6 chars, hidden): ${NC}")" PASSWORD
        echo ""
        if [[ ${#PASSWORD} -ge 6 ]]; then
          break
        fi
        warn "Password must be at least 6 characters"
      done
    else
      die "PASSWORD must be set in config or environment for non-interactive mode"
    fi
  fi

  (( ${#USERNAME} >= 2 )) || die "Username must be at least 2 characters"
  (( ${#PASSWORD} >= 6 )) || die "Password must be at least 6 characters"

  ok "Credentials configured (user: $USERNAME)"
}

# ── Timezone ───────────────────────────────────────────────────────────────
detect_tz() {
  if [[ -n "${TIMEZONE:-}" ]]; then
    TZ_VAL="$TIMEZONE"
  else
    TZ_VAL="$(timedatectl show -p Timezone --value 2>/dev/null || true)"

    if [[ -z "$TZ_VAL" || "$TZ_VAL" == "n/a" ]]; then
      if [[ -L /etc/localtime ]]; then
        TZ_VAL="$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##' || true)"
      elif [[ -f /etc/timezone ]]; then
        TZ_VAL="$(tr -d '[:space:]' </etc/timezone)"
      fi
    fi

    TZ_VAL="${TZ_VAL:-Etc/UTC}"
  fi
  log "Timezone: $TZ_VAL"
}

# ── Port validation ────────────────────────────────────────────────────────
validate_ports() {
  for label_port in "PORT_HTTP:$PORT_HTTP" "PORT_HTTPS:$PORT_HTTPS"; do
    local label="${label_port%%:*}" port="${label_port##*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || die "$label must be a number (got: $port)"
    (( port >= 1 && port <= 65535 )) || die "$label must be 1-65535 (got: $port)"
  done

  [[ "$PORT_HTTP" != "$PORT_HTTPS" ]] || die "PORT_HTTP and PORT_HTTPS must be different"

  # Check if ports are already in use (skip if our container is using them)
  local existing_container=""
  existing_container="$(docker ps --format '{{.Names}}' --filter "name=$CONTAINER_NAME" 2>/dev/null || true)"

  if [[ -z "$existing_container" ]]; then
    for p in "$PORT_HTTP" "$PORT_HTTPS"; do
      if command -v ss &>/dev/null; then
        if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
          die "Port $p is already in use by another process"
        fi
      elif command -v netstat &>/dev/null; then
        if netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
          die "Port $p is already in use by another process"
        fi
      fi
    done
  fi

  ok "Ports $PORT_HTTP / $PORT_HTTPS validated"
}

# ── Firewall ───────────────────────────────────────────────────────────────
open_firewall() {
  log "Configuring firewall …"

  # Collect all ports to open
  local -a ports=("$PORT_HTTP" "$PORT_HTTPS")
  if (( USE_DNS )); then
    ports+=(80 443)
  fi

  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active"; then
    for p in "${ports[@]}"; do
      ufw allow "${p}/tcp" >>"$LOG_FILE" 2>&1 || true
    done
    ok "UFW: ports ${ports[*]} opened"
  elif command -v firewall-cmd &>/dev/null && firewall-cmd --state &>/dev/null 2>&1; then
    for p in "${ports[@]}"; do
      firewall-cmd --permanent --add-port="${p}/tcp" >>"$LOG_FILE" 2>&1 || true
    done
    firewall-cmd --reload >>"$LOG_FILE" 2>&1 || true
    ok "Firewalld: ports ${ports[*]} opened"
  else
    warn "No active firewall detected. Open ports ${ports[*]} in your cloud provider's firewall."
  fi
}

# ── Deploy browser container ──────────────────────────────────────────────
deploy() {
  # Clean up old container
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Removing existing container: $CONTAINER_NAME …"
    docker rm -f "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || warn "Could not remove old container"
  fi

  # Pull image
  log "Pulling $BR_NAME image ($IMAGE) …"
  if ! docker pull "$IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    die "Failed to pull image: $IMAGE"
  fi
  ok "Image pulled"

  # Config directory
  mkdir -p "$CONFIG_DIR"
  chown "$PUID:$PGID" "$CONFIG_DIR" 2>/dev/null || true

  # Build docker run args
  echo ""
  log "Deploying $BR_NAME container (network: $NETWORK_MODE) …"

  local -a args=(
    run -d
    --name "$CONTAINER_NAME"
    --security-opt seccomp=unconfined
    -e PUID="$PUID"
    -e PGID="$PGID"
    -e TZ="$TZ_VAL"
    -e CUSTOM_USER="$USERNAME"
    -e PASSWORD="$PASSWORD"
    -v "$CONFIG_DIR:/config"
    --shm-size="$SHM_SIZE"
    --restart unless-stopped
  )

  if [[ "$NETWORK_MODE" == "host" ]]; then
    args+=(--network host)
  else
    args+=(-p "$PORT_HTTP:3000" -p "$PORT_HTTPS:3001")
  fi

  # IPv6 handling
  if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
    if [[ "$(tr -d '[:space:]' </proc/sys/net/ipv6/conf/all/disable_ipv6)" == "1" ]]; then
      args+=(-e DISABLE_IPV6=true)
      log "Host IPv6 disabled → container IPv6 disabled too"
    fi
  fi

  args+=("$IMAGE")

  if ! docker "${args[@]}" >>"$LOG_FILE" 2>&1; then
    die "Failed to start container"
  fi
  ok "Container started"

  # Bridge fallback: if ports not published, retry with host networking
  if [[ "$NETWORK_MODE" == "bridge" ]]; then
    sleep 2
    local ports_json
    ports_json="$(docker inspect -f '{{json .NetworkSettings.Ports}}' "$CONTAINER_NAME" 2>/dev/null || true)"
    if [[ "$ports_json" != *"3000/tcp"* && "$ports_json" != *"3001/tcp"* ]]; then
      warn "Bridge networking failed to publish ports — retrying with host networking …"
      docker rm -f "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || die "Cannot remove container for retry"
      NETWORK_MODE="host"
      deploy
      return
    fi
  fi
}

# ── Watchtower auto-updater ───────────────────────────────────────────────
setup_watchtower() {
  local do_wt="${WATCHTOWER:-}"

  if [[ -z "$do_wt" ]]; then
    if (( INTERACTIVE )); then
      echo ""
      read -rp "$(printf "  ${CYAN}Enable auto-updates via Watchtower? [Y/n]: ${NC}")" do_wt
      do_wt="${do_wt:-y}"
    else
      do_wt="y"
    fi
  fi

  if [[ "${do_wt,,}" =~ ^(y|yes)$ ]]; then
    if docker ps --format '{{.Names}}' | grep -qx "watchtower"; then
      ok "Watchtower is already running"
      return
    fi

    # Remove stopped watchtower if exists
    docker rm -f watchtower >>"$LOG_FILE" 2>&1 || true

    log "Deploying Watchtower (auto-updates every 24h) …"
    if docker run -d \
      --name watchtower \
      --restart unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock \
      containrrr/watchtower \
      --cleanup --interval 86400 >>"$LOG_FILE" 2>&1; then
      ok "Watchtower active — browser image will auto-update daily"
    else
      warn "Watchtower failed to deploy (non-critical — browser still works)"
    fi
  else
    log "Watchtower skipped"
  fi
}

# ── Optional DNS / SSL setup (Caddy reverse proxy) ───────────────────────
setup_dns() {
  local do_dns="${DOMAIN:+y}"

  if [[ -z "$do_dns" ]] && (( INTERACTIVE )); then
    echo ""
    read -rp "$(printf "  ${CYAN}Set up a custom domain with free SSL? [y/N]: ${NC}")" do_dns
    do_dns="${do_dns:-n}"
  fi

  if [[ "${do_dns,,}" =~ ^(y|yes)$ ]]; then
    USE_DNS=1

    # Get domain if not already set
    if [[ -z "$DOMAIN" ]]; then
      while true; do
        read -rp "$(printf "  ${CYAN}Enter your domain (e.g. browser.example.com): ${NC}")" DOMAIN
        if [[ -n "$DOMAIN" && "$DOMAIN" == *.* ]]; then
          break
        fi
        warn "Please enter a valid domain name (e.g. browser.example.com)"
      done
    fi

    log "Setting up Caddy reverse proxy for $DOMAIN …"

    # Create Caddy config directory
    local caddy_dir="/opt/caddy-browser"
    mkdir -p "$caddy_dir/data" "$caddy_dir/config"

    # Write Caddyfile — reverse proxy HTTPS to the browser's KasmVNC
    cat > "${caddy_dir}/Caddyfile" <<CADDYEOF
${DOMAIN} {
    reverse_proxy 127.0.0.1:${PORT_HTTPS} {
        transport http {
            tls
            tls_insecure_skip_verify
        }
    }
}
CADDYEOF

    ok "Caddyfile written to ${caddy_dir}/Caddyfile"

    # Remove old caddy container if exists
    docker rm -f caddy-browser >>"$LOG_FILE" 2>&1 || true

    # Open ports 80/443 for Caddy (needed for Let's Encrypt)
    open_firewall

    # Deploy Caddy
    log "Deploying Caddy container …"
    if docker run -d \
      --name caddy-browser \
      --restart unless-stopped \
      --network host \
      -v "${caddy_dir}/Caddyfile:/etc/caddy/Caddyfile:ro" \
      -v "${caddy_dir}/data:/data" \
      -v "${caddy_dir}/config:/config" \
      caddy:2-alpine >>"$LOG_FILE" 2>&1; then
      ok "Caddy is running — SSL will auto-provision for $DOMAIN"
    else
      warn "Caddy failed to deploy. You can still access via IP with self-signed cert."
      USE_DNS=0
      DOMAIN=""
    fi

    if (( USE_DNS )); then
      echo ""
      printf "  ${YELLOW}⚠  Make sure your DNS is configured:${NC}\n"
      get_ip
      printf "  ${BOLD}   → Add an A record: ${CYAN}%s${NC} → ${CYAN}%s${NC}\n" "$DOMAIN" "$IP"
      printf "  ${DIM}   (at your domain registrar / Cloudflare / etc.)${NC}\n"
      echo ""
    fi
  else
    log "DNS/SSL setup skipped"
  fi
}

# ── Wait for service to be ready ──────────────────────────────────────────
wait_ready() {
  local waited=0
  log "Waiting for $BR_NAME to become ready (max ${STARTUP_TIMEOUT}s) …"

  while (( waited < STARTUP_TIMEOUT )); do
    local state
    state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"

    if [[ "$state" == "exited" || "$state" == "dead" ]]; then
      warn "Container died during startup. Last 30 log lines:"
      docker logs --tail 30 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
      die "Container exited before becoming ready"
    fi

    if [[ "$state" == "running" ]]; then
      # Try HTTPS first, then HTTP
      local code
      code="$(curl -kLsS -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:${PORT_HTTPS}" 2>/dev/null || true)"
      if [[ -n "$code" && "$code" != "000" ]]; then
        ok "Service is live on HTTPS port $PORT_HTTPS"
        return
      fi

      code="$(curl -LsS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT_HTTP}" 2>/dev/null || true)"
      if [[ -n "$code" && "$code" != "000" ]]; then
        ok "Service is live on HTTP port $PORT_HTTP"
        return
      fi
    fi

    sleep 3
    waited=$((waited + 3))
    # Progress indicator every 15 seconds
    if (( waited % 15 == 0 )); then
      printf "  ${DIM}… still waiting (%ds / %ds)${NC}\n" "$waited" "$STARTUP_TIMEOUT"
    fi
  done

  warn "Service did not respond within ${STARTUP_TIMEOUT}s. Dumping diagnostics:"
  docker ps -a --filter "name=${CONTAINER_NAME}" 2>&1 | tee -a "$LOG_FILE" || true
  docker port "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
  docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
  die "Browser never became reachable on ports ${PORT_HTTP}/${PORT_HTTPS}"
}

# ── Get public IP ─────────────────────────────────────────────────────────
get_ip() {
  local svc
  for svc in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
    IP="$(curl -fsS --max-time "$IP_FETCH_TIMEOUT" "$svc" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ -n "$IP" ]] && return
  done
  IP="<your-server-ip>"
  warn "Could not auto-detect public IP"
}

# ── Final summary ─────────────────────────────────────────────────────────
show_summary() {
  get_ip

  local wt_status="Disabled"
  docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "watchtower" && wt_status="Enabled (daily)"

  local dns_status="Not configured"
  local primary_url="https://${IP}:${PORT_HTTPS}"
  if (( USE_DNS )) && [[ -n "$DOMAIN" ]]; then
    dns_status="$DOMAIN (Caddy + Let's Encrypt)"
    primary_url="https://${DOMAIN}"
  fi

  echo ""
  printf "${GREEN}${BOLD}"
  cat <<'ART'
  ╔══════════════════════════════════════════════════╗
  ║          ✅  Installation Complete!              ║
  ╚══════════════════════════════════════════════════╝
ART
  printf "${NC}\n"
  printf "  ${BOLD}Browser${NC}       ${GREEN}%s${NC}\n" "$BR_NAME"
  printf "  ${BOLD}Username${NC}      %s\n" "$USERNAME"

  if (( USE_DNS )) && [[ -n "$DOMAIN" ]]; then
    printf "  ${BOLD}🌐 Domain URL${NC}  ${CYAN}https://%s${NC}  ${GREEN}← use this (valid SSL)${NC}\n" "$DOMAIN"
    printf "  ${BOLD}IP URL${NC}        ${DIM}https://%s:%s (self-signed fallback)${NC}\n" "$IP" "$PORT_HTTPS"
  else
    printf "  ${BOLD}Access URL${NC}    ${CYAN}https://%s:%s${NC}\n" "$IP" "$PORT_HTTPS"
    printf "  ${BOLD}HTTP URL${NC}      http://%s:%s\n" "$IP" "$PORT_HTTP"
  fi

  printf "  ${BOLD}Container${NC}     %s\n" "$CONTAINER_NAME"
  printf "  ${BOLD}Config Dir${NC}    %s\n" "$CONFIG_DIR"
  printf "  ${BOLD}Network${NC}       %s\n" "$NETWORK_MODE"
  printf "  ${BOLD}Auto-Update${NC}   %s\n" "$wt_status"
  printf "  ${BOLD}DNS / SSL${NC}     %s\n" "$dns_status"
  printf "  ${BOLD}Timezone${NC}      %s\n" "$TZ_VAL"
  echo ""

  if (( USE_DNS )) && [[ -n "$DOMAIN" ]]; then
    printf "  ${GREEN}✓  No SSL warnings — valid certificate via Let's Encrypt${NC}\n"
    printf "  ${YELLOW}⚠  DNS A record must point %s → %s${NC}\n" "$DOMAIN" "$IP"
  else
    printf "  ${YELLOW}⚠  Accept the self-signed SSL warning on first visit${NC}\n"
  fi

  printf "  ${YELLOW}⚠  Open required ports in your cloud firewall if needed${NC}\n"
  echo ""
  printf "  ${BOLD}Useful commands:${NC}\n"
  printf "    ${DIM}docker logs -f %s${NC}       ${DIM}# browser logs${NC}\n" "$CONTAINER_NAME"
  printf "    ${DIM}docker restart %s${NC}        ${DIM}# restart browser${NC}\n" "$CONTAINER_NAME"
  if (( USE_DNS )); then
    printf "    ${DIM}docker logs -f caddy-browser${NC}  ${DIM}# Caddy/SSL logs${NC}\n"
  fi
  printf "    ${DIM}docker rm -f %s${NC}          ${DIM}# remove (re-run to change settings)${NC}\n" "$CONTAINER_NAME"
  echo ""

  log "Installation complete — $primary_url"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  banner
  log "Installation started ($(date))"
  ensure_root
  load_config
  setup_docker
  check_resources
  pick_browser
  get_creds
  detect_tz
  validate_ports
  open_firewall
  deploy
  setup_watchtower
  setup_dns
  wait_ready
  show_summary
}

main "$@"
