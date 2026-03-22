#!/usr/bin/env bash
# =============================================================================
# RepoMirror — Backup
# Backs up Forgejo data to local path or S3-compatible storage.
# Called by cron or: ./repomirror.sh backup
# =============================================================================
set -euo pipefail

: "${ENV_FILE:?ENV_FILE not set — run via repomirror.sh or set ENV_FILE}"
# shellcheck disable=SC1090
source "$ENV_FILE"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OS="$(uname -s)"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILENAME="forgejo_${TIMESTAMP}.tar.gz"

# Portable date calculation for "N days ago"
date_days_ago() {
  local days="$1"
  if [[ "$OS" == "Darwin" ]]; then
    date -v-"${days}"d +%Y%m%d
  else
    date -d "$days days ago" +%Y%m%d
  fi
}

echo "[$(date)] Starting RepoMirror backup..."

case "${BACKUP_MODE:-1}" in
  # ── Local backup ────────────────────────────────────────────────────────────
  2)
    [[ -z "${BACKUP_DIR:-}" ]] && { echo "BACKUP_DIR not set"; exit 1; }
    mkdir -p "$BACKUP_DIR"

    echo "  -> Compressing to $BACKUP_DIR/$BACKUP_FILENAME ..."
    tar czf "$BACKUP_DIR/$BACKUP_FILENAME" -C "$SCRIPT_DIR" data/forgejo

    # Keep last 14 backups, delete older ones
    ls -1t "$BACKUP_DIR"/forgejo_*.tar.gz 2>/dev/null | tail -n +15 | while read -r f; do rm "$f"; done
    echo "  Done: $BACKUP_DIR/$BACKUP_FILENAME"
    ;;

  # ── S3-compatible backup ─────────────────────────────────────────────────────
  3)
    [[ -z "${S3_BUCKET:-}"     ]] && { echo "S3_BUCKET not set";     exit 1; }
    [[ -z "${S3_ACCESS_KEY:-}" ]] && { echo "S3_ACCESS_KEY not set"; exit 1; }
    [[ -z "${S3_SECRET_KEY:-}" ]] && { echo "S3_SECRET_KEY not set"; exit 1; }

    # Check for aws cli
    if ! command -v aws &>/dev/null; then
      if [[ "$OS" == "Darwin" ]]; then
        if command -v brew &>/dev/null; then
          echo "  Installing AWS CLI via Homebrew..."
          brew install awscli
        else
          echo "  ERROR: AWS CLI required. Install with: brew install awscli" >&2
          exit 1
        fi
      else
        echo "  Installing AWS CLI..."
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o /tmp/awscli.zip
        unzip -q /tmp/awscli.zip -d /tmp/aws-install
        sudo /tmp/aws-install/aws/install --update
        rm -rf /tmp/awscli.zip /tmp/aws-install
      fi
    fi

    export AWS_ACCESS_KEY_ID="$S3_ACCESS_KEY"
    export AWS_SECRET_ACCESS_KEY="$S3_SECRET_KEY"

    ENDPOINT_ARGS=()
    [[ -n "${S3_ENDPOINT:-}" ]] && ENDPOINT_ARGS=(--endpoint-url "$S3_ENDPOINT")

    echo "  -> Streaming to s3://$S3_BUCKET/$BACKUP_FILENAME ..."
    tar czf - -C "$SCRIPT_DIR" data/forgejo | \
      aws s3 cp - "s3://$S3_BUCKET/$BACKUP_FILENAME" "${ENDPOINT_ARGS[@]}"

    # Prune backups older than 30 days in the bucket
    cutoff=$(date_days_ago 30)
    aws s3 ls "s3://$S3_BUCKET/" "${ENDPOINT_ARGS[@]}" | \
      awk '{print $4}' | grep '^forgejo_' | \
      while read -r key; do
        file_date=$(echo "$key" | grep -o '[0-9]\{8\}')
        [[ "$file_date" < "$cutoff" ]] && \
          aws s3 rm "s3://$S3_BUCKET/$key" "${ENDPOINT_ARGS[@]}" && \
          echo "  Pruned old backup: $key"
      done

    echo "  Done: s3://$S3_BUCKET/$BACKUP_FILENAME"
    ;;

  *)
    echo "  Backup mode is 'none' — skipping"
    ;;
esac

echo "[$(date)] Backup complete."
