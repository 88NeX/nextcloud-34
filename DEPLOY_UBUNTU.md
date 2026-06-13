# Пошаговое развёртывание: Nextcloud 34 + Euro-Office на Ubuntu Server 24.04

Инструкция для 5 отдельных Ubuntu Server 24.04 VM. Каждая команда сопровождается объяснением. Проблемы описаны в точке их возникновения.

---

## Архитектура

```
Internet / LAN
      │
      ▼
[VM-200] nc-proxy  192.168.88.10   Nginx: TLS-терминация, reverse proxy
      │                            nextcloud.lan  → VM-201 :8080
      │                            eurooffice.lan → VM-204 :80
      ├──────────────────────────────────────────────────────────┐
      ▼                                                          ▼
[VM-201] nc-app  192.168.88.20    [VM-204] nc-office  192.168.88.50
PHP 8.3-FPM + Nginx (порт 8080)   Euro-Office DocumentServer (Docker)
Nextcloud 34 (/var/www/nextcloud)  образ: euro-office-patched:local
      │
      ├──► [VM-202] nc-db     192.168.88.30   PostgreSQL 16
      └──► [VM-203] nc-cache  192.168.88.40   Redis 7
```

**LAN-домены** (Mikrotik DNS + mkcert TLS):
- `nextcloud.lan` → 192.168.88.10
- `eurooffice.lan` → 192.168.88.10

**Предполагается:** 5 VM с Ubuntu Server 24.04 уже созданы, каждой назначен
статический IP из таблицы выше. Пользователь: `ubuntu` с sudo-правами.

---

## Условные обозначения

| Префикс | Где выполняется |
|---------|----------------|
| `[Win]` | Рабочая машина Windows (PowerShell) |
| `[VM-NNN]` | SSH-сессия на соответствующей VM |

Для каждой VM подключение выглядит так:
```powershell
# [Win]
ssh ubuntu@192.168.88.10   # VM-200 (nc-proxy)
ssh ubuntu@192.168.88.20   # VM-201 (nc-app)
ssh ubuntu@192.168.88.30   # VM-202 (nc-db)
ssh ubuntu@192.168.88.40   # VM-203 (nc-cache)
ssh ubuntu@192.168.88.50   # VM-204 (nc-office)
```

---

## Шаг 0. Подготовка рабочего места (Windows)

### 0.1 SSH-ключ для доступа к VM

```powershell
# [Win] Генерируем ключ ed25519.
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\nc_ed25519" -N ""
```

```powershell
# [Win] Устанавливаем публичный ключ на каждую VM (вводим пароль ubuntu один раз).
# Повторяем для всех 5 IP.
foreach ($ip in @("192.168.88.10","192.168.88.20","192.168.88.30","192.168.88.40","192.168.88.50")) {
    ssh-copy-id -i "$env:USERPROFILE\.ssh\nc_ed25519.pub" ubuntu@$ip
    Write-Host "Key installed on $ip"
}
```

```powershell
# [Win] Проверяем: должны подключиться без пароля.
ssh -i "$env:USERPROFILE\.ssh\nc_ed25519" ubuntu@192.168.88.20 "echo OK"
```

Для удобства добавьте в `~\.ssh\config`:
```
Host nc-proxy
    HostName 192.168.88.10
    User ubuntu
    IdentityFile ~/.ssh/nc_ed25519

Host nc-app
    HostName 192.168.88.20
    User ubuntu
    IdentityFile ~/.ssh/nc_ed25519

Host nc-db
    HostName 192.168.88.30
    User ubuntu
    IdentityFile ~/.ssh/nc_ed25519

Host nc-cache
    HostName 192.168.88.40
    User ubuntu
    IdentityFile ~/.ssh/nc_ed25519

Host nc-office
    HostName 192.168.88.50
    User ubuntu
    IdentityFile ~/.ssh/nc_ed25519
```

После этого можно подключаться просто как `ssh nc-app`.

### 0.2 mkcert — TLS-сертификат для LAN-доменов

```powershell
# [Win] Устанавливаем mkcert.
winget install FiloSottile.mkcert
# или: choco install mkcert
```

```powershell
# [Win] Добавляем локальный CA в доверенные хранилища Windows и браузеров.
mkcert -install
```

```powershell
# [Win] Генерируем сертификат сразу для обоих LAN-доменов.
cd "$env:USERPROFILE\Desktop"
mkcert nextcloud.lan eurooffice.lan
# Создаются файлы: nextcloud.lan+1.pem и nextcloud.lan+1-key.pem
```

```powershell
# [Win] Сохраняем корневой CA — он нужен для Linux VM.
$caDir = & mkcert -CAROOT
Copy-Item "$caDir\rootCA.pem" "$env:USERPROFILE\Desktop\mkcert-rootCA.pem"
```

### 0.3 DNS в Mikrotik

```routeros
/ip dns static
add name=nextcloud.lan  address=192.168.88.10
add name=eurooffice.lan address=192.168.88.10
```

```powershell
# [Win] Проверяем — должен ответить 192.168.88.10.
Resolve-DnsName nextcloud.lan
```

### 0.4 Клонируем репозиторий проекта

```powershell
# [Win] Проект содержит патч-скрипты.
git clone <repo-url> C:\projects\NC34
```

---

## Шаг 1. Первичная настройка всех VM

Выполнить на каждой из 5 VM сразу после установки.

