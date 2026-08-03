#!/usr/bin/env bash
#
# Deploy the time logger to the Oracle server.
#
#   ./deploy.sh ubuntu@your-server            # first run and every update
#   ./deploy.sh ubuntu@your-server /opt/timelog
#
# With an identity file that is not in ~/.ssh:
#   SSH_KEY=~/Downloads/ssh-key.key ./deploy.sh ubuntu@1.2.3.4
#
# Pass ONLY user@host as the first argument, never a whole ssh command line.
#
# Idempotent: re-run it after any code change. The shared secret is generated
# once on the first run and preserved afterwards, so the watch never needs
# reconfiguring.
#
# credentials.json is deliberately NOT copied. token.json already contains the
# client id, client secret and refresh token, so the interactive OAuth client
# file has no reason to exist on a public server.

set -euo pipefail

TARGET="${1:?usage: ./deploy.sh user@host [remote_dir]   (SSH_KEY=... for an identity file)}"
REMOTE_DIR="${2:-/opt/timelog}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Catch the easy mistake of pasting a full ssh invocation as the argument.
if [[ "$TARGET" == "ssh" || "$TARGET" == -* ]]; then
    cat >&2 <<'USAGE'
ERROR: pass only user@host, not a whole ssh command.

  wrong:  ./deploy.sh ssh -i ~/key.key ubuntu@1.2.3.4
  right:  SSH_KEY=~/key.key ./deploy.sh ubuntu@1.2.3.4
USAGE
    exit 1
fi

# Applied to both ssh and rsync so they authenticate identically.
SSH_OPTS=()
if [[ -n "${SSH_KEY:-}" ]]; then
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "ERROR: SSH_KEY '$SSH_KEY' not found" >&2
        exit 1
    fi
    SSH_OPTS=(-i "$SSH_KEY")
fi
SSH_CMD=(ssh "${SSH_OPTS[@]}")

# -- preflight, locally ---------------------------------------------------

if [[ ! -f "$HERE/token.json" ]]; then
    echo "ERROR: token.json missing. Run: .venv/bin/python authorize.py" >&2
    exit 1
fi

if [[ ! -f "$HERE/config.yaml" ]]; then
    echo "ERROR: config.yaml missing (it is gitignored; a fresh clone has none)." >&2
    echo "       Run: cp config.example.yaml config.yaml" >&2
    exit 1
fi

if grep -q "FILL_ME" "$HERE/config.yaml"; then
    echo "ERROR: config.yaml still has FILL_ME placeholders." >&2
    echo "       Run: .venv/bin/python list_calendars.py" >&2
    exit 1
fi

echo "==> Deploying to $TARGET:$REMOTE_DIR"

# -- copy -----------------------------------------------------------------

# A staging dir under the login user's home avoids needing rsync-over-sudo.
"${SSH_CMD[@]}" "$TARGET" "mkdir -p ~/timelog-staging"

rsync -az --delete -e "${SSH_CMD[*]}" \
    --exclude '.venv/' \
    --exclude '__pycache__/' \
    --exclude '.pytest_cache/' \
    --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
    --exclude 'credentials.json' \
    --exclude '.sim_state.json' \
    --exclude 'deploy.sh' \
    "$HERE/" "$TARGET:~/timelog-staging/"

# -- remote setup ---------------------------------------------------------

"${SSH_CMD[@]}" "$TARGET" REMOTE_DIR="$REMOTE_DIR" 'bash -s' <<'REMOTE'
set -euo pipefail

echo "==> Ensuring service user and directory"
if ! id timelog &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin -d "$REMOTE_DIR" timelog
fi
sudo mkdir -p "$REMOTE_DIR"

echo "==> Installing files"
sudo rsync -a --delete \
    --exclude '.venv/' --exclude '*.db' --exclude '*.db-wal' --exclude '*.db-shm' \
    ~/timelog-staging/ "$REMOTE_DIR/"
