#!/bin/bash
set -uex
set -o pipefail

if [ -z "$1" ]; then
  echo "Usage: $0 <ssh-key-name>"
  exit 1
fi

KEY_NAME="$1"
LOCATION="eu-central-h1"
PREFIX="mastodon-demo"
PG_SUBNET="${PREFIX}-pg-subnet"
RELAY_URL="https://relay.toot.io/inbox"

# Helper function: wait for VM to be SSH-accessible
wait_for_ssh() {
  local vm_name=$1
  local max_attempts=${2:-60}
  local attempt=0
  
  echo "Waiting for SSH access to ${vm_name}..."
  while [ $attempt -lt $max_attempts ]; do
    if ubi vm "${LOCATION}/${vm_name}" ssh -- echo "SSH OK" 2>/dev/null; then
      echo "SSH to ${vm_name} is ready!"
      return 0
    fi
    sleep 2
    attempt=$((attempt + 1))
  done
  echo "Timeout waiting for SSH to ${vm_name}"
  return 1
}

# Helper function: get field with retry
get_field_with_retry() {
  local resource_type=$1
  local resource_name=$2
  local field=$3
  local max_attempts=${4:-30}
  local attempt=0
  
  while [ $attempt -lt $max_attempts ]; do
    local value=$(ubi ${resource_type} "${LOCATION}/${resource_name}" show -f ${field} 2>/dev/null | awk -F': ' 'NF==2 {print $2; exit}' || echo "")
    if [ -n "$value" ] && [ "$value" != "null" ] && [ "$value" != "" ]; then
      echo "$value"
      return 0
    fi
    sleep 1
    attempt=$((attempt + 1))
  done
  echo ""
  return 1
}

# 1. Managed PostgreSQL
ubi pg "${LOCATION}/${PREFIX}-pg" create \
  --size=burstable-2 \
  --storage-size=64 \
  --version=18 \
  --ha-type=none \
  --private-subnet-name=${PG_SUBNET}

# Poll for connection string
echo "Waiting for PostgreSQL connection string..."
attempt=0
while [ $attempt -lt 60 ]; do
  PG_CONN_RAW=$(ubi pg "${LOCATION}/${PREFIX}-pg" show -f connection-string 2>/dev/null || echo "")
  DATABASE_URL=$(echo "$PG_CONN_RAW" | grep "connection-string:" | sed 's/connection-string: //' || echo "")
  
  if [ -n "$DATABASE_URL" ] && [ "$DATABASE_URL" != "null" ]; then
    echo "PostgreSQL connection string available!"
    break
  fi
  
  sleep 2
  attempt=$((attempt + 1))
done

if [ -z "$DATABASE_URL" ]; then
  echo "ERROR: Timeout waiting for PostgreSQL connection string"
  exit 1
fi

# Create two versions of DATABASE_URL:
# 1. Ruby version: use channel_binding=require (implies SSL and prevents downgrade attacks)
# 2. Node version: use sslmode=no-verify (Node.js pg driver specific)

if echo "$DATABASE_URL" | grep -q '?'; then
  # URL already has query parameters - replace sslmode if exists, or add channel_binding
  DATABASE_URL_RUBY=$(echo "$DATABASE_URL" | sed 's/sslmode=[^&]*/channel_binding=require/')
  DATABASE_URL_NODE=$(echo "$DATABASE_URL" | sed 's/sslmode=[^&]*/sslmode=no-verify/')
else
  # URL has no query parameters yet
  DATABASE_URL_RUBY="${DATABASE_URL}?channel_binding=require"
  DATABASE_URL_NODE="${DATABASE_URL}?sslmode=no-verify"
fi

echo "Database URL (Ruby): $DATABASE_URL_RUBY"
echo "Database URL (Node): $DATABASE_URL_NODE"

# 2. Create firewalls
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" create --description="SSH access from internet"
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" add-rule --start-port=22 --description="SSH IPv6" "::/0"
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" add-rule --start-port=22 --description="SSH IPv4" "0.0.0.0/0"

