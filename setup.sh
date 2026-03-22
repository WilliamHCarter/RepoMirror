#!/usr/bin/env bash
# =============================================================================
# RepoMirror Setup Wizard
# Turns any Linux or macOS machine into a self-hosted Forgejo mirror for your GitHub.
# =============================================================================
set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }
prompt()  { echo -e "${BOLD}${CYAN}[?]${RESET} $*"; }
section() { echo -e "\n${BOLD}── $* ${RESET}"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

# ── Platform detection ────────────────────────────────────────────────────────
OS="$(uname -s)"   # Darwin or Linux
ARCH="$(uname -m)"
[[ "$ARCH" == "arm64" ]] && ARCH="aarch64"  # Normalize macOS arm64

confirm_install() {
  local pkg="$1"
  prompt "$pkg is required but not installed. Install it now? [Y/n]:"
  read -r answer
  [[ "${answer:-Y}" =~ ^[Yy]$ ]] || error "Cannot continue without $pkg. Please install it manually and re-run."
}

sed_inplace() {
  if [[ "$OS" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ____                 __  __  _
 |  _ \ ___ _ __   ___|  \/  |(_)_ __ _ __ ___  _ __
 | |_) / _ \ '_ \ / _ \ |\/| || | '__| '__/ _ \| '__|
 |  _ <  __/ |_) | (_) | |  | || | |  | | | (_) | |
 |_| \_\___| .__/ \___/|_|  |_||_|_|  |_|  \___/|_|
            |_|
EOF
echo -e "${RESET}"
echo -e "  Self-hosted Forgejo mirror for your GitHub account."
echo -e "  https://github.com/williamcarter-dev/repomirror\n"

# ── Prereq checks ─────────────────────────────────────────────────────────────
section "Checking prerequisites"

check_cmd() {
  if ! command -v "$1" &>/dev/null; then
    warn "$1 not found — attempting install..."
    return 1
  fi
  success "$1 found"
  return 0
}

# Docker
if ! check_cmd docker; then
  confirm_install "Docker"
  if [[ "$OS" == "Darwin" ]]; then
    error "Install Docker Desktop (https://docker.com/products/docker-desktop) or OrbStack (https://orbstack.dev) and re-run."
  else
    info "Installing Docker via get.docker.com..."
    curl -fsSL https://get.docker.com | sh
    sudo usermod -aG docker "$USER"
    warn "Docker installed. You may need to log out/in for group changes to take effect."
    warn "Re-run this script after logging back in if docker commands fail."
  fi
fi

# Docker Compose (v2 plugin check)
if ! docker compose version &>/dev/null 2>&1; then
  if [[ "$OS" == "Darwin" ]]; then
    error "Docker Compose is included with Docker Desktop / OrbStack. Install one of those and re-run."
  else
    confirm_install "Docker Compose"
    info "Installing Docker Compose plugin..."
    DOCKER_CONFIG="${DOCKER_CONFIG:-$HOME/.docker}"
    mkdir -p "$DOCKER_CONFIG/cli-plugins"
    [[ "$ARCH" == "aarch64" ]] && COMPOSE_ARCH="aarch64" || COMPOSE_ARCH="x86_64"
    curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$COMPOSE_ARCH" \
      -o "$DOCKER_CONFIG/cli-plugins/docker-compose"
    chmod +x "$DOCKER_CONFIG/cli-plugins/docker-compose"
  fi
fi
success "Docker Compose available"

# jq
if ! check_cmd jq; then
  confirm_install "jq"
  if command -v brew &>/dev/null; then
    brew install jq
  elif command -v apt-get &>/dev/null; then
    sudo apt-get install -y -q jq
  else
    error "Please install jq manually and re-run: https://stedolan.github.io/jq/download/"
  fi
fi

# cloudflared (only needed for tunnel mode — checked later)

# ── Networking mode ───────────────────────────────────────────────────────────
section "Networking"
echo "How will RepoMirror be accessible from the internet?"
echo ""
echo "  1) Cloudflare Tunnel  [recommended — no port forwarding, works behind CGNAT]"
echo "  2) Direct / Port forward  [you handle DNS + port 80/443 forwarding]"
echo "  3) Local only  [accessible on your LAN only — no public domain]"
echo ""
prompt "Choice [1/2/3]:"
read -r NET_MODE

case "$NET_MODE" in
  1) NET_MODE="tunnel"  ;;
  2) NET_MODE="direct"  ;;
  3) NET_MODE="local"   ;;
  *) error "Invalid choice" ;;