```bash
# [VM-xxx] Обновляем систему.
sudo apt update && sudo apt upgrade -y

# [VM-xxx] Устанавливаем базовые инструменты.
sudo apt install -y curl ca-certificates gnupg2 lsb-release apt-transport-https

# [VM-xxx] Устанавливаем правильный hostname (замените nc-proxy на нужный).
sudo hostnamectl set-hostname nc-proxy  # или nc-app, nc-db, nc-cache, nc-office
```

> **Брандмауэр:** Ubuntu 24.04 устанавливается с `ufw` в неактивном состоянии.
> Если `ufw` активен (`sudo ufw status` → active) — убедитесь, что SSH-порт открыт:
> `sudo ufw allow OpenSSH`. Дополнительные правила брандмауэра выходят за рамки
> этой инструкции — при необходимости добавьте правила для портов 80, 443 на VM-200.

---

## Шаг 2. VM-202 — PostgreSQL 16

```bash
# [Win] Подключаемся.
ssh nc-db
```

```bash
# [VM-202] Устанавливаем PostgreSQL 16. Ubuntu 24.04 содержит PG 16 в стандартном репо.
sudo apt install -y postgresql-16
```

### 2.1 Настройка сетевого доступа

```bash
# [VM-202] Разрешаем PostgreSQL слушать на внутреннем IP VM.
# Без этого CT 201 не сможет подключиться — получит "connection refused".
sudo sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '192.168.88.30'/" \
  /etc/postgresql/16/main/postgresql.conf

# [VM-202] Добавляем параметры производительности.
sudo tee -a /etc/postgresql/16/main/postgresql.conf << 'EOF'
shared_buffers = 256MB
effective_cache_size = 512MB
work_mem = 8MB
maintenance_work_mem = 64MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200
log_min_duration_statement = 1000
EOF

# [VM-202] Разрешаем подключение пользователю nextcloud с VM-201 (192.168.88.20).
# scram-sha-256 — современный безопасный метод аутентификации.
echo "host nextcloud nextcloud 192.168.88.20/32 scram-sha-256" \
  | sudo tee -a /etc/postgresql/16/main/pg_hba.conf

# [VM-202] Применяем конфигурацию.
sudo systemctl restart postgresql
sudo systemctl enable postgresql
```

### 2.2 Создание базы данных и пользователя

```bash
# [VM-202] Создаём пользователя и базу данных.
# TEMPLATE template0 гарантирует чистую UTF-8 без конфликтов локали.
sudo -u postgres psql << 'PSQL'
CREATE USER nextcloud WITH PASSWORD 'nc_db_pass_2026';
CREATE DATABASE nextcloud
  OWNER nextcloud
  ENCODING 'UTF8'
  LC_COLLATE 'en_US.UTF-8'
  LC_CTYPE 'en_US.UTF-8'
  TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
\q
PSQL
```

### 2.3 Проверка

```bash
# [VM-202] Проверяем подключение. Должен вывести версию PostgreSQL.
psql -h 192.168.88.30 -U nextcloud -d nextcloud -c "SELECT version();"
# Вводим пароль: nc_db_pass_2026
```

---

## Шаг 3. VM-203 — Redis 7

```bash
# [Win] Подключаемся.
ssh nc-cache
```

```bash
# [VM-203] Устанавливаем Redis. Ubuntu 24.04 содержит Redis 7 в репо.
sudo apt install -y redis-server
```

### 3.1 Настройка Redis

```bash
# [VM-203] Разрешаем слушать на loopback и внутреннем IP (для VM-201).
# Стандартная строка Ubuntu 24.04 — "bind 127.0.0.1 -::1".
sudo sed -i 's/^bind 127.0.0.1 -::1/bind 127.0.0.1 192.168.88.40/' \
  /etc/redis/redis.conf

# [VM-203] Устанавливаем пароль. Без него любой в сети может читать/писать в Redis.
sudo sed -i 's/^# requirepass foobared/requirepass nc_redis_pass_2026/' \
  /etc/redis/redis.conf

# [VM-203] Ограничиваем память и задаём политику вытеснения.
# allkeys-lru: при переполнении удаляет давно неиспользованные ключи.
sudo tee -a /etc/redis/redis.conf << 'EOF'
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF

# [VM-203] Применяем конфигурацию.
sudo systemctl restart redis-server
sudo systemctl enable redis-server
```

### 3.2 Проверка

```bash
# [VM-203] Должно ответить PONG.
redis-cli -h 192.168.88.40 -a nc_redis_pass_2026 PING
```

---

## Шаг 4. VM-201 — Nextcloud (PHP 8.3 + Nginx)

```bash
# [Win] Подключаемся.
ssh nc-app
```

### 4.1 Репозиторий PHP (Ondrej Sury PPA)

Ubuntu 24.04 содержит PHP 8.3 в основных репозиториях, однако PPA Ondrej Sury
предоставляет более полный набор расширений (redis, imagick, igbinary и др.),
которые в ubuntu/universe могут быть неполными или устаревшими.

```bash
# [VM-201] Добавляем PPA Ondrej Sury — стандартный источник PHP для Ubuntu.
# add-apt-repository автоматически добавляет ключ и записывает sources.list.
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update
```

### 4.2 Установка PHP 8.3 и расширений

