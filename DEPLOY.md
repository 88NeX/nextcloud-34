# Пошаговое развёртывание: Nextcloud 34 + Euro-Office на Proxmox LXC

Инструкция для ручного развёртывания с нуля. Каждая команда сопровождается объяснением. Проблемы, с которыми можно столкнуться, описаны в точке их возникновения.

---

## Архитектура

```
Internet / LAN
      │
      ▼
[CT 200] nc-proxy  192.168.88.10   Nginx: TLS-терминация, reverse proxy
      │                            nextcloud.lan → CT 201 :8080
      │                            eurooffice.lan → CT 204 :80
      ├──────────────────────────────────────────────────────────┐
      ▼                                                          ▼
[CT 201] nc-app  192.168.88.20    [CT 204] nc-office  192.168.88.50
PHP 8.3-FPM + Nginx (порт 8080)   Euro-Office DocumentServer (Docker)
Nextcloud 34 (/var/www/nextcloud)  образ: euro-office-patched:local
      │
      ├──► [CT 202] nc-db     192.168.88.30   PostgreSQL 16
      └──► [CT 203] nc-cache  192.168.88.40   Redis 7
```

**LAN-домены** (Mikrotik DNS + mkcert TLS):
- `nextcloud.lan` → 192.168.88.10
- `eurooffice.lan` → 192.168.88.10

**Proxmox хост:** 192.168.88.144, root, ключ `~/.ssh/proxyid_ed25519`

---

## Условные обозначения

| Префикс | Где выполняется |
|---------|----------------|
| `[Win]` | Рабочая машина Windows (PowerShell) |
| `[Proxmox]` | SSH-сессия на хосте Proxmox (192.168.88.144) |
| `[CT NNN]` | Внутри LXC-контейнера (через `pct exec NNN -- bash`) |

---

## Шаг 0. Подготовка рабочего места (Windows)

### 0.1 SSH-ключ для доступа к Proxmox

```powershell
# [Win] Генерируем ключ ed25519. Путь ~\.ssh\proxyid_ed25519 обязателен —
# он прописан во всех дальнейших командах scp/ssh.
ssh-keygen -t ed25519 -f "$env:USERPROFILE\.ssh\proxyid_ed25519" -N ""
```

```powershell
# [Win] Копируем публичный ключ на Proxmox (вводим пароль root один раз).
# После этого все подключения будут по ключу без пароля.
$pubkey = Get-Content "$env:USERPROFILE\.ssh\proxyid_ed25519.pub"
ssh root@192.168.88.144 "mkdir -p ~/.ssh && echo '$pubkey' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

```powershell
# [Win] Проверяем: должны подключиться без запроса пароля.
ssh -i "$env:USERPROFILE\.ssh\proxyid_ed25519" root@192.168.88.144 "echo OK"
```

### 0.2 mkcert — TLS-сертификат для LAN-доменов

mkcert создаёт локальный CA и выпускает сертификат, которому браузер доверяет.
Без этого браузер покажет "небезопасное соединение" и некоторые фичи Nextcloud не будут работать.

```powershell
# [Win] Устанавливаем mkcert (нужен winget или choco).
winget install FiloSottile.mkcert
# или: choco install mkcert
```

```powershell
# [Win] Добавляем локальный CA в доверенные хранилища Windows и браузеров.
# После этой команды созданные сертификаты будут доверенными в Chrome/Edge/Firefox.
mkcert -install
```

```powershell
# [Win] Генерируем сертификат для обоих доменов.
# Создаются два файла: nextcloud.lan+1.pem (цепочка) и nextcloud.lan+1-key.pem (ключ).
cd "$env:USERPROFILE\Desktop"
mkcert nextcloud.lan eurooffice.lan
```

```powershell
# [Win] Сохраняем корневой CA — он понадобится для Linux-контейнеров.
# Путь может отличаться — mkcert выводит его при запуске mkcert -install.
$caDir = & mkcert -CAROOT
Copy-Item "$caDir\rootCA.pem" "$env:USERPROFILE\Desktop\mkcert-rootCA.pem"
```

### 0.3 DNS в Mikrotik

Входим в Mikrotik (WinBox или SSH) и добавляем статические записи:

```routeros
/ip dns static
add name=nextcloud.lan  address=192.168.88.10
add name=eurooffice.lan address=192.168.88.10
```

Проверяем с Windows:
```powershell
# [Win] Должен ответить 192.168.88.10
Resolve-DnsName nextcloud.lan
```

### 0.4 Клонируем репозиторий проекта

```powershell
# [Win] Проект содержит патч-скрипты и конфиги.
# Если git не установлен — скачайте архив и распакуйте вручную.
git clone <repo-url> C:\projects\NC34
cd C:\projects\NC34
```

---

## Шаг 1. Создание LXC-контейнеров в Proxmox

Все команды выполняются на хосте Proxmox.

```bash
# [Win] Подключаемся к Proxmox
ssh -i ~/.ssh/proxyid_ed25519 root@192.168.88.144
```

### 1.1 Скачивание шаблона Debian 12

```bash
# [Proxmox] Обновляем список доступных шаблонов из репозитория Proxmox.
pveam update

# [Proxmox] Скачиваем шаблон Debian 12 (имя может незначительно отличаться —
# используйте `pveam available | grep debian-12` для актуального имени).
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

### 1.2 Создание контейнеров

Параметры одинаковы для всех, кроме CT 204 (для Docker нужен привилегированный режим).

