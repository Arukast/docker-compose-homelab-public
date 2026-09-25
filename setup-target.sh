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
BASE_DIR="/opt/docker-compose-homelab"
DEPLOY_SCRIPT="/usr/local/bin/deploy-service.sh"

echo "==> 1. Creating target user '$TARGET_USER' if missing..."
if ! id "$TARGET_USER" &>/dev/null; then
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "User '$TARGET_USER' created."
fi

echo "==> 2. Checking dependencies..."
# Ensure Docker is already installed on the LXC
if ! command -v docker &> /dev/null; then
    echo "Error: Docker is not installed on this host. Please install Docker first."
    exit 1
fi

# Install git or curl only if missing
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

TARGET_DIR="${1:-}"

if [ -z "$TARGET_DIR" ] || [ ! -d "$TARGET_DIR" ]; then
    echo "Error: Invalid target directory '$TARGET_DIR'."
    exit 1
fi

cd "$TARGET_DIR"
git pull origin main
docker compose pull || true
docker compose up -d --build --remove-orphans
docker image prune -f
EOF

chmod +x "$DEPLOY_SCRIPT"

echo "==> 4. Setting up restricted SSH key authorization for '$TARGET_USER'..."
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

echo "==> 5. Setting up sparse checkout..."
mkdir -p "$BASE_DIR"

# Allow both root and deployer to execute git commands in $BASE_DIR
git config --global --add safe.directory "$BASE_DIR" || true
su - "$TARGET_USER" -c "git config --global --add safe.directory '$BASE_DIR'" || true

if [ ! -d "$BASE_DIR/.git" ]; then
    git clone --filter=blob:none --sparse "$REPO_URL" "$BASE_DIR"
    cd "$BASE_DIR"
    git sparse-checkout set $SERVICE_NAMES
else
    cd "$BASE_DIR"
    git sparse-checkout set $SERVICE_NAMES
    git pull origin main
fi

# Hand over ownership to the deployer user
echo "==> Setting permissions and safe directory for $TARGET_USER..."
chown -R "$TARGET_USER:$TARGET_USER" "$BASE_DIR"
su - "$TARGET_USER" -c "git config --global --add safe.directory '$BASE_DIR'""

echo "==> Setup complete for service(s): $SERVICE_NAMES"