```bash
# [VM-201] Устанавливаем PHP-FPM и все расширения для Nextcloud.
# php8.3-pgsql  — работа с PostgreSQL
# php8.3-redis  — подключение к Redis (кэш, блокировки)
# php8.3-apcu   — локальный кэш в памяти процесса PHP
# php8.3-imagick — обработка изображений (превью)
# php8.3-igbinary — эффективный сериализатор для Redis
# php8.3-bz2    — распаковка .bz2 архивов (тарбол Nextcloud)
# php8.3-gmp    — криптографические операции
sudo apt install -y \
  php8.3-fpm php8.3-pgsql php8.3-redis php8.3-apcu \
  php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml \
  php8.3-zip php8.3-intl php8.3-bcmath php8.3-gmp \
  php8.3-imagick php8.3-bz2 php8.3-igbinary
```

### 4.3 Настройка PHP-FPM пула

```bash
# [VM-201] Отключаем пул по умолчанию (www), чтобы он не конфликтовал с нашим.
sudo mv /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf.disabled
```

```bash
# [VM-201] Создаём пул nextcloud.
# PHP-FPM работает от www-data, nginx обращается через Unix-сокет.
sudo tee /etc/php/8.3/fpm/pool.d/nextcloud.conf << 'EOF'
[nextcloud]
user = www-data
group = www-data

; Unix-сокет. Nginx обращается к PHP-FPM через него.
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

; PATH нужен для корректного запуска cron-заданий Nextcloud.
env[PATH] = /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF
```

### 4.4 OPcache

```bash
# [VM-201] Настраиваем кэш скомпилированного PHP-кода.
# Без него каждый запрос компилирует PHP-файлы заново.
sudo tee /etc/php/8.3/fpm/conf.d/10-opcache-nextcloud.ini << 'EOF'
opcache.enable=1
opcache.memory_consumption=256
opcache.interned_strings_buffer=64
opcache.max_accelerated_files=20000
opcache.revalidate_freq=60
opcache.save_comments=1
opcache.enable_cli=0
EOF
```

### 4.5 Установка и настройка Nginx

```bash
# [VM-201] Устанавливаем Nginx.
sudo apt install -y nginx

# [VM-201] Отключаем дефолтный сайт.
sudo rm -f /etc/nginx/sites-enabled/default
```

```bash
# [VM-201] Создаём конфиг сайта Nextcloud.
# Nginx слушает на 192.168.88.20:8080 — к нему обращается VM-200 (proxy).
# ВАЖНО: mjs в location со статикой — без него Nextcloud Office не загружается
# (браузер получит MIME type mismatch и откажется исполнять модуль).
sudo tee /etc/nginx/sites-available/nextcloud << 'EOF'
upstream php-handler {
    server unix:/run/php/php8.3-nextcloud.sock;
}

server {
    listen 192.168.88.20:8080;
    server_name _;
    root /var/www/nextcloud;
    index index.php index.html;

    client_max_body_size 16G;
    client_body_timeout 3600s;
    send_timeout 3600s;

    location = /robots.txt  { allow all; log_not_found off; access_log off; }
    location = /favicon.ico { log_not_found off; access_log off; }

    location ^~ /.well-known {
        # ВАЖНО: абсолютный https://$http_host — иначе nginx генерирует
        # http://nextcloud.lan:8080/... (внутренний порт), что недоступно снаружи.
        location = /.well-known/carddav { return 301 https://$http_host/remote.php/dav; }
        location = /.well-known/caldav  { return 301 https://$http_host/remote.php/dav; }
        # ВАЖНО: rewrite (внутренний), а не return 301 (HTTP-редирект).
        # return 301 /index.php... сгенерировал бы http://nextcloud.lan:8080/index.php/...
        # Nextcloud-проверка .well-known/webfinger упала бы с cURL error 7 (порт 8080 не открыт).
        rewrite ^ /index.php$request_uri last;
    }

    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

    # ВАЖНО: location ~ (не ^~). ^~ совпадёт с /ocs-provider/index.php
    # и вызовет цикл редиректов. ~ матчит только /ocs-provider и /ocs-provider/.
    location ~ ^/ocs-provider/?$ {
        rewrite ^ /ocs-provider/index.php last;
    }

    location / {
        rewrite ^ /index.php$request_uri;
    }

    location ~ \.php(?:$|/) {
        fastcgi_split_path_info ^(.+?\.php)(/.*)$;
        set $path_info $fastcgi_path_info;
        try_files $fastcgi_script_name =404;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME  $document_root$fastcgi_script_name;
        fastcgi_param PATH_INFO        $path_info;
        fastcgi_param front_controller_active true;
        fastcgi_pass php-handler;
        fastcgi_intercept_errors on;
        fastcgi_request_buffering off;
        fastcgi_max_temp_file_size 0;
        fastcgi_send_timeout 3600s;
        fastcgi_read_timeout 3600s;
        fastcgi_connect_timeout 60s;
    }

    location ~ \.(?:css|js|mjs|svg|gif|ico|jpg|jpeg|png|webp|wasm|tflite|map|ogg|flac)$ {
        try_files $uri /index.php$request_uri;
        expires 6M;
        access_log off;
    }
    # ВАЖНО: добавляем otf — без него Nextcloud Setup Check "Font file loading" падает с 404.
    location ~ \.(?:otf|woff2?)$ {
        try_files $uri /index.php$request_uri;
        expires 7d;
        access_log off;
    }
    location /remote { return 301 /remote.php$request_uri; }
}
EOF

# [VM-201] Включаем сайт, проверяем конфиг.
sudo ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
sudo nginx -t
```