ubi fw "${LOCATION}/${PREFIX}-https-internet-fw" create --description="HTTPS access from internet"
ubi fw "${LOCATION}/${PREFIX}-https-internet-fw" add-rule --start-port=443 --description="HTTPS IPv6" "::/0"
ubi fw "${LOCATION}/${PREFIX}-https-internet-fw" add-rule --start-port=443 --description="HTTPS IPv4" "0.0.0.0/0"

ubi fw "${LOCATION}/${PREFIX}-valkey-fw" create --description="Valkey internal access"
ubi fw "${LOCATION}/${PREFIX}-pg-fw" create --description="PostgreSQL internal access"


# 3. Create subnets with firewalls
ubi ps "${LOCATION}/${PREFIX}-valkey-subnet" create -f "${PREFIX}-valkey-fw"
ubi ps "${LOCATION}/${PREFIX}-web-subnet" create -f "${PREFIX}-https-internet-fw"
ubi ps "${LOCATION}/${PREFIX}-streaming-subnet" create -f "${PREFIX}-https-internet-fw"
ubi ps "${LOCATION}/${PREFIX}-sidekiq-subnet" create -f "${PREFIX}-ssh-internet-fw"

# Attach SSH firewall to all subnets
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" attach-subnet "${PREFIX}-valkey-subnet"
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" attach-subnet "${PREFIX}-web-subnet"
ubi fw "${LOCATION}/${PREFIX}-ssh-internet-fw" attach-subnet "${PREFIX}-streaming-subnet"

# 4. Create load balancers EARLY (so cert provisioning happens in parallel)
echo "Creating load balancers (cert provisioning will happen in background)..."

# Web load balancer
ubi lb "${LOCATION}/${PREFIX}-web" create \
  --algorithm=round_robin \
  --check-protocol=http \
  --check-endpoint=/health \
  --stack=dual \
  --cert-enabled=true \
  "${PREFIX}-web-subnet" \
  443 \
  443

# Streaming load balancer
ubi lb "${LOCATION}/${PREFIX}-streaming" create \
  --algorithm=round_robin \
  --check-protocol=http \
  --check-endpoint=/health \
  --stack=dual \
  --cert-enabled=true \
  "${PREFIX}-streaming-subnet" \
  443 \
  443

# 5. Connect subnets
for svc in web streaming sidekiq; do
  ubi ps "${LOCATION}/${PREFIX}-${svc}-subnet" connect "${PREFIX}-valkey-subnet" || true
  ubi ps "${LOCATION}/${PREFIX}-${svc}-subnet" connect "$PG_SUBNET" || true
done

# 6. Configure internal firewalls
for svc in web streaming sidekiq; do
  ubi fw "${LOCATION}/${PREFIX}-valkey-fw" add-rule \
    --start-port=6379 \
    --description="Allow Valkey access from ${svc}" \
    "${PREFIX}-${svc}-subnet"

  ubi fw "${LOCATION}/${PREFIX}-pg-fw" add-rule \
    --start-port 5432 \
    --description="Allow PostgreSQL access from ${svc}" \
    "${PREFIX}-${svc}-subnet"
done

# 7. Create Valkey VM
ubi vm "${LOCATION}/${PREFIX}-valkey-vm" create \
  --size=standard-2 \
  --storage-size=40 \
  --boot-image=ubuntu-noble \
  --private-subnet-id="${PREFIX}-valkey-subnet" \
  --unix-user=ubi \
  "$KEY_NAME"

# 8. Create Mastodon VMs
for svc in web streaming sidekiq; do
  size=standard-2
  if [ "$svc" = "web" ]; then
    size=standard-4
  fi
  
  ubi vm "${LOCATION}/${PREFIX}-${svc}-vm" create \
    --size=$size \
    --storage-size=80 \
    --boot-image=ubuntu-noble \
    --private-subnet-id="${PREFIX}-${svc}-subnet" \
    --unix-user=ubi \
    "$KEY_NAME"
done

