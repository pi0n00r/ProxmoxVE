#!/usr/bin/env bash
set -e

APP="Nginx Proxy Manager"

echo "=== Installing prerequisites ==="
apt update && apt install -y curl git python3 python3-pip build-essential openssl

echo "=== Installing Node.js via nvm ==="
curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
nvm install 22
nvm alias default 22

echo "=== Updating npm and enabling Corepack ==="
npm install -g npm@latest
corepack enable
corepack prepare pnpm@latest --activate

echo "=== Fetching latest NPM release ==="
RELEASE=$(curl -fsSL https://api.github.com/repos/NginxProxyManager/nginx-proxy-manager/releases/latest \
  | grep "tag_name" | cut -d '"' -f4 | sed 's/^v//')
curl -fsSL "https://codeload.github.com/NginxProxyManager/nginx-proxy-manager/tar.gz/v${RELEASE}" \
  | tar -xz
cd nginx-proxy-manager-"${RELEASE}"

echo "=== Building frontend ==="
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" backend/package.json
sed -i "s|\"version\": \"0.0.0\"|\"version\": \"$RELEASE\"|" frontend/package.json
cd frontend
pnpm install
pnpm upgrade
pnpm run build
cd ..

echo "=== Initializing backend ==="
rm -rf /app/config/default.json || true
if [ ! -f /app/config/production.json ]; then
  mkdir -p /app/config
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
cd backend
pnpm install
cd ..

echo "=== Setting up environment ==="
mkdir -p /app /data /etc/nginx /var/www/html
mkdir -p /tmp/nginx/body /run/nginx
mkdir -p /data/nginx/{default_host,default_www,proxy_host,redirection_host,stream,dead_host,temp}
mkdir -p /data/{custom_ssl,logs,access}
mkdir -p /var/lib/nginx/cache/{public,private} /var/cache/nginx/proxy_temp
chmod -R 777 /var/cache/nginx
chown root /tmp/nginx

# Symlinks
ln -sf /usr/bin/python3 /usr/bin/python
ln -sf /usr/bin/certbot /opt/certbot/bin/certbot
ln -sf /usr/local/openresty/nginx/sbin/nginx /usr/sbin/nginx
ln -sf /usr/local/openresty/nginx/ /etc/nginx

# Copy configs
cp -r docker/rootfs/var/www/html/* /var/www/html/
cp -r docker/rootfs/etc/nginx/* /etc/nginx/
cp docker/rootfs/etc/letsencrypt.ini /etc/letsencrypt.ini
cp docker/rootfs/etc/logrotate.d/nginx-proxy-manager /etc/logrotate.d/nginx-proxy-manager
ln -sf /etc/nginx/nginx.conf /etc/nginx/conf/nginx.conf
rm -f /etc/nginx/conf.d/dev.conf

# DNS resolvers
echo resolver "$(awk 'BEGIN{ORS=" "} $1=="nameserver" {print ($2 ~ ":")? "["$2"]": $2}' /etc/resolv.conf);" \
  >/etc/nginx/conf.d/include/resolvers.conf

# Dummy SSL certs
if [ ! -f /data/nginx/dummycert.pem ] || [ ! -f /data/nginx/dummykey.pem ]; then
  openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
    -subj "/O=Nginx Proxy Manager/OU=Dummy Certificate/CN=localhost" \
    -keyout /data/nginx/dummykey.pem \
    -out /data/nginx/dummycert.pem
fi

# Copy built app
mkdir -p /app/global /app/frontend/images
cp -r frontend/dist/* /app/frontend
cp -r frontend/app-images/* /app/frontend/images
cp -r backend/* /app
cp -r global/* /app/global

echo "=== Creating systemd services ==="

cat >/etc/systemd/system/openresty.service <<'EOF'
[Unit]
Description=OpenResty Web Platform
After=network.target

[Service]
Type=forking
PIDFile=/run/nginx.pid
ExecStartPre=/usr/local/openresty/nginx/sbin/nginx -t -q -g 'daemon on; master_process on;'
ExecStart=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;'
ExecReload=/usr/local/openresty/nginx/sbin/nginx -g 'daemon on; master_process on;' -s reload
ExecStop=/usr/local/openresty/nginx/sbin/nginx -s quit
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/npm.service <<'EOF'
[Unit]
Description=Nginx Proxy Manager Backend
After=network.target mariadb.service

[Service]
Type=simple
WorkingDirectory=/app
ExecStart=/usr/bin/node /app/index.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
User=root

[Install]
WantedBy=multi-user.target
EOF

echo "=== Patching configs for LXC ==="
sed -i 's/user npm/user root/g; s/^pid/#pid/g' /usr/local/openresty/nginx/conf/nginx.conf
sed -i 's/su npm npm/su root root/g' /etc/logrotate.d/nginx-proxy-manager

echo "=== Starting services ==="
systemctl daemon-reload
systemctl enable --now openresty
systemctl enable --now npm

echo "=== Build complete ==="
echo "Nginx Proxy Manager setup has been successfully initialized!"
echo "Access it using the following URL:"
echo "    http://$(hostname -I | awk '{print $1}'):81"
