#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <service_folder_names> <git_repo_url> \"<runner_pub_key>\""
  echo "Example: $0 \"adguard vaultwarden\" https://oauth2:TOKEN@github.com/user/repo.git \"ssh-ed25519 AAAAC3...\""
  exit 1
fi

SERVICE_NAMES="$1"
REPO_URL="$2"
RUNNER_PUB_KEY="$3"

TARGET_USER="deployer"
TARGET_HOME="/home/$TARGET_USER"
BASE_DIR="/opt/docker/docker-compose-homelab"
DEPLOY_SCRIPT="/usr/local/bin/deploy-service.sh"

echo "==> 1. Creating target user '$TARGET_USER' if missing..."
if ! id "$TARGET_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "User '$TARGET_USER' created."
fi

echo "==> 2. Checking dependencies..."
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed on this host. Install Docker first."
    exit 1
fi

MISSING_PKGS=()
for pkg in git curl; do
    if ! command -v "$pkg" &> /dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo "Installing missing dependencies: ${MISSING_PKGS[*]}..."
    apt update && apt install -y "${MISSING_PKGS[@]}"
fi

usermod -aG docker "$TARGET_USER"

echo "==> 3. Creating restricted deployment script..."
tee "$DEPLOY_SCRIPT" > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

cd /opt/docker/docker-compose-homelab

TARGET_DIR="${1:-}"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Invalid target directory '$TARGET_DIR'."
    exit 1
fi

cd "$TARGET_DIR"
git pull origin main

# Reclaim BEFORE pulling. Renovate bumps tag AND digest (v1.106.5 -> v1.107.0),
# so the superseded image keeps a real tag and is never "dangling": plain
# `docker image prune -f` skips it and every version bump permanently adds a
# full image set (litellm/presidio/open-webui are 1-3GB each). `-a` removes
# anything no container references; the 24h filter keeps a rollback window and
# avoids reaping an image that was pulled but not yet started. Doing it here
# also stops a large pull from hitting ENOSPC mid-transfer on the 11GB AI LXC.
docker image prune -a -f --filter "until=24h"

docker compose pull || true
docker compose up -d --build --remove-orphans

# Reap the version this deploy just took out of service, then bound the
# BuildKit cache. `--build` above runs on openwebui and on any compose file
# with a build context, so without this the newest cache set is retained
# forever.
docker image prune -a -f --filter "until=24h"
docker builder prune -f --filter "until=24h"
EOF

chmod +x "$DEPLOY_SCRIPT"

echo "==> 4. Installing logrotate for NPM access logs..."
# nginx-proxy-manager writes one access log per proxy host into /data/logs.
# The compose json-file cap only bounds stdout, so those files are unbounded
# and scale with request volume -- on the public TLS edge (npm-front) they are
# the host's largest consumer and nothing in the image rotates them.
# `copytruncate` avoids signalling nginx workers the host does not own, and
# `missingok` makes this a no-op on hosts without either stack. Deliberately
# size- as well as time-based: cron.daily runs logrotate, so maxsize caps a
# busy edge at 200MB per file instead of waiting for the weekly pass.
cat > /etc/logrotate.d/npm-stacks <<LOGROTATE
$BASE_DIR/npm/npm/data/logs/*.log
$BASE_DIR/npm-front/npm-front/data/logs/*.log
{
    weekly
    rotate 4
    maxsize 200M
    missingok
    notifempty
    compress
    copytruncate
}
LOGROTATE
chmod 644 /etc/logrotate.d/npm-stacks

echo "==> 5. Setting up restricted SSH key authorization for '$TARGET_USER'..."
SSH_DIR="$TARGET_HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

RESTRICTED_KEY_LINE="command=\"$DEPLOY_SCRIPT \$SSH_ORIGINAL_COMMAND\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding $RUNNER_PUB_KEY"

if ! grep -qF "$RUNNER_PUB_KEY" "$AUTH_KEYS"; then
    echo "$RESTRICTED_KEY_LINE" >> "$AUTH_KEYS"
    echo "Restricted SSH key added to $AUTH_KEYS."
else
    echo "Key already present in $AUTH_KEYS."
fi

chown -R "$TARGET_USER:$TARGET_USER" "$SSH_DIR"

echo "==> 6. Verifying git metadata ownership..."
# Repaired per-path BEFORE any git operation, never `chown -R "$BASE_DIR"`:
# only .git may have been left root-owned by older versions of this script,
# and walking into bind-mounted runtime data (e.g.
# uptime-kuma/uptime-kuma/data) would reset container-owned files to the
# deployer UID, breaking uptime-kuma's embedded MariaDB (uid 1000) on every
# setup run. find-based check: .git itself can be deployer-owned while
# objects/ or refs/ underneath are still root-owned.
if [ -d "$BASE_DIR/.git" ] && [ -n "$(find "$BASE_DIR/.git" ! -user "$TARGET_USER" -print -quit 2>/dev/null)" ]; then
    chown -R "$TARGET_USER:$TARGET_USER" "$BASE_DIR/.git"
fi

echo "==> 7. Setting up sparse checkout..."
mkdir -p "$BASE_DIR"
chown "$TARGET_USER:$TARGET_USER" "$BASE_DIR"

# Configure safe directory for both root and deployer before git operations
git config --global --add safe.directory "$BASE_DIR" || true
su - "$TARGET_USER" -c "git config --global --add safe.directory '$BASE_DIR'" || true

# Run git AS the deployer, never as root. The old flow cloned/pulled as root
# and then ran `chown -R "$BASE_DIR"` to fix it, but that walked into
# bind-mounted runtime data (e.g. uptime-kuma/uptime-kuma/data) and reset
# container-owned files to the deployer UID. That broke uptime-kuma's
# embedded MariaDB (uid 1000) on every setup run: Errcode 13, data not
# writable. Runtime data must keep its container-assigned ownership.
if [ ! -d "$BASE_DIR/.git" ]; then
    su - "$TARGET_USER" -c "git clone --filter=blob:none --sparse '$REPO_URL' '$BASE_DIR' && cd '$BASE_DIR' && git sparse-checkout set $SERVICE_NAMES"
else
    su - "$TARGET_USER" -c "cd '$BASE_DIR' && git sparse-checkout set $SERVICE_NAMES && git pull origin main"
fi

echo "==> Setup complete for service: $SERVICE_NAMES"