### 4.6 Скачивание и установка Nextcloud 34

```bash
# [VM-201] Скачиваем архив Nextcloud 34 (~170 MB).
curl -L https://download.nextcloud.com/server/releases/nextcloud-34.0.0.tar.bz2 \
  -o /tmp/nextcloud.tar.bz2

# [VM-201] Распаковываем в /var/www. Создаётся папка /var/www/nextcloud.
sudo tar -xjf /tmp/nextcloud.tar.bz2 -C /var/www/

# [VM-201] Создаём директорию данных пользователей (не внутри /var/www — безопаснее).
sudo mkdir -p /var/nc-data

# [VM-201] PHP-FPM работает от www-data — ему нужен полный доступ.
sudo chown -R www-data:www-data /var/www/nextcloud /var/nc-data
```

### 4.7 Запуск сервисов и установка Nextcloud

```bash
# [VM-201] Запускаем и добавляем в автозапуск.
sudo systemctl enable --now php8.3-fpm nginx

# [VM-201] Проверяем: оба должны быть active (running).
systemctl status php8.3-fpm --no-pager
systemctl status nginx --no-pager

# [VM-201] Проверяем, что сокет создан.
ls -la /run/php/php8.3-nextcloud.sock
```

```bash
# [VM-201] Инициализируем Nextcloud: создаём схему БД, admin-пользователя, config.php.
# ОБЯЗАТЕЛЬНО от имени www-data — иначе права на файлы будут неверные.
sudo -u www-data php /var/www/nextcloud/occ maintenance:install \
  --database=pgsql \
  --database-host=192.168.88.30 \
  --database-name=nextcloud \
  --database-user=nextcloud \
  --database-pass='nc_db_pass_2026' \
  --admin-user=admin \
  --admin-pass='changeme2026!' \
  --data-dir=/var/nc-data
```

После выполнения появится: `Nextcloud was successfully installed`.

---

## Шаг 5. VM-204 — Euro-Office DocumentServer (Docker)

```bash
# [Win] Подключаемся.
ssh nc-office
```

### 5.1 Установка Docker

```bash
# [VM-204] Добавляем GPG-ключ Docker.
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# [VM-204] Добавляем репозиторий Docker.
# $(. /etc/os-release && echo $VERSION_CODENAME) на Ubuntu 24.04 вернёт "noble".
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list

sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io

# [VM-204] Запускаем Docker и добавляем ubuntu-пользователя в группу docker.
# Это позволит запускать docker без sudo.
sudo systemctl enable --now docker
sudo usermod -aG docker ubuntu

# [VM-204] Применяем членство в группе (без выхода из сессии).
newgrp docker

# [VM-204] Проверяем.
docker --version
```

### 5.2 Скачивание образа Euro-Office

```bash
# [VM-204] Скачиваем образ (~3 GB). Может занять несколько минут.
docker pull ghcr.io/euro-office/documentserver:latest

# [VM-204] Создаём директории для persistent-данных.
sudo mkdir -p /opt/euro-office/logs /opt/euro-office/data
sudo chown ubuntu:ubuntu /opt/euro-office/logs /opt/euro-office/data
```

### 5.3 Первый запуск контейнера (для патчинга)

```bash
# [VM-204] Запускаем контейнер с нужными переменными окружения.
docker run -d --name euro-office \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=a928fb82f23ed6c536e67b8b5019f093af7b3a2bafda7618606798259cc65e35 \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  -v /opt/euro-office/logs:/var/log/euro-office \
  -v /opt/euro-office/data:/var/www/euro-office/Data \
  ghcr.io/euro-office/documentserver:latest

# [VM-204] Ждём ~30 секунд, проверяем запуск.
sleep 30
docker logs euro-office --tail=10
```

### 5.4 Патч entrypoint.sh — PKCS#1 + cat (ОБЯЗАТЕЛЬНО)

> **Почему нужен патч:**
>
> Euro-Office генерирует RSA-ключ через `openssl genpkey`. В OpenSSL 3.x
> эта команда создаёт ключ в формате **PKCS#8** (`BEGIN PRIVATE KEY`).
> Встроенный в бинарь `docservice` Node.js загружает только **PKCS#1** (`BEGIN RSA PRIVATE KEY`).
> При PKCS#8 в логах docservice появляется:
> ```
> Error: error:1E08010C:DECODER routines::unsupported
>   at generateProofSign (wopiUtils.js)
> ```
> Вторая проблема: оригинальный entrypoint.sh записывает PEM через `awk '{printf "%s\\n"}'` —
> это создаёт **буквальные** `\n` (backslash+n), а не реальные переносы строк.
> Node.js при чтении из JSON получает строку с `\n`-литералами и не может распознать
> PEM-формат — та же ошибка DECODER.
>
> **Без патча:** WOPI Proof не работает. Документ открывается (видна панель), но
> не загружается — в логах docservice `DECODER routines::unsupported`.

```powershell
# [Win] Копируем патч-скрипт на VM-204.
scp -i "$env:USERPROFILE\.ssh\nc_ed25519" `
  C:\projects\NC34\euro-office\patch_ep_final.py `
  ubuntu@192.168.88.50:/tmp/patch_ep_final.py
```