```bash
# [Proxmox] CT 200 — Nginx reverse proxy.
# 1 CPU, 512 MB RAM, 8 GB диск.
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-proxy \
  --cores 1 \
  --memory 512 \
  --swap 512 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.10/24,gw=192.168.88.1 \
  --nameserver 192.168.88.1 \
  --unprivileged 1

# [Proxmox] CT 201 — Nextcloud PHP.
# 2 CPU, 2 GB RAM, 20 GB диск (под данные Nextcloud).
pct create 201 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-app \
  --cores 2 \
  --memory 2048 \
  --swap 1024 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.20/24,gw=192.168.88.1 \
  --nameserver 192.168.88.1 \
  --unprivileged 1

# [Proxmox] CT 202 — PostgreSQL.
# 2 CPU, 1 GB RAM, 20 GB диск.
pct create 202 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-db \
  --cores 2 \
  --memory 1024 \
  --swap 512 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.30/24,gw=192.168.88.1 \
  --nameserver 192.168.88.1 \
  --unprivileged 1

# [Proxmox] CT 203 — Redis.
# 1 CPU, 512 MB RAM, 8 GB диск.
pct create 203 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-cache \
  --cores 1 \
  --memory 512 \
  --swap 256 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.40/24,gw=192.168.88.1 \
  --nameserver 192.168.88.1 \
  --unprivileged 1

# [Proxmox] CT 204 — Euro-Office (Docker).
# ВАЖНО: --unprivileged 0 (привилегированный). Docker внутри LXC требует прав
# для работы с namespaces. --features nesting=1 включает вложенную виртуализацию.
# 4 CPU, 4 GB RAM, 40 GB диск (образ Docker ~3 GB + логи).
pct create 204 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-office \
  --cores 4 \
  --memory 4096 \
  --swap 2048 \
  --rootfs local-lvm:40 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.50/24,gw=192.168.88.1 \
  --nameserver 192.168.88.1 \
  --unprivileged 0 \
  --features nesting=1
```

### 1.3 Запуск контейнеров

```bash
# [Proxmox] Запускаем все пять контейнеров.
for ct in 200 201 202 203 204; do
  pct start $ct
  echo "Started CT $ct"
done

# [Proxmox] Проверяем статус — все должны быть running.
pct list
```

---

## Шаг 2. CT 202 — PostgreSQL 16

```bash
# [Proxmox] Входим в контейнер.
pct exec 202 -- bash
```

Теперь мы внутри CT 202. Все команды до конца этого шага — в этой сессии.

```bash
# [CT 202] Обновляем систему. Debian 12 поставляется с базовым набором пакетов.
apt update && apt upgrade -y

# [CT 202] Устанавливаем PostgreSQL 16. Debian 12 содержит его в стандартном репо.
apt install -y postgresql-16
```

### 2.1 Настройка сетевого доступа

По умолчанию PostgreSQL слушает только `localhost`. Нужно разрешить подключения
с CT 201 (192.168.88.20).

```bash
# [CT 202] Разрешаем PostgreSQL слушать на внутреннем IP контейнера.
# Без этого CT 201 не сможет подключиться — получит "connection refused".
sed -i "s/#listen_addresses = 'localhost'/listen_addresses = '192.168.88.30'/" \
  /etc/postgresql/16/main/postgresql.conf

# [CT 202] Добавляем параметры производительности.
# PostgreSQL 16 на 1GB RAM: tuning для небольшого сервера.
cat >> /etc/postgresql/16/main/postgresql.conf << 'EOF'
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

# [CT 202] Добавляем правило аутентификации: разрешаем пользователю nextcloud
# подключаться к БД nextcloud с IP 192.168.88.20 (CT 201).
# scram-sha-256 — современный безопасный метод (не md5).
echo "host nextcloud nextcloud 192.168.88.20/32 scram-sha-256" \
  >> /etc/postgresql/16/main/pg_hba.conf

# [CT 202] Применяем изменения конфига.
systemctl restart postgresql
```

### 2.2 Создание пользователя и базы данных

```bash
# [CT 202] Создаём пользователя и базу данных от имени суперпользователя postgres.
# TEMPLATE template0 гарантирует чистую кодировку UTF-8 без конфликтов.
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
# [CT 202] Проверяем подключение к базе под пользователем nextcloud.
# Должен открыться psql-промпт. Введите \q для выхода.
psql -h 192.168.88.30 -U nextcloud -d nextcloud -c "SELECT version();"

# [CT 202] Выходим из контейнера.
exit
```

---

## Шаг 3. CT 203 — Redis 7

```bash
# [Proxmox] Входим в контейнер.
pct exec 203 -- bash
```

```bash
# [CT 203] Обновляем систему и устанавливаем Redis.
apt update && apt upgrade -y
apt install -y redis-server
```

### 3.1 Настройка Redis

По умолчанию Redis слушает только `127.0.0.1` и не требует пароля.
Нам нужен сетевой доступ с CT 201 и аутентификация.

```bash
# [CT 203] Изменяем bind: слушаем на loopback и внутреннем IP (для CT 201).
# Стандартная строка в Debian 12 — "bind 127.0.0.1 -::1".
sed -i 's/^bind 127.0.0.1 -::1/bind 127.0.0.1 192.168.88.40/' /etc/redis/redis.conf

# [CT 203] Устанавливаем пароль. Без него любой в сети может читать/писать в Redis.
sed -i 's/^# requirepass foobared/requirepass nc_redis_pass_2026/' /etc/redis/redis.conf

# [CT 203] Ограничиваем память и задаём политику вытеснения.
# allkeys-lru: при переполнении удаляет давно неиспользованные ключи — подходит для кэша.
cat >> /etc/redis/redis.conf << 'EOF'
maxmemory 256mb
maxmemory-policy allkeys-lru
EOF

# [CT 203] Применяем конфиг.
systemctl restart redis-server
```

