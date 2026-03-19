#!/bin/bash
# MSP Client Portal — Ubuntu 24.04 LTS StackScript
# Provisions an nginx + PHP-FPM server for the MSP portal framework.
# Ref: msp-portal-framework.md
#
# <UDF name="USERNAME"       label="Admin username"                                                              example="mspuser" />
# <UDF name="PASSWORD"       label="Admin password" />
# <UDF name="ADMIN_EMAIL"    label="Admin email address (used by acme.sh)"                                      example="admin@example.com" />
# <UDF name="PRIMARY_DOMAIN" label="Primary domain"                                                             example="portal.example.com" />
# <UDF name="OFFICE_IP"          label="MSP office IPs — comma-separated IPs, CIDRs, or FQDNs (ports 22/80/443)"  example="203.0.113.10,203.0.113.11,host.example.com" />
# <UDF name="NAMECHEAP_USERNAME" label="Namecheap account username (for DNS-01 cert validation via acme.sh)" />
# <UDF name="NAMECHEAP_API_KEY"  label="Namecheap API key (find under Profile, Tools, Namecheap API)" />

# ============================================================
# Init — verbose logging
# ============================================================
set -x
exec > >(tee -a /root/stackscript.log) 2>&1

echo "StackScript starting at $(date)"
echo "UDF Variables:"
echo "  USERNAME=${USERNAME}"
echo "  PRIMARY_DOMAIN=${PRIMARY_DOMAIN}"
echo "  ADMIN_EMAIL=${ADMIN_EMAIL}"
echo "  OFFICE_IP=${OFFICE_IP}"

set -e
export DEBIAN_FRONTEND=noninteractive

# ============================================================
# 1. System update
# ============================================================
echo "[1/13] Updating system..."
apt-get update -y
apt-get upgrade -y

# ============================================================
# 2. Hostname and FQDN
# ============================================================
echo "[2/13] Configuring hostname..."
HOSTNAME=$(echo "${PRIMARY_DOMAIN}" | cut -d. -f1)
echo "${HOSTNAME}" > /etc/hostname
hostname -F /etc/hostname
echo "127.0.1.1 ${PRIMARY_DOMAIN} ${HOSTNAME}" >> /etc/hosts

# ============================================================
# 3. Timezone
# ============================================================
echo "[3/13] Setting timezone to America/Anchorage..."
timedatectl set-timezone America/Anchorage

# ============================================================
# 4. Create admin user
# ============================================================
echo "[4/13] Creating user: ${USERNAME}..."
if [ -z "${USERNAME}" ]; then
    echo "ERROR: USERNAME is empty"
    exit 1
fi
useradd -m -s /bin/bash "${USERNAME}"
usermod -aG sudo "${USERNAME}"
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "User ${USERNAME} created successfully"

# Copy Linode-injected SSH keys from root to the admin user.
# Linode writes keys from your profile into /root/.ssh/authorized_keys at boot.
# Since root login is disabled, they must be copied to the admin user's home.
if [ -f /root/.ssh/authorized_keys ]; then
    mkdir -p /home/${USERNAME}/.ssh
    cp /root/.ssh/authorized_keys /home/${USERNAME}/.ssh/authorized_keys
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh
    chmod 700 /home/${USERNAME}/.ssh
    chmod 600 /home/${USERNAME}/.ssh/authorized_keys
    echo "SSH keys copied to ${USERNAME}"
else
    echo "WARNING: No /root/.ssh/authorized_keys found — SSH key login will not work until keys are added manually"
fi

# ============================================================
# 5. Install nginx, PHP, and Composer
# ============================================================
echo "[5/13] Installing packages..."
apt-get install -y curl unzip git

# Install nginx and PHP with extensions required by the MSP portal.
# Unversioned package names map to the distro default PHP version.
#   cli      — PHP CLI for running Composer
#   fpm      — PHP-FPM for nginx
#   mbstring — string handling (Composer / Slim 4 dependency)
#   xml      — XML processing (Composer dependency)
#   curl     — Azure Key Vault REST API and Microsoft Graph HTTP calls
#   ldap     — Active Directory / LDAPS connections (php ldap_* extension)
#   sqlite3  — SQLite app data store via PDO
#   zip      — Composer package extraction
apt-get install -y nginx php php-cli php-fpm php-mbstring php-xml php-curl php-ldap php-sqlite3 php-zip