```bash
# [VM-204] Копируем патч из VM в Docker-контейнер.
# ВАЖНО: копируем именно patch_ep_final.py — НЕ сам entrypoint.sh.
# docker cp к /entrypoint.sh снимает execute-бит и контейнер не стартует.
docker cp /tmp/patch_ep_final.py euro-office:/tmp/patch_ep_final.py

# [VM-204] Запускаем патч внутри живого контейнера.
docker exec euro-office python3 /tmp/patch_ep_final.py
```

Ожидаемый вывод:
```
  replaced: 'openssl genpkey -algorithm RSA -outform PEM -out "$WOPI_PRIVATE_KEY"'
  replaced: 'WOPI_PRIVATE_KEY_DATA=$(awk \'{printf "%s\\\\n", $0}\' "$WOPI_PRIVATE_KEY")'
  replaced: 'chmod 600 "$WOPI_PRIVATE_KEY" 2>/dev/null || true'
Total: 3/3 replacements, permissions 0o755
```

Если написано `NOT FOUND` — версия образа отличается от ожидаемой. Проверьте:
```bash
docker exec euro-office grep -n 'genpkey' /entrypoint.sh
```

### 5.5 Настройка NODE_TLS_REJECT_UNAUTHORIZED

> **Почему нужно:**
>
> Внутри Euro-Office — два бинаря (`docservice` и `converter`) с **встроенным CA store**.
> Системный `/etc/ssl/certs/ca-certificates.crt` они не читают: `update-ca-certificates`
> внутри контейнера не помогает. При HTTPS с mkcert оба бинаря отклоняют TLS к nextcloud.lan.
>
> - `docservice` — без этого падает CheckFileInfo (первый WOPI-запрос).
> - `converter` — без этого не скачивает файл (`/contents`) для конвертации:
>   редактор открывается, но документ не загружается (`UNABLE_TO_VERIFY_LEAF_SIGNATURE`).

```bash
# [VM-204] Добавляем NODE_EXTRA_CA_CERTS и NODE_TLS_REJECT_UNAUTHORIZED=0
# в supervisord-конфиг обоих процессов.
docker exec euro-office sed -i \
  's|environment=NODE_ENV=production-linux,|environment=NODE_ENV=production-linux,NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mkcert-local.crt,NODE_TLS_REJECT_UNAUTHORIZED=0,|' \
  /etc/supervisor/conf.d/ds-docservice.conf

docker exec euro-office sed -i \
  's|environment=NODE_ENV=production-linux,|environment=NODE_ENV=production-linux,NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mkcert-local.crt,NODE_TLS_REJECT_UNAUTHORIZED=0,|' \
  /etc/supervisor/conf.d/ds-converter.conf

# [VM-204] Проверяем, что строки добавились.
docker exec euro-office grep NODE_TLS /etc/supervisor/conf.d/ds-docservice.conf
docker exec euro-office grep NODE_TLS /etc/supervisor/conf.d/ds-converter.conf
```

### 5.6 Добавление mkcert CA в контейнер

```powershell
# [Win] Копируем rootCA на VM-204.
scp -i "$env:USERPROFILE\.ssh\nc_ed25519" `
  "$env:USERPROFILE\Desktop\mkcert-rootCA.pem" `
  ubuntu@192.168.88.50:/tmp/mkcert-rootCA.crt
```

```bash
# [VM-204] Копируем CA из VM в Docker-контейнер и обновляем хранилище.
docker cp /tmp/mkcert-rootCA.crt \
  euro-office:/usr/local/share/ca-certificates/mkcert-local.crt
docker exec euro-office update-ca-certificates
```

### 5.7 Финальный commit и перезапуск

```bash
# [VM-204] Фиксируем все изменения (entrypoint, supervisord, CA) в новый образ.
docker commit euro-office euro-office-patched:local

# [VM-204] Останавливаем временный контейнер.
docker stop euro-office
docker rm euro-office

# [VM-204] Финальный запуск из патченого образа.
# --restart unless-stopped — автоматически стартует после перезагрузки VM.
# --add-host — прописывает LAN-домены в /etc/hosts контейнера.
#   Без этого при рестарте контейнера имена nextcloud.lan / eurooffice.lan
#   не будут резолвиться и документы не откроются.
docker run -d --name euro-office \
  --restart unless-stopped \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=a928fb82f23ed6c536e67b8b5019f093af7b3a2bafda7618606798259cc65e35 \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  --add-host=nextcloud.lan:192.168.88.10 \
  --add-host=eurooffice.lan:192.168.88.10 \
  -v /opt/euro-office/logs:/var/log/euro-office \
  -v /opt/euro-office/data:/var/www/euro-office/Data \
  euro-office-patched:local
```

### 5.8 Проверка Euro-Office

```bash
# [VM-204] Смотрим логи через ~30 секунд. Норма: запуск без ошибок DECODER.
docker logs euro-office --tail=30

# [VM-204] Healthcheck — должен вернуть {"status":"alive"}.
curl http://192.168.88.50/healthcheck

# [VM-204] Проверяем WOPI Proof в discovery XML.
# Ищем непустой атрибут value= у тега proof-key.
curl -s http://192.168.88.50/hosting/discovery | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
pk = root.find('.//{*}proof-key')
if pk is None: print('ERROR: no proof-key element')
elif not pk.get('value'): print('ERROR: proof-key value is empty — patch not applied')
else: print('OK: proof-key present, length', len(pk.get('value')))
"
```

---

## Шаг 6. VM-200 — Nginx Reverse Proxy + TLS