### 3.2 Проверка

```bash
# [CT 203] Проверяем доступность с паролем. Должно ответить PONG.
redis-cli -h 192.168.88.40 -a nc_redis_pass_2026 PING

# [CT 203] Выходим из контейнера.
exit
```

---

## Шаг 4. CT 201 — Nextcloud (PHP 8.3 + Nginx)

```bash
# [Proxmox] Входим в контейнер.
pct exec 201 -- bash
```

### 4.1 Добавление репозитория PHP 8.3

Debian 12 содержит PHP 8.2. Nextcloud 34 работает с 8.3.
Добавляем репозиторий Ondrej Sury — официальный мейнтейнер PHP-пакетов для Debian.

```bash
# [CT 201] Устанавливаем инструменты для работы с репозиториями.
apt update && apt upgrade -y
apt install -y curl apt-transport-https lsb-release ca-certificates gnupg2

# [CT 201] Добавляем GPG-ключ репозитория Ondrej Sury.
curl -sSL https://packages.sury.org/php/apt.gpg \
  | gpg --dearmor > /etc/apt/trusted.gpg.d/php.gpg

# [CT 201] Добавляем репозиторий.
echo "deb https://packages.sury.org/php/ $(lsb_release -sc) main" \
  > /etc/apt/sources.list.d/php.list

apt update
```

### 4.2 Установка PHP 8.3 и расширений

```bash
# [CT 201] Устанавливаем PHP-FPM и все расширения, необходимые Nextcloud.
# php8.3-pgsql  — работа с PostgreSQL
# php8.3-redis  — подключение к Redis (кэш, блокировки)
# php8.3-apcu   — локальный кэш в памяти процесса
# php8.3-imagick — обработка изображений (превью файлов)
# php8.3-gmp    — криптографические операции
# остальные — стандартные требования Nextcloud
apt install -y \
  php8.3-fpm php8.3-pgsql php8.3-redis php8.3-apcu \
  php8.3-curl php8.3-gd php8.3-mbstring php8.3-xml \
  php8.3-zip php8.3-intl php8.3-bcmath php8.3-gmp \
  php8.3-imagick php8.3-bz2 php8.3-igbinary
```

### 4.3 Настройка PHP-FPM пула

PHP-FPM запускает пул процессов, которые обрабатывают PHP-файлы Nextcloud.
Nginx будет отправлять запросы пулу через Unix-сокет.

```bash
# [CT 201] Отключаем пул по умолчанию (www), чтобы не конфликтовал с нашим.
mv /etc/php/8.3/fpm/pool.d/www.conf /etc/php/8.3/fpm/pool.d/www.conf.disabled

# [CT 201] Создаём пул nextcloud.
cat > /etc/php/8.3/fpm/pool.d/nextcloud.conf << 'EOF'
[nextcloud]
user = www-data
group = www-data

; Unix-сокет. Nginx обращается к PHP-FPM через него.
listen = /run/php/php8.3-nextcloud.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

; Динамический пул: масштабируется между min/max в зависимости от нагрузки.
pm = dynamic
pm.max_children = 32
pm.start_servers = 4
pm.min_spare_servers = 2
pm.max_spare_servers = 8
pm.max_requests = 500

; PHP-настройки для Nextcloud (переопределяют php.ini).
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
# [CT 201] Настраиваем OPcache — кэш скомпилированного PHP-кода.
# Существенно ускоряет работу Nextcloud (без него каждый запрос компилирует PHP).
# opcache.jit=1255 включает JIT-компиляцию (PHP 8+).
cat > /etc/php/8.3/fpm/conf.d/10-opcache-nextcloud.ini << 'EOF'
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
# [CT 201] Устанавливаем Nginx.
apt install -y nginx

# [CT 201] Отключаем дефолтный сайт — он занимает порт 80, нам он не нужен.
rm -f /etc/nginx/sites-enabled/default
```

```bash
# [CT 201] Создаём конфиг сайта Nextcloud.
# Nginx слушает только на 192.168.88.20:8080 — внутренний IP, к нему обращается CT 200.
# Статические файлы (.mjs включительно — без него Nextcloud Office не загружается).
cat > /etc/nginx/sites-available/nextcloud << 'EOF'
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

    # Защищаем служебные директории от прямого доступа.
    location ~ ^/(?:build|tests|config|lib|3rdparty|templates|data)(?:$|/) { return 404; }
    location ~ ^/(?:\.|autotest|occ|issue|indie|db_|console) { return 404; }

    # ВАЖНО: location ~ (не ^~). ^~ совпадёт с /ocs-provider/index.php и вызовет
    # цикл редиректов. ~ матчит только /ocs-provider и /ocs-provider/.
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

    # ВАЖНО: mjs обязателен. Без него Nextcloud Office не загрузится —
    # браузер получит MIME type mismatch и откажется исполнять модуль.
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

# [CT 201] Включаем сайт.
ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
nginx -t  # должно быть: syntax is ok + test is successful
```

### 4.6 Скачивание Nextcloud 34

```bash
# [CT 201] Скачиваем архив Nextcloud 34. Размер ~170 MB, скачивание может занять минуту.
curl -L https://download.nextcloud.com/server/releases/nextcloud-34.0.0.tar.bz2 \
  -o /tmp/nextcloud.tar.bz2

# [CT 201] Распаковываем в /var/www. Создаётся папка /var/www/nextcloud.
tar -xjf /tmp/nextcloud.tar.bz2 -C /var/www/

# [CT 201] Создаём директорию данных пользователей (не внутри /var/www — безопаснее).
mkdir -p /var/nc-data

# [CT 201] Устанавливаем владельца www-data на весь Nextcloud.
# PHP-FPM работает от имени www-data и должен иметь полный доступ.
chown -R www-data:www-data /var/www/nextcloud /var/nc-data
```