# Detect the installed PHP version — needed for the FPM socket path and service name
PHP_VERSION=$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;')
echo "Installed PHP version: ${PHP_VERSION}"

# Install Composer globally
echo "Installing Composer..."
export COMPOSER_ALLOW_SUPERUSER=1
curl -sS https://getcomposer.org/installer | php -- --install-dir=/usr/local/bin --filename=composer
echo "Composer: $(composer --version)"

# ============================================================
# 6. UFW firewall — restrict all inbound to MSP office IP only
# ============================================================
echo "[6/13] Configuring UFW firewall..."
apt-get install -y ufw

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# OFFICE_IP accepts comma-separated IPs, CIDRs, and/or FQDNs.
# Static IPs/CIDRs are added as permanent rules.
# FQDNs are resolved now and also registered for periodic refresh — when the
# resolved IP changes, the refresh script removes the stale rule and adds the new one.

DDNS_DIR="/etc/ufw-dynamic"
mkdir -p "${DDNS_DIR}"
DDNS_FOUND=false

is_fqdn() {
    if echo "$1" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'; then
        return 1
    else
        return 0
    fi
}

resolve_to_ipv4() {
    local VALUE="$1"
    if echo "${VALUE}" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$'; then
        echo "${VALUE}"
    else
        local RESOLVED
        RESOLVED=$(getent hosts "${VALUE}" 2>/dev/null | awk '{print $1}' | grep -v ':' | head -1)
        if [ -n "${RESOLVED}" ]; then
            echo "${RESOLVED}"
        else
            echo "WARNING: Could not resolve '${VALUE}' — skipping" >&2
        fi
    fi
}

add_office_rules() {
    local IP="$1"
    local COMMENT="$2"
    ufw allow from "${IP}" to any port 22  proto tcp comment "${COMMENT}"
    ufw allow from "${IP}" to any port 80  proto tcp comment "${COMMENT}"
    ufw allow from "${IP}" to any port 443 proto tcp comment "${COMMENT}"
}

IFS=',' read -ra OFFICE_ENTRIES <<< "${OFFICE_IP}"
for ENTRY in "${OFFICE_ENTRIES[@]}"; do
    ENTRY=$(echo "${ENTRY}" | tr -d '[:space:]')
    [ -z "${ENTRY}" ] && continue

    RESOLVED=$(resolve_to_ipv4 "${ENTRY}")
    [ -z "${RESOLVED}" ] && continue

    if is_fqdn "${ENTRY}"; then
        echo "${RESOLVED}" > "${DDNS_DIR}/${ENTRY}.ip"
        add_office_rules "${RESOLVED}" "DDNS:${ENTRY}"
        DDNS_FOUND=true
        echo "Firewall rules added for DDNS host: ${ENTRY} -> ${RESOLVED}"
    else
        add_office_rules "${RESOLVED}" "office:${ENTRY}"
        echo "Firewall rules added for: ${ENTRY}"
    fi
done

ufw --force enable
ufw status verbose

# If any FQDNs were registered, install the dynamic refresh script and cron job
if [ "${DDNS_FOUND}" = "true" ]; then
    echo "DDNS entries detected — installing refresh script..."

    cat > /usr/local/sbin/ufw-dynamic-refresh << 'SCRIPT'
#!/bin/bash
# Refreshes UFW rules for DDNS hostnames tracked in /etc/ufw-dynamic/.
# When a hostname resolves to a new IP, the stale rules are removed and
# new rules are added. Resolution failures leave existing rules intact.
DDNS_DIR="/etc/ufw-dynamic"
LOG="/var/log/ufw-dynamic.log"
PORTS=(22 80 443)

