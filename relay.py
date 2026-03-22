"""
RepoMirror — Webhook Relay
Validates GitHub push webhooks and triggers Forgejo mirror-sync calls.
"""

import hashlib
import hmac
import logging
import os

import requests
from flask import Flask, abort, request

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger(__name__)

app = Flask(__name__)

GITHUB_WEBHOOK_SECRET = os.environ["GITHUB_WEBHOOK_SECRET"].encode()
FORGEJO_TOKEN         = os.environ["FORGEJO_TOKEN"]
FORGEJO_URL           = os.environ["FORGEJO_URL"].rstrip("/")
FORGEJO_USER          = os.environ["FORGEJO_USER"]


def _verify_signature(payload: bytes, sig_header: str) -> bool:
    """Verify the GitHub HMAC-SHA256 webhook signature."""
    if not sig_header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(
        GITHUB_WEBHOOK_SECRET, payload, hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(expected, sig_header)


@app.route("/webhook/<path:repo>", methods=["POST"])
def relay(repo: str):
    """
    Receive a GitHub push webhook and trigger a Forgejo mirror sync.

    GitHub webhook payload URL: https://<domain>/webhook/<repo-name>
    """
    # Validate signature
    sig = request.headers.get("X-Hub-Signature-256", "")
    if not _verify_signature(request.data, sig):
        log.warning("Invalid webhook signature for repo: %s", repo)
        abort(403)

    # Only act on push events; ignore everything else silently
    event = request.headers.get("X-GitHub-Event", "")
    if event not in ("push", "create", "delete"):
        log.info("Ignoring event '%s' for repo: %s", event, repo)
        return "", 204

    # Trigger mirror sync
    sync_url = f"{FORGEJO_URL}/api/v1/repos/{FORGEJO_USER}/{repo}/mirror-sync"
    try:
        resp = requests.post(
            sync_url,
            headers={"Authorization": f"Bearer {FORGEJO_TOKEN}"},
            timeout=10,
        )
        if resp.status_code in (200, 204):
            log.info("Mirror sync triggered for %s", repo)
        else:
            log.warning(
                "Forgejo returned %s for %s: %s",
                resp.status_code, repo, resp.text[:200],
            )
    except requests.RequestException as exc:
        log.error("Failed to reach Forgejo for %s: %s", repo, exc)
        return "", 500

    return "", 204


@app.route("/healthz")
def healthz():
    return "ok", 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=3001)