### 4.7 Запуск сервисов

```bash
# [CT 201] Запускаем PHP-FPM и Nginx, добавляем в автозапуск.
systemctl enable php8.3-fpm nginx
systemctl start php8.3-fpm nginx

# [CT 201] Проверяем: оба должны быть active (running).
systemctl status php8.3-fpm --no-pager
systemctl status nginx --no-pager

# [CT 201] Проверяем, что сокет создан.
ls -la /run/php/php8.3-nextcloud.sock
```

### 4.8 Установка Nextcloud

```bash
# [CT 201] Инициализируем Nextcloud: создаём БД-схему, admin-пользователя, config.php.
# Эта команда выполняется от имени www-data (обязательно — иначе права будут неверные).
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

```bash
# [CT 201] Выходим из контейнера — дальнейшая конфигурация через occ на шаге 7.
exit
```

---

## Шаг 5. CT 204 — Euro-Office DocumentServer (Docker)

```bash
# [Proxmox] Входим в контейнер.
pct exec 204 -- bash
```

### 5.1 Установка Docker

```bash
# [CT 204] Обновляем систему.
apt update && apt upgrade -y

# [CT 204] Устанавливаем зависимости для добавления репозитория Docker.
apt install -y ca-certificates curl gnupg

# [CT 204] Добавляем GPG-ключ Docker.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# [CT 204] Добавляем репозиторий Docker (официальный, не из Debian).
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  > /etc/apt/sources.list.d/docker.list

apt update
apt install -y docker-ce docker-ce-cli containerd.io

# [CT 204] Включаем Docker в автозапуск и запускаем.
systemctl enable docker
systemctl start docker

# [CT 204] Проверяем: должно вывести версию Docker.
docker --version
```

### 5.2 Скачивание образа Euro-Office

```bash
# [CT 204] Скачиваем образ (~3 GB). Может занять несколько минут.
docker pull ghcr.io/euro-office/documentserver:latest

# [CT 204] Создаём директории для persistent-данных (логи и файлы сессий).
# Они монтируются как тома и сохраняются между рестартами контейнера.
mkdir -p /opt/euro-office/logs /opt/euro-office/data
```

### 5.3 Первый запуск контейнера (для патчинга)

Контейнер запускается из оригинального образа. Нам нужно зайти внутрь и применить патч
к `/entrypoint.sh`, а затем зафиксировать изменения через `docker commit`.

```bash
# [CT 204] Запускаем контейнер с нужными переменными окружения.
# JWT_HEADER=AuthorizationJwt — нестандартный заголовок (не Authorization),
#   чтобы не конфликтовать со стандартной HTTP-авторизацией.
# WOPI_ENABLED=true — включаем WOPI Proof (подпись запросов).
docker run -d --name euro-office \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=a928fb82f23ed6c536e67b8b5019f093af7b3a2bafda7618606798259cc65e35 \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  -v /opt/euro-office/logs:/var/log/onlyoffice \
  -v /opt/euro-office/data:/var/www/onlyoffice/Data \
  ghcr.io/euro-office/documentserver:latest

# [CT 204] Ждём ~30 секунд, пока контейнер поднимется. Проверяем статус.
sleep 30
docker logs euro-office --tail=10
```

### 5.4 Патч entrypoint.sh — PKCS#1 + cat (ОБЯЗАТЕЛЬНО)

> **Почему нужен патч:**
>
> Euro-Office генерирует RSA-ключ для WOPI Proof через `openssl genpkey`. В OpenSSL 3.x
> эта команда по умолчанию создаёт ключ в формате **PKCS#8** (`BEGIN PRIVATE KEY`).
> Встроенный в бинарь `docservice` Node.js может загружать ключи только в формате
> **PKCS#1** (`BEGIN RSA PRIVATE KEY`). При PKCS#8 `crypto.createPrivateKey()` выдаёт:
> ```
> Error: error:1E08010C:DECODER routines::unsupported
> ```
>
> Дополнительная проблема: оригинальный `entrypoint.sh` записывает PEM-ключ в JSON
> через `awk '{printf "%s\\n"}'` — это создаёт **буквальные** символы `\n` (backslash+n)
> вместо реальных переносов строк. Node.js читает из JSON строку с `\n`-литералами
> и не может распознать PEM-формат — та же ошибка DECODER. Замена `awk` на `cat`
> сохраняет реальные переносы строк, которые `jq` корректно кодирует в JSON.
>
> **Без патча:** WOPI Proof не работает. Редактор открывается, но при попытке загрузить
> документ в логах docservice появляется `DECODER routines::unsupported`, и документ
> не загружается.

```bash
# [CT 204] Выходим из bash LXC временно, чтобы передать файл с Windows.
exit
```

```powershell
# [Win] Копируем патч-скрипт на Proxmox хост.
scp -i "$env:USERPROFILE\.ssh\proxyid_ed25519" `
  C:\projects\NC34\euro-office\patch_ep_final.py `
  root@192.168.88.144:/tmp/patch_ep_final.py
```

```bash
# [Proxmox] Передаём патч из Proxmox-хоста в LXC-контейнер CT 204.
pct push 204 /tmp/patch_ep_final.py /tmp/patch_ep_final.py