# 9. Wait for VMs
wait_for_ssh "${PREFIX}-valkey-vm"
wait_for_ssh "${PREFIX}-web-vm"
wait_for_ssh "${PREFIX}-streaming-vm"
wait_for_ssh "${PREFIX}-sidekiq-vm"

# 10. Attach VMs to load balancers
echo "Attaching VMs to load balancers..."
ubi lb "${LOCATION}/${PREFIX}-web" attach-vm "${PREFIX}-web-vm"
ubi lb "${LOCATION}/${PREFIX}-streaming" attach-vm "${PREFIX}-streaming-vm"

WEB_LB_HOSTNAME=$(get_field_with_retry lb "${PREFIX}-web" hostname)
if [ -z "$WEB_LB_HOSTNAME" ]; then
  echo "ERROR: Could not get web load balancer hostname"
  exit 1
fi
echo "Web load balancer hostname: $WEB_LB_HOSTNAME"

STREAMING_LB_HOSTNAME=$(get_field_with_retry lb "${PREFIX}-streaming" hostname)
if [ -z "$STREAMING_LB_HOSTNAME" ]; then
  echo "ERROR: Could not get streaming load balancer hostname"
  exit 1
fi
echo "Streaming load balancer hostname: $STREAMING_LB_HOSTNAME"

# 11. Setup Valkey
echo "Setting up Valkey..."
VALKEY_PASSWORD=$(openssl rand -hex 32)
echo "Valkey password: $VALKEY_PASSWORD"

ubi vm "${LOCATION}/${PREFIX}-valkey-vm" ssh -- bash -s <<VALKEYEOF
set -uex
set -o pipefail
sudo apt-get update
sudo apt-get install -y valkey
sudo sed -i 's/bind 127.0.0.1 -::1/bind :: 0.0.0.0/' /etc/valkey/valkey.conf
echo "requirepass ${VALKEY_PASSWORD}" | sudo tee -a /etc/valkey/valkey.conf
sudo systemctl restart valkey-server
sudo systemctl enable valkey-server
VALKEYEOF

VALKEY_PRIVATE_IP6=$(get_field_with_retry vm "${PREFIX}-valkey-vm" private-ipv6)
if [ -z "$VALKEY_PRIVATE_IP6" ]; then
  echo "ERROR: Could not get Valkey private IPv6"
  exit 1
fi
echo "Valkey IPv6: $VALKEY_PRIVATE_IP6"

# 12. Setup Mastodon common packages
echo "Installing Docker and Mastodon images..."
for svc in web streaming sidekiq; do
  echo "Setting up ${svc} VM..."
  ubi vm "${LOCATION}/${PREFIX}-${svc}-vm" ssh -- bash -s <<'COMMONEOF'
set -uex
set -o pipefail
sudo apt-get update
sudo apt-get install -y docker.io docker-compose git curl nginx
sudo systemctl start docker
sudo systemctl enable docker
sudo usermod -aG docker ubi

mkdir -p /home/ubi/mastodon/public/system
sudo chown -R 991:991 /home/ubi/mastodon/public

sg docker -c "docker pull ghcr.io/mastodon/mastodon:v4.5.1"
sg docker -c "docker pull ghcr.io/mastodon/mastodon-streaming:v4.5.1"
COMMONEOF
done

# 13. Generate secrets
SECRET_KEY_BASE=$(openssl rand -hex 64)
OTP_SECRET=$(openssl rand -hex 64)

echo "Generating Active Record Encryption keys..."
ENCRYPTION_KEYS=$(ubi vm "${LOCATION}/${PREFIX}-web-vm" ssh -- bash <<'ENCEOF'
set -uex
set -o pipefail
sg docker -c "docker run --rm ghcr.io/mastodon/mastodon:v4.5.1 bin/rails db:encryption:init" | grep -E "^(ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY|ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT|ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY)="
ENCEOF
)

