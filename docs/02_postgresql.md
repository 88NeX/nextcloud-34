# 02 — PostgreSQL 16 (контейнер nc-db, 192.168.88.30)

```bash
pct exec 202 -- bash
```

## 1. Установка PostgreSQL 16

```bash
curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | gpg --dearmor -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] \
  https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list

apt-get update
apt-get install -y postgresql-16 postgresql-client-16
```

## 2. Конфигурация PostgreSQL

```bash
# /etc/postgresql/16/main/postgresql.conf — ключевые параметры
cat >> /etc/postgresql/16/main/postgresql.conf << 'EOF'

# Nextcloud tuning
listen_addresses = '192.168.88.30'
max_connections = 100
shared_buffers = 256MB
effective_cache_size = 512MB
work_mem = 8MB
maintenance_work_mem = 64MB
wal_buffers = 16MB
checkpoint_completion_target = 0.9
random_page_cost = 1.1
effective_io_concurrency = 200

# Logging
log_min_duration_statement = 1000
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
EOF
```

```bash
# /etc/postgresql/16/main/pg_hba.conf — разрешить подключение с nc-app
echo "host nextcloud nextcloud 192.168.88.20/32 scram-sha-256" \
  >> /etc/postgresql/16/main/pg_hba.conf
```

## 3. Создание БД и пользователя

```bash
systemctl restart postgresql

sudo -u postgres psql << 'EOF'
CREATE USER nextcloud WITH PASSWORD 'CHANGE_ME_DB_PASS' LOGIN;
CREATE DATABASE nextcloud
    OWNER nextcloud
    ENCODING 'UTF8'
    LC_COLLATE 'en_US.UTF-8'
    LC_CTYPE 'en_US.UTF-8'
    TEMPLATE template0;
GRANT ALL PRIVILEGES ON DATABASE nextcloud TO nextcloud;
\c nextcloud
GRANT ALL ON SCHEMA public TO nextcloud;
EOF
```

## 4. Проверка доступности с nc-app

```bash
# выполнять с nc-app (192.168.88.20)
apt-get install -y postgresql-client-16
psql -h 192.168.88.30 -U nextcloud -d nextcloud -c '\conninfo'
```

## 5. Настройка автозапуска

```bash
systemctl enable postgresql
```
