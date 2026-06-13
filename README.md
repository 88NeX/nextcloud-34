# Nextcloud 34 + Euro-Office DocumentServer

Развёртывание Nextcloud 34 с редактором документов Euro-Office (форк ONLYOFFICE) через протокол WOPI (приложение Nextcloud Office / richdocuments). Инфраструктура: 5 LXC-контейнеров на Proxmox 8.x, TLS через mkcert + Mikrotik DNS.

---

## Архитектура

```
Браузер
  │
  ├── https://nextcloud.lan ──► CT 200  nc-proxy   192.168.88.10  Nginx (TLS-терминация)
  │                                          │
  │                                          ├── :8080 ──► CT 201  nc-app    192.168.88.20  PHP 8.3 + Nginx
  │                                          │                 │
  │                                          │                 ├── :5432 ──► CT 202  nc-db     192.168.88.30  PostgreSQL 16
  │                                          │                 └── :6379 ──► CT 203  nc-cache  192.168.88.40  Redis 7
  │
  └── https://eurooffice.lan ─► CT 200  nc-proxy
                                         │
                                         └── :80 ──► CT 204  nc-office  192.168.88.50  Euro-Office (Docker)

WOPI: Euro-Office ──GET/PUT──► https://nextcloud.lan/index.php/apps/richdocuments/wopi/...
```

| CT  | Имя       | IP              | Сервис                                    |
|-----|-----------|-----------------|-------------------------------------------|
| 200 | nc-proxy  | 192.168.88.10   | Nginx reverse proxy + TLS (mkcert)        |
| 201 | nc-app    | 192.168.88.20   | PHP 8.3 + Nextcloud 34 + Nginx (8080)     |
| 202 | nc-db     | 192.168.88.30   | PostgreSQL 16                             |
| 203 | nc-cache  | 192.168.88.40   | Redis 7                                   |
| 204 | nc-office | 192.168.88.50   | Euro-Office DocumentServer (Docker)       |

**Proxmox хост:** `192.168.88.144` · root · ключ `~/.ssh/proxyid_ed25519`

---

## Быстрый старт (Proxmox LXC)

Подробные пошаговые инструкции — в [DEPLOY.md](DEPLOY.md). Ниже — минимум для ориентации.

### 1. Переменные окружения

```bash
cp .env.example .env
# отредактируйте .env — пароли, JWT-секрет, IP-адреса
```

Обязательно сменить: `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `NEXTCLOUD_ADMIN_PASSWORD`, `JWT_SECRET`.  
Для `JWT_SECRET` используйте: `openssl rand -hex 32`

### 2. Сборка и запуск Euro-Office с patched entrypoint.sh

Два варианта доставки патча — подробно в [EURO_OFFICE_WOPI.md §3.3](EURO_OFFICE_WOPI.md#33-как-доставить-patched-entrypointsh-в-контейнер).

**Вариант 1 (рекомендуется): Dockerfile — патч зашит в образ**

```bash
# Копируем на Proxmox
scp -i ~/.ssh/proxyid_ed25519 euro-office/entrypoint.sh root@192.168.88.144:/tmp/entrypoint.sh
scp -i ~/.ssh/proxyid_ed25519 euro-office/Dockerfile    root@192.168.88.144:/tmp/Dockerfile

# Доставляем в CT 204 и собираем образ
pct push 204 /tmp/entrypoint.sh /tmp/build/entrypoint.sh
pct push 204 /tmp/Dockerfile    /tmp/build/Dockerfile
pct exec 204 -- docker build -t euro-office-patched:local /tmp/build/
```

**Вариант 2: volume mount — патч без пересборки образа**

```bash
# Доставляем entrypoint.sh и docker-compose.yml в CT 204
scp -i ~/.ssh/proxyid_ed25519 euro-office/entrypoint.sh root@192.168.88.144:/tmp/entrypoint.sh
scp -i ~/.ssh/proxyid_ed25519 docker-compose.yml        root@192.168.88.144:/tmp/docker-compose.yml