```bash
# [Win] Подключаемся.
ssh nc-proxy
```

```bash
# [VM-200] Устанавливаем Nginx.
sudo apt install -y nginx

# [VM-200] Создаём директорию для сертификатов.
sudo mkdir -p /etc/ssl/local

# [VM-200] Отключаем дефолтный сайт.
sudo rm -f /etc/nginx/sites-enabled/default
```

### 6.1 Загрузка TLS-сертификатов

```powershell
# [Win] Копируем сертификат и ключ на VM-200.
scp -i "$env:USERPROFILE\.ssh\nc_ed25519" `
  "$env:USERPROFILE\Desktop\nextcloud.lan+1.pem" `
  ubuntu@192.168.88.10:/tmp/fullchain.pem

scp -i "$env:USERPROFILE\.ssh\nc_ed25519" `
  "$env:USERPROFILE\Desktop\nextcloud.lan+1-key.pem" `
  ubuntu@192.168.88.10:/tmp/privkey.pem
```

```bash
# [VM-200] Устанавливаем сертификаты в нужную директорию.
sudo mv /tmp/fullchain.pem /etc/ssl/local/fullchain.pem
sudo mv /tmp/privkey.pem   /etc/ssl/local/privkey.pem

# [VM-200] Ограничиваем права на приватный ключ.
sudo chmod 640 /etc/ssl/local/privkey.pem
sudo chown root:www-data /etc/ssl/local/privkey.pem
```

### 6.2 Конфигурация Nginx

```bash
# [VM-200] Создаём конфиг для обоих LAN-доменов.
sudo tee /etc/nginx/sites-available/nextcloud << 'EOF'
# HTTP → HTTPS редирект. [::]:80 — IPv6.
server {
    listen 80;
    listen [::]:80;
    server_name nextcloud.lan eurooffice.lan;
    return 301 https://$host$request_uri;
}

# ── Nextcloud ──────────────────────────────────────────────────────────────────
server {
    # listen 443 ssl http2; — единая директива для nginx < 1.25.1 (Ubuntu 24.04 = 1.24.x).
    # "listen 443 ssl;" + отдельная "http2 on;" работают только с nginx 1.25.1+.
    listen 443 ssl http2;
    listen [::]:443 ssl;
    server_name nextcloud.lan;

    ssl_certificate     /etc/ssl/local/fullchain.pem;
    ssl_certificate_key /etc/ssl/local/privkey.pem;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache         shared:SSL:10m;
    ssl_session_timeout       1d;
    ssl_session_tickets       off;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header X-Content-Type-Options    nosniff    always;
    add_header X-Frame-Options           SAMEORIGIN always;
    add_header X-XSS-Protection          "1; mode=block" always;
    add_header Referrer-Policy           "no-referrer" always;
    add_header X-Permitted-Cross-Domain-Policies none always;

    client_max_body_size 16G;
    client_body_timeout 3600s;
    send_timeout        3600s;

    location / {
        proxy_pass         http://192.168.88.20:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_set_header X-Forwarded-Port  443;
        proxy_set_header Upgrade           $http_upgrade;
        proxy_set_header Connection        "upgrade";
        proxy_connect_timeout      60s;
        proxy_send_timeout       3600s;
        proxy_read_timeout       3600s;
        proxy_request_buffering    off;
        proxy_buffering            off;
    }
}

# ── Euro-Office ────────────────────────────────────────────────────────────────
server {
    listen 443 ssl http2;
    listen [::]:443 ssl;
    server_name eurooffice.lan;

    ssl_certificate     /etc/ssl/local/fullchain.pem;
    ssl_certificate_key /etc/ssl/local/privkey.pem;

    ssl_protocols             TLSv1.2 TLSv1.3;
    ssl_ciphers               ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384;
    ssl_prefer_server_ciphers off;
    ssl_session_cache         shared:SSL_EO:10m;
    ssl_session_timeout       1d;

    add_header Strict-Transport-Security "max-age=15552000; includeSubDomains" always;
    add_header X-Content-Type-Options    nosniff always;

    client_max_body_size 100M;

    # WebSocket для совместного редактирования.
    location ~* ^/[\d]+\.[\d]+\.[\d]+\.[\d]+/(c2s|s2c) {
        proxy_pass         http://192.168.88.50:80;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_set_header   Host       $host;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_read_timeout 86400s;
    }

    location / {
        proxy_pass         http://192.168.88.50:80;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           $http_upgrade;
        proxy_set_header   Connection        "upgrade";
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto https;
        proxy_connect_timeout   60s;
        proxy_send_timeout     120s;
        proxy_read_timeout     120s;
        proxy_buffering         off;
    }
}
EOF

# [VM-200] Включаем сайт, проверяем конфиг, запускаем.
sudo ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
sudo nginx -t     # syntax is ok + test is successful
sudo systemctl enable --now nginx
```

### 6.3 Доверие mkcert CA на VM-201

VM-201 (PHP) делает HTTPS-запросы к `eurooffice.lan` для получения discovery XML.
Без mkcert CA в системном хранилище PHP-curl не примет сертификат.

```powershell
# [Win] Копируем CA на VM-201.
scp -i "$env:USERPROFILE\.ssh\nc_ed25519" `
  "$env:USERPROFILE\Desktop\mkcert-rootCA.pem" `
  ubuntu@192.168.88.20:/tmp/mkcert-rootCA.crt
```