DETERMINISTIC_KEY=$(echo "$ENCRYPTION_KEYS" | grep DETERMINISTIC_KEY | cut -d= -f2)
KEY_DERIVATION_SALT=$(echo "$ENCRYPTION_KEYS" | grep KEY_DERIVATION_SALT | cut -d= -f2)
PRIMARY_KEY=$(echo "$ENCRYPTION_KEYS" | grep PRIMARY_KEY | cut -d= -f2)

# 14. Create .env.production files
# Ruby version (web and sidekiq) - uses channel_binding=require
cat > /tmp/env.production <<ENVFILE
LOCAL_DOMAIN=${WEB_LB_HOSTNAME}
STREAMING_API_BASE_URL=wss://${STREAMING_LB_HOSTNAME}
ALTERNATE_DOMAINS=${STREAMING_LB_HOSTNAME}
REDIS_URL=redis://default:${VALKEY_PASSWORD}@[${VALKEY_PRIVATE_IP6}]:6379/0
DATABASE_URL=${DATABASE_URL_RUBY}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
OTP_SECRET=${OTP_SECRET}
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${DETERMINISTIC_KEY}
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${KEY_DERIVATION_SALT}
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${PRIMARY_KEY}
RAILS_ENV=production
NODE_ENV=production
NODE_TLS_REJECT_UNAUTHORIZED=0

# Disable email delivery for demo
SMTP_DELIVERY_METHOD=test
SMTP_ENABLE_STARTTLS_AUTO=false
ENVFILE

# Node version (streaming) - uses sslmode=no-verify
cat > /tmp/env.production.streaming <<ENVFILE
LOCAL_DOMAIN=${WEB_LB_HOSTNAME}
STREAMING_API_BASE_URL=wss://${STREAMING_LB_HOSTNAME}
ALTERNATE_DOMAINS=${WEB_LB_HOSTNAME}
REDIS_URL=redis://default:${VALKEY_PASSWORD}@[${VALKEY_PRIVATE_IP6}]:6379/0
DATABASE_URL=${DATABASE_URL_NODE}
SECRET_KEY_BASE=${SECRET_KEY_BASE}
OTP_SECRET=${OTP_SECRET}
ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=${DETERMINISTIC_KEY}
ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=${KEY_DERIVATION_SALT}
ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=${PRIMARY_KEY}
RAILS_ENV=production
NODE_ENV=production
NODE_TLS_REJECT_UNAUTHORIZED=0
ENVFILE

# 15. Setup cert rotation script (reusable for web and streaming)
cat > /tmp/setup-cert-rotation.sh <<'CERT_SETUP'
#!/bin/bash
set -uex
set -o pipefail

SERVICE_NAME=$1

# Create directory for certificates
sudo mkdir -p /var/certs/${SERVICE_NAME}

# Generate the refresh script
sudo tee /usr/local/bin/${SERVICE_NAME}-cert-refresh > /dev/null <<'REFRESH_SCRIPT'
#!/bin/bash
set -e

CERT_BASE="/var/certs/SERVICE_NAME_PLACEHOLDER"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
NEW_DIR="$CERT_BASE/$TIMESTAMP"

mkdir -p "$NEW_DIR"

curl --fail --silent --show-error --max-time 30 \
  "http://[FD00:0B1C:100D:5afe:CE::]/load-balancer/cert.pem" \
  -o "$NEW_DIR/cert.pem"

curl --fail --silent --show-error --max-time 30 \
  "http://[FD00:0B1C:100D:5afe:CE::]/load-balancer/key.pem" \
  -o "$NEW_DIR/key.pem"

# Validate certs
openssl x509 -in "$NEW_DIR/cert.pem" -noout > /dev/null 2>&1
openssl pkey -in "$NEW_DIR/key.pem" -noout > /dev/null 2>&1

chmod 644 "$NEW_DIR/cert.pem"
chmod 600 "$NEW_DIR/key.pem"
chmod 755 "$NEW_DIR"

# Atomic symlink swap
ln -sfn "$NEW_DIR" "$CERT_BASE/current.tmp"
mv -Tf "$CERT_BASE/current.tmp" "$CERT_BASE/current"

