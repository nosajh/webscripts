#!/bin/bash

# 1. Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# 2. Prompt for inputs
read -p "Enter the PostgreSQL Server IP: " db_ip
read -p "Enter your Team ID (e.g., 1): " team_id

# 3. Install System Dependencies
echo "Installing system dependencies..."
apt update
apt install git python3 python3-dev python3-pip python3-venv libpq-dev gcc -y

# 4. Neutralize and Backup existing /opt/etechacademy
echo "Neutralizing existing installation..."

# Stop the service if it's already running to free up Port 5000/80
systemctl stop etechacademy 2>/dev/null

if [ -d "/opt/etechacademy" ]; then
    echo "Existing app directory found. Moving and Neutralizing..."
    
    # Clean old backup if it exists
    rm -rf /opt/etechacademyold  
    
    # Move to backup location
    mv /opt/etechacademy /opt/etechacademyold
    
    # NEUTRALIZATION:
    # 1. Change ownership to root so the web user cannot execute it
    chown -R root:root /opt/etechacademyold
    
    # 2. Rename the entry point so 'python3 main.py' fails
    if [ -f "/opt/etechacademyold/main.py" ]; then
        mv /opt/etechacademyold/main.py /opt/etechacademyold/main.py.disabled
    fi

    # 3. Strip all execution permissions and restrict to root only
    chmod -R 600 /opt/etechacademyold
    chmod 700 /opt/etechacademyold # Allow root to enter, but nobody else
    
    echo "Original version neutralized at /opt/etechacademyold"
fi

# 5. Setup New Patched App
echo "Deploying patched application..."
cd /opt/
# Update the URL below to your actual patched repository
apt install git -y
git clone https://github.com/nosajh/webapp_patched.git webapp_patched
mv webapp_patched etechacademy
chown -R www-data:www-data /opt/etechacademy

# 6. Setup Python Virtual Environment
echo "Building Virtual Environment..."
cd /opt/etechacademy
python3 -m venv web_env
./web_env/bin/pip install --upgrade pip
./web_env/bin/pip install psycopg2-binary
./web_env/bin/pip install -r requirements.txt
chown -R www-data:www-data /opt/etechacademy/web_env

# 7. Setup /var/lib/etechacademy and .env file
echo "Configuring environment file..."
CONFIG_DIR="/var/lib/etechacademy"
mkdir -p $CONFIG_DIR

if [ -f "$CONFIG_DIR/.env" ]; then
    echo "Moving old .env to /opt/etechacademy.envold"
    mv "$CONFIG_DIR/.env" "/opt/etechacademy.envold"
    chown root:root /opt/etechacademy.envold
    chmod 600 /opt/etechacademy.envold
fi

cat <<EOF > "$CONFIG_DIR/.env"
SITE_NAME=eTech Academy
SECRET_KEY=a199f5653a3677ba33439855032d5193d1ba0fd8f869080196cad80ed0839805
WEB_APP_PORT=5000
WEB_APP_HOST=127.0.0.1
POSTGRES_HOST=$db_ip
POSTGRES_PORT=5432
POSTGRES_DB=db
POSTGRES_USER=john_pork
POSTGRES_PASSWORD='Kev1n_Bac0n!'
WERKZEUG_DEBUG_PIN=off
DOMAIN_NAME=team$team_id.ncaecybergames.org
EOF

chown -R www-data:www-data $CONFIG_DIR
chmod 600 "$CONFIG_DIR/.env"

# 8. Setup Systemd Service
echo "Configuring Systemd service..."
SERVICE_PATH="/etc/systemd/system/etechacademy.service"

if [ -f "$SERVICE_PATH" ]; then
    echo "Moving old service file to /opt/etechacademy.serviceold"
    mv "$SERVICE_PATH" "/opt/etechacademy.serviceold"
fi

cat <<EOF > "$SERVICE_PATH"
[Unit]
Description=eTechAcademy Flask Application
After=network.target postgresql.service

[Service]
User=www-data
Group=www-data
WorkingDirectory=/opt/etechacademy
EnvironmentFile=/var/lib/etechacademy/.env
Environment="PATH=/opt/etechacademy/web_env/bin:/usr/local/bin:/usr/bin:/bin"
ExecStart=/opt/etechacademy/web_env/bin/python3 main.py
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF

# 9. Setup Nginx (Clean Slate)
if dpkg -l | grep -q nginx; then
    echo "Nginx detected. Moving config and reinstalling..."
    [ -f "/etc/nginx/sites-available/etechacademy" ] && mv /etc/nginx/sites-available/etechacademy /opt/etechacademy.nginxold
    apt purge nginx nginx-common nginx-full -y
    rm -rf /etc/nginx
fi

apt install nginx -y
rm -f /etc/nginx/sites-enabled/default

# Temporary SSL certs for Nginx start-up
mkdir -p /etc/ssl/local-test
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
-keyout /etc/ssl/local-test/etech.key \
-out /etc/ssl/local-test/etech.crt \
-subj "/CN=team$team_id.ncaecybergames.org"

# Create Nginx Config
cat <<EOF > /etc/nginx/sites-available/etechacademy
server {
    listen 80;
    server_name team$team_id.ncaecybergames.org;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name team$team_id.ncaecybergames.org;

    ssl_certificate /etc/ssl/local-test/etech.crt;
    ssl_certificate_key /etc/ssl/local-test/etech.key;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https; 
    }
}
EOF

ln -sf /etc/nginx/sites-available/etechacademy /etc/nginx/sites-enabled/

# 10. Start Services
echo "Finalizing deployment..."
nginx -t && systemctl restart nginx
systemctl daemon-reload
systemctl enable etechacademy.service
systemctl start etechacademy.service

echo "------------------------------------------------"
echo "DEPLOYMENT COMPLETE"
echo "Original app neutralized at /opt/etechacademyold"
echo "New app running from /opt/etechacademy"
echo "------------------------------------------------"
systemctl status etechacademy.service --no-pager