```bash
# [VM-201] Устанавливаем CA в системное хранилище.
ssh nc-app
sudo cp /tmp/mkcert-rootCA.crt /usr/local/share/ca-certificates/mkcert-local.crt
sudo update-ca-certificates
```

---

## Шаг 7. Пост-конфигурация Nextcloud

Все команды выполняются на VM-201 через SSH.

```bash
# [Win]
ssh nc-app
```

Вспомогательный алиас (работает в текущей сессии):
```bash
alias occ='sudo -u www-data php /var/www/nextcloud/occ'
```

### 7.1 Системные параметры

```bash
# [VM-201] Добавляем доверенные домены.
# Без этого Nextcloud отклоняет все запросы с "Access through untrusted domain".
# 0: основной домен, 1: IP proxy (VM-200), 2: IP app (VM-201), 3-4: localhost для CLI.
occ config:system:set trusted_domains 0 --value='nextcloud.lan'
occ config:system:set trusted_domains 1 --value='192.168.88.10'
occ config:system:set trusted_domains 2 --value='192.168.88.20'
occ config:system:set trusted_domains 3 --value='127.0.0.1'
occ config:system:set trusted_domains 4 --value='localhost'

# [VM-201] Разрешаем VM-200 (proxy) передавать X-Forwarded-* заголовки.
# Без этого Nextcloud не верит заголовку X-Forwarded-Proto: https.
occ config:system:set trusted_proxies 0 --value='192.168.88.10'

# [VM-201] Указываем, какой заголовок содержит реальный IP клиента.
occ config:system:set forwarded_for_headers 0 --value='HTTP_X_FORWARDED_FOR'

# [VM-201] Публичный URL Nextcloud (используется в ссылках email, WebDAV).
occ config:system:set overwrite.cli.url --value='https://nextcloud.lan'

# [VM-201] Все URL должны быть HTTPS.
# ВАЖНО: устанавливать ТОЛЬКО после того, как HTTPS уже работает (шаг 6).
# Если поставить раньше — Nextcloud будет генерировать HTTPS-ссылки,
# но Euro-Office ещё на HTTP, WOPI-запросы упадут.
occ config:system:set overwriteprotocol --value='https'
```

### 7.2 Кэширование через APCu и Redis

```bash
# [VM-201] Локальный кэш в памяти процесса PHP.
occ config:system:set memcache.local --value='\OC\Memcache\APCu'

# [VM-201] Распределённый кэш (общий между FPM-воркерами).
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'

# [VM-201] Блокировки файлов через Redis (предотвращает конфликты при одновременном доступе).
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'

# [VM-201] Параметры подключения к Redis.
occ config:system:set redis host     --value='192.168.88.40'
occ config:system:set redis port     --value=6379  --type=integer
occ config:system:set redis password --value='nc_redis_pass_2026'
occ config:system:set redis timeout  --value=1.5   --type=float
```

### 7.3 Установка и настройка Nextcloud Office (richdocuments)

```bash
# [VM-201] Устанавливаем приложение richdocuments (Nextcloud Office / WOPI-клиент).
occ app:install richdocuments
```

```bash
# [VM-201] wopi_url: URL, по которому PHP (VM-201) обращается к Euro-Office
# для получения discovery XML и WOPI actions. Используется серверно.
occ config:app:set richdocuments wopi_url     --value='https://eurooffice.lan/'
occ config:app:set richdocuments collabora_url --value='https://eurooffice.lan/'

# [VM-201] public_wopi_url: откуда БРАУЗЕР загружает редактор Euro-Office.
occ config:app:set richdocuments public_wopi_url --value='https://eurooffice.lan'

# [VM-201] Отключаем проверку TLS-сертификата PHP → Euro-Office.
# При Let's Encrypt убрать (поставить 'no').
occ config:app:set richdocuments disable_certificate_verification --value='yes'

# [VM-201] Разрешаем WOPI-запросы только с IP Euro-Office (192.168.88.50).
occ config:app:set richdocuments wopi_allowlist --value='192.168.88.50'

# [VM-201] Включаем WOPI Proof. Euro-Office подписывает запросы RSA-ключом,
# Nextcloud проверяет подпись. Требует корректного entrypoint.sh (шаг 5.4).
occ config:app:set richdocuments disable_wopi_proof --value='no'
```

### 7.4 activate-config и восстановление wopi_callback_url

> **Ловушка:** `occ richdocuments:activate-config` сбрасывает `wopi_callback_url`
> в пустую строку. Нужно **немедленно** восстановить его после каждого вызова.

```bash
# [VM-201] Обновляем discovery-кэш (загружает WOPI Proof ключ от Euro-Office).
occ richdocuments:activate-config 2>/dev/null || true

# [VM-201] НЕМЕДЛЕННО восстанавливаем wopi_callback_url.
# Это URL, с которого Euro-Office делает WOPI-запросы к Nextcloud.
#
# КРИТИЧЕСКИ ВАЖНО: значение ДОЛЖНО совпадать с overwrite.cli.url.
# Nextcloud генерирует ожидаемый URL через urlGenerator, учитывая overwriteprotocol.
# Если Euro-Office подписывает http://192.168.88.20:8080/..., а Nextcloud ожидает
# https://nextcloud.lan/... — подписи не совпадут → HTTP 500.
occ config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'
```

### 7.5 Сброс Redis-кэша