# Cleanup old certs (keep last 7)
cd "$CERT_BASE" && ls -dt [0-9]* 2>/dev/null | tail -n +8 | xargs -r rm -rf

echo "Certificate rotation successful - new certs in $NEW_DIR"
REFRESH_SCRIPT

sudo sed -i "s/SERVICE_NAME_PLACEHOLDER/${SERVICE_NAME}/g" /usr/local/bin/${SERVICE_NAME}-cert-refresh
sudo chmod +x /usr/local/bin/${SERVICE_NAME}-cert-refresh

# Create systemd service
sudo tee /etc/systemd/system/${SERVICE_NAME}-cert-rotate.service > /dev/null <<SERVICE_UNIT
[Unit]
Description=Rotate ${SERVICE_NAME} TLS certificates from Ubicloud
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
User=root
ExecStart=/usr/local/bin/${SERVICE_NAME}-cert-refresh
ExecStartPost=/bin/systemctl reload nginx.service
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVICE_UNIT

# Create systemd timer
sudo tee /etc/systemd/system/${SERVICE_NAME}-cert-rotate.timer > /dev/null <<TIMER_UNIT
[Unit]
Description=Daily rotation of ${SERVICE_NAME} TLS certificates

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 03:00:00
RandomizedDelaySec=1h
Persistent=true

[Install]
WantedBy=timers.target
TIMER_UNIT

sudo systemctl daemon-reload
sudo systemctl enable ${SERVICE_NAME}-cert-rotate.timer
sudo systemctl start ${SERVICE_NAME}-cert-rotate.timer

# Run initial cert fetch with retry
echo "Fetching initial certificates for ${SERVICE_NAME}..."
for i in {1..60}; do
  if sudo /usr/local/bin/${SERVICE_NAME}-cert-refresh; then
    echo "Initial certificates fetched successfully!"
    break
  fi
  echo "Certificates not ready yet (attempt $i/60), waiting..."
  sleep 5
done

if [ ! -d "/var/certs/${SERVICE_NAME}/current" ]; then
  echo "ERROR: Failed to fetch initial certificates"
  exit 1
fi
CERT_SETUP

chmod +x /tmp/setup-cert-rotation.sh

# 16. Setup web service
echo "Deploying web service..."

ubi vm "${LOCATION}/${PREFIX}-web-vm" scp /tmp/env.production :mastodon/.env.production
ubi vm "${LOCATION}/${PREFIX}-web-vm" scp /tmp/setup-cert-rotation.sh :/tmp/setup-cert-rotation.sh

# Setup certs and nginx for web
ubi vm "${LOCATION}/${PREFIX}-web-vm" ssh -- bash <<'WEBEOF'
set -uex
set -o pipefail

# Setup cert rotation
/tmp/setup-cert-rotation.sh mastodon-web

# Create Nginx config
sudo tee /etc/nginx/sites-available/mastodon <<'NGXCONF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

upstream backend {
  server 127.0.0.1:3000 fail_timeout=0;
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name _;

  ssl_certificate /var/certs/mastodon-web/current/cert.pem;
  ssl_certificate_key /var/certs/mastodon-web/current/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!MEDIUM:!LOW:!aNULL:!NULL:!SHA;
  ssl_prefer_server_ciphers on;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  keepalive_timeout 70;
  sendfile on;
  client_max_body_size 80m;

  root /home/ubi/mastodon/public;

  gzip on;
  gzip_disable "msie6";
  gzip_vary on;
  gzip_proxied any;
  gzip_comp_level 6;
  gzip_buffers 16 8k;
  gzip_http_version 1.1;
  gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml image/x-icon;

  location / {
    try_files $uri @proxy;
  }

  location @proxy {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Proxy "";
    proxy_pass_header Server;

    proxy_pass http://backend;
    proxy_buffering on;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    tcp_nodelay on;
  }

  error_page 500 501 502 503 504 /500.html;
}
NGXCONF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/mastodon /etc/nginx/sites-enabled/mastodon
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

