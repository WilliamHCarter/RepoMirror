# RepoMirror

**Dead-simple self-hosted GitHub mirror.** One setup script turns any Linux machine into a live, synced backup of your entire GitHub account using [Forgejo](https://forgejo.org).

```
git clone https://github.com/williamhcarter/repomirror
cd repomirror
./setup.sh
```

That's it. The wizard handles everything else.

---

## What it does

- Migrates all your GitHub repos (public + private) to a self-hosted Forgejo instance, preserving full commit history and privacy settings
- Keeps them automatically in sync via pull mirroring (every 8h) and near-realtime push via GitHub webhooks
- Puts it all behind a domain you control with automatic HTTPS
- Gives you a `repomirror` CLI for day-to-day management

## Requirements

- A Linux machine (Raspberry Pi 4/5, VPS, anything 64-bit with 1GB+ RAM)
- A domain name you control
- A GitHub account with a [fine-grained PAT](https://github.com/settings/tokens)

Docker and Docker Compose are installed automatically by `setup.sh` if not present.

---

## Quick Start

### 1. Clone

```bash
git clone https://github.com/williamcarter-dev/repomirror
cd repomirror
chmod +x setup.sh repomirror.sh scripts/*.sh
```

### 2. Create a GitHub PAT

Go to **GitHub → Settings → Developer Settings → Fine-grained tokens → Generate new token**

Set these permissions:
| Permission | Access |
|---|---|
| Contents | Read-only |
| Metadata | Read-only |

Set the token to cover **All repositories**. Copy the token — you'll paste it during setup.

### 3. Run the wizard

```bash
./setup.sh
```

The wizard will ask you:

1. **Networking mode** — Cloudflare Tunnel (recommended), direct/port-forward, or local-only
2. **Your domain** — e.g. `repos.yourdomain.com`
3. **GitHub credentials** — username + PAT from step 2
4. **Forgejo admin account** — username, email, and password for your Forgejo instance
5. **Backup preference** — none, local folder, or S3-compatible (Backblaze B2, AWS S3, R2)

Setup takes about 5 minutes. At the end, all your repos will be migrating in the background.

---

## Networking

### Option A: Cloudflare Tunnel (Recommended)

Best for home servers (Raspberry Pi), machines behind CGNAT, or anywhere you can't forward ports. The setup wizard handles the entire Cloudflare setup automatically — you just need a free Cloudflare account with your domain on it.

No ports need to be open on your firewall. Cloudflare routes traffic outbound through a persistent tunnel.

### Option B: Direct / Port Forward

If you're on a VPS or can forward ports on your router:

1. Point your domain's A record at your machine's public IP
2. Forward ports 80 and 443 to the machine
3. Choose "Direct" during setup — Caddy handles HTTPS automatically via Let's Encrypt

### Option C: Local Only

For LAN-only access (no public domain). Forgejo will be available at `http://localhost:3000`.

---

## After Setup

### The `repomirror` CLI

```bash
./repomirror.sh <command>
```

| Command | Description |
|---|---|
| `status` | Show stack health and last sync time for all repos |
| `migrate` | Re-run migration (picks up new repos, skips existing) |
| `sync [repo]` | Force immediate sync — all repos, or one by name |
| `add <clone_url>` | Add a single repo as a mirror |
| `list` | List all mirrors with privacy and sync status |
| `backup` | Run a manual backup |
| `rotate-token` | Update your GitHub PAT across all mirrors |
| `logs [service]` | Tail Docker logs (default: forgejo) |
| `update` | Pull latest Forgejo image and restart |
| `up` / `down` | Start or stop the whole stack |

### Setting up webhooks (optional but recommended)

Webhooks make mirrors update within seconds of a push instead of waiting up to 8 hours. For each repo on GitHub:

1. Go to **Settings → Webhooks → Add webhook**
2. Set Payload URL to: `https://your-domain/webhook/repo-name`
3. Content type: `application/json`
4. Secret: copy `WEBHOOK_SECRET` from your `.env` file
5. Select: **Just the push event**

You can automate this for all repos with the GitHub API — see `scripts/migrate.sh` for the pattern.

---

## Hardware Notes (Raspberry Pi)

**Boot from USB SSD, not SD card.** SD cards degrade quickly under constant database writes. A cheap 120GB USB SSD is a worthwhile investment for reliability.

**Recommended hardware:**
- Raspberry Pi 4 or 5 with 4GB+ RAM
- 120GB+ USB SSD for the OS and Forgejo data
- Optionally: a UPS HAT (e.g. Waveshare UPS Hat) to survive power outages

**Pi-specific setup:**
```bash
# After flashing Raspberry Pi OS Lite (64-bit) and enabling SSH
sudo raspi-config        # hostname, locale, expand filesystem
sudo apt update && sudo apt upgrade -y
# Then run ./setup.sh
```

---

## Stack

| Component | Image | Role |
|---|---|---|
| **Forgejo** | `codeberg.org/forgejo/forgejo:9` | Git server and web UI |
| **Webhook Relay** | (built locally) | GitHub webhook → Forgejo sync bridge |
| **Caddy** | `caddy:2-alpine` | TLS termination + reverse proxy (direct mode) |
| **cloudflared** | `cloudflare/cloudflared` | Tunnel (tunnel mode) |
| **Watchtower** | `containrrr/watchtower` | Auto-updates Forgejo daily |

All data is stored in `./data/forgejo/` — back this directory up to preserve everything.

---

## Backup & Recovery

### Automatic backups

Configure during `./setup.sh` or update `BACKUP_MODE` in `.env`:

- `1` — none
- `2` — local directory (configurable path, keeps last 14 daily backups)
- `3` — S3-compatible (AWS S3, Backblaze B2, Cloudflare R2 — keeps last 30 days)

Backups run daily at 02:00 via cron.

### Manual backup

```bash
./repomirror.sh backup
```

### Recovery

```bash
# Stop the stack
./repomirror.sh down

# Restore from a backup tarball
tar xzf forgejo_20250101_020000.tar.gz -C /path/to/repomirror/

# Start again
./repomirror.sh up
```

---

## Token Rotation

GitHub PATs expire. When you create a new token:

```bash
./repomirror.sh rotate-token
```

This updates `GITHUB_TOKEN` in `.env` and refreshes all mirror configurations.

> **Note:** Forgejo stores mirror credentials in its database. If any repos show authentication errors after rotation, update the token in that repo's **Settings → Mirror Settings** in the Forgejo UI.

---

## Troubleshooting

**Forgejo won't start**
```bash
./repomirror.sh logs forgejo
```

**A repo isn't syncing**
```bash
./repomirror.sh sync my-repo-name
./repomirror.sh logs forgejo
```

**Webhook relay errors**
```bash
./repomirror.sh logs webhook-relay
```

**Cloudflare Tunnel not connecting**
```bash
./repomirror.sh logs cloudflared
```

**Re-run setup without losing data**

Setup is idempotent for most steps. You can safely re-run `./setup.sh` — it will skip repos that already exist and won't overwrite your Forgejo data.

---

## Security

- Registration is disabled by default — only your admin account can create repos
- The `.env` file is created with `chmod 600` and is gitignored
- Webhook payloads are validated with HMAC-SHA256 before triggering any sync
- The webhook relay and Forgejo are only exposed via `127.0.0.1` ports — no direct public access

---

## License

MIT