esac

# ── Domain ────────────────────────────────────────────────────────────────────
if [[ "$NET_MODE" != "local" ]]; then
  prompt "Your domain for Forgejo (e.g. repos.williamcarter.dev):"
  read -r DOMAIN
  [[ -z "$DOMAIN" ]] && error "Domain cannot be empty"
else
  DOMAIN="localhost"
fi

# ── Cloudflare Tunnel setup ───────────────────────────────────────────────────
TUNNEL_ID=""
if [[ "$NET_MODE" == "tunnel" ]]; then
  section "Cloudflare Tunnel"
  if ! check_cmd cloudflared; then
    confirm_install "cloudflared"
    if [[ "$OS" == "Darwin" ]]; then
      if command -v brew &>/dev/null; then
        brew install cloudflared
      else
        error "Install Homebrew (https://brew.sh) first, then re-run. cloudflared requires brew on macOS."
      fi
    else
      info "Installing cloudflared..."
      if command -v dpkg &>/dev/null; then
        if [[ "$ARCH" == "aarch64" ]]; then
          curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb" -o /tmp/cloudflared.deb
        else
          curl -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb" -o /tmp/cloudflared.deb
        fi
        sudo dpkg -i /tmp/cloudflared.deb
      else
        error "Please install cloudflared manually: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/"
      fi
    fi
  fi

  info "Authenticating with Cloudflare — a browser window will open..."
  cloudflared tunnel login

  TUNNEL_NAME="repomirror"
  info "Creating tunnel '$TUNNEL_NAME'..."
  cloudflared tunnel create "$TUNNEL_NAME" 2>&1 | tee /tmp/tunnel_create.log
  TUNNEL_ID=$(grep -o 'Created tunnel [a-zA-Z0-9_-]*' /tmp/tunnel_create.log | awk '{print $3}' || true)

  if [[ -z "$TUNNEL_ID" ]]; then
    prompt "Couldn't auto-detect tunnel ID. Paste it from the output above:"
    read -r TUNNEL_ID
  fi

  # Find credentials file
  CRED_FILE=$(find ~/.cloudflared -name "${TUNNEL_ID}.json" 2>/dev/null | head -1)
  [[ -z "$CRED_FILE" ]] && error "Could not find tunnel credentials file in ~/.cloudflared/"

  # Route DNS
  info "Routing DNS: $DOMAIN → tunnel..."
  cloudflared tunnel route dns "$TUNNEL_NAME" "$DOMAIN"

  # Write cloudflared config
  mkdir -p "$SCRIPT_DIR/config"
  sed \
    -e "s|{{TUNNEL_ID}}|$TUNNEL_ID|g" \
    -e "s|{{DOMAIN}}|$DOMAIN|g" \
    -e "s|{{CRED_FILE}}|/etc/cloudflared/${TUNNEL_ID}.json|g" \
    "$SCRIPT_DIR/cloudflared.yml.template" > "$SCRIPT_DIR/config/cloudflared/cloudflared.yml"

  # Copy cred file so Docker can mount it
  mkdir -p "$SCRIPT_DIR/config/cloudflared"
  cp "$CRED_FILE" "$SCRIPT_DIR/config/cloudflared/${TUNNEL_ID}.json"
  cp "$HOME/.cloudflared/cert.pem" "$SCRIPT_DIR/config/cloudflared/cert.pem" 2>/dev/null || true

  success "Cloudflare Tunnel configured (ID: $TUNNEL_ID)"
fi

# ── GitHub credentials ────────────────────────────────────────────────────────
section "GitHub"
prompt "Your GitHub username:"
read -r GITHUB_USER
[[ -z "$GITHUB_USER" ]] && error "GitHub username required"

echo ""
echo "  Create a fine-grained PAT at: https://github.com/settings/tokens"
echo "  Required permissions: Contents: Read, Metadata: Read (all repositories)"
echo ""
prompt "GitHub Personal Access Token:"
read -rs GITHUB_TOKEN
echo ""
[[ -z "$GITHUB_TOKEN" ]] && error "GitHub token required"

