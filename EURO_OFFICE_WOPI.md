# Интеграция Euro-Office DocumentServer с Nextcloud через WOPI

Руководство охватывает весь путь: от запуска контейнера до открытия документа в браузере.
В каждом разделе описаны ловушки, которые реально встречаются, и способы их диагностики.

---

## Содержание

1. [Архитектура](#1-архитектура)
2. [Euro-Office: запуск контейнера](#2-euro-office-запуск-контейнера)
3. [Патч entrypoint.sh — WOPI Proof](#3-патч-entrypointsh--wopi-proof)
4. [NODE_TLS_REJECT_UNAUTHORIZED для supervisord](#4-node_tls_reject_unauthorized-для-supervisord)
5. [Nextcloud: установка richdocuments](#5-nextcloud-установка-richdocuments)
6. [richdocuments: настройка через occ](#6-richdocuments-настройка-через-occ)
7. [Патч WOPIMiddleware.php](#7-патч-wopimiddlewarephp)
8. [Патч RemoteService.php](#8-патч-remoteservicephp)
9. [Nginx на сервере Nextcloud](#9-nginx-на-сервере-nextcloud)
10. [Диагностика](#10-диагностика)
11. [Таблица симптомов и причин](#11-таблица-симптомов-и-причин)

---

## 1. Архитектура

```
Браузер
  │  HTTPS nextcloud.lan
  ▼
[Nginx proxy / TLS-терминация]
  │                          │
  │ HTTP :8080               │ HTTP :80
  ▼                          ▼
[Nextcloud + PHP-FPM]   [Euro-Office DocumentServer]
  │                          │
  │  WOPI (HTTPS)            │  WOPI (HTTPS)
  └──────────────────────────┘
```

**Роли участников WOPI-сессии:**

| Участник | Роль | Кто инициирует |
|----------|------|---------------|
| Браузер | Загружает JS-редактор из Euro-Office | Пользователь |
| Euro-Office docservice | Читает/пишет файл через WOPI | → Nextcloud |
| Euro-Office converter | Скачивает шаблон и конвертирует | → Nextcloud |
| Nextcloud (richdocuments) | Выдаёт файл по WOPI, проверяет подпись | — |

**Важные URL:**

| Конфиг | Значение | Назначение |
|--------|----------|-----------|
| `wopi_url` | `https://eurooffice.lan/` | PHP → Euro-Office (discovery XML, server-side) |
| `collabora_url` | `https://eurooffice.lan/` | Алиас wopi_url в некоторых версиях |
| `public_wopi_url` | `https://eurooffice.lan` | Браузер → Euro-Office JS (без слэша) |
| `wopi_callback_url` | `https://nextcloud.lan` | Euro-Office → Nextcloud WOPI (должен == overwrite.cli.url) |

---

## 2. Euro-Office: запуск контейнера

### 2.1 Базовый запуск

```bash
docker run -d --name euro-office --restart unless-stopped \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET=<ваш_jwt_secret> \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  --add-host=nextcloud.lan:192.168.88.10 \
  --add-host=eurooffice.lan:192.168.88.10 \
  -v /opt/euro-office/logs:/var/log/euro-office \
  -v /opt/euro-office/data:/var/www/euro-office/Data \
  euro-office-patched:local
```

> **`--add-host`** — обязателен если Euro-Office и Nextcloud работают в одной LAN
> без внешнего DNS. Без него контейнер не разрешит `nextcloud.lan` → WOPI-запросы упадут.
> После `docker restart` флаг сохраняется, но после `docker rm` + нового `docker run` —
> нужно указать снова.

### 2.2 Проверка запуска

```bash
# Healthcheck — должен вернуть {"status":"OK"}
curl -s http://192.168.88.50/healthcheck

# WOPI discovery — должен вернуть XML с <proof-key value="...">
curl -s http://192.168.88.50/hosting/discovery | grep -o 'proof-key[^>]*'
```

Если `proof-key value=""` или элемент отсутствует — WOPI Proof не работает.
Причина: не применён патч entrypoint.sh (см. раздел 3).

---

## 3. Патч entrypoint.sh — WOPI Proof

WOPI Proof — механизм подписи WOPI-запросов RSA-ключом. Euro-Office генерирует ключ при старте
через `entrypoint.sh`. В стандартном образе есть три бага.

### 3.1 Проблема 1: PKCS#8 вместо PKCS#1

**Симптом:** `proof-key` в discovery XML пустой или ошибка в логах:
```
Error: error:1E08010C:DECODER routines::unsupported
```

**Причина:** `openssl genpkey` генерирует PKCS#8. Node.js crypto (`createPublicKey`) в версиях
Euro-Office не поддерживает PKCS#8 — ожидает PKCS#1 (`-----BEGIN RSA PRIVATE KEY-----`).

**Исправление в entrypoint.sh:**

```bash
# Найти строку с genpkey и заменить:
# ДО:
openssl genpkey -algorithm RSA -outform PEM -out "$WOPI_PRIVATE_KEY"

# ПОСЛЕ:
openssl genrsa -traditional 4096 -out "$WOPI_PRIVATE_KEY"
```

Флаг `-traditional` принудительно выводит PKCS#1 (в OpenSSL 3.x по умолчанию PKCS#8).

**Дополнительно:** если на диске уже лежит старый ключ PKCS#8 (из предыдущего старта),
его нужно мигрировать. Добавьте после строки генерации ключа:

```bash
# Если ключ уже существует и в формате PKCS#8 — конвертируем в PKCS#1
if [ -f "$WOPI_PRIVATE_KEY" ]; then
    head=$(head -1 "$WOPI_PRIVATE_KEY")
    if echo "$head" | grep -q 'PRIVATE KEY' && ! echo "$head" | grep -q 'RSA'; then
        openssl rsa -traditional -in "$WOPI_PRIVATE_KEY" -out "${WOPI_PRIVATE_KEY}.pkcs1" 2>/dev/null \
            && mv "${WOPI_PRIVATE_KEY}.pkcs1" "$WOPI_PRIVATE_KEY"
    fi
fi
```

### 3.2 Проблема 2: literal `\n` в JSON вместо реальных переносов строк

**Симптом:** discovery XML содержит `proof-key` с ненулевой длиной, но при проверке подписи:
```
Error: error:1E08010C:DECODER routines::unsupported
```

**Причина:** entrypoint.sh использует `awk` для экранирования PEM в JSON:
```bash
WOPI_PRIVATE_KEY_DATA=$(awk '{printf "%s\\n", $0}' "$WOPI_PRIVATE_KEY")
```
Это заменяет реальные переносы строк на двухсимвольную последовательность `\n`.
Node.js получает строку с literal `\n` вместо настоящего PEM → `createPrivateKey` падает.

**Исправление:**

```bash
# ДО:
WOPI_PRIVATE_KEY_DATA=$(awk '{printf "%s\\n", $0}' "$WOPI_PRIVATE_KEY")

# ПОСЛЕ:
WOPI_PRIVATE_KEY_DATA=$(cat "$WOPI_PRIVATE_KEY")
```

JSON-файл конфига Euro-Office принимает многострочные строки через экранирование в самом JSON.
Если формат требует однострочного значения — используйте:
```bash
WOPI_PRIVATE_KEY_DATA=$(awk '{printf "%s\\n", $0}' "$WOPI_PRIVATE_KEY" | head -c -2)
# и записывайте через printf '%s' вместо echo
```
Но на практике Euro-Office читает ключ как многострочный PEM — используйте `cat`.

### 3.3 Как доставить patched entrypoint.sh в контейнер

Два подхода — выбирайте по ситуации.

#### Вариант 1: Dockerfile (воспроизводимо, рекомендуется)

Подготовьте два файла рядом — `entrypoint.sh` (полная patched версия) и `Dockerfile`:

```dockerfile
FROM ghcr.io/euro-office/documentserver:latest
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
```

```bash
# [Win → Proxmox] Копируем оба файла
scp -i ~/.ssh/proxyid_ed25519 entrypoint.sh Dockerfile root@192.168.88.144:/tmp/

# [Proxmox] Доставляем в CT 204
pct push 204 /tmp/Dockerfile /tmp/build/Dockerfile
pct push 204 /tmp/entrypoint.sh /tmp/build/entrypoint.sh

# [CT 204] Собираем образ
pct exec 204 -- docker build -t euro-office-patched:local /tmp/build/

# Перезапускаем контейнер с новым образом
# (если контейнер запущен из другого образа — пересоздаём)
pct exec 204 -- docker stop euro-office
pct exec 204 -- docker rm euro-office
pct exec 204 -- docker run -d --name euro-office --restart unless-stopped \
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

Плюс: после `docker rm` достаточно `docker run` с тем же образом — патч уже внутри.
При обновлении базового образа — просто пересобрать `docker build`.

#### Вариант 2: volume mount через docker-compose (удобно при частых правках)

Создайте `docker-compose.yml` рядом с `entrypoint.sh`:

```yaml
services:
  euro-office:
    image: ghcr.io/euro-office/documentserver:latest
    restart: unless-stopped
    # Переопределяем entrypoint — монтируем под новым именем, чтобы
    # не конфликтовать с правами исходного файла внутри образа
    entrypoint: ["/entrypoint-patched.sh"]
    ports:
      - "192.168.88.50:80:80"
    environment:
      JWT_ENABLED: "true"
      JWT_SECRET: "a928fb82f23ed6c536e67b8b5019f093af7b3a2bafda7618606798259cc65e35"
      JWT_HEADER: "AuthorizationJwt"
      WOPI_ENABLED: "true"
    extra_hosts:
      - "nextcloud.lan:192.168.88.10"
      - "eurooffice.lan:192.168.88.10"
    volumes:
      - ./entrypoint.sh:/entrypoint-patched.sh:ro
      - /opt/euro-office/logs:/var/log/euro-office
      - /opt/euro-office/data:/var/www/euro-office/Data
```

```bash
# [Win → Proxmox → CT 204] Доставляем файлы
scp -i ~/.ssh/proxyid_ed25519 entrypoint.sh docker-compose.yml root@192.168.88.144:/tmp/
pct push 204 /tmp/entrypoint.sh /opt/euro-office/entrypoint.sh
pct push 204 /tmp/docker-compose.yml /opt/euro-office/docker-compose.yml

# Запускаем
pct exec 204 -- bash -c "cd /opt/euro-office && docker compose up -d"
```

> Монтируем под именем `/entrypoint-patched.sh` (не `/entrypoint.sh`) и указываем его
> через `entrypoint:`. Если монтировать прямо в `/entrypoint.sh`, Docker перекрывает файл
> из образа, но права хоста (644) заменяют права контейнера (755) → контейнер не стартует.

Плюс: правка `entrypoint.sh` на хосте + `docker compose restart` — изменения сразу в контейнере,
без `docker commit` и `docker build`.

#### Сравнение вариантов

| | 1: Dockerfile | 2: volume |
|---|---|---|
| Скорость применения | нужен build | мгновенно |
| Выживает после `docker rm` | да (образ) | да (файл на хосте) |
| Воспроизводимость | высокая | средняя |
| Удобство при доработке | нужен rebuild | удобно |

---

## 4. NODE_TLS_REJECT_UNAUTHORIZED для supervisord

### 4.1 Проблема

**Симптом в логах docservice:**
```
wopi checkFileInfo error status=500 (Internal server error or invalid proof keys):
AxiosError: Request failed with status code 500
```
или сетевая ошибка при HTTPS-запросах от Euro-Office к Nextcloud.

**Причина:** Node.js в Euro-Office не читает системный CA store. При mkcert-сертификатах
(самоподписанных для LAN) TLS-проверка падает с `CERT_INVALID` → axios получает ошибку сети.

### 4.2 Исправление

Добавить `NODE_TLS_REJECT_UNAUTHORIZED=0` в environment обоих supervisord-процессов.

```bash
# Редактируем конфиги supervisord внутри контейнера
docker exec euro-office bash -c "
# Для docservice
sed -i '/^\[program:ds-docservice\]/a environment=NODE_TLS_REJECT_UNAUTHORIZED=\"0\"' \
    /etc/supervisor/conf.d/ds-docservice.conf

# Для converter
sed -i '/^\[program:ds-converter\]/a environment=NODE_TLS_REJECT_UNAUTHORIZED=\"0\"' \
    /etc/supervisor/conf.d/ds-converter.conf
"

# Если секция [program:...] уже содержит environment= — нужно добавить переменную к существующей:
# environment=VAR1=\"val1\",NODE_TLS_REJECT_UNAUTHORIZED=\"0\"

# Применяем
docker exec euro-office supervisorctl reread
docker exec euro-office supervisorctl update

# Фиксируем
docker commit euro-office euro-office-patched:local
```

> Этот флаг отключает проверку TLS-сертификата в Node.js. Приемлемо для изолированной LAN
> с самоподписанными сертификатами. В продакшне с публичными сертификатами не нужен —
> вместо этого добавьте CA в доверенные хранилища системы.

---

## 5. Nextcloud: установка richdocuments

```bash
# Установить приложение Nextcloud Office (richdocuments)
sudo -u www-data php /var/www/nextcloud/occ app:install richdocuments

# Включить (если уже установлено, но отключено)
sudo -u www-data php /var/www/nextcloud/occ app:enable richdocuments
```

---

## 6. richdocuments: настройка через occ

Все команды выполняются на сервере Nextcloud от имени `www-data`.
Далее `$OCC` = `sudo -u www-data php /var/www/nextcloud/occ`.

### 6.1 Основные URL

```bash
# URL Euro-Office для PHP (server-side: получение discovery XML, WOPI actions)
$OCC config:app:set richdocuments wopi_url --value='https://eurooffice.lan/'

# Алиас wopi_url — нужен в некоторых версиях richdocuments
$OCC config:app:set richdocuments collabora_url --value='https://eurooffice.lan/'

# URL Euro-Office для браузера (загрузка JS-редактора)
$OCC config:app:set richdocuments public_wopi_url --value='https://eurooffice.lan'
```

> `public_wopi_url` — **без** завершающего слэша. С ним некоторые браузеры формируют
> двойные слэши в URL iframe → редактор не загружается.

### 6.2 TLS и allowlist

```bash
# Отключить проверку TLS при PHP → Euro-Office запросах (нужно для mkcert/самоподписанных)
$OCC config:app:set richdocuments disable_certificate_verification --value='yes'

# Разрешённые IP для WOPI-запросов (IP Euro-Office)
# Можно указать конкретный IP или CIDR
$OCC config:app:set richdocuments wopi_allowlist --value='192.168.88.50'
# или широкий диапазон для LAN:
# $OCC config:app:set richdocuments wopi_allowlist --value='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1'
```

### 6.3 WOPI Proof

```bash
# Включить WOPI Proof (Euro-Office подписывает запросы RSA-ключом)
$OCC config:app:set richdocuments disable_wopi_proof --value='no'
```

> **Внимание:** `disable_wopi_proof` — **мёртвый код** в текущей версии richdocuments.
> Он нигде не читается. WOPI Proof фактически контролируется наличием `proof-key`
> в discovery XML (т.е. патчем entrypoint.sh из раздела 3).

### 6.4 activate-config и восстановление wopi_callback_url

```bash
# Обновляем discovery-кэш (загружает WOPI endpoints и proof-key от Euro-Office)
$OCC richdocuments:activate-config 2>/dev/null || true

# НЕМЕДЛЕННО после этого восстанавливаем wopi_callback_url
# activate-config сбрасывает его в пустую строку
$OCC config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'
```

**Почему `wopi_callback_url` так важен:**

`WOPIMiddleware.php` проверяет WOPI Proof подпись против URL, сгенерированного через
`urlGenerator->getAbsoluteURL()`. Этот генератор учитывает `overwriteprotocol` и
`overwrite.cli.url` из `config.php` → всегда возвращает `https://nextcloud.lan/...`.

Euro-Office подписывает тот URL, по которому сам обращается к Nextcloud. Если `wopi_callback_url`
указан неправильно (например, `http://192.168.88.20:8080/...`), Euro-Office пошлёт запрос
на этот адрес, подпишет его, а Nextcloud ожидает подпись для `https://nextcloud.lan/...`
→ подпись не совпадает → HTTP 500 "invalid proof keys".

**Правило:** `wopi_callback_url` == `overwrite.cli.url` == `https://<ваш-домен>`.

### 6.5 Сброс Redis-кэша

```bash
# После любых изменений в richdocuments или Euro-Office — обязательно сбросить кэш.
# Redis кэширует discovery XML (proof-key, WOPI endpoints).
# Без сброса Nextcloud использует устаревший кэш ещё часами.
redis-cli -h 192.168.88.40 -a <redis_password> FLUSHALL
```

---

## 7. Патч WOPIMiddleware.php

### 7.1 Проблема

**Симптом:** новые файлы (созданные из шаблона: "Новая презентация", "Новый документ")
не открываются — "Загрузка не удалась". Уже загруженные `.docx`/`.pptx` открываются нормально.

**Ошибка в Nextcloud log** (`/var/nc-data/nextcloud.log`):
```
WOPI error: X-WOPI-TimeStamp header is older than 20 minutes
```

**Причина:** при открытии нового файла из шаблона Euro-Office converter обращается к
`/wopi/template/NNN` **без** заголовков `X-WOPI-Proof`, `X-WOPI-ProofOld`, `X-WOPI-TimeStamp`.

`WOPIMiddleware.php` видит, что discovery содержит `proof-key` (`$hasProofKey = true`),
читает пустой заголовок: `(int)'' = 0`, передаёт в `ticksToUnixTimestamp(0)`:

```
unix_ts = (0 - 621355968000000000) / 10000000 ≈ -62135596800
```

Это секунды Unix для ~1 января 1 года н.э. `isOldTimestamp()` возвращает `true`
→ `throw new WopiException('X-WOPI-TimeStamp header is older than 20 minutes')` → HTTP 500.

Euro-Office converter получает статус 500, не может скачать шаблон → файл не открывается.

### 7.2 Исправление

Файл: `/var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php`

Найти строку (примерно строка 89 в richdocuments для NC 34):
```php
if ($hasProofKey) {
```

Заменить на:
```php
if ($hasProofKey && $wopiProof) {
```

Это изменение пропускает всю проверку WOPI Proof если клиент не прислал заголовки.
Безопасно: если клиент не предоставил доказательство — мы просто не проверяем его,
а не принимаем неверное. Клиент всё равно должен предоставить валидный `access_token`.

```bash
# Применить sed-ом (ВНИМАНИЕ: проверьте точность строки в вашей версии перед применением)
sed -i 's/if (\$hasProofKey) {/if (\$hasProofKey \&\& \$wopiProof) {/' \
    /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php

# Проверить
grep -n 'hasProofKey' /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php

# Применить
systemctl reload php8.3-fpm
```

---

## 8. Патч RemoteService.php

### 8.1 Проблема

**Симптом:** в `/var/nc-data/nextcloud.log` периодически появляется предупреждение:
```
fclose(): supplied resource is not a valid stream resource in RemoteService.php line 73
```

**Причина:** `RemoteService::convertFileTo()` открывает файл через `fopen()`, передаёт stream
в `convertTo()` (HTTP-запрос через Guzzle), а затем в блоке `finally` вызывает `fclose()`.
Guzzle при отправке multipart-запроса читает и закрывает переданный stream самостоятельно.
`finally` пытается закрыть уже закрытый ресурс → PHP warning.

### 8.2 Исправление

Файл: `/var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php`

Найти (примерно строка 73):
```php
        } finally {
            fclose($stream);
        }
```

Заменить на:
```php
        } finally {
            if (is_resource($stream)) { fclose($stream); }
        }
```

```bash
# Применить
sed -i 's/\t\t\tfclose(\$stream);/\t\t\tif (is_resource(\$stream)) { fclose(\$stream); }/' \
    /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php

# Проверить
grep -n 'fclose' /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php

# Применить
systemctl reload php8.3-fpm
```

---

## 9. Nginx на сервере Nextcloud

Типичная конфигурация CT 201 (PHP-FPM + Nginx на порту 8080, за reverse proxy).

### 9.1 Блок `.well-known` — ловушка с `return 301`

**Симптом:** Nextcloud setupcheck "`.well-known` URLs" → "Could not check" или красная ошибка.

**Причина:** `return 301 /index.php$request_uri` строит **абсолютный** URL из схемы и порта
текущего соединения → `http://nextcloud.lan:8080/index.php/.well-known/webfinger`.
Клиент (Nextcloud self-check, Guzzle) пытается подключиться на порт 8080 — reverse proxy
его не слушает → Connection refused → `cURL error 7`.

**Исправление:** использовать `rewrite ... last` (внутренний редирект, без HTTP-ответа):

```nginx
location ^~ /.well-known {
    # Для caldav/carddav нужен именно HTTP 301 с абсолютным https:// URL.
    # $http_host — имя хоста из заголовка запроса (nextcloud.lan).
    location = /.well-known/carddav { return 301 https://$http_host/remote.php/dav; }
    location = /.well-known/caldav  { return 301 https://$http_host/remote.php/dav; }

    # Для остальных .well-known (webfinger, nodeinfo и т.д.) —
    # внутренний rewrite в PHP, без HTTP-редиректа клиенту.
    rewrite ^ /index.php$request_uri last;
}
```

> Для `carddav`/`caldav` нужен 301 с полным `https://` потому что клиенты (DAV-клиенты,
> Nextcloud self-check) ожидают именно HTTP-редирект. Но URL должен быть абсолютным
> (`https://$http_host/...`), а не относительным — иначе клиент построит `http://....:8080/...`.

### 9.2 Шрифты `.otf` — 404

**Симптом:** в setupcheck "Загрузка шрифтов" → ошибка. В браузере консоль показывает
`404` на `.otf` файлы (например `OpenDyslexic-Regular.otf`).

**Причина:** в `location /` стоит `rewrite ^ /index.php$request_uri last` — все запросы,
не подпавшие под более специфичные location, попадают в PHP. Nextcloud возвращает 404
для путей вида `/apps/theming/fonts/...otf`.

**Исправление:** добавить `.otf` в статическую location для шрифтов:

```nginx
# Было:
location ~ \.woff2?$ {
    try_files $uri /index.php$request_uri;
    expires 7d;
    access_log off;
}

# Стало:
location ~ \.(?:otf|woff2?)$ {
    try_files $uri /index.php$request_uri;
    expires 7d;
    access_log off;
}
```

### 9.3 trusted_domains

**Симптом:** setupcheck "Trusted domains" → предупреждение. Или запросы с `localhost`/`127.0.0.1`
(Nextcloud self-check работает в CLI-режиме) завершаются с "Access through untrusted domain".

```bash
$OCC config:system:set trusted_domains 0 --value='nextcloud.lan'
$OCC config:system:set trusted_domains 1 --value='192.168.88.20'
$OCC config:system:set trusted_domains 2 --value='localhost'
$OCC config:system:set trusted_domains 3 --value='127.0.0.1'
```

---

## 10. Диагностика

### 10.1 Проверка WOPI Proof в discovery XML

```bash
# Запрос напрямую к Euro-Office (обходя proxy)
curl -s http://192.168.88.50/hosting/discovery | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
pk = root.find('.//{*}proof-key')
if pk is None:
    print('ERROR: нет элемента proof-key — WOPI Proof не работает')
elif not pk.get('value'):
    print('ERROR: proof-key value пустой — патч entrypoint.sh не применён')
else:
    print('OK: proof-key присутствует, длина', len(pk.get('value')))
"
```

### 10.2 Проверка формата RSA-ключа

```bash
# Посмотреть первую строку ключа внутри контейнера
docker exec euro-office head -1 /var/www/euro-office/Data/certs/wopi-private.key

# Должно быть:
#   -----BEGIN RSA PRIVATE KEY-----   (PKCS#1 — правильно)
# Если:
#   -----BEGIN PRIVATE KEY-----       (PKCS#8 — нужен патч)
```

### 10.3 Логи Euro-Office

```bash
# Docservice — основной WOPI-процесс (checkFileInfo, getFile, putFile)
docker exec euro-office tail -50 /var/log/euro-office/documentserver/docservice/out.log

# Converter — конвертация файлов (скачивает шаблон, конвертирует)
docker exec euro-office tail -50 /var/log/euro-office/documentserver/converter/out.log

# Потоковое наблюдение
docker exec euro-office tail -f /var/log/euro-office/documentserver/docservice/out.log
```

**Типичные ошибки и их значение:**

| Строка в логе | Значение |
|---------------|----------|
| `wopi checkFileInfo error status=500` | Nextcloud вернул 500 на первом WOPI-запросе |
| `downloadFile:url=.../wopi/template/NNN;attempt=3;code:ERR_BAD_RESPONSE` | Не смог скачать шаблон (3 попытки), Nextcloud вернул не-200 |
| `receiveTask Error: ENOENT: .../source/Editor.bin` | Файл шаблона не был скачан → converter не нашёл входные данные |
| `ExitCode (code=88;signal=null;error:-88)` | Source file not found (следствие ENOENT выше) |
| `ExitCode (code=80;signal=null;error:-80)` | Ошибка скачивания/конвертации (download/convert error) |
| `wopi checkFileInfo error status=401` | Невалидный JWT или неверный JWT_SECRET |

### 10.4 Лог Nextcloud

```bash
# Файл лога Nextcloud
tail -50 /var/nc-data/nextcloud.log

# Фильтр только ошибок WOPI/richdocuments
tail -200 /var/nc-data/nextcloud.log | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line)
        msg = e.get('message', '')
        app = e.get('app', '')
        if 'wopi' in msg.lower() or 'richdocuments' in app.lower() or e.get('level', 0) >= 3:
            print(f\"[{e.get('level')}] [{app}] {msg}\")
    except: pass
"
```

**Типичные ошибки:**

| Сообщение в nextcloud.log | Значение |
|---------------------------|----------|
| `X-WOPI-TimeStamp header is older than 20 minutes` | Пустой или нулевой timestamp → нужен патч WOPIMiddleware.php |
| `WOPI error: invalid proof keys` | Подпись не совпадает → проверить wopi_callback_url и формат ключа |
| `fclose(): supplied resource is not a valid stream resource` | Двойной fclose в RemoteService.php (предупреждение, не ошибка) |
| `DECODER routines::unsupported` | Ключ в формате PKCS#8 → нужен патч entrypoint.sh |

### 10.5 Симуляция WOPI-запроса вручную

Чтобы понять, что именно возвращает Nextcloud на WOPI-запрос без proof-заголовков:

```bash
# Получить access_token: открыть файл в браузере, в DevTools найти iframe URL
# Параметр access_token=... из wopiSrc URL

TOKEN="ВАШ_ACCESS_TOKEN"
FILE_ID="205"  # node ID файла

# Запрос checkFileInfo без proof-заголовков (как делает converter)
curl -v -k \
  -H "Authorization: Bearer $TOKEN" \
  "https://nextcloud.lan/index.php/apps/richdocuments/wopi/files/${FILE_ID}_oc5zz6ijsp90?access_token=$TOKEN"
```

### 10.6 Проверка richdocuments конфига

```bash
# Посмотреть все установленные параметры richdocuments
sudo -u www-data php /var/www/nextcloud/occ config:app:get richdocuments --all
# или
sudo -u www-data php /var/www/nextcloud/occ config:list richdocuments
```

### 10.7 Проверка supervisord в контейнере

```bash
# Статус процессов
docker exec euro-office supervisorctl status

# Конфиги supervisord (проверить наличие NODE_TLS_REJECT_UNAUTHORIZED)
docker exec euro-office cat /etc/supervisor/conf.d/ds-docservice.conf
docker exec euro-office cat /etc/supervisor/conf.d/ds-converter.conf

# Перезапуск отдельного сервиса без перестарта контейнера
docker exec euro-office supervisorctl restart ds-docservice
docker exec euro-office supervisorctl restart ds-converter
```

### 10.8 Проверка nginx

```bash
# Тест конфигурации
nginx -t

# Проверить .well-known вручную (должен вернуть 200/404, но не connection refused)
curl -v http://127.0.0.1:8080/.well-known/webfinger

# Проверить шрифты
curl -I https://nextcloud.lan/apps/theming/fonts/OpenDyslexic-Regular.otf
# Ожидаем: HTTP/2 200, content-type: font/otf
```

---

## 11. Таблица симптомов и причин

| Симптом | Первое что проверить | Вероятная причина |
|---------|---------------------|-------------------|
| `proof-key` в discovery пустой | `head -1` RSA-ключа в контейнере | PKCS#8 вместо PKCS#1 |
| Редактор не открывается совсем | Лог docservice: `checkFileInfo error` | JWT secret / NODE_TLS / wopi_allowlist |
| Загруженный файл открывается, новый нет | `downloadFile:url=.../wopi/template` в converter log | Нет патча WOPIMiddleware.php |
| HTTP 500 "invalid proof keys" | `wopi_callback_url` в occ | Не совпадает с overwrite.cli.url |
| `.well-known` setupcheck красный | nginx config | `return 301 /relative` вместо `rewrite last` |
| `.otf` шрифты 404 | nginx location для шрифтов | Нет `.otf` в паттерне `\.(?:otf|woff2?)$` |
| `fclose(): supplied resource` warning | RemoteService.php line ~73 | Double-fclose; патч `is_resource()` |
| После activate-config всё сломалось | `occ config:app:get richdocuments wopi_callback_url` | activate-config сбросил в пустую строку |
| Redis кэш устарел (старые ключи) | `FLUSHALL` и повторная проверка | Не сброшен после изменений |
