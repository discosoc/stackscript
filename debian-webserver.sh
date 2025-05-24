#!/bin/bash
# <UDF name="USERNAME" label="The limited sudo user to be created" example="myuser" default="">
# <UDF name="PASSWORD" label="The password for the limited sudo user" example="s3cure_p4ssw0rd" default="">
# <UDF name="PUBKEY" label="The SSH Public Key that will be used to access the server (optional)" default="">

# This makes the script verbose, showing all executed commands
set -x

# Log file for debugging
exec > >(tee -a /root/stackscript.log) 2>&1

echo "Stack Script starting at $(date)"
echo "UDF Variables received: USERNAME=${USERNAME}"

# Exit script if any command fails
set -e

# Update system and install required packages
echo "Starting system update..."
apt-get update
apt-get upgrade -y

# 1. Set up hostname to 'aktechworks'
echo "Setting hostname to 'aktechworks'..."
echo "aktechworks" > /etc/hostname
hostname -F /etc/hostname

# 2. Set up FQDN to 'aktechworks.net'
echo "Setting up FQDN..."
echo "127.0.1.1 aktechworks.net aktechworks" >> /etc/hosts

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
    
# Add SSH key if provided
if [ ! -z "${PUBKEY}" ]; then
    echo "Adding SSH public key for user ${USERNAME}"
    mkdir -p /home/${USERNAME}/.ssh
    echo "${PUBKEY}" > /home/${USERNAME}/.ssh/authorized_keys
    chmod 700 /home/${USERNAME}/.ssh
    chmod 600 /home/${USERNAME}/.ssh/authorized_keys
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh
    echo "SSH key added successfully"
else
    echo "No SSH public key provided, skipping"
fi

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
groupadd sftp
usermod -a -G sftp ${USERNAME}

# Restart SSH service
systemctl restart ssh

# 9. Install certbot
echo "Installing certbot..."
apt-get install -y certbot python3-certbot-nginx

# 10. Setup root web directory
echo "Creating web directories..."
mkdir -p /srv/www/aktechworks.net
chown -R www-data:www-data /srv/www
chmod -R 755 /srv/www

# Set proper permissions for SFTP
chown root:root /srv/www
chmod 755 /srv/www
chown -R ${USERNAME}:${USERNAME} /srv/www/aktechworks.net

# 11 & 12. Configure nginx virtual host with PHP support
echo "Configuring nginx virtual host..."
cat > /etc/nginx/sites-available/aktechworks.net << 'EOL'
server {
    listen 80;
    server_name aktechworks.net www.aktechworks.net;
    root /srv/www/aktechworks.net;
    index index.php index.html index.htm;

    location / {
        try_files $uri $uri/ /index.php?$args;
    }

    location ~ \.php$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOL

# Enable the site
ln -s /etc/nginx/sites-available/aktechworks.net /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Create a sample index.php file
echo "Creating sample index.php..."
cat > /srv/www/aktechworks.net/index.php << 'EOL'
<?php
phpinfo();
EOL

# Set proper ownership
chown -R www-data:www-data /srv/www/aktechworks.net
chmod -R 755 /srv/www/aktechworks.net

# 13. Obtain SSL certificate with certbot
echo "Setting up SSL with certbot..."
systemctl restart nginx
certbot --nginx -d aktechworks.net -d www.aktechworks.net --non-interactive --agree-tos --email admin@aktechworks.net

# Final system restart
echo "Restarting services..."
systemctl restart nginx
systemctl restart php8.2-fpm
systemctl restart mariadb

echo "======================================"
echo "Setup complete! Your server is now configured with nginx, MariaDB, PHP 8.2, and SSL."
echo "======================================"
echo "Created user: ${USERNAME}"
echo "Website URL: https://aktechworks.net"
echo "Web root directory: /srv/www/aktechworks.net"
echo "Stack Script log: /root/stackscript.log"