for TRACK_FILE in "${DDNS_DIR}"/*.ip; do
    [ -f "${TRACK_FILE}" ] || continue
    HOSTNAME=$(basename "${TRACK_FILE}" .ip)
    OLD_IP=$(cat "${TRACK_FILE}")

    NEW_IP=$(getent hosts "${HOSTNAME}" 2>/dev/null | awk '{print $1}' | grep -v ':' | head -1)

    if [ -z "${NEW_IP}" ]; then
        echo "$(date -Iseconds) WARNING: could not resolve ${HOSTNAME} — leaving existing rules intact" >> "${LOG}"
        continue
    fi

    if [ "${NEW_IP}" = "${OLD_IP}" ]; then
        continue
    fi

    echo "$(date -Iseconds) ${HOSTNAME}: ${OLD_IP} -> ${NEW_IP}" >> "${LOG}"

    for PORT in "${PORTS[@]}"; do
        ufw delete allow from "${OLD_IP}" to any port "${PORT}" proto tcp 2>/dev/null || true
    done

    for PORT in "${PORTS[@]}"; do
        ufw allow from "${NEW_IP}" to any port "${PORT}" proto tcp comment "DDNS:${HOSTNAME}"
    done

    echo "${NEW_IP}" > "${TRACK_FILE}"
done
SCRIPT

    chmod 700 /usr/local/sbin/ufw-dynamic-refresh

    cat > /etc/cron.d/ufw-dynamic << 'EOL'
*/10 * * * * root /usr/local/sbin/ufw-dynamic-refresh
EOL
    chmod 644 /etc/cron.d/ufw-dynamic

    echo "Refresh script: /usr/local/sbin/ufw-dynamic-refresh"
    echo "Cron: every 10 minutes — log at /var/log/ufw-dynamic.log"
fi

# ============================================================
# 7. fail2ban (SSH brute-force protection)
# ============================================================
echo "[7/13] Installing fail2ban..."
apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local << 'EOL'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
filter   = sshd
logpath  = /var/log/auth.log
maxretry = 3
EOL

systemctl enable fail2ban
systemctl start fail2ban

# ============================================================
# 8. SSH configuration
# ============================================================
echo "[8/13] Configuring SSH and SFTP..."

# Modern Ubuntu OpenSSH options only — legacy/deprecated directives from older
# OpenSSH versions have been removed.
cat > /etc/ssh/sshd_config << 'EOL'
Port 22
AddressFamily any
ListenAddress 0.0.0.0
ListenAddress ::

HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key

SyslogFacility AUTH
LogLevel INFO

LoginGraceTime 60
PermitRootLogin no
StrictModes yes
MaxAuthTries 4

PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys

PasswordAuthentication yes
PermitEmptyPasswords no
KbdInteractiveAuthentication no

X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes

AcceptEnv LANG LC_*

# SFTP chroot — users in the sftp group are jailed to /srv/www
# Ref: msp-portal-framework.md §7.3 (cert distribution via SFTP)
Subsystem sftp internal-sftp
Match Group sftp
    ChrootDirectory /srv/www
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOL

# Create sftp group — for dedicated cert-distribution accounts only, not the admin user
groupadd sftp 2>/dev/null || true

systemctl restart ssh

# ============================================================
# 9. Web directory structure
# ============================================================
echo "[9/13] Setting up web directories..."

# webgroup allows both the admin user and www-data (nginx) to share write access
groupadd webgroup 2>/dev/null || true
usermod -a -G webgroup "${USERNAME}"
usermod -a -G webgroup www-data

# /srv/www must be owned root:root 755 — required by the SFTP chroot security model
mkdir -p /srv/www
chown root:root /srv/www
chmod 755 /srv/www

setup_domain_dir() {
    local DOMAIN="$1"
    # Slim 4 uses public/ as the nginx document root; app code lives in the parent
    mkdir -p "/srv/www/${DOMAIN}/public"
    chown -R "${USERNAME}:webgroup" "/srv/www/${DOMAIN}"
    chmod -R 775 "/srv/www/${DOMAIN}"
    chmod g+s "/srv/www/${DOMAIN}"

    # Slim 4-compatible placeholder entry point
    # Replace with the actual application's public/index.php during deployment
    cat > "/srv/www/${DOMAIN}/public/index.php" << PHPEOF
<?php
// MSP Portal placeholder — replace with your Slim 4 application entry point.
echo '<!DOCTYPE html><html><head><meta charset="UTF-8">';
echo '<title>' . htmlspecialchars('${DOMAIN}') . '</title></head><body>';
echo '<h1>' . htmlspecialchars('${DOMAIN}') . '</h1>';
echo '<p>PHP ' . phpversion() . '</p>';
echo '<p>' . date('Y-m-d H:i:s') . '</p>';
echo '</body></html>';
PHPEOF
}

