#!/bin/bash

# ------------------------------
# Script réutilisable Node.js LTS + pnpm + PM2 + Nginx + Certbot Cloudflare
# Arguments :
#   $1 = Domaine (ex: exemple.com)
#   $2 = Port Node.js (ex: 3000)
#   $3 = Email pour SSL (ex: email@example.com)
# ------------------------------

if [ "$#" -ne 3 ]; then
    echo "Usage: $0 <domain> <app_port> <email>"
    exit 1
fi

DOMAIN="$1"
APP_PORT="$2"
EMAIL="$3"
CLOUDFLARE_CREDENTIALS="$HOME/.secrets/certbot/cloudflare.ini"

echo "⚙️  Configuration pour :"
echo "Domaine: $DOMAIN"
echo "Port Node.js: $APP_PORT"
echo "Email SSL: $EMAIL"

# ------------------------------
# Fonction pour installer un paquet si absent
# ------------------------------
install_if_missing() {
    if ! command -v $1 &> /dev/null; then
        echo "Installation de $1..."
        sudo apt install -y $2
    else
        echo "$1 déjà installé, skipping..."
    fi
}

# ------------------------------
# Mise à jour système
# ------------------------------
sudo apt update && sudo apt upgrade -y

# Installer dépendances de base
install_if_missing curl curl
install_if_missing git git
install_if_missing build-essential build-essential
install_if_missing software-properties-common software-properties-common

# Installer Node.js LTS si absent
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs
else
    echo "Node.js déjà installé, skipping..."
fi

# Installer pnpm si absent
if ! command -v pnpm &> /dev/null; then
    sudo npm install -g pnpm
else
    echo "pnpm déjà installé, skipping..."
fi

# Installer PM2 si absent
if ! command -v pm2 &> /dev/null; then
    sudo npm install -g pm2
    pm2 startup systemd -u $USER --hp $HOME
    pm2 save
else
    echo "PM2 déjà installé, skipping..."
fi

# Installer Nginx si absent
install_if_missing nginx nginx
sudo systemctl enable nginx
sudo systemctl start nginx

# ------------------------------
# Configurer Nginx pour l'app (wildcard)
# ------------------------------
NGINX_CONF="/etc/nginx/sites-available/$DOMAIN"
sudo tee $NGINX_CONF > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN *.$DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }
}
EOF

sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx

# ------------------------------
# Installer Certbot et plugin Cloudflare
# ------------------------------
install_if_missing certbot certbot
install_if_missing python3-certbot-dns-cloudflare python3-certbot-dns-cloudflare

# Générer certificat wildcard SSL via Cloudflare si absent
if [ ! -d "/etc/letsencrypt/live/$DOMAIN" ]; then
    sudo certbot certonly \
      --dns-cloudflare \
      --dns-cloudflare-credentials $CLOUDFLARE_CREDENTIALS \
      -d $DOMAIN -d *.$DOMAIN \
      -m $EMAIL \
      --agree-tos \
      --non-interactive
else
    echo "Certificat SSL déjà existant pour $DOMAIN, skipping..."
fi

# Configurer Nginx pour SSL
sudo tee /etc/nginx/sites-available/$DOMAIN > /dev/null <<EOF
server {
    listen 80;
    server_name $DOMAIN *.$DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl;
    server_name $DOMAIN *.$DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
        proxy_redirect off;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP \$remote_addr;
        
        # Pour les requêtes de streaming
        proxy_buffering off;
        proxy_cache off;
        proxy_request_buffering off;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
    }
}
EOF

sudo nginx -t && sudo systemctl reload nginx

echo "✅ Installation terminée !"
echo "Port Node.js: $APP_PORT"
echo "Nginx configuré avec SSL wildcard pour $DOMAIN et *.$DOMAIN"