# [Proxmox] Из LXC копируем в Docker-контейнер.
# ВАЖНО: копируем именно patch_ep_final.py — НЕ сам entrypoint.sh.
# docker cp к /entrypoint.sh снимет execute-бит и контейнер не стартует.
pct exec 204 -- docker cp /tmp/patch_ep_final.py euro-office:/tmp/patch_ep_final.py

# [Proxmox] Запускаем патч внутри работающего контейнера.
# Скрипт модифицирует /entrypoint.sh изнутри — execute-бит сохраняется.
pct exec 204 -- docker exec euro-office python3 /tmp/patch_ep_final.py
```

Ожидаемый вывод:
```
  replaced: 'openssl genpkey -algorithm RSA -outform PEM -out "$WOPI_PRIVATE_KEY"'
  replaced: 'WOPI_PRIVATE_KEY_DATA=$(awk \'{printf "%s\\\\n", $0}\' "$WOPI_PRIVATE_KEY")'
  replaced: 'chmod 600 "$WOPI_PRIVATE_KEY" 2>/dev/null || true'
Total: 3/3 replacements, permissions 0o755
```

Если написано `NOT FOUND` — версия образа отличается от ожидаемой. Проверьте содержимое
`/entrypoint.sh` внутри контейнера: `docker exec euro-office grep -n 'genpkey' /entrypoint.sh`.

### 5.5 Настройка NODE_TLS_REJECT_UNAUTHORIZED

> **Почему нужно:**
>
> Euro-Office содержит два бинаря (`docservice` и `converter`), написанных на Node.js.
> Каждый использует **встроенный CA store** (Mozilla CA bundle из времени сборки бинаря),
> а не системный `/etc/ssl/certs/ca-certificates.crt`. Поэтому `update-ca-certificates`
> внутри контейнера не помогает — бинари об этом не знают.
>
> При переходе на HTTPS с mkcert-сертификатом оба бинаря отклоняют TLS-подключение
> к `nextcloud.lan` — mkcert CA не в их bundled store.
>
> - `docservice` — без этого не работает CheckFileInfo (первый WOPI-запрос).
> - `converter` — без этого не работает скачивание файла (`/contents`) для конвертации:
>   редактор открывается, но документ не загружается (ошибка `UNABLE_TO_VERIFY_LEAF_SIGNATURE`).
>
> **Без этой настройки:** Документ не загружается при любом HTTPS-сетапе с mkcert.
> Это не нужно для Let's Encrypt — его CA уже в bundled store Node.js.

```bash
# [Proxmox] Добавляем NODE_TLS_REJECT_UNAUTHORIZED=0 и NODE_EXTRA_CA_CERTS
# в supervisord-конфиг docservice.
# NODE_EXTRA_CA_CERTS позволяет Node.js использовать указанный CA-файл
# (работает для самого бинаря, но bundled axios может не читать его — поэтому
# дополнительно ставим NODE_TLS_REJECT_UNAUTHORIZED=0 как надёжный fallback).
pct exec 204 -- docker exec euro-office sed -i \
  's|environment=NODE_ENV=production-linux,|environment=NODE_ENV=production-linux,NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mkcert-local.crt,NODE_TLS_REJECT_UNAUTHORIZED=0,|' \
  /etc/supervisor/conf.d/ds-docservice.conf

# [Proxmox] То же самое для converter.
pct exec 204 -- docker exec euro-office sed -i \
  's|environment=NODE_ENV=production-linux,|environment=NODE_ENV=production-linux,NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/mkcert-local.crt,NODE_TLS_REJECT_UNAUTHORIZED=0,|' \
  /etc/supervisor/conf.d/ds-converter.conf

# [Proxmox] Проверяем, что строки добавились.
pct exec 204 -- docker exec euro-office grep NODE_TLS /etc/supervisor/conf.d/ds-docservice.conf
pct exec 204 -- docker exec euro-office grep NODE_TLS /etc/supervisor/conf.d/ds-converter.conf
```

### 5.6 Добавление mkcert CA в контейнер

```powershell
# [Win] Копируем rootCA на Proxmox.
scp -i "$env:USERPROFILE\.ssh\proxyid_ed25519" `
  "$env:USERPROFILE\Desktop\mkcert-rootCA.pem" `
  root@192.168.88.144:/tmp/mkcert-rootCA.pem
```

```bash
# [Proxmox] Передаём CA в LXC.
pct push 204 /tmp/mkcert-rootCA.pem /tmp/mkcert-rootCA.crt

# [Proxmox] Копируем CA из LXC в Docker-контейнер и обновляем хранилище.
# Это помогает curl/wget внутри контейнера, но НЕ Node.js бинарям (см. выше).
pct exec 204 -- docker cp /tmp/mkcert-rootCA.crt \
  euro-office:/usr/local/share/ca-certificates/mkcert-local.crt
pct exec 204 -- docker exec euro-office update-ca-certificates
```

### 5.7 Фиксация изменений и финальный запуск

```bash
# [Proxmox] Сохраняем все изменения (entrypoint.sh, supervisord, CA) в новый образ.
# docker commit создаёт слой поверх текущего состояния контейнера.
pct exec 204 -- docker commit euro-office euro-office-patched:local

# [Proxmox] Останавливаем и удаляем временный контейнер.
pct exec 204 -- docker stop euro-office
pct exec 204 -- docker rm euro-office

