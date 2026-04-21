#!/bin/bash

set -euo pipefail  # Exit on error, undefined vars, pipe failures

# ===== CONFIGURATION =====
CONFIG_FILE="${1:-.browser-config}"
LOG_FILE="browser_installer_$(date +%s).log"
CONTAINER_NAME="browser"
DEFAULT_SHM_SIZE="2gb"
IP_FETCH_TIMEOUT=10
IP_FETCH_RETRIES=3

# ===== LOGGING SETUP =====
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
  echo "❌ [ERROR] $*" | tee -a "$LOG_FILE" >&2
  exit 1
}

warning() {
  echo "⚠️  [WARNING] $*" | tee -a "$LOG_FILE"
}

success() {
  echo "✅ $*" | tee -a "$LOG_FILE"
}

# ===== HEADER =====
clear
echo "======================================="
echo "   O3DN Browser VPS Installer 🚀"
echo "======================================="
echo "Log file: $LOG_FILE"
log "Installation started"

# ===== COMMAND HELP =====
show_help() {
  cat << EOF
Usage: $0 [config_file]

Options:
  [config_file]    Path to config file (default: .browser-config)
                   If provided, uses config instead of interactive input
  --help, -h       Show this help message

Config file format:
  BROWSER=1        (1=Chromium, 2=Brave, 3=Firefox)
  USERNAME=myuser
  PASSWORD=mypass
  SHM_SIZE=2gb
  PORT_GUAC=3000
  PORT_HTTPS=3001
  TIMEZONE=        (leave empty for auto-detect)

EOF
  exit 0
}

[[ "$*" == *"--help"* ]] || [[ "$*" == *"-h"* ]] && show_help

# ===== ROOT CHECK =====
if [ "$EUID" -ne 0 ]; then
  error "This script must run as root (use: sudo $0)"
fi

# ===== DEPENDENCY CHECK =====
log "Checking dependencies..."
for cmd in curl docker; do
  if ! command -v "$cmd" &> /dev/null; then
    error "Required command not found: $cmd"
  fi
done
success "Dependencies found"

# ===== DOCKER INSTALLATION =====
log "Checking Docker installation..."
if ! docker info &> /dev/null; then
  warning "Docker daemon not responding, attempting to start..."
  systemctl start docker || error "Failed to start Docker"
fi
success "Docker is running"

# ===== PULL IMAGES TO CHECK CONNECTIVITY =====
log "Verifying Docker connectivity..."
if ! docker pull hello-world 2>&1 | tee -a "$LOG_FILE" > /dev/null; then
  error "Cannot reach Docker registry. Check internet connection."
fi
docker rmi hello-world 2>/dev/null || true

# ===== REMOVE OLD CONTAINER =====
if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
  log "Removing old container: $CONTAINER_NAME"
  docker rm -f "$CONTAINER_NAME" >> "$LOG_FILE" 2>&1 || warning "Could not remove container"
fi

# ===== INPUT METHOD: CONFIG FILE OR INTERACTIVE =====
if [ -f "$CONFIG_FILE" ] && [ "$CONFIG_FILE" != ".browser-config" ]; then
  log "Loading configuration from: $CONFIG_FILE"
  # shellcheck source=/dev/null
  source "$CONFIG_FILE" || error "Failed to source config file"
  BROWSER="${BROWSER:-}"
  USERNAME="${USERNAME:-}"
  PASSWORD="${PASSWORD:-}"
  TIMEZONE="${TIMEZONE:-}"
else
  # Interactive mode
  BROWSER=""
  USERNAME=""
  PASSWORD=""
  TIMEZONE=""
fi

# ===== BROWSER SELECTION =====
if [ -z "$BROWSER" ]; then
  echo ""
  echo "Select browser to install:"
  echo "1) Chromium"
  echo "2) Brave"
  echo "3) Firefox"
  while true; do
    read -p "Enter choice (1/2/3): " BROWSER
    if [[ "$BROWSER" =~ ^[1-3]$ ]]; then
      break
    else
      warning "Invalid choice. Please enter 1, 2, or 3."
    fi
  done
fi

case "$BROWSER" in
  1)
    IMAGE="lscr.io/linuxserver/chromium:latest"
    NAME="Chromium"
    ;;
  2)
    IMAGE="lscr.io/linuxserver/brave:latest"
    NAME="Brave"
    ;;
  3)
    IMAGE="lscr.io/linuxserver/firefox:latest"
    NAME="Firefox"
    ;;
  *)
    error "Invalid browser choice: $BROWSER"
    ;;