setup_domain_dir "${PRIMARY_DOMAIN}"

# ============================================================
# 9b. Credentials file location
# ============================================================
echo "Setting up credentials directory..."

# /etc/aktechworks-net/ holds the JSON config file referenced in msp-portal-framework.md §6.3.
# It lives outside the web root and is only accessible to the admin user (rw)
# and www-data / PHP-FPM (r). No other users or processes have access.
mkdir -p /etc/aktechworks-net
chown "${USERNAME}:www-data" /etc/aktechworks-net
chmod 750 /etc/aktechworks-net

# Placeholder config — populate manually before first application run
cat > /etc/aktechworks-net/config.json << 'EOL'
{
    "_note": "Populate before first run — see msp-portal-framework.md §6.3",
    "key_vault": {
        "tenant_id": "",
        "client_id": "",
        "client_secret": ""
    },
    "oauth": {
        "allowed_domains": []
    }
}
EOL
chown "${USERNAME}:www-data" /etc/aktechworks-net/config.json
chmod 640 /etc/aktechworks-net/config.json

# ============================================================
# 10. Install acme.sh
# ============================================================
echo "[10/13] Installing acme.sh..."
curl https://get.acme.sh | sh -s email="${ADMIN_EMAIL}"
ACME="/root/.acme.sh/acme.sh"

# ============================================================
# 11. Obtain SSL certificates via acme.sh — staging / test mode
# ============================================================
# STAGING MODE: --staging uses Let's Encrypt's staging CA.
#
#   - Full DNS-01 validation runs against Cloudflare — the complete cert
#     workflow is exercised end-to-end on every test deployment.
#   - Issued certs ARE installed and used by nginx (SSL config is fully tested).
#   - Staging certs are NOT trusted by browsers — expect an untrusted CA warning.
#   - Staging has ~10x higher rate limits than production, making it safe for
#     repeated test deployments without risk of hitting the production rate
#     limit (5 certs/domain/week).
#
# To promote to production certs after testing:
#   export CF_Token=<your-token>
#   /root/.acme.sh/acme.sh --issue --force \
#       -d example.com -d www.example.com --dns dns_cf --server letsencrypt
#   (acme.sh will automatically reload nginx via the installed --reloadcmd)

echo "[11/13] Issuing SSL certificates (staging mode)..."

# NAMECHEAP_SOURCEIP must match the IP whitelisted in your Namecheap API settings.
# For a static Linode this is the server's own public IP, detected from the interface.
export NAMECHEAP_USERNAME="${NAMECHEAP_USERNAME}"
export NAMECHEAP_API_KEY="${NAMECHEAP_API_KEY}"
export NAMECHEAP_SOURCEIP=$(ip -4 route get 1.1.1.1 | grep -oP 'src \K[\d.]+')

issue_and_install_cert() {
    local DOMAIN="$1"
    echo "Requesting staging cert for ${DOMAIN}..."

    set +e
    # Toggle between staging and production by swapping which line is commented out.
    # ${ACME} --issue --staging \    # staging  — high rate limits, untrusted cert, use for test deployments
    ${ACME} --issue \                # production — trusted cert, rate limited to 5/domain/week
        -d "${DOMAIN}" -d "www.${DOMAIN}" \
        --dns dns_namecheap
    local RESULT=$?
    set -e

    if [ ${RESULT} -eq 0 ]; then
        mkdir -p "/etc/ssl/acme/${DOMAIN}"
        ${ACME} --install-cert -d "${DOMAIN}" \
            --cert-file      "/etc/ssl/acme/${DOMAIN}/cert.pem" \
            --key-file       "/etc/ssl/acme/${DOMAIN}/key.pem" \
            --fullchain-file "/etc/ssl/acme/${DOMAIN}/fullchain.pem" \
            --reloadcmd      "systemctl reload nginx"
        echo "Cert installed for ${DOMAIN}"
    else
        echo "WARNING: Cert issuance failed for ${DOMAIN} (exit ${RESULT})."
        echo "  Nginx will be configured HTTP-only for this domain."
        echo "  Check /root/stackscript.log and re-run acme.sh manually once resolved."
    fi
}