# Create docker-compose for web
cat > /home/ubi/mastodon/docker-compose.yml <<'DCEOF'
services:
  web:
    image: ghcr.io/mastodon/mastodon:v4.5.1
    restart: always
    env_file: .env.production
    command: bundle exec puma -C config/puma.rb
    network_mode: host
    volumes:
      - ./public/system:/mastodon/public/system
DCEOF

# Create systemd service for web
sudo tee /etc/systemd/system/mastodon-web.service > /dev/null <<'UNITEOF'
[Unit]
Description=Mastodon web Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/ubi/mastodon
ExecStart=/usr/bin/docker-compose up
ExecStop=/usr/bin/docker-compose down
Restart=always
RestartSec=10
User=ubi
Group=docker

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable mastodon-web.service
sudo systemctl start mastodon-web.service
WEBEOF

# 17. Setup streaming service
echo "Deploying streaming service..."

ubi vm "${LOCATION}/${PREFIX}-streaming-vm" scp /tmp/env.production.streaming :mastodon/.env.production
ubi vm "${LOCATION}/${PREFIX}-streaming-vm" scp /tmp/setup-cert-rotation.sh :/tmp/setup-cert-rotation.sh

# Setup certs and nginx for streaming
ubi vm "${LOCATION}/${PREFIX}-streaming-vm" ssh -- bash <<'STREAMINGEOF'
set -uex
set -o pipefail

# Setup cert rotation
/tmp/setup-cert-rotation.sh mastodon-streaming

# Create Nginx config
sudo tee /etc/nginx/sites-available/mastodon-streaming <<'NGXCONF'
map $http_upgrade $connection_upgrade {
  default upgrade;
  ''      close;
}

upstream streaming {
  server 127.0.0.1:4000 fail_timeout=0;
}

server {
  listen 443 ssl http2;
  listen [::]:443 ssl http2;
  server_name _;

  ssl_certificate /var/certs/mastodon-streaming/current/cert.pem;
  ssl_certificate_key /var/certs/mastodon-streaming/current/key.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  ssl_ciphers HIGH:!MEDIUM:!LOW:!aNULL:!NULL:!SHA;
  ssl_prefer_server_ciphers on;
  ssl_session_cache shared:SSL:10m;
  ssl_session_tickets off;

  keepalive_timeout 70;

  location / {
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header Proxy "";

    proxy_pass http://streaming;
    proxy_buffering off;
    proxy_redirect off;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;

    tcp_nodelay on;
  }
}
NGXCONF

sudo rm -f /etc/nginx/sites-enabled/default
sudo ln -sf /etc/nginx/sites-available/mastodon-streaming /etc/nginx/sites-enabled/mastodon-streaming
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx

# Create docker-compose for streaming
cat > /home/ubi/mastodon/docker-compose.yml <<'DCEOF'
services:
  streaming:
    image: ghcr.io/mastodon/mastodon-streaming:v4.5.1
    restart: always
    env_file: .env.production
    command: node ./streaming/index.js
    network_mode: host
DCEOF

# Create systemd service for streaming
sudo tee /etc/systemd/system/mastodon-streaming.service > /dev/null <<'UNITEOF'
[Unit]
Description=Mastodon streaming Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/ubi/mastodon
ExecStart=/usr/bin/docker-compose up
ExecStop=/usr/bin/docker-compose down
Restart=always
RestartSec=10
User=ubi
Group=docker

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable mastodon-streaming.service
sudo systemctl start mastodon-streaming.service
STREAMINGEOF

# 18. Setup sidekiq service
echo "Deploying sidekiq service..."

ubi vm "${LOCATION}/${PREFIX}-sidekiq-vm" scp /tmp/env.production :mastodon/.env.production

ubi vm "${LOCATION}/${PREFIX}-sidekiq-vm" ssh -- bash <<'SIDEKIQEOF'
set -uex
set -o pipefail

