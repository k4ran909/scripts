#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
DEFAULT_CONFIG_FILE=".browser-config"
CONFIG_FILE="$DEFAULT_CONFIG_FILE"
EXPLICIT_CONFIG=0

LOG_FILE="browser_installer_$(date +%Y%m%d_%H%M%S).log"
CONTAINER_NAME="${CONTAINER_NAME:-browser}"
DEFAULT_SHM_SIZE="2gb"
IP_FETCH_TIMEOUT=5
STARTUP_TIMEOUT=180
INTERACTIVE=0
FAILED=0
SERVICE_URL=""

if [[ -t 0 && -t 1 ]]; then
  INTERACTIVE=1
fi

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE"
}

error() {
  FAILED=1
  printf '[ERROR] %s\n' "$*" | tee -a "$LOG_FILE" >&2
  exit 1
}

warning() {
  printf '[WARN] %s\n' "$*" | tee -a "$LOG_FILE"
}

success() {
  printf '[OK] %s\n' "$*" | tee -a "$LOG_FILE"
}

show_help() {
  cat <<EOF
Usage: $SCRIPT_NAME [config_file]
       $SCRIPT_NAME --config /path/to/config

Options:
  [config_file]      Path to config file (default: .browser-config)
  -c, --config FILE  Explicit config file path
  -h, --help         Show this help message

Supported config values:
  BROWSER=1          1=Chromium, 2=Brave, 3=Firefox
  USERNAME=browser
  PASSWORD=strong-password
  SHM_SIZE=2gb
  PORT_GUAC=3000
  PORT_HTTPS=3001
  TIMEZONE=Etc/UTC
  CONFIG_DIR=/opt/browser-firefox
  PUID=1000
  PGID=1000
EOF
  exit 0
}

cleanup() {
  local exit_code=$?

  if (( exit_code != 0 && FAILED == 0 )); then
    warning "Installer exited with status ${exit_code}. Review ${LOG_FILE} for details."
  fi
}

trap cleanup EXIT

parse_args() {
  while (($#)); do
    case "$1" in
      -h|--help)
        show_help
        ;;
      -c|--config)
        shift
        [[ $# -gt 0 ]] || error "Missing value for --config"
        CONFIG_FILE="$1"
        EXPLICIT_CONFIG=1
        ;;
      -*)
        error "Unknown option: $1"
        ;;
      *)
        if (( EXPLICIT_CONFIG )); then
          error "Unexpected extra argument: $1"
        fi
        CONFIG_FILE="$1"
        EXPLICIT_CONFIG=1
        ;;
    esac
    shift
  done
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || error "Required command not found: $1"
}

install_docker() {
  local installer="/tmp/get-docker.sh"

  log "Docker not found. Installing Docker with the official convenience script..."

  curl -fsSL "https://get.docker.com" -o "$installer" || error "Failed to download the Docker installer"
  sh "$installer" >>"$LOG_FILE" 2>&1 || error "Docker installation failed"
  rm -f "$installer"

  need_cmd docker
  success "Docker installed successfully"
}

open_firewall_ports() {
  log "Checking firewall rules for ports ${PORT_GUAC} and ${PORT_HTTPS}..."

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "^Status: active"; then
      ufw allow "${PORT_GUAC}/tcp" >>"$LOG_FILE" 2>&1 || warning "Failed to open ${PORT_GUAC}/tcp in ufw"
      ufw allow "${PORT_HTTPS}/tcp" >>"$LOG_FILE" 2>&1 || warning "Failed to open ${PORT_HTTPS}/tcp in ufw"
      success "ufw rules updated"
      return
    fi
  fi

  if command -v firewall-cmd >/dev/null 2>&1; then
    if firewall-cmd --state >/dev/null 2>&1; then
      firewall-cmd --permanent --add-port="${PORT_GUAC}/tcp" >>"$LOG_FILE" 2>&1 || warning "Failed to open ${PORT_GUAC}/tcp in firewalld"
      firewall-cmd --permanent --add-port="${PORT_HTTPS}/tcp" >>"$LOG_FILE" 2>&1 || warning "Failed to open ${PORT_HTTPS}/tcp in firewalld"
      firewall-cmd --reload >>"$LOG_FILE" 2>&1 || warning "Failed to reload firewalld"
      success "firewalld rules updated"
      return
    fi
  fi

  warning "No supported active host firewall manager detected. If your VPS provider has a cloud firewall, open TCP ports ${PORT_GUAC} and ${PORT_HTTPS} there too."
}