esac
log "Selected browser: $NAME ($IMAGE)"

# ===== CREDENTIALS INPUT =====
if [ -z "$USERNAME" ]; then
  echo ""
  read -p "Enter username [default: browser]: " USERNAME
  USERNAME="${USERNAME:-browser}"
fi

if [ -z "$PASSWORD" ]; then
  read -s -p "Enter password (hidden): " PASSWORD
  echo ""
  if [ -z "$PASSWORD" ]; then
    error "Password cannot be empty"
  fi
fi

# Validate credentials length
if [ ${#USERNAME} -lt 2 ]; then
  error "Username must be at least 2 characters"
fi
if [ ${#PASSWORD} -lt 6 ]; then
  error "Password must be at least 6 characters"
fi

log "Credentials configured: username=$USERNAME"

# ===== TIMEZONE DETECTION =====
if [ -z "$TIMEZONE" ]; then
  TIMEZONE=$(timedatectl 2>/dev/null | grep "Time zone" | awk '{print $3}' || echo "")
  TIMEZONE="${TIMEZONE:-Etc/UTC}"
fi
log "Timezone: $TIMEZONE"

# ===== SYSTEM RESOURCE CHECK =====
log "Checking system resources..."
AVAILABLE_MEM=$(free -g | awk 'NR==2 {print $7}')
if [ "$AVAILABLE_MEM" -lt 2 ]; then
  warning "Low available memory: ${AVAILABLE_MEM}GB. Container needs ~2GB."
fi

# ===== DOCKER IMAGE PULL =====
log "Pulling Docker image: $IMAGE"
if ! docker pull "$IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
  error "Failed to pull Docker image: $IMAGE"
fi
success "Image pulled successfully"

# ===== DEPLOYMENT =====
echo ""
log "Deploying $NAME browser container..."

SHM_SIZE="${SHM_SIZE:-$DEFAULT_SHM_SIZE}"
PORT_GUAC="${PORT_GUAC:-3000}"
PORT_HTTPS="${PORT_HTTPS:-3001}"

if ! docker run -d \
  --name="$CONTAINER_NAME" \
  --security-opt seccomp=unconfined \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ="$TIMEZONE" \
  -e CUSTOM_USER="$USERNAME" \
  -e PASSWORD="$PASSWORD" \
  -p "$PORT_GUAC:3000" \
  -p "$PORT_HTTPS:3001" \
  --shm-size="$SHM_SIZE" \
  --restart unless-stopped \
  --health-cmd="curl -f http://localhost:3001 || exit 1" \
  --health-interval=30s \
  --health-timeout=10s \
  --health-retries=3 \
  "$IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
  error "Failed to start Docker container"
fi

log "Container started successfully"

# ===== WAIT FOR CONTAINER STARTUP =====
log "Waiting for container to initialize (max 30s)..."
WAIT_TIME=0
while [ $WAIT_TIME -lt 30 ]; do
  if docker exec "$CONTAINER_NAME" true 2>/dev/null; then
    log "Container is responsive"
    break
  fi
  sleep 2
  WAIT_TIME=$((WAIT_TIME + 2))
done

# ===== GET PUBLIC IP =====
log "Retrieving public IP address..."
IP=""
for ((i=1; i<=IP_FETCH_RETRIES; i++)); do
  IP=$(curl -s --max-time "$IP_FETCH_TIMEOUT" ifconfig.me 2>/dev/null || echo "")
  if [ -n "$IP" ]; then
    break
  fi
  if [ $i -lt $IP_FETCH_RETRIES ]; then
    warning "IP retrieval attempt $i failed, retrying..."
    sleep 2
  fi
done

if [ -z "$IP" ]; then
  warning "Could not retrieve public IP. Using 'localhost' instead."
  IP="localhost"
else
  success "Public IP: $IP"
fi

# ===== DISPLAY RESULTS =====
echo ""
echo "======================================="
success "Installation Complete!"
echo "======================================="
echo "🌐 Browser: $NAME"
echo "👤 Username: $USERNAME"
echo "🔐 Access URL: https://$IP:$PORT_HTTPS"
echo "🕐 Timezone: $TIMEZONE"
echo ""
echo "⚠️  Accept the SSL warning (self-signed certificate)"
echo "📝 Log file: $LOG_FILE"
echo "======================================="

log "Installation completed successfully"
log "Container name: $CONTAINER_NAME"
log "Access: https://$IP:$PORT_HTTPS"
