#!/bin/bash
set -e

# --- Helper Functions ---
log_info() {
  echo "[INFO] $1"
}

log_warn() {
  echo "[WARN] $1"
}

log_error() {
  echo "[ERROR] $1" >&2
}

log_success() {
  echo "[SUCCESS] $1"
}

# --- Installation Function ---
install_peertube() {
  read -p "Enter your domain name for PeerTube (e.g., peertube.example.com): " PEERTUBE_DOMAIN
  if [[ -z "$PEERTUBE_DOMAIN" ]]; then
    log_error "Domain name cannot be empty. Exiting."
    exit 1
  fi

  read -sp "Enter a password for the 'peertube' system user: " PEERTUBE_SYSTEM_USER_PASSWORD
  echo
  if [[ -z "$PEERTUBE_SYSTEM_USER_PASSWORD" ]]; then
    log_error "PeerTube system user password cannot be empty. Exiting."
    exit 1
  fi

  read -sp "Enter a password for the 'peertube' PostgreSQL database user: " PEERTUBE_DB_PASSWORD
  echo
  if [[ -z "$PEERTUBE_DB_PASSWORD" ]]; then
    log_error "PeerTube database password cannot be empty. Exiting."
    exit 1
  fi

  read -p "Enter the email address for the PeerTube administrator (root user) (used for SSL cert): " PEERTUBE_ADMIN_EMAIL
  if [[ -z "$PEERTUBE_ADMIN_EMAIL" ]]; then
    log_error "Admin email cannot be empty. Exiting."
    exit 1
  fi

  echo "--- INSTALLATION SUMMARY ---"
  echo "PeerTube Domain: $PEERTUBE_DOMAIN"
  echo "PeerTube Admin Email: $PEERTUBE_ADMIN_EMAIL"
  echo "PeerTube System User: peertube"
  echo "PeerTube DB User: peertube"
  echo "---"
  read -p "Proceed with installation? (y/N): " CONFIRM
  if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    log_info "Installation cancelled."
    exit 0
  fi

  log_info "Updating system packages..."
  apt-get update -y
  apt-get upgrade -y

  log_info "Installing basic dependencies (curl, sudo, unzip, vim, gnupg)..."
  apt-get install -y curl sudo unzip vim gnupg apt-transport-https

  log_info "Attempting to remove any existing older NodeJS versions and libnode-dev..."
  if dpkg -l | grep -q 'libnode-dev'; then
    log_warn "'libnode-dev' is installed. Attempting to remove it along with old nodejs."
    apt-get remove --purge -y nodejs libnode-dev
    if dpkg -l | grep -q 'libnode-dev'; then
      log_warn "Failed to remove 'libnode-dev' with apt-get. Trying dpkg --force-depends."
      dpkg --remove --force-depends libnode-dev || echo "[WARN] dpkg remove failed for libnode-dev, but continuing if error was minor."
      if dpkg -l | grep -q 'libnode-dev'; then
          log_error "'libnode-dev' could not be removed. Please resolve this manually. The file /usr/include/node/common.gypi is causing a conflict."
          exit 1
      fi
    fi
  else
    log_info "'libnode-dev' not found, proceeding with NodeJS installation."
    apt-get remove --purge -y nodejs > /dev/null 2>&1 || true
  fi
  apt-get autoremove -y
  apt-get clean

  NODE_MAJOR=20
  log_info "Setting up Nodesource repository and installing NodeJS ${NODE_MAJOR}.x..."
  curl -fsSL https://deb.nodesource.com/setup_${NODE_MAJOR}.x | sudo -E bash -
  apt-get update -y
  apt-get install -y nodejs

  log_info "NodeJS version:"
  node -v
  log_info "NPM version:"
  npm -v

  log_info "Installing Yarn..."
  npm install --global yarn
  log_info "Yarn version:"
  yarn --version

  log_info "Installing PostgreSQL, Nginx, Redis, FFmpeg, Certbot, jq, and other dependencies..."
  apt-get install -y \
    postgresql postgresql-contrib \
    nginx \
    redis-server \
    ffmpeg \
    g++ make openssl libssl-dev \
    python3-dev \
    cron \
    wget \
    certbot python3-certbot-nginx jq

  log_info "Starting and enabling PostgreSQL and Redis..."
  systemctl start postgresql
  systemctl enable postgresql
  systemctl start redis-server
  systemctl enable redis-server

  log_info "Creating 'peertube' system user..."
  if id "peertube" &>/dev/null; then
    log_warn "'peertube' user already exists. Skipping creation, but ensuring home directory exists."
    mkdir -p /var/www/peertube
    chown peertube:peertube /var/www/peertube
  else
    useradd -m -d /var/www/peertube -s /bin/bash peertube
  fi
  echo "peertube:$PEERTUBE_SYSTEM_USER_PASSWORD" | chpasswd
  log_success "'peertube' system user configured."

  log_info "Setting up PostgreSQL database for PeerTube..."
  sudo -u postgres psql -c "CREATE USER peertube WITH PASSWORD '$PEERTUBE_DB_PASSWORD';" || log_warn "PostgreSQL user 'peertube' might already exist."
  sudo -u postgres psql -c "CREATE DATABASE peertube_prod OWNER peertube ENCODING 'UTF8' TEMPLATE template0;" || log_warn "Database 'peertube_prod' might already exist."
  sudo -u postgres psql -d peertube_prod -c "CREATE EXTENSION IF NOT EXISTS pg_trgm;" || log_warn "Could not enable pg_trgm extension."
  sudo -u postgres psql -d peertube_prod -c "CREATE EXTENSION IF NOT EXISTS unaccent;" || log_warn "Could not enable unaccent extension."
  log_success "PostgreSQL database setup complete."

  log_info "Fetching latest PeerTube version tag..."
  PEERTUBE_VERSION=$(curl -s https://api.github.com/repos/Chocobozzz/PeerTube/releases/latest | jq -r .tag_name | sed 's/v//')
  if [[ -z "$PEERTUBE_VERSION" ]]; then
    log_warn "Could not automatically fetch latest PeerTube version. Please check manually."
    read -p "Enter PeerTube version to install (e.g., 7.1.0): " PEERTUBE_VERSION
    if [[ -z "$PEERTUBE_VERSION" ]]; then
      log_error "Version required. Exiting."
      exit 1
    fi
  fi
  log_info "Latest PeerTube version identified as: v$PEERTUBE_VERSION"

  log_info "Preparing PeerTube directories..."
  mkdir -p /var/www/peertube/{versions,storage,config}
  chown -R peertube:peertube /var/www/peertube

  log_info "Downloading PeerTube v$PEERTUBE_VERSION..."
  cd /var/www/peertube/versions
  sudo -u peertube wget -q "https://github.com/Chocobozzz/PeerTube/releases/download/v${PEERTUBE_VERSION}/peertube-v${PEERTUBE_VERSION}.zip"
  log_info "Unzipping PeerTube..."
  sudo -u peertube unzip -o -q "peertube-v${PEERTUBE_VERSION}.zip"
  sudo -u peertube rm "peertube-v${PEERTUBE_VERSION}.zip"

  log_info "Installing PeerTube..."
  cd /var/www/peertube
  sudo -u peertube ln -sfn versions/peertube-v$PEERTUBE_VERSION peertube-latest
  cd peertube-latest
  sudo -u peertube yarn install --production --pure-lockfile
  log_success "PeerTube installation complete."

  log_info "Configuring PeerTube (production.yaml)..."
  CONFIG_DIR="/var/www/peertube/config"
  PRODUCTION_YAML="$CONFIG_DIR/production.yaml"
  PRODUCTION_EXAMPLE_YAML="/var/www/peertube/peertube-latest/config/production.yaml.example"

  if [ ! -f "$PRODUCTION_YAML" ]; then
      sudo -u peertube cp "$PRODUCTION_EXAMPLE_YAML" "$PRODUCTION_YAML"
  else
      chown peertube:peertube "$PRODUCTION_YAML"
  fi

  log_info "Setting basic configuration in $PRODUCTION_YAML..."
  sudo -u peertube sed -i -E "s|^(\s*hostname:\s*).*|\1'$PEERTUBE_DOMAIN'|" "$PRODUCTION_YAML"
  sudo -u peertube perl -0777 -i -pe "s/(webserver\s*:\s*.*?port\s*:\s*)(\d+)/\19000/s" "$PRODUCTION_YAML"
  sudo -u peertube perl -0777 -i -pe "s/(webserver\s*:\s*.*?listen_address\s*:\s*')([^']+?)(')/\10.0.0.0\3/s" "$PRODUCTION_YAML"
  
  log_info "Configuring database connection..."
  sudo -u peertube perl -0777 -i -pe "s/(database\s*:\s*.*?username\s*:\s*')([^']+?)(')/\1peertube\3/s" "$PRODUCTION_YAML"
  sudo -u peertube perl -0777 -i -pe "s/(database\s*:\s*.*?password\s*:\s*')([^']+?)(')/\1$PEERTUBE_DB_PASSWORD\3/s" "$PRODUCTION_YAML"

  log_info "Configuring admin email..."
  sudo -u peertube perl -0777 -i -pe "s/(admin\s*:\s*.*?email\s*:\s*')([^']+?)(')/\1$PEERTUBE_ADMIN_EMAIL\3/s" "$PRODUCTION_YAML"

  chown -R peertube:peertube "$CONFIG_DIR"
  chmod 640 "$PRODUCTION_YAML"

  log_success "PeerTube basic configuration written."
  log_warn "You may need to further customize $PRODUCTION_YAML for advanced features (email, federation, etc.)."

  log_info "Configuring Nginx for $PEERTUBE_DOMAIN..."
  NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
  NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
  NGINX_CONF_PEERTUBE="$NGINX_SITES_AVAILABLE_DIR/$PEERTUBE_DOMAIN"
  CERTBOT_WEBROOT="/var/www/certbot" 

  mkdir -p "$CERTBOT_WEBROOT"
  chown www-data:www-data "$CERTBOT_WEBROOT"

  log_info "Creating temporary Nginx config for Certbot challenge..."
  cat << EOF > "$NGINX_CONF_PEERTUBE"
server {
    listen 80;
    listen [::]:80;
    server_name $PEERTUBE_DOMAIN;

    location /.well-known/acme-challenge/ {
        root $CERTBOT_WEBROOT;
        try_files \$uri =404;
    }

    location / {
        # This can be a simple placeholder or a temporary redirect that Certbot will replace
        # return 301 https://\$host\$request_uri; # Certbot often prefers to manage this itself
        return 404; # Or just a 404 until Certbot configures SSL
    }
}
EOF

  log_info "Enabling temporary Nginx site for $PEERTUBE_DOMAIN..."
  rm -f "$NGINX_SITES_ENABLED_DIR/$PEERTUBE_DOMAIN"
  ln -sfn "$NGINX_CONF_PEERTUBE" "$NGINX_SITES_ENABLED_DIR/$PEERTUBE_DOMAIN"

  log_info "Testing temporary Nginx configuration for Certbot..."
  if ! nginx -t; then
    log_error "Temporary Nginx configuration test failed for Certbot!"
    cat "$NGINX_CONF_PEERTUBE"
    exit 1
  fi
  log_success "Temporary Nginx configuration test successful."

  log_info "Reloading Nginx for Certbot HTTP challenge..."
  systemctl reload-or-restart nginx

  log_info "Obtaining SSL certificate for $PEERTUBE_DOMAIN with Certbot..."
  # --nginx plugin will find the above HTTP block and modify it for SSL.
  certbot --nginx -d "$PEERTUBE_DOMAIN" --non-interactive --agree-tos -m "$PEERTUBE_ADMIN_EMAIL" --redirect --keep-until-expiring

  log_info "Replacing Certbot-modified config with the full PeerTube template, then applying certs..."
  # Save what Certbot did, in case we need to reference its SSL settings
  mv "$NGINX_CONF_PEERTUBE" "${NGINX_CONF_PEERTUBE}.certbot_modified"
  sudo cp /var/www/peertube/peertube-latest/support/nginx/peertube "$NGINX_CONF_PEERTUBE"

  # Replace domain name placeholders
  sed -i "s/\${PEERTUBE_DOMAIN}/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/PEERTUBE_DOMAIN/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/\${WEBSERVER_HOST}/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/WEBSERVER_HOST/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"

  # Replace PEERTUBE_HOST placeholder for the upstream backend
  sed -i 's|server "\${PEERTUBE_HOST}";|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  sed -i 's|server \${PEERTUBE_HOST};|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  sed -i 's|server PEERTUBE_HOST;|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  
  # Ensure SSL is on for port 443 in the full template
  sed -i -E 's|listen\s+443(\s+http2)?\s*;|listen 443 ssl\1;|g' "$NGINX_CONF_PEERTUBE"
  sed -i -E 's|listen\s+\[::\]:443(\s+http2)?\s*;|listen \[::\]:443 ssl\1;|g' "$NGINX_CONF_PEERTUBE"

  # Set the certificate paths
  FULLCHAIN_PATH="/etc/letsencrypt/live/$PEERTUBE_DOMAIN/fullchain.pem"
  PRIVKEY_PATH="/etc/letsencrypt/live/$PEERTUBE_DOMAIN/privkey.pem"
  sed -i "s|^\(\s*ssl_certificate\s\+\).*;\s*$|\1$FULLCHAIN_PATH;|" "$NGINX_CONF_PEERTUBE"
  sed -i "s|^\(\s*ssl_certificate_key\s\+\).*;\s*$|\1$PRIVKEY_PATH;|" "$NGINX_CONF_PEERTUBE"

  # Add Certbot's recommended SSL options if not already present from template or Certbot's modification
  if ! grep -q "include /etc/letsencrypt/options-ssl-nginx.conf;" "$NGINX_CONF_PEERTUBE"; then
      sed -i "/ssl_certificate_key/a \    include /etc/letsencrypt/options-ssl-nginx.conf;" "$NGINX_CONF_PEERTUBE"
  fi
  if ! grep -q "ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;" "$NGINX_CONF_PEERTUBE"; then
      sed -i "/include \/etc\/letsencrypt\/options-ssl-nginx.conf;/a \    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;" "$NGINX_CONF_PEERTUBE"
  fi
  # Comment out duplicate SSL settings from the template if options-ssl-nginx.conf is included
  if grep -q "include /etc/letsencrypt/options-ssl-nginx.conf;" "$NGINX_CONF_PEERTUBE"; then
    sed -i -E 's|^(\s*ssl_protocols\s+[^;]+;)|# Original template (now handled by options-ssl-nginx.conf): \1|' "$NGINX_CONF_PEERTUBE"
    sed -i -E 's|^(\s*ssl_prefer_server_ciphers\s+on;)|# Original template (now handled by options-ssl-nginx.conf): \1|' "$NGINX_CONF_PEERTUBE"
  fi

  log_info "Final Nginx configuration test with SSL (after Certbot and full template)..."
  if ! nginx -t; then
      log_error "Nginx configuration test FAILED after Certbot setup and applying full template!"
      log_error "Contents of /etc/nginx/sites-enabled/$PEERTUBE_DOMAIN :"
      cat "$NGINX_CONF_PEERTUBE" || log_error "Could not display site config."
      log_error "Check the Nginx site configuration file and output of 'nginx -t' for details."
      log_error "You may need to manually edit /etc/nginx/sites-available/$PEERTUBE_DOMAIN to fix it."
      exit 1
  fi
  log_success "Final Nginx configuration with SSL test successful."

  log_info "Reloading Nginx with SSL configuration..."
  systemctl reload-or-restart nginx
  log_success "Nginx configured and reloaded with SSL."

  log_info "Setting up Systemd service for PeerTube..."
  PEERTUBE_SERVICE_FILE="/etc/systemd/system/peertube.service"
  sudo cp /var/www/peertube/peertube-latest/support/systemd/peertube.service "$PEERTUBE_SERVICE_FILE"

  sed -i "s|^User=peertube|User=peertube|" "$PEERTUBE_SERVICE_FILE"
  sed -i "s|^Group=peertube|Group=peertube|" "$PEERTUBE_SERVICE_FILE"
  sed -i "s|^WorkingDirectory=/var/www/peertube/peertube-latest|WorkingDirectory=/var/www/peertube/peertube-latest|" "$PEERTUBE_SERVICE_FILE"
  
  YARN_PATH=$(which yarn)
  if [ -z "$YARN_PATH" ]; then
    log_error "Yarn command not found. Please ensure Yarn is installed and in PATH for the root user."
    exit 1
  fi
  sed -i "s|^ExecStart=.*|ExecStart=$YARN_PATH start --production|" "$PEERTUBE_SERVICE_FILE"

  systemctl daemon-reload
  systemctl enable --now peertube
  log_success "PeerTube service started and enabled."

  log_info "Waiting a few seconds for PeerTube to fully initialize..."
  sleep 15

  log_success "PeerTube installation should be complete!"
  echo "--------------------------------------------------------------------"
  echo " Access your PeerTube instance at: https://$PEERTUBE_DOMAIN"
  echo ""
  echo " IMPORTANT: Your initial 'root' administrator password for PeerTube"
  echo " has been generated. You need to find it in the PeerTube logs."
  echo " Run the following command to check the logs:"
  echo "   sudo journalctl -feu peertube | grep -A5 -B2 'User password'"
  echo " Or search for 'Default password for root user is'"
  echo " Or 'User password' in the output of 'sudo journalctl -feu peertube'"
  echo ""
  echo " Login as 'root' with this password and CHANGE IT IMMEDIATELY."
  echo " Also, verify the admin email in PeerTube's admin settings."
  echo "--------------------------------------------------------------------"
}

uninstall_peertube() {
  read -p "Enter the domain name of the PeerTube instance to uninstall (e.g., peertube.example.com): " PEERTUBE_DOMAIN_UNINSTALL
  if [[ -z "$PEERTUBE_DOMAIN_UNINSTALL" ]]; then
    log_error "Domain name for uninstallation cannot be empty. Exiting."
    exit 1
  fi

  echo "--- UNINSTALLATION WARNING ---"
  echo "This will attempt to remove PeerTube for the domain: $PEERTUBE_DOMAIN_UNINSTALL"
  echo "This includes:"
  echo "  - Stopping and disabling the PeerTube service."
  echo "  - Removing the PeerTube systemd service file."
  echo "  - Disabling and removing the Nginx site configuration."
  echo "  - Attempting to delete the SSL certificate for $PEERTUBE_DOMAIN_UNINSTALL."
  echo "  - DELETING ALL PEERTUBE FILES in /var/www/peertube (videos, configs, etc.)."
  echo "  - DROPPING THE PEERTUBE DATABASE (peertube_prod)."
  echo "  - DELETING THE POSTGRESQL USER 'peertube'."
  echo "  - DELETING THE SYSTEM USER 'peertube'."
  echo "This action is IRREVERSIBLE and will result in DATA LOSS for this PeerTube instance."
  echo "SHARED DEPENDENCIES (Nginx, PostgreSQL, Redis, FFmpeg, Node.js) WILL NOT BE UNINSTALLED."
  echo "---"
  read -p "Are you absolutely sure you want to proceed with uninstallation? (Type 'yes' to confirm): " CONFIRM_UNINSTALL
  if [[ "$CONFIRM_UNINSTALL" != "yes" ]]; then
    log_info "Uninstallation cancelled."
    exit 0
  fi

  log_info "Starting PeerTube uninstallation for $PEERTUBE_DOMAIN_UNINSTALL..."

  log_info "Stopping and disabling PeerTube service..."
  systemctl stop peertube || log_warn "PeerTube service already stopped or not found."
  systemctl disable peertube || log_warn "PeerTube service already disabled or not found."
  rm -f /etc/systemd/system/peertube.service
  systemctl daemon-reload

  log_info "Disabling and removing Nginx site configuration for $PEERTUBE_DOMAIN_UNINSTALL..."
  NGINX_SITES_AVAILABLE_DIR="/etc/nginx/sites-available"
  NGINX_SITES_ENABLED_DIR="/etc/nginx/sites-enabled"
  rm -f "$NGINX_SITES_ENABLED_DIR/$PEERTUBE_DOMAIN_UNINSTALL"
  rm -f "$NGINX_SITES_AVAILABLE_DIR/$PEERTUBE_DOMAIN_UNINSTALL"
  log_info "Reloading Nginx..."
  if nginx -t; then
    systemctl reload nginx || log_warn "Nginx reload failed."
  else
    log_warn "Nginx configuration test failed after removing site. Nginx not reloaded. Please check main Nginx config."
  fi


  log_info "Attempting to remove SSL certificate for $PEERTUBE_DOMAIN_UNINSTALL..."
  if command -v certbot &> /dev/null; then
    certbot delete --cert-name "$PEERTUBE_DOMAIN_UNINSTALL" --non-interactive || log_warn "Certbot failed to delete certificate (it might not exist or another error occurred)."
  else
    log_warn "Certbot command not found, cannot remove SSL certificate automatically."
  fi

  log_info "Removing PeerTube application files in /var/www/peertube..."
  if [ -d "/var/www/peertube" ]; then
    rm -rf /var/www/peertube
    log_success "Removed /var/www/peertube directory."
  else
    log_warn "/var/www/peertube directory not found."
  fi

  log_info "Dropping PeerTube PostgreSQL database and user..."
  sudo -u postgres psql -c "DROP DATABASE IF EXISTS peertube_prod;" || log_warn "Failed to drop database peertube_prod (might not exist)."
  sudo -u postgres psql -c "DROP USER IF EXISTS peertube;" || log_warn "Failed to drop user peertube (might not exist)."
  log_success "PostgreSQL cleanup attempted."

  log_info "Removing 'peertube' system user..."
  if id "peertube" &>/dev/null; then
    userdel -r peertube || log_warn "Failed to remove user 'peertube' (some files might need manual cleanup if home dir wasn't in /var/www/peertube or was mounted)."
    log_success "'peertube' system user removed."
  else
    log_warn "'peertube' system user not found."
  fi

  log_success "PeerTube uninstallation for $PEERTUBE_DOMAIN_UNINSTALL attempted."
  log_warn "Remember that shared dependencies (Nginx, PostgreSQL, Node.js, etc.) were NOT uninstalled."
  log_warn "You may need to manually clean up any remaining Nginx snippets or other configurations if they were customized outside this script."
}

# --- Main Script Logic ---
echo "PeerTube Management Script"
echo "--------------------------"
echo "1. Install PeerTube"
echo "2. Uninstall PeerTube"
read -p "Choose an option (1 or 2): " MAIN_CHOICE

case $MAIN_CHOICE in
  1)
    install_peertube
    ;;
  2)
    uninstall_peertube
    ;;
  *)
    log_error "Invalid option. Exiting."
    exit 1
    ;;
esac

exit 0
