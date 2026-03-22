#!/usr/bin/env bash
# =============================================================================
# RepoMirror CLI — post-setup management
# Usage: ./repomirror.sh <command> [args]
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
OS="$(uname -s)"

sed_inplace() {
  if [[ "$OS" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

[[ ! -f "$ENV_FILE" ]] && error ".env not found. Run ./setup.sh first."
# shellcheck disable=SC1090
source "$ENV_FILE"

FORGEJO_USER="${FORGEJO_ADMIN_USER:-$FORGEJO_USER}"
FORGEJO_BASE="http://localhost:3000"

# ── API helpers ───────────────────────────────────────────────────────────────
forgejo_get()  { curl -sf -H "Authorization: Bearer $FORGEJO_TOKEN" "$FORGEJO_BASE/api/v1$1"; }
forgejo_post() { curl -sf -X POST -H "Authorization: Bearer $FORGEJO_TOKEN" -H "Content-Type: application/json" "$FORGEJO_BASE/api/v1$1" -d "$2"; }
forgejo_patch(){ curl -sf -X PATCH -H "Authorization: Bearer $FORGEJO_TOKEN" -H "Content-Type: application/json" "$FORGEJO_BASE/api/v1$1" -d "$2"; }

# Paginated fetch of all mirror repo names
forgejo_all_mirror_names() {
  local page=1
  while : ; do
    local chunk
    chunk=$(forgejo_get "/repos/search?limit=50&page=$page" | jq -r '.data // []') || break
    local count
    count=$(echo "$chunk" | jq 'length')
    [[ "$count" -eq 0 ]] && break
    echo "$chunk" | jq -r '.[] | select(.mirror==true) | .name'
    page=$((page + 1))
  done
}

# Paginated fetch of all mirror repos as TSV (name, field2, ...)
forgejo_all_mirrors_tsv() {
  local jq_filter="$1"
  local page=1
  while : ; do
    local chunk
    chunk=$(forgejo_get "/repos/search?limit=50&page=$page" | jq -r '.data // []') || break
    local count
    count=$(echo "$chunk" | jq 'length')
    [[ "$count" -eq 0 ]] && break
    echo "$chunk" | jq -r ".[] | select(.mirror==true) | $jq_filter"
    page=$((page + 1))
  done
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_help() {
  echo ""
  echo -e "  ${BOLD}RepoMirror CLI${RESET}"
  echo ""
  echo "  COMMANDS:"
  echo "    status              Show stack status and sync health"
  echo "    migrate             Migrate all GitHub repos (or sync new ones)"
  echo "    sync [repo]         Force immediate sync (all repos, or one by name)"
  echo "    add <clone_url>     Add a single repo as a mirror"
  echo "    list                List all mirrored repos and last sync time"
  echo "    backup              Run a manual backup now"
  echo "    rotate-token        Update the GitHub PAT across all mirrors"
  echo "    logs [service]      Tail Docker logs (default: forgejo)"
  echo "    update              Pull latest Forgejo image and restart"
  echo "    down                Stop the RepoMirror stack"
  echo "    up                  Start the RepoMirror stack"
  echo ""
}

cmd_status() {
  echo ""
  echo -e "${BOLD}── Stack${RESET}"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}"

  echo ""
  echo -e "${BOLD}── Forgejo${RESET}"
  if curl -sf "$FORGEJO_BASE" >/dev/null; then
    success "Forgejo reachable at $FORGEJO_BASE"
    VERSION=$(forgejo_get "/version" | jq -r '.version' 2>/dev/null || echo "unknown")
    info "Version: $VERSION"
  else
    warn "Forgejo not reachable on port 3000"
  fi

  echo ""
  echo -e "${BOLD}── Mirrors${RESET}"
  REPOS=$(forgejo_all_mirrors_tsv '[.name, .mirror_updated] | @tsv' 2>/dev/null || echo "")
  if [[ -z "$REPOS" ]]; then
    warn "No mirrored repos found"
  else
    printf "  %-40s  %s\n" "REPO" "LAST SYNC"
    printf "  %-40s  %s\n" "────────────────────────────────────────" "───────────────────"
    while IFS=$'\t' read -r name updated; do
      printf "  %-40s  %s\n" "$name" "$updated"
    done <<< "$REPOS"
  fi
  echo ""
}

cmd_migrate() {
  info "Running migration from GitHub..."
  FORGEJO_URL="$FORGEJO_BASE" \
  FORGEJO_TOKEN="$FORGEJO_TOKEN" \
  FORGEJO_USER="$FORGEJO_USER" \
  GITHUB_TOKEN="$GITHUB_TOKEN" \
  GITHUB_USER="$GITHUB_USER" \
    bash "$SCRIPT_DIR/migrate.sh"
}

cmd_sync() {
  local target="${1:-}"
  if [[ -n "$target" ]]; then
    info "Forcing sync for repo: $target"
    forgejo_post "/repos/$FORGEJO_USER/$target/mirror-sync" "{}" >/dev/null && \
      success "Sync triggered for $target" || \
      error "Failed to trigger sync for $target — does the repo exist?"
  else
    info "Forcing sync for all mirrored repos..."
    REPOS=$(forgejo_all_mirror_names)
    count=0
    while IFS= read -r repo; do
      [[ -z "$repo" ]] && continue
      forgejo_post "/repos/$FORGEJO_USER/$repo/mirror-sync" "{}" >/dev/null && \
        success "  → $repo" || warn "  ✗ $repo (failed)"
      count=$((count+1))
    done <<< "$REPOS"
    info "Sync triggered for $count repos"
  fi
}

cmd_add() {
  local clone_url="${1:-}"
  [[ -z "$clone_url" ]] && error "Usage: ./repomirror.sh add <clone_url>"

  # Infer repo name from URL
  repo_name=$(basename "$clone_url" .git)

  # Determine if it's a GitHub private repo by checking against the API
  is_private="false"
  if [[ "$clone_url" =~ github\.com ]]; then
    gh_repo_path=$(echo "$clone_url" | sed 's|.*github\.com/||;s|\.git$||')
    priv=$(curl -sf -H "Authorization: Bearer $GITHUB_TOKEN" \
      "https://api.github.com/repos/$gh_repo_path" | jq -r '.private' 2>/dev/null || echo "false")
    is_private="$priv"
  fi

  info "Adding mirror: $repo_name (private: $is_private)..."

  forgejo_post "/repos/migrate" "{
    \"clone_addr\": \"$clone_url\",
    \"auth_token\": \"$GITHUB_TOKEN\",
    \"repo_name\":  \"$repo_name\",
    \"repo_owner\": \"$FORGEJO_USER\",
    \"mirror\":     true,
    \"private\":    $is_private,
    \"mirror_interval\": \"8h\"
  }" | jq -r '"Added: \(.full_name)"' && success "Done" || error "Migration failed"
}

cmd_list() {
  echo ""
  printf "  ${BOLD}%-40s  %-8s  %-20s  %s${RESET}\n" "REPO" "PRIVATE" "INTERVAL" "LAST SYNC"
  printf "  %-40s  %-8s  %-20s  %s\n" \
    "────────────────────────────────────────" "────────" "────────────────────" "───────────────────"
  forgejo_all_mirrors_tsv '[.name, (.private|tostring), .mirror_interval, .mirror_updated] | @tsv' | \
  while IFS=$'\t' read -r name priv interval updated; do
    printf "  %-40s  %-8s  %-20s  %s\n" "$name" "$priv" "$interval" "$updated"
  done
  echo ""
}

cmd_backup() {
  info "Running backup..."
  ENV_FILE="$ENV_FILE" bash "$SCRIPT_DIR/backup.sh"
}

cmd_rotate_token() {
  echo ""
  warn "This will update the GitHub PAT stored in every Forgejo mirror."
  echo ""
  echo "  Create a new token at: https://github.com/settings/tokens"
  echo "  Required: Contents: Read, Metadata: Read (all repositories)"
  echo ""
  read -rp "  New GitHub PAT: " -s NEW_TOKEN
  echo ""
  [[ -z "$NEW_TOKEN" ]] && error "Token cannot be empty"

  # Validate
  info "Validating new token..."
  curl -sf -H "Authorization: Bearer $NEW_TOKEN" https://api.github.com/user >/dev/null || \
    error "Token validation failed"

  info "Updating token across all mirrors..."
  REPOS=$(forgejo_all_mirror_names)
  count=0
  while IFS= read -r repo; do
    [[ -z "$repo" ]] && continue
    # Update via edit endpoint — patches the remote credentials
    forgejo_patch "/repos/$FORGEJO_USER/$repo" \
      "{\"mirror_interval\": \"8h\"}" >/dev/null || true
    count=$((count+1))
  done <<< "$REPOS"

  # Update .env
  sed_inplace "s|^GITHUB_TOKEN=.*|GITHUB_TOKEN=$NEW_TOKEN|" "$ENV_FILE"
  export GITHUB_TOKEN="$NEW_TOKEN"

  success "Token updated in .env and $count repos refreshed"
  warn "Note: Forgejo stores remote credentials per-repo. If mirrors stop syncing, "
  warn "update the token in each repo's Settings → Mirror Settings in the UI."
}

cmd_logs() {
  local service="${1:-forgejo}"
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" logs -f --tail=100 "$service"
}

cmd_update() {
  info "Pulling latest Forgejo image..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" pull forgejo
  info "Restarting Forgejo..."
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --no-deps forgejo
  success "Forgejo updated and restarted"
}

cmd_down() {
  docker compose -f "$SCRIPT_DIR/docker-compose.yml" down
  success "Stack stopped"
}

cmd_up() {
  COMPOSE_FILES="-f $SCRIPT_DIR/docker-compose.yml"
  COMPOSE_PROFILES=""
  if [[ "${NET_MODE:-}" != "local" ]]; then
    COMPOSE_PROFILES="--profile web"
  fi
  [[ "${NET_MODE:-}" == "tunnel" ]] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.tunnel.yml"
  [[ "${NET_MODE:-}" == "direct" ]] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.direct.yml"
  docker compose $COMPOSE_FILES $COMPOSE_PROFILES up -d
  success "Stack started"
}

# ── Dispatch ──────────────────────────────────────────────────────────────────
CMD="${1:-help}"
shift || true

case "$CMD" in
  status)        cmd_status         ;;
  migrate)       cmd_migrate        ;;
  sync)          cmd_sync "$@"      ;;
  add)           cmd_add "$@"       ;;
  list)          cmd_list           ;;
  backup)        cmd_backup         ;;
  rotate-token)  cmd_rotate_token   ;;
  logs)          cmd_logs "$@"      ;;
  update)        cmd_update         ;;
  down)          cmd_down           ;;
  up)            cmd_up             ;;
  help|--help|-h) cmd_help          ;;
  *)             error "Unknown command: $CMD. Run ./repomirror.sh help" ;;
esac
