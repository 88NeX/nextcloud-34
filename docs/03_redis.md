# 03 — Redis 7 (контейнер nc-cache, 192.168.88.40)

> **Почему Redis, а не Valkey:** репозиторий `packages.valkey.io` оказался недоступен
> в момент развёртывания. Redis 7 из стандартного репозитория Debian Bookworm полностью
> совместим с Nextcloud и не требует дополнительных источников пакетов.

```bash
pct exec 203 -- bash
```

## 1. Установка Redis 7

```bash
apt-get update
apt-get install -y redis-server
```

## 2. Конфигурация /etc/redis/redis.conf

```bash
# Основные параметры — дописываем / заменяем в конфиге
cat >> /etc/redis/redis.conf << 'EOF'

# Сеть — слушать только внутренний интерфейс (не 127.0.0.1 — он недоступен с nc-app)
bind 127.0.0.1 192.168.88.40
protected-mode yes
port 6379

# Аутентификация
requirepass CHANGE_ME_REDIS_PASS

# Память — лимит и политика вытеснения для кэша
maxmemory 256mb
maxmemory-policy allkeys-lru

# Персистентность — для кэша сессий AOF достаточно
save ""
appendonly yes
appendfsync everysec
no-appendfsync-on-rewrite yes

# Логирование
loglevel notice
logfile /var/log/redis/redis-server.log

# Таймаут соединений
timeout 300
tcp-keepalive 60
EOF
```

## 3. Системные параметры ядра

```bash
# Отключить Transparent HugePage — обязательно для Redis
# Выполнять на ХОСТЕ Proxmox (LXC делит ядро с хостом)
echo never > /sys/kernel/mm/transparent_hugepage/enabled

# Сохранить после перезагрузки — добавить в /etc/rc.local на хосте
echo 'echo never > /sys/kernel/mm/transparent_hugepage/enabled' \
  >> /etc/rc.local

# overcommit_memory
echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
sysctl -p
```

## 4. Запуск и автозапуск

```bash
systemctl enable redis-server
systemctl restart redis-server

# Проверка
redis-cli -h 192.168.88.40 -a 'CHANGE_ME_REDIS_PASS' PING
# Ожидаемый ответ: PONG
```

## 5. Проверка подключения с nc-app

```bash
# На nc-app (CT 201)
redis-cli -h 192.168.88.40 -p 6379 -a 'CHANGE_ME_REDIS_PASS' PING
```

## Использование в Nextcloud

Nextcloud использует Redis для двух целей:

| Назначение | Nextcloud параметр |
|-----------|-------------------|
| Distributed cache | `memcache.distributed` = `\OC\Memcache\Redis` |
| File locking | `memcache.locking` = `\OC\Memcache\Redis` |

Конфигурация в `config.php` — см. [07_nextcloud_config.md](07_nextcloud_config.md).

Euro-Office DocumentServer также поднимает **внутренний** Redis внутри Docker-контейнера.
Он отдельный от nc-cache — Euro-Office в nc-cache не обращается.
