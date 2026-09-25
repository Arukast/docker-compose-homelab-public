#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ]; then
  echo "Usage: $0 <service_folder_name> <git_repo_url> \"<runner_pub_key>\""
  echo "Example: $0 adguard https://github.com/user/docker-compose-homelab.git \"ssh-ed25519 AAAAC3...\""
  exit 1
fi

SERVICE_NAME="$1"
REPO_URL="$2"
RUNNER_PUB_KEY="$3"

BASE_DIR="/opt/docker/docker-compose-homelab"
DEPLOY_SCRIPT="/usr/local/bin/deploy-service.sh"

echo "==> 1. Granting Docker permissions..."
sudo usermod -aG docker "$USER"

echo "==> 2. Creating restricted deployment script..."
sudo tee "$DEPLOY_SCRIPT" > /dev/null << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

TARGET_DIR="${1:-}"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Invalid target directory '$TARGET_DIR'."
    exit 1
fi

cd "$TARGET_DIR"
git pull origin main
docker compose pull || true                 # Continue if pull fails (local build)
docker compose up -d --build --remove-orphans # Rebuilds local Dockerfiles if context changed
docker image prune -f
EOF

sudo chmod +x "$DEPLOY_SCRIPT"

echo "==> 3. Setting up restricted SSH key authorization..."
mkdir -p ~/.ssh
chmod 700 ~/.ssh
AUTH_KEYS=~/.ssh/authorized_keys
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

RESTRICTED_KEY_LINE="command=\"$DEPLOY_SCRIPT \$SSH_ORIGINAL_COMMAND\",no-port-forwarding,no-x11-forwarding,no-agent-forwarding $RUNNER_PUB_KEY"

if ! grep -qF "$RUNNER_PUB_KEY" "$AUTH_KEYS"; then
    echo "$RESTRICTED_KEY_LINE" >> "$AUTH_KEYS"
    echo "Restricted SSH key added to $AUTH_KEYS."
else
    echo "Key already present in $AUTH_KEYS."
fi

echo "==> 4. Setting up sparse checkout..."
sudo mkdir -p "$BASE_DIR"
sudo chown -R "$USER:$USER" "$BASE_DIR"

# Change this section in setup-target.sh:
if [ ! -d "$BASE_DIR/.git" ]; then
    git clone --filter=blob:none --sparse "$REPO_URL" "$BASE_DIR"
    cd "$BASE_DIR"
    git sparse-checkout set $SERVICE_NAME   # <-- Unquoted to expand multiple folder names
else
    cd "$BASE_DIR"
    git sparse-checkout set $SERVICE_NAME   # <-- Unquoted
    git pull origin main
fi

echo "==> Setup complete for service '$SERVICE_NAME'."
