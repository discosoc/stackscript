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

# 5. Install nginx, python3, pip, and venv
echo "Installing nginx, Python3, and dependencies..."
apt-get install -y nginx python3 python3-pip python3-venv python3-dev build-essential

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

# 10. Setup Python application directory
echo "Creating Python application directories..."
mkdir -p /srv/www/aktechworks.net
chown -R ${USERNAME}:${USERNAME} /srv/www/aktechworks.net

# Set proper permissions for SFTP
chown root:root /srv/www
chmod 755 /srv/www

# 11. Create Python virtual environment and install Gunicorn
echo "Setting up Python virtual environment..."
cd /srv/www/aktechworks.net
sudo -u ${USERNAME} python3 -m venv venv
sudo -u ${USERNAME} /srv/www/aktechworks.net/venv/bin/pip install gunicorn flask

# 12. Create sample Flask application
echo "Creating sample Flask application..."
cat > /srv/www/aktechworks.net/app.py << 'EOL'
from flask import Flask
import socket
import datetime

app = Flask(__name__)

@app.route('/')
def hello():
    hostname = socket.gethostname()
    current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    return f"""
    <!DOCTYPE html>
    <html>
    <head>
        <title>Welcome to aktechworks.net</title>
        <style>
            body {{
                font-family: Arial, sans-serif;
                margin: 40px;
                background-color: #f5f5f5;
            }}
            .container {{
                background-color: white;
                padding: 30px;
                border-radius: 10px;
                box-shadow: 0 2px 10px rgba(0,0,0,0.1);
                max-width: 600px;
                margin: 0 auto;
            }}
            h1 {{
                color: #333;
                border-bottom: 2px solid #007bff;
                padding-bottom: 10px;
            }}
            .info {{
                margin: 20px 0;
                padding: 15px;
                background-color: #e9ecef;
                border-radius: 5px;
            }}
            .label {{
                font-weight: bold;
                color: #495057;
            }}
        </style>
    </head>
    <body>
        <div class="container">
            <h1>Welcome to aktechworks.net</h1>
            <p>This is a sample Python/Flask application running with Gunicorn and Nginx.</p>
            <div class="info">
                <p><span class="label">Server:</span> {hostname}</p>
                <p><span class="label">Current Time:</span> {current_time}</p>
                <p><span class="label">Application:</span> Flask + Gunicorn + Nginx</p>
            </div>
        </div>
    </body>
    </html>
    """

if __name__ == '__main__':
    app.run(debug=True)
EOL

# Set ownership
chown ${USERNAME}:${USERNAME} /srv/www/aktechworks.net/app.py

# 13. Create Gunicorn service
echo "Creating Gunicorn systemd service..."
cat > /etc/systemd/system/gunicorn.service << EOL
[Unit]
Description=Gunicorn instance to serve Flask app
After=network.target

[Service]
User=${USERNAME}
Group=${USERNAME}
WorkingDirectory=/srv/www/aktechworks.net
Environment="PATH=/srv/www/aktechworks.net/venv/bin"
ExecStart=/srv/www/aktechworks.net/venv/bin/gunicorn --workers 3 --bind unix:aktechworks.sock -m 007 app:app

[Install]
WantedBy=multi-user.target
EOL

# Enable and start Gunicorn
systemctl enable gunicorn
systemctl start gunicorn

# 14. Configure nginx as reverse proxy
echo "Configuring nginx as reverse proxy..."
cat > /etc/nginx/sites-available/aktechworks.net << 'EOL'
server {
    listen 80;
    server_name aktechworks.net www.aktechworks.net;

    location / {
        include proxy_params;
        proxy_pass http://unix:/srv/www/aktechworks.net/aktechworks.sock;
    }

    location /static {
        alias /srv/www/aktechworks.net/static;
        expires 30d;
    }
}
EOL

# Enable the site
ln -sf /etc/nginx/sites-available/aktechworks.net /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

# Test nginx configuration
nginx -t

# 15. Restart nginx
systemctl restart nginx

# 16. Obtain SSL certificate with certbot (using staging for testing)
echo "Setting up SSL with certbot (staging)..."
certbot --nginx -d aktechworks.net -d www.aktechworks.net --non-interactive --agree-tos --email admin@aktechworks.net --test-cert

# Final restart of services
echo "Restarting services..."
systemctl restart gunicorn
systemctl restart nginx

# Create a helpful README
cat > /srv/www/aktechworks.net/README.md << EOL
# Python Web Application on aktechworks.net

## Application Structure
- app.py: Main Flask application
- venv/: Python virtual environment
- aktechworks.sock: Unix socket for Gunicorn

## Service Management
- Start/Stop/Restart Gunicorn: systemctl [start|stop|restart] gunicorn
- Start/Stop/Restart Nginx: systemctl [start|stop|restart] nginx

## Logs
- Gunicorn logs: journalctl -u gunicorn
- Nginx access logs: /var/log/nginx/access.log
- Nginx error logs: /var/log/nginx/error.log

## SSL Certificate
Currently using Let's Encrypt staging certificate (for testing).
To get a production certificate, run:
certbot --nginx -d aktechworks.net -d www.aktechworks.net --force-renewal

## Updating the Application
1. Make changes to app.py
2. Restart Gunicorn: systemctl restart gunicorn
EOL

chown ${USERNAME}:${USERNAME} /srv/www/aktechworks.net/README.md

echo "======================================"
echo "Setup complete! Your Python web server is configured."
echo "======================================"
echo "Created user: ${USERNAME}"
echo "Website URL: https://aktechworks.net (using test certificate)"
echo "Application root: /srv/www/aktechworks.net"
echo "Stack Script log: /root/stackscript.log"
echo ""
echo "To switch to production SSL certificate, run:"
echo "certbot --nginx -d aktechworks.net -d www.aktechworks.net --force-renewal"