pct push 204 /tmp/entrypoint.sh    /opt/euro-office/entrypoint.sh
pct push 204 /tmp/docker-compose.yml /opt/euro-office/docker-compose.yml

# Запуск (entrypoint монтируется под другим именем — иначе Docker снимает execute bit)
pct exec 204 -- bash -c "cd /opt/euro-office && docker compose up -d"
```

Соответствующий блок в `docker-compose.yml`:
```yaml
entrypoint: ["/entrypoint-patched.sh"]
volumes:
  - ./entrypoint.sh:/entrypoint-patched.sh:ro
```

### 3. Запуск Euro-Office

```bash
pct exec 204 -- docker run -d --name euro-office --restart unless-stopped \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=<JWT_SECRET из .env> \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  --add-host=nextcloud.lan:192.168.88.10 \
  --add-host=eurooffice.lan:192.168.88.10 \
  -v /opt/euro-office/logs:/var/log/euro-office \
  -v /opt/euro-office/data:/var/www/euro-office/Data \
  euro-office-patched:local
```

### 4. Конфигурация Nextcloud (occ)

```bash
pct exec 201 -- bash
alias occ='sudo -u www-data php /var/www/nextcloud/occ'

occ app:install richdocuments
occ config:app:set richdocuments wopi_url                         --value='https://eurooffice.lan/'
occ config:app:set richdocuments collabora_url                    --value='https://eurooffice.lan/'
occ config:app:set richdocuments public_wopi_url                  --value='https://eurooffice.lan'
occ config:app:set richdocuments disable_certificate_verification --value='yes'
occ config:app:set richdocuments wopi_allowlist                   --value='192.168.88.50'
occ richdocuments:activate-config

# ОБЯЗАТЕЛЬНО после activate-config — команда сбрасывает этот параметр
occ config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'
```

### 5. Применить патчи richdocuments (один раз)

```bash
# WOPIMiddleware.php — пропускать запросы Euro-Office converter без proof-заголовков
sed -i \
  's/if (\$hasProofKey) {/if (\$hasProofKey \&\& \$wopiProof) {/' \
  /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php

# RemoteService.php — защита от двойного fclose
sed -i \
  's/\t\t\tfclose(\$stream);/\t\t\tif (is_resource(\$stream)) { fclose(\$stream); }/' \
  /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php

systemctl reload php8.3-fpm
```

### 6. Проверка

- Войти в Nextcloud: `https://nextcloud.lan`
- Загрузить `.docx` / `.xlsx` → кликнуть → должен открыться редактор Euro-Office
- Создать «Новую презентацию» → открыть → не «Загрузка не удалась»
- Euro-Office healthcheck: `http://192.168.88.50/healthcheck`

---

## Настройки

### config.php (ключевые параметры)

```php
'overwrite.cli.url'  => 'https://nextcloud.lan',
'overwriteprotocol'  => 'https',
'trusted_domains'    => ['nextcloud.lan', '192.168.88.20', '192.168.88.10', '127.0.0.1', 'localhost'],
'trusted_proxies'    => ['192.168.88.10'],
```

### richdocuments

| Параметр | Значение |
|----------|----------|
| `wopi_url` | `https://eurooffice.lan/` |
| `collabora_url` | `https://eurooffice.lan/` |
| `public_wopi_url` | `https://eurooffice.lan` |
| `disable_certificate_verification` | `yes` (для mkcert) |
| `wopi_allowlist` | `192.168.88.50` |
| `wopi_callback_url` | `https://nextcloud.lan` |

> **`wopi_callback_url` обязан совпадать с `overwrite.cli.url`** — иначе WOPI Proof validation → HTTP 500.

### Euro-Office (переменные Docker)

