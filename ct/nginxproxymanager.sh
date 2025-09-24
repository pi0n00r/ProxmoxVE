#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/pi0n00r/ProxmoxVE/main/misc/build.func)

# Copyright (c) 2021-2025 tteck
# Author: tteck (tteckster)
# License: MIT | https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Source: https://nginxproxymanager.com/

APP="Nginx Proxy Manager"
var_tags="${var_tags:-proxy}"
var_cpu="${var_cpu:-2}"
var_ram="${var_ram:-1024}"
var_disk="${var_disk:-4}"
var_os="${var_os:-debian}"
var_version="${var_version:-13}"   # Debian 13.x ready
var_unprivileged="${var_unprivileged:-1}"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /lib/systemd/system/npm.service ]]; then
    msg_error "No ${APP} Installation Found!"
    exit
  fi

  # Ensure pnpm via Corepack
  if ! command -v pnpm &>/dev/null; then
    msg_info "Installing pnpm via Corepack"
    corepack enable
    corepack prepare pnpm@latest --activate
    msg_ok "Installed pnpm"
  fi

  # Ensure Node.js 22 via nvm
  export NVM_DIR="$HOME/.nvm"
  if [ ! -d "$NVM_DIR" ]; then
    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
    . "$NVM_DIR/nvm.sh"
  fi
  nvm install 22
  nvm use 22

  # Fetch latest release
  RELEASE=$(curl -fsSL https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest \
    | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')

  msg_info "Downloading NPM v${RELEASE}"
  curl -fsSL "https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v${RELEASE}" | tar -xz
  cd nginx-proxy-manager-"${RELEASE}" || exit
  msg_ok "Downloaded NPM v${RELEASE}"

  # Build frontend
  msg_info "Building Frontend"
  (
    sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" backend/package.json
    sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" frontend/package.json
    export NODE_OPTIONS=--openssl-legacy-provider
    cd ./frontend || exit
    pnpm install --no-frozen-lockfile
    pnpm upgrade
    pnpm run build
  )
  msg_ok "Built Frontend"

  # Stop services
  msg_info "Stopping Services"
  systemctl stop openresty
  systemctl stop npm
  msg_ok "Stopped Services"

  # Clean old files
  msg_info "Cleaning Old Files"
  rm -rf /app \
         /var/www/html \
         /etc/nginx \
         /var/log/nginx \
         /var/lib/nginx \
         /var/cache/nginx
  msg_ok "Cleaned Old Files"

  # Environment setup
  setup_environment "$RELEASE"

  # Initialize backend
  msg_info "Initializing Backend"
  rm -rf /app/config/default.json
  if [ ! -f /app/config/production.json ]; then
    cat <<'EOF' >/app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
  fi
  cd /app || exit
  pnpm install
  msg_ok "Initialized Backend"

  # Start services
  msg_info "Starting Services"
  sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf
  sed -i 's/su npm npm/su root root/g' /etc/logrotate.d/nginx-proxy-manager
  sed -i 's/include-system-site-packages = false/include-system-site-packages = true/g' /opt/certbot/pyvenv.cfg
  systemctl enable -q --now openresty
  systemctl enable -q --now npm
  msg_ok "Started Services"

  # Cleanup
  msg_info "Cleaning up"
  rm -rf ~/nginx-proxy-manager-*
  msg_ok "Cleaned"

  msg_ok "Updated Successfully"
  exit
}

setup_environment() {
  RELEASE=$1
  msg_info "Setting up Environment"

  # Ensure Python is cleanly installed
  apt-get update
  apt-get install -y python3 python3-pip python-is-python3

  # Symlinks (only if missing)
  [ -x /usr/bin/python ] || ln -sf /usr/bin/python3 /usr/bin/python
  [ -x /usr/bin/certbot ] && mkdir -p /opt/certbot/bin && ln -sf /usr/bin/certbot /opt/certbot/bin/certbot
  ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
  ln -sf /usr/local/openresty/nginx/ /etc/nginx

  # Dummy SSL certificates
  if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
    openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
      -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
      -keyout /data/nginx/dummykey.pem \
      -out /data/nginx/dummycert.pem
  fi

  # Install certbot DNS plugin in user space (avoids system pip issues)
  python3 -m pip install --user --no-cache-dir certbot-dns-cloudflare

  # Guarded patch for certbot venv (only if it exists)
  if [ -f /opt/certbot/pyvenv.cfg ]; then
    sed -i 's/include-system-site-packages = false/include-system-site-packages = true/g' /opt/certbot/pyvenv.cfg
  fi

  msg_ok "Setup Environment"
}

# --- Main install ---
start
build_container
description

# Prereqs
msg_info "Installing prerequisites"
$STD apt update
$STD apt install -y curl git python3 python3-pip build-essential openssl

# Hardened Node/npm/pnpm
msg_info "Installing Node.js via nvm"
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22
msg_ok "Installed Node 22"

msg_info "Updating npm and enabling Corepack"
$STD npm install -g npm@latest
corepack enable
corepack prepare pnpm@latest --activate
msg_ok "Enabled Corepack and pnpm@latest"

# Fetch and build
msg_info "Fetching latest NPM release"
RELEASE=$(curl -fsSL https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest \
  | grep "tag_name" | awk '{print substr($2, 3, length($2)-4) }')
curl -fsSL "https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v${RELEASE}" | tar -xz
cd nginx-proxy-manager-"${RELEASE}" || exit
msg_ok "Fetched NPM v${RELEASE}"

msg_info "Building Frontend"
(
  sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" backend/package.json
  sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" frontend/package.json
  export NODE_OPTIONS=--openssl-legacy-provider
  cd ./frontend || exit
  pnpm install --no-frozen-lockfile
  pnpm upgrade
  pnpm run build
)
msg_ok "Built Frontend"

# Environment and backend
setup_environment "$RELEASE"

msg_info "Initializing Backend"
$STD rm -rf /app/config/default.json
if [ ! -f /app/config/production.json ]; then
  cat <<'EOF' >/app/config/production.json
{
  "database": {
    "engine": "knex-native",
    "knex": {
      "client": "sqlite3",
      "connection": {
        "filename": "/data/database.sqlite"
      }
    }
  }
}
EOF
fi
cd /app || exit
pnpm install
msg_ok "Initialized Backend"

# Start services with LXC patches
msg_info "Starting Services"
sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf
sed -i 's/su npm npm/su root root/g' /etc/logrotate.d/nginx-proxy-manager
sed -i 's/include-system-site-packages = false/include-system-site-packages = true/g' /opt/certbot/pyvenv.cfg
systemctl enable -q --now openresty
systemctl enable -q --now npm
msg_ok "Started Services"

# Final banner
msg_ok "Completed Successfully!\n"
echo -e "${CREATING}${GN}${APP} setup has been successfully initialized!${CL}"
echo -e "${INFO}${YW} Access it using the following URL:${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:81${CL}"