cat > /home/ubi/mastodon/docker-compose.yml <<'DCEOF'
services:
  sidekiq:
    image: ghcr.io/mastodon/mastodon:v4.5.1
    restart: always
    env_file: .env.production
    command: bundle exec sidekiq
    network_mode: host
    volumes:
      - ./public/system:/mastodon/public/system
DCEOF

sudo tee /etc/systemd/system/mastodon-sidekiq.service > /dev/null <<'UNITEOF'
[Unit]
Description=Mastodon sidekiq Service
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/home/ubi/mastodon
ExecStart=/usr/bin/docker-compose up
ExecStop=/usr/bin/docker-compose down
Restart=always
RestartSec=10
User=ubi
Group=docker

[Install]
WantedBy=multi-user.target
UNITEOF

sudo systemctl daemon-reload
sudo systemctl enable mastodon-sidekiq.service
sudo systemctl start mastodon-sidekiq.service
SIDEKIQEOF

# 19. DB migration and seed
echo "Running database migrations and seeding roles..."
ubi vm "${LOCATION}/${PREFIX}-web-vm" ssh -- bash <<'MIGRATEEOF'
set -uex
set -o pipefail
cd /home/ubi/mastodon
sg docker -c "docker run --rm \
  --env-file .env.production \
  --network host \
  -v /home/ubi/mastodon/public/system:/mastodon/public/system \
  ghcr.io/mastodon/mastodon:v4.5.1 \
  bundle exec rails db:migrate"

sg docker -c "docker run --rm \
  --env-file .env.production \
  --network host \
  ghcr.io/mastodon/mastodon:v4.5.1 \
  bundle exec rake db:seed"
MIGRATEEOF

# 20. Create admin user with retry
echo "Creating admin user..."

for attempt in {1..10}; do
  echo "Attempt $attempt..."
  
  ADMIN_OUTPUT=$(ubi vm "${LOCATION}/${PREFIX}-web-vm" ssh -- bash <<ADMINEOF
set -ux
cd /home/ubi/mastodon
sg docker -c "docker run --rm --env-file .env.production --network host -v /home/ubi/mastodon/public/system:/mastodon/public/system ghcr.io/mastodon/mastodon:v4.5.1 tootctl accounts create admin --email admin@${WEB_LB_HOSTNAME} --confirmed --role Owner" 2>&1 || true
sg docker -c "docker run --rm --env-file .env.production --network host ghcr.io/mastodon/mastodon:v4.5.1 tootctl accounts modify admin --approve --confirm" 2>&1 || true
ADMINEOF
)
  
  if echo "$ADMIN_OUTPUT" | grep -q "New password:"; then
    echo "Success!"
    break
  fi
  
  [ $attempt -lt 10 ] && sleep 5
done

echo "$ADMIN_OUTPUT"
ADMIN_PASSWORD=$(echo "$ADMIN_OUTPUT" | grep "New password:" | awk '{print $NF}')

if [ -z "$ADMIN_PASSWORD" ]; then
  echo "WARNING: Admin creation failed after 10 attempts. Create manually after deployment."
  ADMIN_PASSWORD="<creation failed>"
fi

rm -f /tmp/env.production /tmp/env.production.streaming /tmp/setup-cert-rotation.sh

# Disable command tracing for clean final output
set +x

# Final output in heredoc for clean presentation
cat <<FINAL_OUTPUT

==========================================
Mastodon instance deployed successfully!
==========================================

Access your instance:
  URL: https://${WEB_LB_HOSTNAME}

Admin login credentials:
  Username: admin
  Email: admin@${WEB_LB_HOSTNAME}
  Password: ${ADMIN_PASSWORD}

Next steps:
  1. Log in at: https://${WEB_LB_HOSTNAME}/auth/sign_in
  2. Add federation relay at: https://${WEB_LB_HOSTNAME}/admin/relays
     - Click 'Add New Relay'
     - Enter relay URL: ${RELAY_URL}
     - Click 'Save and enable'
  3. Configure instance settings at: https://${WEB_LB_HOSTNAME}/admin/settings/edit
==========================================
FINAL_OUTPUT