| Переменная | Значение |
|-----------|---------|
| `JWT_ENABLED` | `true` |
| `JWT_SECRET` | hex-строка 64 символа |
| `JWT_HEADER` | `AuthorizationJwt` |
| `WOPI_ENABLED` | `true` |

Volumes: `/opt/euro-office/logs` → `/var/log/euro-office`, `/opt/euro-office/data` → `/var/www/euro-office/Data`

---

## Структура репозитория

```
.env.example                 — шаблон переменных окружения
docker-compose.yml           — reference-стек (не используется в LXC)
euro-office/
  entrypoint.sh              — patched entrypoint: PKCS#1, реальные newlines, миграция ключа
  Dockerfile                 — COPY entrypoint + NODE_TLS_REJECT_UNAUTHORIZED=0 в supervisord
config/
  nginx-nextcloud.conf       — nginx конфиг для CT 201 (nc-app)
  nginx-proxy.conf           — nginx конфиг для CT 200 (nc-proxy, HTTP)
  nginx-proxy-tls.conf       — nginx конфиг для CT 200 (nc-proxy, HTTPS/mkcert)
  php-extra.ini              — php.ini overrides
scripts/
  nextcloud-configure.sh     — пост-установочная конфигурация occ
docs/
  00_overview.md             — архитектура, порядок развёртывания
  01_proxmox_lxc.md          — создание LXC-контейнеров
  02_postgresql.md           — PostgreSQL 16
  03_redis.md                — Redis 7
  04_nextcloud.md            — установка Nextcloud
  05_collabora.md            — Euro-Office Docker + WOPI
  06_nginx.md                — nginx CT 200 (reverse proxy + TLS)
  07_nextcloud_config.md     — финальная конфигурация occ
  08_security_hardening.md   — hardening
DEPLOY.md                    — пошаговое развёртывание: Proxmox LXC
DEPLOY_UBUNTU.md             — пошаговое развёртывание: Ubuntu VM
EURO_OFFICE_WOPI.md          — полное руководство по интеграции Euro-Office + WOPI
```

---

## Известные ловушки

| Симптом | Причина | Решение |
|---------|---------|---------|
| «Загрузка не удалась» для новых файлов | Euro-Office converter не шлёт WOPI Proof заголовки | Патч `WOPIMiddleware.php`: `if ($hasProofKey && $wopiProof)` |
| `DECODER routines::unsupported` | Ключ в PKCS#8 или literal `\n` в PEM | `genrsa -traditional` + `cat` в `entrypoint.sh` |
| HTTP 500 «invalid proof keys» | `wopi_callback_url ≠ overwrite.cli.url` | Восстановить `wopi_callback_url` после `activate-config` |
| `wopi_callback_url` пустой | `occ richdocuments:activate-config` сбрасывает его | Всегда восстанавливать вручную сразу после |
| `.well-known` setupcheck красный | nginx `return 301 /path` на порту 8080 строит `http://...:8080/...` | `rewrite ^ /index.php$request_uri last` |

Подробная диагностика и все варианты решений — [EURO_OFFICE_WOPI.md](EURO_OFFICE_WOPI.md).

---

## Полезные команды

```bash
# occ (Nextcloud CLI)
pct exec 201 -- sudo -u www-data php /var/www/nextcloud/occ <команда>

# Логи Euro-Office
pct exec 204 -- docker exec euro-office bash -c \
  'tail -50 /var/log/euro-office/documentserver/docservice/out.log'
pct exec 204 -- docker exec euro-office bash -c \
  'tail -50 /var/log/euro-office/documentserver/converter/out.log'

# Redis flush (после изменений в Euro-Office или richdocuments)
pct exec 203 -- redis-cli -a nc_redis_pass_2026 FLUSHALL

# Пересборка Euro-Office
pct exec 204 -- docker build -t euro-office-patched:local /tmp/build/

# Перезапуск сервисов Euro-Office без пересоздания контейнера
pct exec 204 -- docker exec euro-office supervisorctl restart docservice converter
```
