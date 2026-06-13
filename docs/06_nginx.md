# 06 — Nginx Reverse Proxy + TLS (контейнер nc-proxy, 192.168.88.10)

```bash
pct exec 200 -- bash
```

## 1. Установка Nginx и Certbot

```bash
apt-get update
apt-get install -y nginx certbot python3-certbot-nginx

systemctl enable nginx
```

## 2. Получение TLS-сертификатов

```bash
# Публичный IP контейнера nc-proxy должен быть доступен из интернета
# Или nc-proxy должен иметь второй сетевой интерфейс с публичным IP

# Nextcloud
certbot certonly --nginx \
  -d cloud.example.com \
  --agree-tos --email admin@example.com --non-interactive

# Collabora Office
certbot certonly --nginx \
  -d office.example.com \
  --agree-tos --email admin@example.com --non-interactive

# Автообновление
echo "0 3 * * * root certbot renew --quiet --post-hook 'systemctl reload nginx'" \
  > /etc/cron.d/certbot-renew
```

## 3. Конфигурация Nginx — Nextcloud

```bash
cat > /etc/nginx/sites-available/nextcloud << 'NGINXEOF'
# HTTP → HTTPS редирект
server {
    listen 80;
    listen [::]:80;
    server_name cloud.example.com;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name cloud.example.com;

    ssl_certificate     /etc/letsencrypt/live/cloud.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/cloud.example.com/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/cloud.example.com/chain.pem;

    # Современные TLS настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:DHE-RSA-AES128-GCM-SHA256;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    ssl_stapling on;
    ssl_stapling_verify on;
    resolver 1.1.1.1 8.8.8.8 valid=300s;

    # Security headers
    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains; preload" always;
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header X-XSS-Protection "1; mode=block" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header Permissions-Policy "interest-cohort=()" always;

    client_max_body_size 16G;
    client_body_timeout 3600s;
    send_timeout 3600s;

    # Proxy к nc-app
    location / {
        proxy_pass http://192.168.88.20:8080;
        proxy_http_version 1.1;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port $server_port;

        proxy_connect_timeout 60s;
        proxy_send_timeout 3600s;
        proxy_read_timeout 3600s;
        proxy_request_buffering off;
        proxy_buffering off;

        # WebSocket (для Notify Push / Euro-Office)
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
    }

    # Nextcloud Push notifications
    location /push/ {
        proxy_pass http://192.168.88.20:7867/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    }
}
NGINXEOF
```

## 4. Конфигурация Nginx — Euro-Office DocumentServer

Euro-Office слушает на `192.168.88.50:80` (порт 80 внутри Docker-контейнера).
Nginx снимает TLS и проксирует трафик, включая WebSocket-соединения редактора.

> LAN-домен `eurooffice.lan` — замените на ваш публичный домен если нужно.

```bash
cat > /etc/nginx/sites-available/euro-office << 'NGINXEOF'
server {
    listen 80;
    listen [::]:80;
    server_name eurooffice.lan;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name eurooffice.lan;

    ssl_certificate     /etc/ssl/certs/eurooffice.lan.pem;
    ssl_certificate_key /etc/ssl/private/eurooffice.lan-key.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL_EO:10m;
    ssl_session_timeout 1d;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header X-Content-Type-Options nosniff always;

    # Буфер для больших запросов (конвертация документов)
    client_max_body_size 100M;
    client_body_timeout 120s;

    # Euro-Office слушает на порту 80 (не 8080)
    # docker run задаёт: -p 192.168.88.50:80:80

    # Discovery endpoint — healthcheck и WOPI proof-key
    location /hosting/discovery {
        proxy_pass http://192.168.88.50:80;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # WebSocket — совместное редактирование (docservice)
    location ~* ^/[\d]+\.[\d]+\.[\d]+\.[\d]+/(c2s|s2c) {
        proxy_pass http://192.168.88.50:80;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
    }

    # Остальные запросы (статика, API, конвертер)
    location / {
        proxy_pass http://192.168.88.50:80;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;

        proxy_connect_timeout 60s;
        proxy_send_timeout 120s;
        proxy_read_timeout 120s;
        proxy_buffering off;
    }
}
NGINXEOF
```

## 5. Активация конфигов

```bash
ln -sf /etc/nginx/sites-available/nextcloud   /etc/nginx/sites-enabled/nextcloud
ln -sf /etc/nginx/sites-available/euro-office /etc/nginx/sites-enabled/euro-office
rm -f /etc/nginx/sites-enabled/default

# Настройка основного nginx.conf
cat > /etc/nginx/nginx.conf << 'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
include /etc/nginx/modules-enabled/*.conf;

events {
    worker_connections 1024;
    use epoll;
    multi_accept on;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;
    server_tokens off;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    # Логирование
    access_log /var/log/nginx/access.log;
    error_log  /var/log/nginx/error.log;

    gzip on;
    gzip_vary on;
    gzip_proxied any;
    gzip_comp_level 6;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

    include /etc/nginx/sites-enabled/*;
}
EOF

nginx -t && systemctl reload nginx
```