# [Proxmox] Запускаем финальный контейнер из патченого образа.
# --restart unless-stopped — автоматически стартует после перезагрузки LXC.
# --add-host — прописывает имена в /etc/hosts контейнера (при рестарте не сбрасываются).
#   Без этого контейнер не сможет резолвить nextcloud.lan / eurooffice.lan
#   и будет падать при попытке открыть документ.
pct exec 204 -- docker run -d --name euro-office \
  --restart unless-stopped \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=a928fb82f23ed6c536e67b8b5019f093af7b3a2bafda7618606798259cc65e35 \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  --add-host=nextcloud.lan:192.168.88.10 \
  --add-host=eurooffice.lan:192.168.88.10 \
  -v /opt/euro-office/logs:/var/log/onlyoffice \
  -v /opt/euro-office/data:/var/www/onlyoffice/Data \
  euro-office-patched:local
```

### 5.8 Проверка Euro-Office

```bash
# [Proxmox] Ждём ~30 секунд, затем смотрим логи.
# В норме: "docservice started" без ошибок DECODER.
pct exec 204 -- docker logs euro-office --tail=30

# [Proxmox] Healthcheck — должен вернуть {"status":"alive"}.
curl http://192.168.88.50/healthcheck

# [Proxmox] Проверяем WOPI Proof: ключ должен присутствовать в discovery XML.
# Ищем тег <proof-key>. Если пустой атрибут value="" — патч не применился.
curl -s http://192.168.88.50/hosting/discovery | grep -o 'proof-key[^/]*'
```

Если в discovery видно `value=""` или атрибуты пустые — перезапустите контейнер
(`docker restart euro-office`) и проверьте снова: entrypoint генерирует ключ при старте.

---

## Шаг 6. CT 200 — Nginx Reverse Proxy + TLS

```bash
# [Proxmox] Входим в контейнер.
pct exec 200 -- bash
```

```bash
# [CT 200] Обновляем систему и устанавливаем Nginx.
apt update && apt upgrade -y
apt install -y nginx

# [CT 200] Создаём директорию для сертификатов.
mkdir -p /etc/ssl/local

# [CT 200] Отключаем дефолтный сайт.
rm -f /etc/nginx/sites-enabled/default

# [CT 200] Выходим — нужно загрузить сертификаты с Windows.
exit
```

### 6.1 Загрузка TLS-сертификатов

```powershell
# [Win] Копируем сертификат и ключ на Proxmox.
scp -i "$env:USERPROFILE\.ssh\proxyid_ed25519" `
  "$env:USERPROFILE\Desktop\nextcloud.lan+1.pem" `
  root@192.168.88.144:/tmp/fullchain.pem

scp -i "$env:USERPROFILE\.ssh\proxyid_ed25519" `
  "$env:USERPROFILE\Desktop\nextcloud.lan+1-key.pem" `
  root@192.168.88.144:/tmp/privkey.pem
```

```bash
# [Proxmox] Загружаем в CT 200.
pct push 200 /tmp/fullchain.pem /etc/ssl/local/fullchain.pem
pct push 200 /tmp/privkey.pem   /etc/ssl/local/privkey.pem

# [Proxmox] Ограничиваем права на приватный ключ.
pct exec 200 -- chmod 640 /etc/ssl/local/privkey.pem
```

### 6.2 Конфигурация Nginx

```bash
# [Proxmox] Создаём конфиг proxy для обоих LAN-доменов.
pct exec 200 -- bash -c 'cat > /etc/nginx/sites-available/nextcloud << '"'"'EOF'"'"'
# HTTP → HTTPS редирект. listen [::]:80 — IPv6.
server {
    listen 80;
    listen [::]:80;
    server_name nextcloud.lan eurooffice.lan;
    return 301 https://$host$request_uri;
}

