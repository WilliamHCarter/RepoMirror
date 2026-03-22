#!/usr/bin/env bash
# =============================================================================
# RepoMirror — GitHub → Forgejo bulk migration
# Called by setup.sh and repomirror.sh migrate. All config via env vars.
# =============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RESET='\033[0m'
info()    { echo -e "${CYAN}[•]${RESET} $*"; }
success() { echo -e "${GREEN}[✓]${RESET} $*"; }
warn()    { echo -e "${YELLOW}[!]${RESET} $*"; }
error()   { echo -e "${RED}[✗]${RESET} $*" >&2; exit 1; }

: "${FORGEJO_URL:?FORGEJO_URL not set}"
: "${FORGEJO_TOKEN:?FORGEJO_TOKEN not set}"
: "${FORGEJO_USER:?FORGEJO_USER not set}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN not set}"
: "${GITHUB_USER:?GITHUB_USER not set}"

# ── Fetch all repos from GitHub (paginated) ───────────────────────────────────
info "Fetching repo list from GitHub for user: $GITHUB_USER ..."

all_repos="[]"
page=1
while : ; do
  chunk=$(curl -sf \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/user/repos?per_page=100&page=$page&type=all")

  count=$(echo "$chunk" | jq 'length')
  [[ "$count" -eq 0 ]] && break

  all_repos=$(echo "$all_repos $chunk" | jq -s 'add')
  page=$((page + 1))
done

total=$(echo "$all_repos" | jq 'length')
info "Found $total repos on GitHub"

# ── Fetch existing mirrors in Forgejo (paginated) ─────────────────────────────
existing="[]"
page=1
while : ; do
  raw=$(curl -s \
    -H "Authorization: Bearer $FORGEJO_TOKEN" \
    "$FORGEJO_URL/api/v1/repos/search?limit=50&page=$page") || break
  chunk=$(echo "$raw" | jq '.data // []' 2>/dev/null) || break
  count=$(echo "$chunk" | jq 'length')
  [[ "$count" -eq 0 ]] && break
  existing=$(echo "$existing" | jq --argjson c "$chunk" '. + [$c[] | .name]')
  page=$((page + 1))
done

# ── Migrate each repo ─────────────────────────────────────────────────────────
success_count=0; skip_count=0; fail_count=0

while IFS= read -r repo; do
  name=$(echo    "$repo" | jq -r '.name')
  clone=$(echo   "$repo" | jq -r '.clone_url')
  private=$(echo "$repo" | jq -r '.private')
  desc=$(echo    "$repo" | jq -r '.description // ""')

  # Skip if already mirrored
  if echo "$existing" | jq -e --arg n "$name" '. | index($n) != null' >/dev/null 2>&1; then
    warn "  skip  $name  (already exists)"
    skip_count=$((skip_count + 1))
    continue
  fi

  # Escape description for JSON
  desc_escaped=$(echo "$desc" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip()))")

  http_code=$(curl -s -o /tmp/repomirror_migrate.json -w "%{http_code}" -X POST \
    -H "Authorization: Bearer $FORGEJO_TOKEN" \
    -H "Content-Type: application/json" \
    "$FORGEJO_URL/api/v1/repos/migrate" \
    -d "{
      \"clone_addr\":       \"$clone\",
      \"auth_token\":       \"$GITHUB_TOKEN\",
      \"repo_name\":        \"$name\",
      \"repo_owner\":       \"$FORGEJO_USER\",
      \"mirror\":           true,
      \"private\":          $private,
      \"description\":      $desc_escaped,
      \"mirror_interval\":  \"8h\",
      \"wiki\":             true,
      \"releases\":         true,
      \"labels\":           true,
      \"issues\":           false,
      \"pull_requests\":    false
    }" 2>/dev/null) || true

  if [[ "$http_code" =~ ^2 ]]; then
    success "  done  $name  (private: $private)"
    success_count=$((success_count + 1))
  else
    response=$(cat /tmp/repomirror_migrate.json 2>/dev/null || echo "HTTP $http_code")
    warn "  fail  $name: $response"
    fail_count=$((fail_count + 1))
  fi

  # Small delay to avoid hammering GitHub/Forgejo APIs
  sleep 0.5
done < <(echo "$all_repos" | jq -c '.[]')

echo ""
info "Migration complete:"
info "  ✓ Migrated:  $success_count"
info "  ⟳ Skipped:   $skip_count (already existed)"
[[ $fail_count -gt 0 ]] && warn "  ✗ Failed:    $fail_count  — check output above"
