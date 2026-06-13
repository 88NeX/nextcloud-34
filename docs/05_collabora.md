# 05 — Euro-Office DocumentServer (контейнер nc-office, 192.168.88.50)

Euro-Office DocumentServer — open-source форк ONLYOFFICE DocumentServer (AGPL-3.0).
Интеграция с Nextcloud через протокол **WOPI** (приложение `richdocuments`).

> Нативных deb-пакетов нет — единственный способ установки: Docker.

```bash
pct exec 204 -- bash
```

## 1. Подготовка LXC-контейнера для Docker

На **хосте Proxmox** добавить в `/etc/pve/lxc/204.conf`:

```
features: keyctl=1,nesting=1
```

Перезапустить контейнер:

```bash
pct restart 204
```

## 2. Установка Docker

```bash
apt-get update && apt-get install -y ca-certificates curl gnupg
curl -fsSL https://get.docker.com | sh

systemctl enable docker
systemctl start docker
```

## 3. Подготовка директорий и образа

```bash
# Директории для volumes (данные и логи переживают пересоздание контейнера)
mkdir -p /opt/euro-office/data /opt/euro-office/logs

# Скопировать Dockerfile и entrypoint.sh из репозитория на хост Proxmox:
#   scp -i ~/.ssh/proxyid_ed25519 euro-office/Dockerfile euro-office/entrypoint.sh \
#       root@192.168.88.144:/tmp/build/
# Затем в CT 204:
mkdir -p /tmp/build
```

## 4. Сборка патченного образа

Образ включает два патча поверх базового `ghcr.io/euro-office/documentserver:latest`:

**Патч 1 — entrypoint.sh** (WOPI Proof):
- `openssl genrsa -traditional` вместо `genpkey` — генерирует PKCS#1, Node.js не поддерживает PKCS#8
- `cat` вместо `awk` для `WOPI_PRIVATE_KEY_DATA` — реальные переносы строк в PEM
- Миграция существующих PKCS#8 ключей → PKCS#1 при старте

**Патч 2 — supervisord** (TLS):
- `NODE_TLS_REJECT_UNAUTHORIZED=0` в `ds-docservice.conf` и `ds-converter.conf`
- Node.js не читает системный CA store → mkcert/самоподписанные сертификаты вызывают ошибку TLS

```bash
# Передать файлы из /tmp (куда положили через pct push) и собрать образ
cp /tmp/Dockerfile /tmp/build/
cp /tmp/entrypoint.sh /tmp/build/

docker build -t euro-office-patched:local /tmp/build/
```

## 5. Запуск контейнера

```bash
JWT_SECRET="ВСТАВИТЬ_JWT_SECRET_ИЗ_.ENV"

docker run -d \
  --name euro-office \
  --restart unless-stopped \
  -p 192.168.88.50:80:80 \
  -e JWT_ENABLED=true \
  -e JWT_SECRET="${JWT_SECRET}" \
  -e JWT_HEADER=AuthorizationJwt \
  -e WOPI_ENABLED=true \
  --add-host=nextcloud.lan:192.168.88.10 \
  --add-host=eurooffice.lan:192.168.88.10 \
  -v /opt/euro-office/logs:/var/log/euro-office \
  -v /opt/euro-office/data:/var/www/euro-office/Data \
  euro-office-patched:local
```

> **`--add-host`** — обязателен. Euro-Office делает WOPI-запросы к `nextcloud.lan`;
> без этой записи DNS не разрешается изнутри контейнера.
>
> **`-p 192.168.88.50:80:80`** — биндим только на IP nc-office, не на 0.0.0.0.
> nc-proxy проксирует трафик на этот адрес.
>
> **Volumes:** `/var/log/euro-office` и `/var/www/euro-office/Data` — пути, которые
> реально использует Euro-Office. `/var/log/onlyoffice` и `/var/www/onlyoffice/Data`
> — устаревшие пути ONLYOFFICE, Euro-Office их игнорирует.

## 6. Проверка запуска

```bash
# Healthcheck
curl -s http://192.168.88.50/healthcheck
# Ожидаем: {"status":"OK"}  или  {"documentType":"cell",...}

# WOPI Proof — proof-key должен быть непустым
curl -s http://192.168.88.50/hosting/discovery | python3 -c "
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.stdin).getroot()
pk = root.find('.//{*}proof-key')
if pk is None: print('ERROR: нет proof-key')
elif not pk.get('value'): print('ERROR: proof-key пустой — патч не применён')
else: print('OK: proof-key длина', len(pk.get('value')))
"

# Логи (если что-то не так)
docker exec euro-office tail -30 /var/log/euro-office/documentserver/docservice/out.log
docker exec euro-office tail -30 /var/log/euro-office/documentserver/converter/out.log
```

## 7. Обновление образа

```bash
# Пересобрать патченный образ на новой версии базового
docker pull ghcr.io/euro-office/documentserver:latest
docker build --no-cache -t euro-office-patched:local /tmp/build/

docker stop euro-office && docker rm euro-office
# Повторить команду docker run из шага 5
```

## Архитектура внутри контейнера

Euro-Office в standalone-режиме запускает через **supervisord**:

| Процесс | Роль |
|---------|------|
| nginx | HTTP-фронтенд (порт 80) |
| docservice | Основной WOPI-сервис (checkFileInfo, getFile, putFile) |
| converter | Конвертация форматов (скачивает шаблон, конвертирует) |
| postgresql | Внутренняя БД состояния |
| redis | Внутренний кэш |
| rabbitmq | Очередь задач |

Все эти сервисы работают **внутри контейнера** и не связаны с nc-db и nc-cache.

## Пути внутри контейнера

| Переменная | Путь |
|-----------|------|
| `EO_ROOT` | `/var/www/euro-office/documentserver` |
| `EO_LOG` | `/var/log/euro-office/documentserver` |
| `EO_CONF` | `/etc/euro-office/documentserver` |
| WOPI ключи / JWT / данные | `/var/www/euro-office/Data` |

Supervisord конфиги: `/etc/supervisor/conf.d/ds-docservice.conf`, `ds-converter.conf`.

## Параметры для nc-proxy

Nginx на nc-proxy проксирует `eurooffice.lan` → `http://192.168.88.50:80`.
Конфигурация Nginx — см. [06_nginx.md](06_nginx.md).

## Параметры для Nextcloud

Настройка WOPI-интеграции через `richdocuments` — см. [07_nextcloud_config.md](07_nextcloud_config.md).
Полное руководство по интеграции — см. [EURO_OFFICE_WOPI.md](../EURO_OFFICE_WOPI.md).