validate_positive_integer() {
  local value="$1"
  local label="$2"

  [[ "$value" =~ ^[0-9]+$ ]] || error "${label} must be a positive integer"
}

validate_port() {
  local port="$1"
  local label="$2"

  validate_positive_integer "$port" "$label"
  (( port >= 1 && port <= 65535 )) || error "${label} must be between 1 and 65535"
}

port_in_use() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -ltn | awk '{print $4}' | grep -Eq "[:.]${port}$"
    return
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    return
  fi

  return 1
}

load_config() {
  BROWSER="${BROWSER:-}"
  USERNAME="${USERNAME:-}"
  PASSWORD="${PASSWORD:-}"
  TIMEZONE="${TIMEZONE:-}"
  SHM_SIZE="${SHM_SIZE:-$DEFAULT_SHM_SIZE}"
  PORT_GUAC="${PORT_GUAC:-3000}"
  PORT_HTTPS="${PORT_HTTPS:-3001}"
  CONFIG_DIR="${CONFIG_DIR:-}"
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"

  if [[ -f "$CONFIG_FILE" ]]; then
    log "Loading configuration from: $CONFIG_FILE"
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
  elif (( EXPLICIT_CONFIG )); then
    error "Config file not found: $CONFIG_FILE"
  else
    log "No config file found at $CONFIG_FILE. Continuing with prompts/defaults."
  fi

  BROWSER="${BROWSER:-}"
  USERNAME="${USERNAME:-}"
  PASSWORD="${PASSWORD:-}"
  TIMEZONE="${TIMEZONE:-}"
  SHM_SIZE="${SHM_SIZE:-$DEFAULT_SHM_SIZE}"
  PORT_GUAC="${PORT_GUAC:-3000}"
  PORT_HTTPS="${PORT_HTTPS:-3001}"
  CONFIG_DIR="${CONFIG_DIR:-}"
  PUID="${PUID:-1000}"
  PGID="${PGID:-1000}"
}

print_banner() {
  if command -v clear >/dev/null 2>&1 && (( INTERACTIVE )); then
    clear
  fi

  cat <<EOF
=======================================
   O3DN Browser VPS Installer
=======================================
Log file: $LOG_FILE
EOF
}

ensure_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    error "This script must run as root (use: sudo $SCRIPT_NAME)"
  fi
}

check_dependencies() {
  log "Checking dependencies..."

  need_cmd curl

  if ! command -v docker >/dev/null 2>&1; then
    install_docker
  fi

  success "Required commands are available"
}

ensure_docker_running() {
  log "Checking Docker daemon..."

  if docker info >/dev/null 2>&1; then
    success "Docker is running"
    return
  fi

  if command -v systemctl >/dev/null 2>&1; then
    warning "Docker daemon not responding. Attempting to start docker.service..."
    systemctl start docker >/dev/null 2>&1 || error "Failed to start Docker with systemctl"

    docker info >/dev/null 2>&1 || error "Docker is still unavailable after starting docker.service"
    success "Docker is running"
    return
  fi

  error "Docker daemon is not available. Start Docker manually and rerun the script."
}

remove_old_container() {
  if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    log "Removing old container: $CONTAINER_NAME"
    docker rm -f "$CONTAINER_NAME" >>"$LOG_FILE" 2>&1 || warning "Could not remove existing container"
  fi
}

prompt_for_browser() {
  if [[ -n "$BROWSER" ]]; then
    return
  fi

  echo
  echo "Select browser to install:"
  echo "1) Chromium"
  echo "2) Brave"
  echo "3) Firefox"

  if (( INTERACTIVE )); then
    while true; do
      read -r -p "Enter choice (1/2/3) [3]: " BROWSER
      BROWSER="${BROWSER:-3}"

      if [[ "$BROWSER" =~ ^[1-3]$ ]]; then
        break
      fi

      warning "Invalid choice. Please enter 1, 2, or 3."
    done
  else
    warning "Non-interactive mode detected. Defaulting to Firefox."
    BROWSER="3"
  fi
}

