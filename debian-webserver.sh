# This makes the script verbose, showing all executed commands
set -x

# Log file for debugging
exec > >(tee -a /root/stackscript.log) 2>&1

echo "Stack Script starting at $(date)"
echo "UDF Variables received:"
echo "USERNAME=${USERNAME}"
echo "PRIMARY_DOMAIN=${PRIMARY_DOMAIN}"
echo "SECONDARY_DOMAIN=${SECONDARY_DOMAIN}"
echo "TERTIARY_DOMAIN=${TERTIARY_DOMAIN}"
echo "ADMIN_EMAIL=${ADMIN_EMAIL}"

# Exit script if any command fails
set -e

# Update system and install required packages
echo "Starting system update..."
apt-get update
apt-get upgrade -y

# 1. Set up hostname (use the primary domain name without the TLD)
HOSTNAME=$(echo "${PRIMARY_DOMAIN}" | cut -d. -f1)
echo "Setting hostname to '${HOSTNAME}'..."
echo "${HOSTNAME}" > /etc/hostname
hostname -F /etc/hostname

# 2. Set up FQDN to the primary domain
echo "Setting up FQDN..."
echo "127.0.1.1 ${PRIMARY_DOMAIN} ${HOSTNAME}" >> /etc/hosts

# 3. Set timezone to 'America/Anchorage'
echo "Setting timezone..."
timedatectl set-timezone America/Anchorage

# 4. Create the sudo user specified in the UDF
echo "Creating user account for: ${USERNAME}"

# Check if USERNAME is defined
if [ -z "${USERNAME}" ]; then
    echo "ERROR: USERNAME variable is not defined or empty"
    echo "Available environment variables:"
    env | sort
    exit 1
fi

# Try creating the user
useradd -m -s /bin/bash "${USERNAME}" || { echo "Failed to create user"; exit 1; }
usermod -aG sudo "${USERNAME}" || { echo "Failed to add user to sudo group"; exit 1; }
echo "${USERNAME}:${PASSWORD}" | chpasswd || { echo "Failed to set user password"; exit 1; }
echo "User ${USERNAME} created successfully"

# 5. Install nginx, mariadb, php8
echo "Installing nginx, MariaDB, and PHP..."
apt-get install -y nginx mariadb-server
apt-get install -y php8.2 php8.2-fpm php8.2-mysql php8.2-mbstring php8.2-xml php8.2-gd php8.2-curl

# Secure MariaDB installation
echo "Securing MariaDB..."
mysql_secure_installation <<EOF

y
${PASSWORD}
${PASSWORD}
y
y
y
y
EOF

# 6. Install nftables and configure firewall
echo "Setting up firewall..."
apt-get install -y nftables

# Create nftables configuration
cat > /etc/nftables.conf << 'EOL'
#!/usr/sbin/nft -f

flush ruleset

table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        
        # Accept loopback traffic
        iif "lo" accept
        
        # Accept established/related connections
        ct state {established, related} accept
        
        # Accept SSH, HTTP, HTTPS
        tcp dport {22, 80, 443} accept
        
        # Accept ICMP and IGMP
        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept
        
        # Reject all other traffic
        reject with icmpx type port-unreachable
    }
    
    chain forward {
        type filter hook forward priority 0; policy drop;
    }
    
    chain output {
        type filter hook output priority 0; policy accept;
    }
}
EOL

# Enable and start nftables
systemctl enable nftables
systemctl start nftables

# 7. Install fail2ban
echo "Installing fail2ban..."
apt-get install -y fail2ban

# Configure fail2ban for SSH
cat > /etc/fail2ban/jail.local << 'EOL'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5

