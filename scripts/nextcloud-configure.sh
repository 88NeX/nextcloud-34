#!/usr/bin/env bash
# Пост-установочная конфигурация Nextcloud: richdocuments + WOPI.
# Запускать ПОСЛЕ первого docker compose up, когда Nextcloud уже поднялся.
#
# Использование:
#   source .env && bash scripts/nextcloud-configure.sh
#   или
#   NEXTCLOUD_PUBLIC_URL=http://192.168.88.10 EURO_OFFICE_PUBLIC_URL=http://192.168.88.10:8080 bash scripts/nextcloud-configure.sh

set -euo pipefail

NC_PUBLIC="${NEXTCLOUD_PUBLIC_URL:-http://localhost}"
EURO_PUBLIC="${EURO_OFFICE_PUBLIC_URL:-http://localhost:8080}"
# Euro-Office внутри Docker-сети: nc-app и euro-office — в одной сети nextcloud-net
EURO_INTERNAL="http://euro-office/"
# Callback URL: Euro-Office → Nextcloud (через proxy внутри Docker)
NC_CALLBACK="http://proxy"

occ() {
    docker compose exec -T nc-app php /var/www/html/occ "$@"
}

echo "==> Ожидаем готовности Nextcloud..."
until occ status 2>/dev/null | grep -q "installed: true"; do
    printf '.'
    sleep 5
done
echo " готов!"

# ── overwrite.cli.url (нужен для корректных URL в фоновых задачах) ───────────
echo "==> Устанавливаем overwrite.cli.url..."
occ config:system:set overwrite.cli.url --value="$NC_PUBLIC"

# ── Установка / включение richdocuments ──────────────────────────────────────
echo "==> Устанавливаем richdocuments (Nextcloud Office)..."
occ app:install richdocuments 2>/dev/null || occ app:enable richdocuments

# ── Конфигурация WOPI ─────────────────────────────────────────────────────────
echo "==> Настраиваем WOPI..."

# wopi_url / collabora_url: откуда nc-app (PHP) обращается к Euro-Office (внутренняя сеть)
occ config:app:set richdocuments wopi_url      --value="$EURO_INTERNAL"
occ config:app:set richdocuments collabora_url --value="$EURO_INTERNAL"

# public_wopi_url: откуда БРАУЗЕР загружает редактор (внешний адрес)
occ config:app:set richdocuments public_wopi_url --value="$EURO_PUBLIC"

# Отключаем проверку TLS (HTTP-only, при HTTPS убрать этот параметр)
occ config:app:set richdocuments disable_certificate_verification --value='yes'

# WOPI allowlist: разрешённые IP для WOPI-запросов к Nextcloud от Euro-Office
occ config:app:set richdocuments wopi_allowlist --value='10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 127.0.0.1'

# WOPI Proof включён: Euro-Office подписывает запросы PKCS#1 ключом (patch_ep_final.py)
occ config:app:set richdocuments disable_wopi_proof --value='no'

# activate-config обновляет discovery-кэш, но СБРАСЫВАЕТ wopi_callback_url → восстанавливаем
echo "==> Запускаем activate-config..."
occ richdocuments:activate-config 2>/dev/null || true

# wopi_callback_url: URL, с которого Euro-Office делает WOPI-запросы к Nextcloud.
# ВАЖНО: должен совпадать с тем URL, который Nextcloud генерирует для проверки WOPI Proof
# (urlGenerator->getAbsoluteURL, зависит от overwriteprotocol).
# При HTTPS: должен быть HTTPS публичный URL; при HTTP: внутренний адрес.
occ config:app:set richdocuments wopi_callback_url --value="$NC_CALLBACK"

# ── Сброс кэша Redis (хранит discovery XML) ───────────────────────────────────
echo "==> Сбрасываем Redis-кэш (discovery XML)..."
REDIS_PASS="${REDIS_PASSWORD:-}"
if [ -n "$REDIS_PASS" ]; then
    docker compose exec -T redis redis-cli -a "$REDIS_PASS" FLUSHALL 2>/dev/null || true
else
    docker compose exec -T redis redis-cli FLUSHALL 2>/dev/null || true
fi

echo ""
echo "==> Конфигурация завершена!"
echo ""
echo "  Nextcloud:   $NC_PUBLIC"
echo "  Euro-Office: $EURO_PUBLIC"
echo ""
echo "Откройте $NC_PUBLIC, войдите как admin и попробуйте открыть .docx/.xlsx"
echo ""
echo "ВАЖНО: при повторном запуске occ richdocuments:activate-config"
echo "  нужно вручную восстановить wopi_callback_url:"
echo "  occ config:app:set richdocuments wopi_callback_url --value='$NC_CALLBACK'"