```bash
# [VM-203] Redis кэширует discovery XML с WOPI endpoints и proof-key.
# После изменений конфига Euro-Office или richdocuments — сбрасываем кэш,
# иначе Nextcloud будет использовать устаревшие данные.
ssh nc-cache
redis-cli -h 192.168.88.40 -a nc_redis_pass_2026 FLUSHALL
exit
```

### 7.6 Патч richdocuments: WOPI Proof для конвертера и fclose

> **Проблема 1 — Новые файлы не открываются ("Загрузка не удалась"):**
> Euro-Office converter делает WOPI-запросы к `/wopi/template/NNN` БЕЗ заголовков
> `X-WOPI-Proof`. `WOPIMiddleware.php` видит пустой `X-WOPI-TimeStamp`,
> преобразует `(int)'' = 0` → год ~1 н.э. → "старше 20 минут" → HTTP 500.
>
> **Проблема 2 — PHP warning:** `fclose(): supplied resource is not a valid stream resource`
> в `RemoteService.php` — Guzzle закрывает stream, `finally` блок пытается ещё раз.

```bash
# [VM-201] Патч 1: пропускаем WOPI Proof если клиент не прислал заголовки.
ssh nc-app
sudo sed -i \
  's/if (\$hasProofKey) {/if (\$hasProofKey \&\& \$wopiProof) {/' \
  /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php

# [VM-201] Патч 2: guard против double-fclose в RemoteService.php.
sudo sed -i \
  's/\t\t\tfclose(\$stream);/\t\t\tif (is_resource(\$stream)) { fclose(\$stream); }/' \
  /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php

sudo systemctl reload php8.3-fpm
exit
```

---

## Шаг 8. Финальная проверка

### 8.1 Проверка сервисов

```bash
# [VM-202] PostgreSQL.
ssh nc-db
systemctl status postgresql --no-pager

# [VM-203] Redis.
ssh nc-cache
redis-cli -h 192.168.88.40 -a nc_redis_pass_2026 PING   # должен ответить PONG

# [VM-201] PHP-FPM и Nginx.
ssh nc-app
systemctl status php8.3-fpm nginx --no-pager

# [VM-204] Euro-Office healthcheck.
ssh nc-office
curl -s http://192.168.88.50/healthcheck   # {"status":"alive"}

# [VM-200] Nginx proxy.
ssh nc-proxy
systemctl status nginx --no-pager

# [VM-204] Проверяем WOPI Proof в discovery.
ssh nc-office
curl -s http://192.168.88.50/hosting/discovery | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
pk = root.find('.//{*}proof-key')
if pk is None: print('ERROR: no proof-key element')
elif not pk.get('value'): print('ERROR: proof-key value is empty')
else: print('OK: proof-key length', len(pk.get('value')))
"
```

### 8.2 Проверка в браузере

1. Откройте `https://nextcloud.lan` (на машине с установленным mkcert CA)
2. Войдите: `admin` / `changeme2026!`
3. Загрузите тестовый `.docx` через "+" → "Загрузить файл"
4. Кликните по файлу — должен открыться редактор Euro-Office
5. Внесите изменения, закройте вкладку — файл должен сохраниться

### 8.3 Диагностика при проблемах

```bash
# [VM-204] Логи docservice (WOPI-запросы).
ssh nc-office
docker exec euro-office tail -50 /var/log/euro-office/documentserver/docservice/out.log

# [VM-204] Логи converter (конвертация файлов).
docker exec euro-office tail -50 /var/log/euro-office/documentserver/converter/out.log

# [VM-201] Логи Nextcloud (WOPI-ошибки PHP).
ssh nc-app
sudo tail -30 /var/nc-data/nextcloud.log
```

---

## Различия между Ubuntu 24.04 и Debian 12 (LXC)

| Аспект | Debian 12 (Proxmox LXC) | Ubuntu 24.04 VM |
|--------|------------------------|-----------------|
| Доступ | `pct exec NNN -- bash` | `ssh ubuntu@IP` |
| Копирование файлов | `pct push NNN src dst` | `scp src ubuntu@IP:dst` |
| PHP репозиторий | packages.sury.org (curl + gpg) | `add-apt-repository ppa:ondrej/php` |
| Docker репозиторий | `download.docker.com/linux/debian` | `download.docker.com/linux/ubuntu` |
| Docker без sudo | root внутри LXC | `usermod -aG docker ubuntu` + `newgrp docker` |
| sudo | Не нужен (root) | Нужен для системных команд |
| Docker in LXC | Нужен привилегированный CT + nesting=1 | Нативный Docker в VM |

---

## Справочник: частые команды после развёртывания

```bash
# Перезапуск Euro-Office (без пересоздания контейнера).
ssh nc-office
docker restart euro-office

# Сброс Redis-кэша (после изменений в richdocuments или Euro-Office).
ssh nc-cache
redis-cli -h 192.168.88.40 -a nc_redis_pass_2026 FLUSHALL

# occ-команды (от www-data — обязательно).
ssh nc-app
sudo -u www-data php /var/www/nextcloud/occ <команда>

# Восстановление wopi_callback_url (после каждого activate-config).
sudo -u www-data php /var/www/nextcloud/occ \
  config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'

# Логи Euro-Office.
ssh nc-office
docker logs euro-office --tail=30
docker exec euro-office tail -50 /var/log/euro-office/documentserver/docservice/out.log

# Логи Nextcloud.
ssh nc-app
sudo tail -30 /var/nc-data/nextcloud.log
```