sudo chown -R timelog: "$REMOTE_DIR"
sudo chmod 600 "$REMOTE_DIR/token.json"

echo "==> Python interpreter"
# Ubuntu 20.04's system python3 is 3.8, which predates zoneinfo (added in 3.9).
# 3.9 is the newest with a -venv package on focal/arm64: deadsnakes ships no
# python3.1x-venv for this architecture, so 3.9 is the ceiling here and the code
# is written to that floor. Installed ALONGSIDE the system python -- never
# replace /usr/bin/python3, which Ubuntu's own tooling depends on.
PYTHON_BIN=""
for cand in python3.12 python3.11 python3.10 python3.9; do
    if command -v "$cand" &>/dev/null && "$cand" -m venv --help &>/dev/null; then
        PYTHON_BIN="$(command -v "$cand")"
        break
    fi
done

if [[ -z "$PYTHON_BIN" ]]; then
    echo "    no usable python >= 3.9 found; installing python3.9"
    export DEBIAN_FRONTEND=noninteractive
    sudo -E apt-get update -qq
    sudo -E apt-get install -y -qq python3.9 python3.9-venv
    PYTHON_BIN="$(command -v python3.9)"
fi
echo "    using $PYTHON_BIN ($("$PYTHON_BIN" --version 2>&1))"

echo "==> Python environment"
# A venv left behind by a failed run can have bin/python but no pip. Verify it is
# actually usable and modern enough, and rebuild it from scratch if not.
VENV_OK=0
if [[ -x "$REMOTE_DIR/.venv/bin/pip" ]]; then
    if sudo -u timelog "$REMOTE_DIR/.venv/bin/python" -c \
        'import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)' 2>/dev/null; then
        VENV_OK=1
    fi
fi
if [[ "$VENV_OK" != "1" ]]; then
    echo "    (re)creating virtualenv"
    sudo rm -rf "$REMOTE_DIR/.venv"
    sudo -u timelog "$PYTHON_BIN" -m venv "$REMOTE_DIR/.venv"
fi

sudo -u timelog "$REMOTE_DIR/.venv/bin/pip" install -q --upgrade pip
sudo -u timelog "$REMOTE_DIR/.venv/bin/pip" install -q -r "$REMOTE_DIR/requirements.txt"

echo "==> Shared secret"
# Generated once. Regenerating would silently break the watch, so never clobber.
if [[ ! -f /etc/timelog.env ]]; then
    SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(32))')"
    echo "TIMELOG_TOKEN_SECRET=$SECRET" | sudo tee /etc/timelog.env >/dev/null
    sudo chmod 600 /etc/timelog.env
    echo "    created /etc/timelog.env"
else
    echo "    /etc/timelog.env already exists, left untouched"
fi

echo "==> systemd"
sudo cp "$REMOTE_DIR/timelog.service" /etc/systemd/system/timelog.service
sudo sed -i "s|/opt/timelog|$REMOTE_DIR|g" /etc/systemd/system/timelog.service
sudo systemctl daemon-reload
sudo systemctl enable timelog >/dev/null 2>&1 || true
sudo systemctl restart timelog

sleep 2
if ! systemctl is-active --quiet timelog; then
    echo "ERROR: service failed to start. Recent log:" >&2
    sudo journalctl -u timelog -n 30 --no-pager >&2
    exit 1
fi

echo "==> Health check"
TOKEN="$(sudo grep -oP '(?<=TIMELOG_TOKEN_SECRET=).*' /etc/timelog.env)"
curl -fsS -H "Authorization: Bearer $TOKEN" http://127.0.0.1:8099/v1/domains \
    | head -c 400
echo
echo
echo "Service is up. Auth token for the watch:"
echo "    $TOKEN"
REMOTE

echo
echo "==> Done."
echo "Next: point your reverse proxy at 127.0.0.1:8099 (see deploy/ snippets),"
echo "      then set Server URL + Auth token in the watch app settings."