set_browser_image() {
  case "$BROWSER" in
    1)
      IMAGE="lscr.io/linuxserver/chromium:latest"
      NAME="Chromium"
      BROWSER_SLUG="chromium"
      ;;
    2)
      IMAGE="lscr.io/linuxserver/brave:latest"
      NAME="Brave"
      BROWSER_SLUG="brave"
      ;;
    3)
      IMAGE="lscr.io/linuxserver/firefox:latest"
      NAME="Firefox"
      BROWSER_SLUG="firefox"
      ;;
    *)
      error "Invalid browser choice: $BROWSER"
      ;;
  esac

  if [[ -z "$CONFIG_DIR" ]]; then
    CONFIG_DIR="/opt/${CONTAINER_NAME}-${BROWSER_SLUG}"
  fi

  log "Selected browser: $NAME ($IMAGE)"
}

configure_credentials() {
  if [[ -z "$USERNAME" ]]; then
    if (( INTERACTIVE )); then
      echo
      read -r -p "Enter username [browser]: " USERNAME
      USERNAME="${USERNAME:-browser}"
    else
      USERNAME="browser"
      warning "USERNAME not provided. Using default: $USERNAME"
    fi
  fi

  if [[ -z "$PASSWORD" ]]; then
    if (( INTERACTIVE )); then
      while [[ -z "$PASSWORD" ]]; do
        read -r -s -p "Enter password (hidden): " PASSWORD
        echo

        if [[ -z "$PASSWORD" ]]; then
          warning "Password cannot be empty."
        fi
      done
    else
      error "PASSWORD must be set in the config file or environment for non-interactive runs"
    fi
  fi

  (( ${#USERNAME} >= 2 )) || error "Username must be at least 2 characters"
  (( ${#PASSWORD} >= 6 )) || error "Password must be at least 6 characters"

  log "Credentials configured: username=$USERNAME"
}

detect_timezone() {
  local detected_timezone=""

  if [[ -n "$TIMEZONE" ]]; then
    log "Timezone: $TIMEZONE"
    return
  fi

  if command -v timedatectl >/dev/null 2>&1; then
    detected_timezone="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  fi

  if [[ -z "$detected_timezone" || "$detected_timezone" == "n/a" ]]; then
    if [[ -L /etc/localtime ]]; then
      detected_timezone="$(readlink /etc/localtime 2>/dev/null | sed 's#^.*/zoneinfo/##' || true)"
    elif [[ -f /etc/timezone ]]; then
      detected_timezone="$(tr -d '[:space:]' </etc/timezone)"
    fi
  fi

  TIMEZONE="${detected_timezone:-Etc/UTC}"
  log "Timezone: $TIMEZONE"
}

check_system_resources() {
  local available_mem_mb=""

  log "Checking system resources..."

  if command -v free >/dev/null 2>&1; then
    available_mem_mb="$(free -m | awk 'NR==2 {print $7}')"

    if [[ "$available_mem_mb" =~ ^[0-9]+$ ]] && (( available_mem_mb < 2048 )); then
      warning "Low available memory: ${available_mem_mb}MB. Browser containers work best with at least 2048MB available."
    fi
  else
    warning "'free' command not found. Skipping memory availability check."
  fi
}

validate_runtime_settings() {
  validate_positive_integer "$PUID" "PUID"
  validate_positive_integer "$PGID" "PGID"
  validate_port "$PORT_GUAC" "PORT_GUAC"
  validate_port "$PORT_HTTPS" "PORT_HTTPS"

  [[ "$PORT_GUAC" != "$PORT_HTTPS" ]] || error "PORT_GUAC and PORT_HTTPS must be different"

  if port_in_use "$PORT_GUAC"; then
    error "PORT_GUAC ($PORT_GUAC) is already in use"
  fi

  if port_in_use "$PORT_HTTPS"; then
    error "PORT_HTTPS ($PORT_HTTPS) is already in use"
  fi

  [[ -n "$SHM_SIZE" ]] || error "SHM_SIZE cannot be empty"
  [[ -n "$CONFIG_DIR" ]] || error "CONFIG_DIR cannot be empty"
}

pull_image() {
  log "Pulling Docker image: $IMAGE"

  if ! docker pull "$IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    error "Failed to pull Docker image: $IMAGE"
  fi

  success "Image pulled successfully"
}

prepare_config_directory() {
  log "Preparing persistent config directory: $CONFIG_DIR"

  mkdir -p "$CONFIG_DIR"

  if ! chown "$PUID:$PGID" "$CONFIG_DIR" >/dev/null 2>&1; then
    warning "Could not change ownership of $CONFIG_DIR to ${PUID}:${PGID}. Container startup may fail if the directory is not writable."
  fi
}

run_container() {
  echo
  log "Deploying $NAME browser container..."

  if ! docker run -d \
    --name "$CONTAINER_NAME" \
    --security-opt seccomp=unconfined \
    -e PUID="$PUID" \
    -e PGID="$PGID" \
    -e TZ="$TIMEZONE" \
    -e CUSTOM_USER="$USERNAME" \
    -e PASSWORD="$PASSWORD" \
    -p "$PORT_GUAC:3000" \
    -p "$PORT_HTTPS:3001" \
    -v "$CONFIG_DIR:/config" \
    --shm-size="$SHM_SIZE" \
    --restart unless-stopped \
    "$IMAGE" 2>&1 | tee -a "$LOG_FILE"; then
    error "Failed to start Docker container"
  fi

  success "Container started successfully"
}

wait_for_service() {
  local waited=0
  local container_state=""
  local http_code=""

  log "Waiting for browser service to become reachable (max ${STARTUP_TIMEOUT}s)..."

  while (( waited < STARTUP_TIMEOUT )); do
    container_state="$(docker inspect -f '{{.State.Status}}' "$CONTAINER_NAME" 2>/dev/null || true)"

    if [[ "$container_state" == "exited" || "$container_state" == "dead" ]]; then
      warning "Container stopped before the web UI became ready."
      docker ps -a --filter "name=${CONTAINER_NAME}" | tee -a "$LOG_FILE" || true
      docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
      error "Browser container exited during startup"
    fi

    if [[ "$container_state" == "running" ]]; then
      http_code="$(curl -kLsS -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1:${PORT_HTTPS}" 2>/dev/null || true)"

      if [[ -n "$http_code" && "$http_code" != "000" ]]; then
        SERVICE_URL="https://127.0.0.1:${PORT_HTTPS}"
        success "Browser service is responding on ${SERVICE_URL}"
        return
      fi

      http_code="$(curl -LsS -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${PORT_GUAC}" 2>/dev/null || true)"

      if [[ -n "$http_code" && "$http_code" != "000" ]]; then
        SERVICE_URL="http://127.0.0.1:${PORT_GUAC}"
        success "Browser service is responding on ${SERVICE_URL}"
        return
      fi
    fi

    sleep 2
    waited=$((waited + 2))
  done

  warning "Browser service did not become reachable within ${STARTUP_TIMEOUT}s."
  warning "Recent container logs:"
  docker ps -a --filter "name=${CONTAINER_NAME}" | tee -a "$LOG_FILE" || true
  docker port "$CONTAINER_NAME" | tee -a "$LOG_FILE" || true
  docker logs --tail 50 "$CONTAINER_NAME" 2>&1 | tee -a "$LOG_FILE" || true
  error "Browser UI never became reachable on localhost ports ${PORT_GUAC}/${PORT_HTTPS}"
}

get_public_ip() {
  local candidate=""
  local service=""
  local services=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )

  log "Retrieving public IP address..."

  for service in "${services[@]}"; do
    candidate="$(curl -fsS --max-time "$IP_FETCH_TIMEOUT" "$service" 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ -n "$candidate" ]]; then
      IP="$candidate"
      success "Public IP: $IP"
      return
    fi
  done

  IP="localhost"
  warning "Could not retrieve public IP. Using '${IP}' instead."
}

show_results() {
  echo
  echo "======================================="
  success "Installation complete"
  echo "======================================="
  echo "Browser      : $NAME"
  echo "Username     : $USERNAME"
  echo "HTTP URL     : http://$IP:$PORT_GUAC"
  echo "Access URL   : https://$IP:$PORT_HTTPS"
  echo "Guac Port    : $PORT_GUAC"
  echo "Timezone     : $TIMEZONE"
  echo "Config Dir   : $CONFIG_DIR"
  echo "Container    : $CONTAINER_NAME"
  echo
  echo "Note: Accept the browser SSL warning on first load."
  echo "Log file     : $LOG_FILE"
  echo "======================================="

  log "Installation completed successfully"
  log "Container name: $CONTAINER_NAME"
  log "Access: https://$IP:$PORT_HTTPS"
}

main() {
  parse_args "$@"
  print_banner
  log "Installation started"
  ensure_root
  check_dependencies
  ensure_docker_running
  load_config
  prompt_for_browser
  set_browser_image
  configure_credentials
  detect_timezone
  check_system_resources
  validate_runtime_settings
  open_firewall_ports
  remove_old_container
  pull_image
  prepare_config_directory
  run_container
  wait_for_service
  get_public_ip
  show_results
}

main "$@"
