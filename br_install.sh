#!/bin/bash

set -euo pipefail

# ===== CONFIGURATION =====
LOG_FILE="browser_installer_$(date +%s).log"
CONTAINER_NAME="browser"

# ===== LOGGING =====
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"; }
error() { echo "❌ [ERROR] $*" | tee -a "$LOG_FILE" >&2; exit 1; }
warning() { echo "⚠️  [WARNING] $*" | tee -a "$LOG_FILE"; }
success() { echo "✅ $*" | tee -a "$LOG_FILE"; }

# ===== HEADER =====
clear
echo "======================================="
echo "   O3DN Browser VPS Installer 🚀"
echo "======================================="
echo "Log file: $LOG_FILE"
log "Installation started"

# ===== ROOT CHECK =====
[ "$EUID" -eq 0 ] || error "Must run as root (use: sudo)"

# ===== CHECK DEPENDENCIES =====
log "Checking dependencies..."
for cmd in curl docker; do
  command -v "$cmd" &>/dev/null || error "Required: $cmd"
done
success "Dependencies found"

# ===== DOCKER CHECK =====
log "Checking Docker..."
docker info &>/dev/null || { systemctl start docker || error "Failed to start Docker"; }
success "Docker is running"

# ===== VERIFY CONNECTIVITY =====
log "Verifying Docker connectivity..."
docker pull hello-world &>/dev/null || error "Cannot reach Docker registry"
docker rmi hello-world 2>/dev/null || true

# ===== REMOVE OLD CONTAINER =====
docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" && {
  log "Removing old container: $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
}

# ===== GET CONFIG FROM ENV OR ARGS =====
CONFIG_FILE="${1:-.browser-config}"
[ -f "$CONFIG_FILE" ] && [ "$CONFIG_FILE" != ".browser-config" ] && {
  log "Loading config from: $CONFIG_FILE"
  source "$CONFIG_FILE" || error "Failed to load config"
}

# Load from environment with defaults
BROWSER="${BROWSER:-}"
USERNAME="${USERNAME:-}"
PASSWORD="${PASSWORD:-}"
TIMEZONE="${TIMEZONE:-}"
SHM_SIZE="${SHM_SIZE:-2gb}"
PORT_GUAC="${PORT_GUAC:-3000}"
PORT_HTTPS="${PORT_HTTPS:-3001}"

# ===== BROWSER SELECTION =====
if [ -z "$BROWSER" ]; then
  if [ -t 0 ]; then
    echo ""
    echo "Select browser to install:"
    echo "1) Chromium  2) Brave  3) Firefox"
    read -p "Enter choice (1/2/3) [1]: " BROWSER || BROWSER=""
    BROWSER="${BROWSER:-1}"
  else
    log "Non-interactive mode: using Chromium"
    BROWSER="1"
  fi
fi

[[ "$BROWSER" =~ ^[1-3]$ ]] || error "Invalid browser: $BROWSER"

case "$BROWSER" in
  1) IMAGE="lscr.io/linuxserver/chromium:latest"; NAME="Chromium" ;;
  2) IMAGE="lscr.io/linuxserver/brave:latest"; NAME="Brave" ;;
  3) IMAGE="lscr.io/linuxserver/firefox:latest"; NAME="Firefox" ;;
esac
log "Selected: $NAME ($IMAGE)"

# ===== CREDENTIALS =====
if [ -z "$USERNAME" ]; then
  if [ -t 0 ]; then
    read -p "Username [browser]: " USERNAME || USERNAME=""
  else
    log "Using default username: browser"
  fi
  USERNAME="${USERNAME:-browser}"
fi

if [ -z "$PASSWORD" ]; then
  if [ -t 0 ]; then
    read -s -p "Password [min 6 chars]: " PASSWORD || PASSWORD=""
    echo ""
  else
    error "PASSWORD required in non-interactive mode"
  fi
fi

[ -z "$PASSWORD" ] && error "Password cannot be empty"
[ ${#USERNAME} -lt 2 ] && error "Username too short (min 2)"
[ ${#PASSWORD} -lt 6 ] && error "Password too short (min 6)"
log "Credentials: $USERNAME"

# ===== TIMEZONE =====
[ -z "$TIMEZONE" ] && TIMEZONE=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "Etc/UTC")
log "Timezone: $TIMEZONE"

# ===== RESOURCES =====
log "Checking resources..."
AVAIL_MEM=$(free -g 2>/dev/null | awk 'NR==2 {print $7}' || echo "0")
[ "$AVAIL_MEM" -lt 2 ] && warning "Low memory: ${AVAIL_MEM}GB (needs 2GB)"

# ===== PULL IMAGE =====
log "Pulling image: $IMAGE"
docker pull "$IMAGE" >/dev/null 2>&1 || error "Failed to pull $IMAGE"
success "Image ready"

# ===== DEPLOY =====
echo ""
log "Deploying container..."
docker run -d \
  --name="$CONTAINER_NAME" \
  --security-opt seccomp=unconfined \
  -e PUID=1000 -e PGID=1000 \
  -e TZ="$TIMEZONE" \
  -e CUSTOM_USER="$USERNAME" \
  -e PASSWORD="$PASSWORD" \
  -p "$PORT_GUAC:3000" -p "$PORT_HTTPS:3001" \
  --shm-size="$SHM_SIZE" \
  --restart unless-stopped \
  "$IMAGE" >/dev/null 2>&1 || error "Failed to start container"
log "Container started"

# ===== WAIT FOR STARTUP =====
log "Waiting for container (max 30s)..."
for i in {1..15}; do
  docker exec "$CONTAINER_NAME" true 2>/dev/null && break
  sleep 2
done

# ===== GET PUBLIC IP =====
log "Getting public IP..."
IP=""
for i in {1..3}; do
  IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || echo "")
  [ -n "$IP" ] && break
  [ $i -lt 3 ] && sleep 2
done
IP="${IP:-localhost}"

# ===== RESULTS =====
echo ""
echo "======================================="
success "Installation Complete!"
echo "======================================="
echo "🌐 Browser: $NAME"
echo "👤 Username: $USERNAME"
echo "🔐 Access: https://$IP:$PORT_HTTPS"
echo "🕐 Timezone: $TIMEZONE"
echo ""
echo "⚠️  Accept SSL warning (self-signed certificate)"
echo "📝 Log: $LOG_FILE"
echo "======================================="

log "✅ Ready at https://$IP:$PORT_HTTPS"
