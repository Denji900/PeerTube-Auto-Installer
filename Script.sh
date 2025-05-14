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
  sudo -u peertube sed -i "s|^\(\s*hostname:\s*\).*|\1'$PEERTUBE_DOMAIN'|" "$PRODUCTION_YAML"
  sudo -u peertube sed -i "s|^\(\s*port:\s*\).*|\1 9000|" "$PRODUCTION_YAML"
  sudo -u peertube sed -i "/webserver:/,/^[^[:space:]]/{s|^\(\s*listen:\s*\).*|\1 '0.0.0.0'|; s|^\(\s*port:\s*\).*|\1 9000|;}" "$PRODUCTION_YAML"

  log_info "Configuring database connection..."
  sudo -u peertube sed -i "s|^\(\s*username:\s*\).*|\1'peertube'|" "$PRODUCTION_YAML"
  sudo -u peertube sed -i "s|^\(\s*password:\s*\).*|\1'$PEERTUBE_DB_PASSWORD'|" "$PRODUCTION_YAML"

  log_info "Configuring admin email..."
  sudo -u peertube sed -i "s|^\(\s*email:\s*\).*|\1'$PEERTUBE_ADMIN_EMAIL'|" "$PRODUCTION_YAML"

  chown -R peertube:peertube "$CONFIG_DIR"
  chmod 640 "$PRODUCTION_YAML"

  log_success "PeerTube basic configuration written."
  log_warn "You may need to further customize $PRODUCTION_YAML for advanced features (email, federation, etc.)."

  log_info "Configuring Nginx for $PEERTUBE_DOMAIN..."
  NGINX_CONF_PEERTUBE="/etc/nginx/sites-available/$PEERTUBE_DOMAIN"
  sudo rm -f "$NGINX_CONF_PEERTUBE"
  sudo cp /var/www/peertube/peertube-latest/support/nginx/peertube "$NGINX_CONF_PEERTUBE"

  sed -i "s/\${PEERTUBE_DOMAIN}/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/PEERTUBE_DOMAIN/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/\${WEBSERVER_HOST}/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"
  sed -i "s/WEBSERVER_HOST/$PEERTUBE_DOMAIN/g" "$NGINX_CONF_PEERTUBE"

  sed -i 's|server "\${PEERTUBE_HOST}";|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  sed -i 's|server \${PEERTUBE_HOST};|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  sed -i 's|server PEERTUBE_HOST;|server 127.0.0.1:9000;|g' "$NGINX_CONF_PEERTUBE"
  
  log_info "Temporarily modifying Nginx site config for Certbot..."
  awk '
    BEGIN { server_block_count=0; in_targeted_block=0 }
    /server\s*\{/ {
      server_block_count++;
      block_buffer = $0; # Start buffer with the "server {" line
      # Determine if this is the block we want to comment (the SSL block)
      # by checking if it contains "listen 443" and NOT "listen 80"
      # We need to read ahead a bit to check for listen directives.
      is_ssl_block_candidate=0
      is_http_block_candidate=0
      
      # Temporarily slurp the block to check its listen directives
      temp_block_slurp = $0
      temp_line_holder = ""
      for (i=0;i<20;i++) { # Read a few lines or until end of block
          if (getline temp_line_holder <= 0) { break; } # EOF
          temp_block_slurp = temp_block_slurp "\n" temp_line_holder
          if (temp_line_holder ~ /listen\s+80[^0-9]/) { is_http_block_candidate=1; }
          if (temp_line_holder ~ /listen\s+443\s+ssl/) { is_ssl_block_candidate=1; }
          if (temp_line_holder ~ /^}/) { break; } # End of current server block
      }
      # Reset getline for main processing
      # This is tricky in awk; a simpler approach is to just process line by line for commenting

      # Simpler awk: if it finds the SSL listen line, start commenting until '}'
      # This still has issues if SSL block is before HTTP block.
      # For PeerTube template: HTTP block is first, THEN upstream, THEN HTTPS block.
      # Let's try to identify the SSL block more directly.
    }

    # More direct approach: If a line indicates an SSL server block, start a flag
    # This assumes the SSL block reliably contains "listen 443 ssl"
    # And the HTTP block does not contain "listen 443 ssl"
    # And that the upstream block is not mistaken for a server block
    
    # If we are inside an SSL block and it is the target one
    if (in_ssl_server_block_for_commenting) {
      if ($0 ~ /^}/) { # End of the SSL server block
        print "#TEMP_SSL_BLOCK_END#";
        print "# " $0; # Comment the closing brace
        in_ssl_server_block_for_commenting=0;
      } else {
        print "# " $0; # Comment lines within the block
      }
      next;
    }

    # Identify the start of the SSL server block
    # Check it is a server block, and it contains "listen 443 ssl"
    # and it is NOT the http block (which might have "listen 80")
    # This is still complex. A robust way is to use a multi-pass or more state.

    # Let's use a state machine based on typical peertube template order:
    # 1. http block (listen 80)
    # 2. upstream block
    # 3. https block (listen 443 ssl)
    if ($0 ~ /^\s*server\s*\{/) {
        current_server_block_content = $0
        is_http_block = 0
        is_ssl_block = 0
        # Read the whole block to determine its type
        block_lines = ""
        while (getline temp_line > 0) {
            current_server_block_content = current_server_block_content "\n" temp_line
            block_lines = block_lines temp_line "\n"
            if (temp_line ~ /listen\s+80[^0-9]/) { is_http_block = 1; }
            if (temp_line ~ /listen\s+443\s+ssl/) { is_ssl_block = 1; }
            if (temp_line ~ /^}/) { break; }
        }

        if (is_ssl_block && !is_http_block) {
            # This is the SSL block, comment it out
            print "#TEMP_SSL_BLOCK_START#"
            printf "%s", block_lines | awk "{print \"# \" \$0}"
            print "#TEMP_SSL_BLOCK_END#"
        } else if (is_http_block) {
            # This is the HTTP block, ensure redirect is commented for acme-challenge
            gsub (/^\s*location \/ *{ *return 301 https:\/\/\$host\$request_uri; *}/, "#TEMP_HTTP_REDIRECT#location / { return 301 https://\\$host\\$request_uri; }", current_server_block_content);
            print current_server_block_content
        } else {
            # Some other server block or couldn't determine, print as is
            print current_server_block_content
        }
        next
    }
    # Print lines not part of a server block (like upstream, or lines before first server block)
    { print }

  ' "$NGINX_CONF_PEERTUBE" > "${NGINX_CONF_PEERTUBE}.tmp" && mv "${NGINX_CONF_PEERTUBE}.tmp" "$NGINX_CONF_PEERTUBE"

  log_info "Enabling Nginx site for $PEERTUBE_DOMAIN..."
  ln -sfn "$NGINX_CONF_PEERTUBE" "/etc/nginx/sites-enabled/$PEERTUBE_DOMAIN"

  log_info "Testing Nginx configuration (HTTP only for Certbot)..."
  if ! nginx -t; then
    log_error "Nginx configuration test failed before Certbot!"
    log_info "Current content of $NGINX_CONF_PEERTUBE :"
    cat "$NGINX_CONF_PEERTUBE"
    log_error "Please check your main /etc/nginx/nginx.conf or the PeerTube site config for errors."
    exit 1
  fi
  log_success "Initial Nginx (HTTP only) configuration test successful."

  log_info "Reloading Nginx for Certbot HTTP challenge..."
  systemctl reload-or-restart nginx

  log_info "Obtaining SSL certificate for $PEERTUBE_DOMAIN with Certbot..."
  certbot --nginx -d "$PEERTUBE_DOMAIN" --non-interactive --agree-tos -m "$PEERTUBE_ADMIN_EMAIL" --redirect --keep-until-expiring

  log_info "Cleaning up temporary Nginx config modifications..."
  sed -i '/^#TEMP_SSL_BLOCK_START#$/d' "$NGINX_CONF_PEERTUBE"
  sed -i '/^#TEMP_SSL_BLOCK_END#$/d' "$NGINX_CONF_PEERTUBE"
  sed -i 's/^#TEMP_HTTP_REDIRECT# *//' "$NGINX_CONF_PEERTUBE"
  sed -i 's/^# *//' "$NGINX_CONF_PEERTUBE" # General uncomment for lines prefixed with "# "

  log_info "Final Nginx configuration test with SSL (after Certbot)..."
  if ! nginx -t; then
      log_error "Nginx configuration test FAILED after Certbot setup!"
      log_error "Contents of /etc/nginx/sites-enabled/$PEERTUBE_DOMAIN :"
      cat "/etc/nginx/sites-enabled/$PEERTUBE_DOMAIN" || log_error "Could not display site config."
      log_error "Check the Nginx site configuration file and output of 'nginx -t' for details."
      log_error "You may need to manually edit /etc/nginx/sites-available/$PEERTUBE_DOMAIN to fix it."
      exit 1
  fi
  log_success "Final Nginx configuration with SSL test successful."

  log_info "Reloading Nginx with SSL configuration..."
  systemctl reload-or-restart nginx
  log_success "Nginx configured and reloaded with SSL."

  log_info "Setting up Systemd service for PeerTube..."
  sudo cp /var/www/peertube/peertube-latest/support/systemd/peertube.service /etc/systemd/system/

  sed -i "s|^User=peertube|User=peertube|" /etc/systemd/system/peertube.service
  sed -i "s|^Group=peertube|Group=peertube|" /etc/systemd/system/peertube.service
  sed -i "s|^WorkingDirectory=/var/www/peertube/peertube-latest|WorkingDirectory=/var/www/peertube/peertube-latest|" /etc/systemd/system/peertube.service
  sed -i "s|ExecStart=/usr/bin/yarn start --production|ExecStart=$(which yarn) start --production|" /etc/systemd/system/peertube.service

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
  rm -f "/etc/nginx/sites-enabled/$PEERTUBE_DOMAIN_UNINSTALL"
  rm -f "/etc/nginx/sites-available/$PEERTUBE_DOMAIN_UNINSTALL"
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