[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
EOL

systemctl enable fail2ban
systemctl start fail2ban

# 8. Configure SSH and SFTP
echo "Configuring SSH and SFTP..."
apt-get install -y openssh-server

# Configure SSH server
cat > /etc/ssh/sshd_config << 'EOL'
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin no
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
PasswordAuthentication yes
X11Forwarding no
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp internal-sftp
Match Group sftp
    ChrootDirectory /srv/www
    ForceCommand internal-sftp
    AllowTcpForwarding no
    X11Forwarding no
EOL

# Create SFTP group and add user to it
echo "Setting up SFTP group..."
groupadd sftp 2>/dev/null || true
usermod -a -G sftp ${USERNAME}

# Restart SSH service
systemctl restart ssh

# 9. Install certbot
echo "Installing certbot..."
apt-get install -y certbot python3-certbot-nginx

# 10. Setup web directory structure and permissions

# Create a web group for shared permissions between user and www-data
echo "Creating web group for shared permissions..."
groupadd webgroup 2>/dev/null || true
usermod -a -G webgroup ${USERNAME}
usermod -a -G webgroup www-data

# Setup root web directory
echo "Setting up root web directory structure..."
mkdir -p /srv/www
chown root:root /srv/www
chmod 755 /srv/www

# Configure primary domain
echo "Setting up primary domain: ${PRIMARY_DOMAIN}"
mkdir -p /srv/www/${PRIMARY_DOMAIN}
chown -R ${USERNAME}:webgroup /srv/www/${PRIMARY_DOMAIN}
chmod -R 775 /srv/www/${PRIMARY_DOMAIN}
chmod g+s /srv/www/${PRIMARY_DOMAIN}

# Create a simple index.php for the primary domain
cat > /srv/www/${PRIMARY_DOMAIN}/index.php << EOL
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${PRIMARY_DOMAIN}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background-color: #f5f5f5;
        }
        .container {
            text-align: center;
            padding: 2rem;
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            max-width: 600px;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
            margin: 1rem 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to <?php echo htmlspecialchars('${PRIMARY_DOMAIN}'); ?></h1>
        <p>Your website is successfully configured and running with nginx and PHP <?php echo phpversion(); ?>.</p>
        <p>Server Time: <?php echo date('Y-m-d H:i:s'); ?></p>
        <p>Site document root: <?php echo htmlspecialchars($_SERVER['DOCUMENT_ROOT']); ?></p>
    </div>
</body>
</html>
EOL

# Configure nginx virtual host for primary domain
echo "Configuring nginx for ${PRIMARY_DOMAIN}..."
cat > /etc/nginx/sites-available/${PRIMARY_DOMAIN} << EOL
server {
    listen 80;
    server_name ${PRIMARY_DOMAIN} www.${PRIMARY_DOMAIN};
    root /srv/www/${PRIMARY_DOMAIN};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Enable the primary site
ln -s /etc/nginx/sites-available/${PRIMARY_DOMAIN} /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Setup secondary domain if provided
if [ ! -z "${SECONDARY_DOMAIN}" ]; then
    echo "Setting up secondary domain: ${SECONDARY_DOMAIN}"
    
    # Create directory structure
    mkdir -p /srv/www/${SECONDARY_DOMAIN}
    chown -R ${USERNAME}:webgroup /srv/www/${SECONDARY_DOMAIN}
    chmod -R 775 /srv/www/${SECONDARY_DOMAIN}
    chmod g+s /srv/www/${SECONDARY_DOMAIN}
    
    # Create a simple index.php for the secondary domain
    cat > /srv/www/${SECONDARY_DOMAIN}/index.php << EOL
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${SECONDARY_DOMAIN}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background-color: #f5f5f5;
        }
        .container {
            text-align: center;
            padding: 2rem;
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            max-width: 600px;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
            margin: 1rem 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to <?php echo htmlspecialchars('${SECONDARY_DOMAIN}'); ?></h1>
        <p>Your website is successfully configured and running with nginx and PHP <?php echo phpversion(); ?>.</p>
        <p>Server Time: <?php echo date('Y-m-d H:i:s'); ?></p>
        <p>Site document root: <?php echo htmlspecialchars($_SERVER['DOCUMENT_ROOT']); ?></p>
    </div>
</body>
</html>
EOL

    # Create nginx configuration
    cat > /etc/nginx/sites-available/${SECONDARY_DOMAIN} << EOL
server {
    listen 80;
    server_name ${SECONDARY_DOMAIN} www.${SECONDARY_DOMAIN};
    root /srv/www/${SECONDARY_DOMAIN};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    # Enable the site
    ln -s /etc/nginx/sites-available/${SECONDARY_DOMAIN} /etc/nginx/sites-enabled/
fi

# Setup tertiary domain if provided
if [ ! -z "${TERTIARY_DOMAIN}" ]; then
    echo "Setting up tertiary domain: ${TERTIARY_DOMAIN}"
    
    # Create directory structure
    mkdir -p /srv/www/${TERTIARY_DOMAIN}
    chown -R ${USERNAME}:webgroup /srv/www/${TERTIARY_DOMAIN}
    chmod -R 775 /srv/www/${TERTIARY_DOMAIN}
    chmod g+s /srv/www/${TERTIARY_DOMAIN}
    
    # Create a simple index.php for the tertiary domain
    cat > /srv/www/${TERTIARY_DOMAIN}/index.php << EOL
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>${TERTIARY_DOMAIN}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            margin: 0;
            padding: 0;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            background-color: #f5f5f5;
        }
        .container {
            text-align: center;
            padding: 2rem;
            background-color: white;
            border-radius: 8px;
            box-shadow: 0 4px 6px rgba(0, 0, 0, 0.1);
            max-width: 600px;
        }
        h1 {
            color: #333;
        }
        p {
            color: #666;
            margin: 1rem 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>Welcome to <?php echo htmlspecialchars('${TERTIARY_DOMAIN}'); ?></h1>
        <p>Your website is successfully configured and running with nginx and PHP <?php echo phpversion(); ?>.</p>
        <p>Server Time: <?php echo date('Y-m-d H:i:s'); ?></p>
        <p>Site document root: <?php echo htmlspecialchars($_SERVER['DOCUMENT_ROOT']); ?></p>
    </div>
</body>
</html>
EOL

    # Create nginx configuration
    cat > /etc/nginx/sites-available/${TERTIARY_DOMAIN} << EOL
server {
    listen 80;
    server_name ${TERTIARY_DOMAIN} www.${TERTIARY_DOMAIN};
    root /srv/www/${TERTIARY_DOMAIN};
    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

    # Enable the site
    ln -s /etc/nginx/sites-available/${TERTIARY_DOMAIN} /etc/nginx/sites-enabled/
fi

# Restart nginx to apply changes
echo "Restarting nginx to apply all configuration changes..."
systemctl restart nginx

# Set up SSL certificates with certbot
echo "Setting up SSL with certbot for ${PRIMARY_DOMAIN}..."
certbot --nginx -d ${PRIMARY_DOMAIN} -d www.${PRIMARY_DOMAIN} \
    --non-interactive --agree-tos --email ${ADMIN_EMAIL} \
    --cert-name ${PRIMARY_DOMAIN}

# Obtain SSL certificate for secondary domain if provided
if [ ! -z "${SECONDARY_DOMAIN}" ]; then
    echo "Setting up SSL with certbot for ${SECONDARY_DOMAIN}..."
    certbot --nginx -d ${SECONDARY_DOMAIN} -d www.${SECONDARY_DOMAIN} \
        --non-interactive --agree-tos --email ${ADMIN_EMAIL} \
        --cert-name ${SECONDARY_DOMAIN}
fi

# Obtain SSL certificate for tertiary domain if provided
if [ ! -z "${TERTIARY_DOMAIN}" ]; then
    echo "Setting up SSL with certbot for ${TERTIARY_DOMAIN}..."
    certbot --nginx -d ${TERTIARY_DOMAIN} -d www.${TERTIARY_DOMAIN} \
        --non-interactive --agree-tos --email ${ADMIN_EMAIL} \
        --cert-name ${TERTIARY_DOMAIN}
fi

# Add a cron job to auto-renew SSL certificates
echo "Setting up automatic SSL renewal..."
echo "0 3 * * * /usr/bin/certbot renew --quiet" > /etc/cron.d/certbot-renew
chmod 644 /etc/cron.d/certbot-renew

# Final system restart
echo "Restarting services..."
systemctl restart nginx
systemctl restart php8.2-fpm
systemctl restart mariadb

# Display setup summary
echo "======================================"
echo "Setup complete! Your server is now configured with nginx, MariaDB, PHP 8.2, and SSL."
echo "======================================"
echo "Created user: ${USERNAME}"
echo "Primary domain: https://${PRIMARY_DOMAIN}"
if [ ! -z "${SECONDARY_DOMAIN}" ]; then
    echo "Secondary domain: https://${SECONDARY_DOMAIN}"
fi
if [ ! -z "${TERTIARY_DOMAIN}" ]; then
    echo "Tertiary domain: https://${TERTIARY_DOMAIN}"
fi
echo "SSL certificates will auto-renew"
echo "Web root directories:"
echo "  /srv/www/${PRIMARY_DOMAIN}"
if [ ! -z "${SECONDARY_DOMAIN}" ]; then
    echo "  /srv/www/${SECONDARY_DOMAIN}"
fi
if [ ! -z "${TERTIARY_DOMAIN}" ]; then
    echo "  /srv/www/${TERTIARY_DOMAIN}"
fi
echo "Stack Script log: /root/stackscript.log"