issue_and_install_cert "${PRIMARY_DOMAIN}"

# ============================================================
# 12. Configure nginx
# ============================================================
echo "[12/13] Configuring nginx..."

FPM_SOCKET="/var/run/php/php${PHP_VERSION}-fpm.sock"

write_nginx_config() {
    local DOMAIN="$1"
    local CONF="/etc/nginx/sites-available/${DOMAIN}"

    if [ -f "/etc/ssl/acme/${DOMAIN}/fullchain.pem" ]; then
        # HTTPS config — staging cert was successfully issued and installed
        cat > "${CONF}" << EOL
# ${DOMAIN} — HTTPS (staging cert)
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name ${DOMAIN} www.${DOMAIN};
    root /srv/www/${DOMAIN}/public;
    index index.php;

    ssl_certificate     /etc/ssl/acme/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/ssl/acme/${DOMAIN}/key.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Slim 4 front-controller routing
    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${FPM_SOCKET};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOL
    else
        # HTTP-only fallback — cert issuance failed or was skipped
        cat > "${CONF}" << EOL
# ${DOMAIN} — HTTP only (update to HTTPS after cert is issued)
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /srv/www/${DOMAIN}/public;
    index index.php;

    # Slim 4 front-controller routing
    location / {
        try_files \$uri /index.php\$is_args\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${FPM_SOCKET};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\\.ht {
        deny all;
    }
}
EOL
    fi

    ln -sf "/etc/nginx/sites-available/${DOMAIN}" "/etc/nginx/sites-enabled/${DOMAIN}"
}

write_nginx_config "${PRIMARY_DOMAIN}"

# Remove the default nginx placeholder site
rm -f /etc/nginx/sites-enabled/default

# Validate config before starting
nginx -t

# ============================================================
# 13. Enable and start services
# ============================================================
echo "[13/13] Starting services..."
systemctl enable "php${PHP_VERSION}-fpm" nginx
systemctl restart "php${PHP_VERSION}-fpm"
systemctl restart nginx

# ============================================================
# Summary
# ============================================================
cert_status() {
    [ -f "/etc/ssl/acme/${1}/fullchain.pem" ] && echo "staging cert installed" || echo "HTTP only — cert failed"
}

echo "======================================================"
echo "MSP Portal Server Setup Complete — $(date)"
echo "======================================================"
echo "Admin user  : ${USERNAME}"
echo "PHP version : ${PHP_VERSION}"
echo "Firewall    : UFW — ports 22/80/443 restricted to ${OFFICE_IP}"
echo ""
echo "Domain      : ${PRIMARY_DOMAIN}  [$(cert_status ${PRIMARY_DOMAIN})]"
echo ""
echo "SSL note    : Certificates are in STAGING mode (not browser-trusted)."
echo "              To issue production certs after testing:"
echo "                export NAMECHEAP_USERNAME=<username>"
echo "                export NAMECHEAP_API_KEY=<key>"
echo "                export NAMECHEAP_SOURCEIP=<this_server_ip>"
echo "                /root/.acme.sh/acme.sh --issue --force \\"
echo "                  -d ${PRIMARY_DOMAIN} -d www.${PRIMARY_DOMAIN} \\"
echo "                  --dns dns_namecheap --server letsencrypt"
echo ""
echo "Web roots   : /srv/www/<domain>/public/"
echo "Config file : /etc/aktechworks-net/config.json (populate before first run)"
echo "Nginx logs  : /var/log/nginx/"
echo "Script log  : /root/stackscript.log"
echo "======================================================"