# Validate token
info "Validating GitHub token..."
GH_CHECK=$(curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" https://api.github.com/user 2>&1) || \
  error "GitHub token validation failed. Check the token and try again."
GH_ACTUAL_USER=$(echo "$GH_CHECK" | jq -r '.login')
success "Authenticated as GitHub user: $GH_ACTUAL_USER"

# ── Forgejo admin account ─────────────────────────────────────────────────────
section "Forgejo Admin Account"
prompt "Forgejo admin username [default: admin]:"
read -r FORGEJO_USER
FORGEJO_USER="${FORGEJO_USER:-admin}"

prompt "Forgejo admin email:"
read -r FORGEJO_EMAIL
[[ -z "$FORGEJO_EMAIL" ]] && error "Email required"

prompt "Forgejo admin password:"
read -rs FORGEJO_PASSWORD
echo ""
[[ ${#FORGEJO_PASSWORD} -lt 8 ]] && error "Password must be at least 8 characters"

# ── Webhook relay secret ──────────────────────────────────────────────────────
WEBHOOK_SECRET=$(openssl rand -hex 32)

# ── Backup configuration ──────────────────────────────────────────────────────
section "Backup (optional)"
echo "Where should RepoMirror back up your Forgejo data?"
echo ""
echo "  1) None"
echo "  2) Local directory on this machine"
echo "  3) S3-compatible (AWS S3 / Backblaze B2 / Cloudflare R2)"
echo ""
prompt "Choice [1/2/3]:"
read -r BACKUP_MODE

BACKUP_DIR=""
S3_BUCKET=""; S3_ENDPOINT=""; S3_ACCESS_KEY=""; S3_SECRET_KEY=""

case "$BACKUP_MODE" in
  2)
    prompt "Local backup path [default: $SCRIPT_DIR/backups]:"
    read -r BACKUP_DIR
    BACKUP_DIR="${BACKUP_DIR:-$SCRIPT_DIR/backups}"
    mkdir -p "$BACKUP_DIR"
    ;;
  3)
    prompt "S3 bucket name:"
    read -r S3_BUCKET
    prompt "S3 endpoint URL (leave blank for AWS, e.g. https://s3.us-west-004.backblazeb2.com for B2):"
    read -r S3_ENDPOINT
    prompt "Access key ID:"
    read -r S3_ACCESS_KEY
    prompt "Secret access key:"
    read -rs S3_SECRET_KEY
    echo ""
    ;;
esac

# ── Write .env ────────────────────────────────────────────────────────────────
section "Writing configuration"

if [[ "$NET_MODE" == "local" ]]; then
  FORGEJO_ROOT_URL="http://localhost:3000"
else
  FORGEJO_ROOT_URL="https://${DOMAIN}"
fi

cat > "$ENV_FILE" <<EOF
# RepoMirror — generated by setup.sh on $(date)
# Do not commit this file. It contains secrets.

# ── Core ──────────────────────────────────────────────────────────────────────
DOMAIN=${DOMAIN}
NET_MODE=${NET_MODE}
TUNNEL_ID=${TUNNEL_ID}
FORGEJO_ROOT_URL=${FORGEJO_ROOT_URL}

# ── GitHub ────────────────────────────────────────────────────────────────────
GITHUB_USER=${GITHUB_USER}
GITHUB_TOKEN=${GITHUB_TOKEN}

# ── Forgejo ───────────────────────────────────────────────────────────────────
FORGEJO_ADMIN_USER=${FORGEJO_USER}
FORGEJO_ADMIN_EMAIL=${FORGEJO_EMAIL}
FORGEJO_ADMIN_PASSWORD=${FORGEJO_PASSWORD}

# ── Webhook Relay ─────────────────────────────────────────────────────────────
WEBHOOK_SECRET=${WEBHOOK_SECRET}

# ── Backup ────────────────────────────────────────────────────────────────────
BACKUP_MODE=${BACKUP_MODE:-1}
BACKUP_DIR=${BACKUP_DIR}
S3_BUCKET=${S3_BUCKET}
S3_ENDPOINT=${S3_ENDPOINT}
S3_ACCESS_KEY=${S3_ACCESS_KEY}
S3_SECRET_KEY=${S3_SECRET_KEY}
EOF

chmod 600 "$ENV_FILE"
success ".env written (permissions: 600)"

# ── Generate Caddyfile (direct mode only) ─────────────────────────────────────
if [[ "$NET_MODE" == "direct" ]]; then
  mkdir -p "$SCRIPT_DIR/config"
  sed "s|{{DOMAIN}}|$DOMAIN|g" \
    "$SCRIPT_DIR/Caddyfile.template" > "$SCRIPT_DIR/config/Caddyfile"
  success "Caddyfile generated"
fi

# ── Bring up the stack ────────────────────────────────────────────────────────
section "Starting RepoMirror stack"
info "Pulling images (this may take a minute)..."

COMPOSE_FILES="-f $SCRIPT_DIR/docker-compose.yml"
COMPOSE_PROFILES=""
if [[ "$NET_MODE" != "local" ]]; then
  COMPOSE_PROFILES="--profile web"
fi
[[ "$NET_MODE" == "tunnel"  ]] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.tunnel.yml"
[[ "$NET_MODE" == "direct"  ]] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.direct.yml"

cd "$SCRIPT_DIR"
docker compose $COMPOSE_FILES $COMPOSE_PROFILES up -d --build

# ── Wait for Forgejo to be ready ──────────────────────────────────────────────
info "Waiting for Forgejo to become ready..."
FORGEJO_BASE="http://localhost:3000"
MAX_WAIT=60; waited=0
until curl -sf "$FORGEJO_BASE" > /dev/null; do
  sleep 2; waited=$((waited+2))
  [[ $waited -ge $MAX_WAIT ]] && error "Forgejo didn't start within ${MAX_WAIT}s. Check: docker compose logs forgejo"
done
success "Forgejo is up"

# ── Bootstrap Forgejo admin account via CLI ───────────────────────────────────
info "Creating Forgejo admin account..."
docker exec forgejo forgejo admin user create \
  --username "$FORGEJO_USER" \
  --password "$FORGEJO_PASSWORD" \
  --email    "$FORGEJO_EMAIL" \
  --admin \
  --must-change-password=false 2>/dev/null || warn "Admin user may already exist — continuing"

# ── Generate Forgejo API token ────────────────────────────────────────────────
info "Generating Forgejo API token..."
FORGEJO_TOKEN=$(docker exec forgejo forgejo admin user generate-access-token \
  --username "$FORGEJO_USER" \
  --token-name "repomirror-setup" \
  --raw 2>/dev/null | tail -1)

if [[ -z "$FORGEJO_TOKEN" ]]; then
  warn "Could not auto-generate Forgejo token. You'll need to create one manually at:"
  warn "  https://$DOMAIN/user/settings/applications"
  prompt "Paste your Forgejo API token here to continue with migration:"
  read -rs FORGEJO_TOKEN
  echo ""
fi

# Append token to .env
echo "FORGEJO_TOKEN=${FORGEJO_TOKEN}" >> "$ENV_FILE"
success "Forgejo API token stored"

# ── Run migration ─────────────────────────────────────────────────────────────
section "Migrating GitHub repos"
prompt "Migrate all GitHub repos now? [Y/n]:"
read -r DO_MIGRATE
if [[ "${DO_MIGRATE:-Y}" =~ ^[Yy]$ ]]; then
  FORGEJO_URL="http://localhost:3000" \
  FORGEJO_TOKEN="$FORGEJO_TOKEN" \
  FORGEJO_USER="$FORGEJO_USER" \
  GITHUB_TOKEN="$GITHUB_TOKEN" \
  GITHUB_USER="$GITHUB_USER" \
    bash "$SCRIPT_DIR/migrate.sh"
else
  info "Skipping migration. Run it later with: ./repomirror.sh migrate"
fi

# ── Set up backup cron ────────────────────────────────────────────────────────
if [[ "${BACKUP_MODE:-1}" != "1" ]]; then
  section "Configuring backups"
  CRON_CMD="0 2 * * * ENV_FILE=$ENV_FILE $SCRIPT_DIR/backup.sh >> $SCRIPT_DIR/backup.log 2>&1"
  (crontab -l 2>/dev/null | grep -v "repomirror"; echo "$CRON_CMD") | crontab -
  success "Daily backup cron job registered (runs at 02:00)"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
section "All done!"
echo ""
echo -e "  ${GREEN}${BOLD}RepoMirror is running.${RESET}"
echo ""
if [[ "$NET_MODE" == "local" ]]; then
  echo -e "  Access Forgejo at: ${BOLD}http://localhost:3000${RESET}"
else
  echo -e "  Access Forgejo at: ${BOLD}https://$DOMAIN${RESET}"
fi
echo ""
echo -e "  Manage with:  ${BOLD}./repomirror.sh${RESET}"
echo -e "  View logs:    ${BOLD}docker compose logs -f forgejo${RESET}"
echo -e "  Stop stack:   ${BOLD}docker compose down${RESET}"
echo ""
warn "Keep your .env file safe — it contains secrets. Never commit it."
echo ""