# ── Nextcloud ──────────────────────────────────────────────────────────────────
server {
    # listen 443 ssl http2; — единая директива для nginx 1.22 (Debian 12).
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
    # Паттерн /IP/c2s и /IP/s2c — стандартные пути Euro-Office WebSocket.
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
EOF'
```

```bash
# [Proxmox] Включаем сайт и перезапускаем Nginx.
pct exec 200 -- ln -s /etc/nginx/sites-available/nextcloud /etc/nginx/sites-enabled/nextcloud
pct exec 200 -- nginx -t     # syntax is ok
pct exec 200 -- systemctl enable nginx
pct exec 200 -- systemctl restart nginx
```

### 6.3 Доверие mkcert CA в CT 201 (для PHP-запросов к eurooffice.lan)

CT 201 (PHP) делает HTTPS-запросы к `eurooffice.lan` для получения discovery XML.
Без mkcert CA в системном хранилище эти запросы упадут.

```bash
# [Proxmox] Копируем CA в CT 201.
pct push 201 /tmp/mkcert-rootCA.pem /usr/local/share/ca-certificates/mkcert-local.crt
pct exec 201 -- update-ca-certificates
```

---

## Шаг 7. Пост-конфигурация Nextcloud

Все `occ`-команды выполняются на Proxmox через `pct exec 201`.

### 7.1 Системные параметры

```bash
# Сокращение для удобства.
OCC="pct exec 201 -- sudo -u www-data php /var/www/nextcloud/occ"

# [Proxmox] Добавляем доверенные домены/IP.
# Без этого Nextcloud отклонит запросы с "Access through untrusted domain".
# 0: основной домен, 1: IP proxy (CT 200), 2: IP app (CT 201), 3-4: localhost для CLI.
$OCC config:system:set trusted_domains 0 --value='nextcloud.lan'
$OCC config:system:set trusted_domains 1 --value='192.168.88.10'
$OCC config:system:set trusted_domains 2 --value='192.168.88.20'
$OCC config:system:set trusted_domains 3 --value='127.0.0.1'
$OCC config:system:set trusted_domains 4 --value='localhost'

# [Proxmox] Разрешаем CT 200 (proxy) передавать заголовки X-Forwarded-*.
# Без этого Nextcloud не будет доверять X-Forwarded-Proto: https и будет
# генерировать HTTP-ссылки даже при HTTPS-доступе.
$OCC config:system:set trusted_proxies 0 --value='192.168.88.10'

# [Proxmox] Указываем, какой заголовок содержит реальный IP клиента.
# Nginx proxy (CT 200) передаёт его через X-Forwarded-For.
# Без этого Nextcloud видит IP прокси вместо IP клиента (влияет на rate limiting, логи).
$OCC config:system:set forwarded_for_headers 0 --value='HTTP_X_FORWARDED_FOR'

# [Proxmox] Устанавливаем публичный URL (используется в ссылках email, WebDAV).
$OCC config:system:set overwrite.cli.url --value='https://nextcloud.lan'

# [Proxmox] Говорим Nextcloud: все URL должны быть HTTPS.
# ВАЖНО: устанавливайте ТОЛЬКО после того, как HTTPS уже работает.
# Если поставить раньше — Nextcloud начнёт генерировать HTTPS-ссылки,
# но Euro-Office ещё на HTTP, и WOPI-запросы упадут.
$OCC config:system:set overwriteprotocol --value='https'
```

### 7.2 Кэширование через Redis и APCu

```bash
# [Proxmox] Локальный кэш в памяти процесса PHP (ускоряет повторные запросы).
$OCC config:system:set memcache.local --value='\OC\Memcache\APCu'

# [Proxmox] Распределённый кэш через Redis (общий между процессами FPM).
$OCC config:system:set memcache.distributed --value='\OC\Memcache\Redis'

# [Proxmox] Блокировки файлов через Redis (предотвращает одновременное редактирование).
$OCC config:system:set memcache.locking --value='\OC\Memcache\Redis'

# [Proxmox] Параметры подключения к Redis.
$OCC config:system:set redis host     --value='192.168.88.40'
$OCC config:system:set redis port     --value=6379 --type=integer
$OCC config:system:set redis password --value='nc_redis_pass_2026'
$OCC config:system:set redis timeout  --value=1.5  --type=float
```

### 7.3 Установка и настройка Nextcloud Office (richdocuments)

```bash
# [Proxmox] Устанавливаем приложение richdocuments (Nextcloud Office / WOPI-клиент).
$OCC app:install richdocuments
```

```bash
# [Proxmox] wopi_url: URL, по которому PHP (CT 201) обращается к Euro-Office
# для получения discovery XML и WOPI actions. Используется серверно (не браузером).
$OCC config:app:set richdocuments wopi_url --value='https://eurooffice.lan/'

# [Proxmox] collabora_url: внутренний алиас для wopi_url в некоторых версиях richdocuments.
$OCC config:app:set richdocuments collabora_url --value='https://eurooffice.lan/'

# [Proxmox] public_wopi_url: URL, откуда БРАУЗЕР загружает редактор Euro-Office.
$OCC config:app:set richdocuments public_wopi_url --value='https://eurooffice.lan'

# [Proxmox] Отключаем проверку TLS-сертификата при запросах PHP → Euro-Office.
# mkcert CA добавлен в CT 201, но для надёжности оставляем 'yes'.
# При Let's Encrypt можно убрать (поставить 'no').
$OCC config:app:set richdocuments disable_certificate_verification --value='yes'

# [Proxmox] Разрешаем WOPI-запросы только с IP Euro-Office (192.168.88.50).
# Без allowlist Nextcloud отклонит запросы как подозрительные.
# Указываем конкретный IP Euro-Office, а не широкую подсеть — минимум необходимых прав.
$OCC config:app:set richdocuments wopi_allowlist --value='192.168.88.50'

# [Proxmox] Включаем WOPI Proof: Euro-Office подписывает запросы RSA-ключом,
# Nextcloud верифицирует подпись. Требует корректного entrypoint.sh (шаг 5.4).
$OCC config:app:set richdocuments disable_wopi_proof --value='no'
```

### 7.4 activate-config и восстановление wopi_callback_url

> **Ловушка:** `occ richdocuments:activate-config` сбрасывает `wopi_callback_url` в пустую строку.
> Нужно **немедленно** восстановить его после каждого вызова этой команды.

```bash
# [Proxmox] Обновляем discovery-кэш (загружает ключи WOPI Proof от Euro-Office).
$OCC richdocuments:activate-config 2>/dev/null || true

# [Proxmox] НЕМЕДЛЕННО восстанавливаем wopi_callback_url.
# Это URL, с которого Euro-Office делает WOPI-запросы (GetFile, PutFile) к Nextcloud.
#
# КРИТИЧЕСКИ ВАЖНО: значение ДОЛЖНО совпадать с overwrite.cli.url (https://nextcloud.lan).
# Nextcloud генерирует ожидаемый URL для проверки WOPI Proof через urlGenerator,
# который учитывает overwriteprotocol и overwrite.cli.url.
# Если Euro-Office подписывает URL http://192.168.88.20:8080/..., а Nextcloud
# ожидает https://nextcloud.lan/... — подписи не совпадут → HTTP 500.
$OCC config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'
```

### 7.5 Сброс Redis-кэша

```bash
# [Proxmox] Redis кэширует discovery XML от Euro-Office (WOPI endpoints, proof-key).
# После изменения конфига Euro-Office или richdocuments нужно сбросить кэш,
# иначе Nextcloud будет использовать устаревшие данные.
pct exec 203 -- redis-cli -a nc_redis_pass_2026 FLUSHALL
```

### 7.6 Патч richdocuments: WOPI Proof для конвертера и fclose

> **Проблема 1 — Новые файлы не открываются ("Загрузка не удалась"):**
> Euro-Office converter делает WOPI-запросы к `/wopi/template/NNN` БЕЗ заголовков
> `X-WOPI-Proof` / `X-WOPI-ProofOld`. `WOPIMiddleware.php` видит пустой `X-WOPI-TimeStamp`,
> преобразует `(int)'' = 0` в `.NET timestamp` → год ~1 н.э. → "старше 20 минут" → HTTP 500.
>
> Симптом в логах converter: `downloadFile:url=.../wopi/template/NNN;code:ERR_BAD_RESPONSE`
>
> **Проблема 2 — PHP warning в `/var/nc-data/nextcloud.log`:**
> `fclose(): supplied resource is not a valid stream resource in RemoteService.php line 73`
> Guzzle закрывает stream после отправки, `finally` блок пытается закрыть его ещё раз.

```bash
# [Proxmox] Патч 1: пропускаем проверку WOPI Proof если клиент не прислал заголовки.
# WOPIMiddleware.php, строка ~89: if ($hasProofKey) → if ($hasProofKey && $wopiProof)
pct exec 201 -- sed -i \
  's/if (\$hasProofKey) {/if (\$hasProofKey \&\& \$wopiProof) {/' \
  /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php

# [Proxmox] Патч 2: guard против double-fclose в RemoteService.php.
pct exec 201 -- sed -i \
  's/\t\t\tfclose(\$stream);/\t\t\tif (is_resource(\$stream)) { fclose(\$stream); }/' \
  /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php

# [Proxmox] Перезагружаем PHP-FPM для применения обоих патчей.
pct exec 201 -- systemctl reload php8.3-fpm
```

> **Почему `disable_wopi_proof` не помогает:** этот конфиг в текущей версии richdocuments
> является мёртвым кодом — нигде не читается. WOPI Proof контролируется только через
> `$this->discoveryService->hasProofKey()` (наличием ключа в discovery XML).

---

## Шаг 8. Финальная проверка

### 8.1 Проверка сервисов

```bash
# [Proxmox] PostgreSQL (CT 202) — должен быть active.
pct exec 202 -- systemctl status postgresql --no-pager

# [Proxmox] Redis (CT 203) — должен отвечать PONG.
pct exec 203 -- redis-cli -a nc_redis_pass_2026 PING

# [Proxmox] Nextcloud PHP-FPM и Nginx (CT 201).
pct exec 201 -- systemctl status php8.3-fpm nginx --no-pager

# [Proxmox] Euro-Office (CT 204) — healthcheck.
pct exec 204 -- curl -s http://192.168.88.50/healthcheck

# [Proxmox] Nginx proxy (CT 200).
pct exec 200 -- systemctl status nginx --no-pager

# [Proxmox] Проверяем WOPI Proof — наличие непустого proof-key в discovery.
pct exec 204 -- curl -s http://192.168.88.50/hosting/discovery | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
pk = root.find('.//{*}proof-key')
if pk is None: print('ERROR: no proof-key element')
elif not pk.get('value'): print('ERROR: proof-key value is empty — patch not applied')
else: print('OK: proof-key present, length', len(pk.get('value')))
"
```

### 8.2 Проверка в браузере

1. Откройте `https://nextcloud.lan` в браузере (на машине с mkcert CA)
2. Войдите: `admin` / `changeme2026!`
3. Загрузите тестовый `.docx` файл через кнопку "+" → "Загрузить файл"
4. Кликните по файлу — должен открыться редактор Euro-Office в браузере
5. Внесите изменения, закройте вкладку — файл должен сохраниться

### 8.3 Диагностика при проблемах

```bash
# [Proxmox] Логи docservice (основной WOPI-процесс).
pct exec 204 -- docker exec euro-office \
  tail -50 /var/log/euro-office/documentserver/docservice/out.log

# [Proxmox] Логи converter (конвертация файлов).
pct exec 204 -- docker exec euro-office \
  tail -50 /var/log/euro-office/documentserver/converter/out.log

# [Proxmox] Логи Nextcloud (WOPI-ошибки PHP).
pct exec 201 -- tail -30 /var/nc-data/nextcloud.log
```

---

## Повторное применение патча (после пересоздания контейнера)

Если Euro-Office контейнер был удалён и пересоздан из оригинального образа
(не из `euro-office-patched:local`) — патч нужно применить заново.
Порядок: шаг 5.3 → 5.4 → 5.5 → 5.6 → `docker restart euro-office`.

Флаг `--add-host` должен присутствовать в команде `docker run` — без него
после каждого рестарта потеряются имена `nextcloud.lan` / `eurooffice.lan`.

---

## Справочник: частые команды после развёртывания

```bash
# Перезапуск Euro-Office (без пересоздания контейнера).
pct exec 204 -- docker restart euro-office

# Сброс Redis-кэша (после изменений в richdocuments или Euro-Office).
pct exec 203 -- redis-cli -a nc_redis_pass_2026 FLUSHALL

# occ-команды (запуск от www-data — обязательно).
pct exec 201 -- sudo -u www-data php /var/www/nextcloud/occ <команда>

# Восстановление wopi_callback_url (после каждого activate-config).
pct exec 201 -- sudo -u www-data php /var/www/nextcloud/occ \
  config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'

# Логи Euro-Office.
pct exec 204 -- docker logs euro-office --tail=30
pct exec 204 -- docker exec euro-office \
  tail -50 /var/log/euro-office/documentserver/docservice/out.log

# Логи Nextcloud.
pct exec 201 -- tail -30 /var/nc-data/nextcloud.log
```
