# 04 — Nextcloud 34 + PHP 8.3 (контейнер nc-app, 192.168.88.20)

```bash
pct exec 201 -- bash
```

## 1. Установка PHP 8.3 и зависимостей

```bash
curl -sSLo /usr/share/keyrings/deb.sury.org-php.gpg \
  https://packages.sury.org/php/apt.gpg

echo "deb [signed-by=/usr/share/keyrings/deb.sury.org-php.gpg] \
  https://packages.sury.org/php/ bookworm main" \
  > /etc/apt/sources.list.d/php.list

apt-get update
apt-get install -y \
  php8.3 php8.3-fpm php8.3-cli \
  php8.3-pgsql php8.3-redis php8.3-gd php8.3-curl \
  php8.3-mbstring php8.3-xml php8.3-zip php8.3-intl \
  php8.3-bcmath php8.3-gmp php8.3-imagick \
  php8.3-apcu php8.3-sysvsem \
  php8.3-ldap php8.3-imap php8.3-bz2 php8.3-exif \
  nginx-light \
  ffmpeg imagemagick \
  curl wget unzip git cron sudo

# Системные утилиты для Nextcloud
apt-get install -y smbclient libsmbclient-dev php8.3-smbclient || true
```

## 2. Настройка PHP-FPM

### /etc/php/8.3/fpm/pool.d/nextcloud.conf

```bash
cat > /etc/php/8.3/fpm/pool.d/nextcloud.conf << 'EOF'
[nextcloud]
user = www-data
group = www-data
listen = /run/php/php8.3-nextcloud.sock
listen.owner = www-data
listen.group = www-data

pm = dynamic
pm.max_children = 32
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500

php_admin_value[upload_max_filesize] = 16G
php_admin_value[post_max_size] = 16G
php_admin_value[memory_limit] = 512M
php_admin_value[max_execution_time] = 3600
php_admin_value[max_input_time] = 3600

php_admin_value[opcache.enable] = 1
php_admin_value[opcache.memory_consumption] = 256
php_admin_value[opcache.interned_strings_buffer] = 32
php_admin_value[opcache.max_accelerated_files] = 20000
php_admin_value[opcache.revalidate_freq] = 60
php_admin_value[opcache.save_comments] = 1

env[PATH] = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF

# Удалить дефолтный пул
rm -f /etc/php/8.3/fpm/pool.d/www.conf
systemctl restart php8.3-fpm
```

## 3. Директории и права

```bash
mkdir -p /var/www/nextcloud
mkdir -p /var/nc-data          # данные пользователей (можно вынести на NFS/NAS)
chown -R www-data:www-data /var/www/nextcloud /var/nc-data
```

## 4. Скачивание и распаковка Nextcloud 34

```bash
NCVER="34.0.0"     # уточнить актуальную версию на nextcloud.com/install

cd /tmp
wget "https://download.nextcloud.com/server/releases/nextcloud-${NCVER}.tar.bz2"
wget "https://download.nextcloud.com/server/releases/nextcloud-${NCVER}.tar.bz2.sha256"
sha256sum -c "nextcloud-${NCVER}.tar.bz2.sha256"

tar -xjf "nextcloud-${NCVER}.tar.bz2" -C /var/www/
chown -R www-data:www-data /var/www/nextcloud
```

## 5. Nginx внутренний (на nc-app, слушает только localhost)

```bash
cat > /etc/nginx/sites-available/nextcloud << 'EOF'
upstream php-handler {
    server unix:/run/php/php8.3-nextcloud.sock;
}

server {
    listen 127.0.0.1:8080;
    server_name _;
    root /var/www/nextcloud;
    index index.php index.html;

    client_max_body_size 16G;
    client_body_timeout 3600s;
    send_timeout 3600s;

    # Security headers — итоговые выставляет nc-proxy
    add_header X-Content-Type-Options nosniff always;

    location = /robots.txt { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }

    location ^~ /.well-known {
        location = /.well-known/carddav  { return 301 /remote.php/dav; }
        location = /.well-known/caldav   { return 301 /remote.php/dav; }
        location /.well-known/acme-challenge { try_files $uri $uri/ =404; }
        location /.well-known/pki-validation { try_files $uri $uri/ =404; }
        return 301 /index.php$request_uri;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/)  { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console)                { return 404; }

    location / {
        rewrite ^ /index.php;
    }

    location ~ \.php(?:$|/) {
        rewrite ^/(?!index|remote|public|cron|core\/ajax\/update|status|ocs\/v[12]|updater\/.+|oc[ms]-provider\/.+|.+\/richdocumentscode\/proxy) /index.php$request_uri;

        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;

        try_files $fastcgi_script_name =404;

        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO $path_info;
        fastcgi_param HTTPS on;
        fastcgi_param modHeadersAvailable true;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;

        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_max_temp_file_size 0;

        fastcgi_send_timeout 3600s;
        fastcgi_read_timeout 3600s;
        fastcgi_connect_timeout 60s;
    }

    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        expires 6M;
        access_log off;
    }
    location ~ \.woff2?$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }
    location /remote {
        return 301 /remote.php$request_uri;
    }
}
EOF

ln -sf /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
```

## 6. Установка Nextcloud (CLI)

```bash
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database "pgsql" \
  --database-host "192.168.88.30" \
  --database-port "5432" \
  --database-name "nextcloud" \
  --database-user "nextcloud" \
  --database-pass "CHANGE_ME_DB_PASS" \
  --admin-user "admin" \
  --admin-pass "CHANGE_ME_ADMIN_PASS" \
  --data-dir "/var/nc-data"
```

## 7. Cron задание

```bash
# Рекомендованный метод — системный cron (не AJAX)
echo "*/5  *  *  *  * www-data php -f /var/www/nextcloud/cron.php" \
  > /etc/cron.d/nextcloud

sudo -u www-data php /var/www/nextcloud/occ background:cron
```

## 8. Автозапуск сервисов

```bash
systemctl enable php8.3-fpm nginx
```
