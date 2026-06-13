# 07 — Финальная конфигурация Nextcloud

Все команды выполнять на **nc-app** (192.168.88.20) от имени `www-data`.

```bash
pct exec 201 -- bash
alias occ='sudo -u www-data php /var/www/nextcloud/occ'
```

## 1. config.php — домен, trusted proxies

```bash
# Домены — добавить все через которые доступен Nextcloud
occ config:system:set trusted_domains 0 --value="nextcloud.lan"
occ config:system:set trusted_domains 1 --value="192.168.88.20"
occ config:system:set trusted_domains 2 --value="192.168.88.10"
occ config:system:set trusted_domains 3 --value="127.0.0.1"
occ config:system:set trusted_domains 4 --value="localhost"

# Публичный URL (должен совпадать с wopi_callback_url в richdocuments)
occ config:system:set overwrite.cli.url --value="https://nextcloud.lan"
occ config:system:set overwriteprotocol --value="https"

# Доверенный прокси (IP nc-proxy)
occ config:system:set trusted_proxies 0 --value="192.168.88.10"
occ config:system:set forwarded_for_headers 0 --value="HTTP_X_FORWARDED_FOR"
```

> **`overwriteprotocol=https`** устанавливать только после настройки TLS на nc-proxy.
> До этого Nextcloud будет генерировать неправильные https:// URL для внутренних запросов.

## 2. Redis — кэш и блокировки файлов

```bash
occ config:system:set memcache.local --value='\OC\Memcache\APCu'
occ config:system:set memcache.distributed --value='\OC\Memcache\Redis'
occ config:system:set memcache.locking --value='\OC\Memcache\Redis'
occ config:system:set redis host --value="192.168.88.40"
occ config:system:set redis port --value=6379 --type=integer
occ config:system:set redis password --value="CHANGE_ME_REDIS_PASS"
occ config:system:set redis timeout --value=1.5 --type=float
occ config:system:set redis dbindex --value=0 --type=integer
occ config:system:set filelocking.enabled --value=true --type=boolean
```

Итоговый блок в `/var/www/nextcloud/config/config.php`:

```php
'memcache.local'       => '\OC\Memcache\APCu',
'memcache.distributed' => '\OC\Memcache\Redis',
'memcache.locking'     => '\OC\Memcache\Redis',
'redis' => [
    'host'     => '192.168.88.40',
    'port'     => 6379,
    'password' => 'CHANGE_ME_REDIS_PASS',
    'timeout'  => 1.5,
    'dbindex'  => 0,
],
'filelocking.enabled' => true,
```

## 3. Email (опционально)

```bash
occ config:system:set mail_smtpmode  --value="smtp"
occ config:system:set mail_smtphost  --value="smtp.example.com"
occ config:system:set mail_smtpport  --value=587 --type=integer
occ config:system:set mail_smtpsecure --value="tls"
occ config:system:set mail_from_address --value="nextcloud"
occ config:system:set mail_domain --value="example.com"
```

## 4. Дополнительные параметры

```bash
# Отключить проверку обновлений
occ config:system:set updatechecker --value=false --type=boolean

# Размер чанка для больших файлов (100 MB)
occ config:system:set max_chunk_size --value=104857600 --type=integer

# Локаль
occ config:system:set default_locale --value="ru_RU"
occ config:system:set default_phone_region --value="RU"
```

## 5. Установка и настройка Nextcloud Office (richdocuments / WOPI)

Euro-Office интегрируется через приложение **richdocuments** по протоколу WOPI.

```bash
# Установить приложение
occ app:install richdocuments

# URL Euro-Office — PHP (серверная сторона): discovery XML, WOPI actions
occ config:app:set richdocuments wopi_url --value='https://eurooffice.lan/'

# Алиас wopi_url (нужен в некоторых версиях richdocuments)
occ config:app:set richdocuments collabora_url --value='https://eurooffice.lan/'

# URL Euro-Office — браузер: загрузка JS-редактора (без завершающего слэша)
occ config:app:set richdocuments public_wopi_url --value='https://eurooffice.lan'

# Отключить проверку TLS-сертификата при PHP → Euro-Office запросах
# (нужно для mkcert/самоподписанных сертификатов)
occ config:app:set richdocuments disable_certificate_verification --value='yes'

# IP Euro-Office — разрешённые источники WOPI-запросов
occ config:app:set richdocuments wopi_allowlist --value='192.168.88.50'

# Обновить discovery-кэш (загружает proof-key от Euro-Office)
occ richdocuments:activate-config 2>/dev/null || true

# КРИТИЧЕСКИ ВАЖНО: activate-config сбрасывает wopi_callback_url в пустую строку.
# Немедленно восстанавливаем.
# Значение ОБЯЗАНО совпадать с overwrite.cli.url из config.php.
occ config:app:set richdocuments wopi_callback_url --value='https://nextcloud.lan'
```

> **Почему `wopi_callback_url` так важен:**
> WOPIMiddleware.php проверяет WOPI Proof подпись против URL, который Nextcloud
> генерирует через `urlGenerator->getAbsoluteURL()`. Этот URL определяется
> `overwriteprotocol` и `overwrite.cli.url`. Если `wopi_callback_url` указан иначе
> (другой протокол, IP вместо домена) — подписи не совпадут → HTTP 500.

```bash
# Сбросить Redis-кэш (обязательно после изменений в richdocuments или Euro-Office)
# Redis кэширует discovery XML с proof-key и WOPI endpoints
redis-cli -h 192.168.88.40 -a 'CHANGE_ME_REDIS_PASS' FLUSHALL
```

## 6. Патчи richdocuments (применяются вручную один раз)

Два файла в `/var/www/nextcloud/apps/richdocuments/`:

**`lib/Middleware/WOPIMiddleware.php`** строка ~89:

Euro-Office converter запрашивает `/wopi/template/NNN` без proof-заголовков.
Оригинальный код видит пустой timestamp → год 1 н.э. → HTTP 500.

```bash
sed -i \
  's/if (\$hasProofKey) {/if (\$hasProofKey \&\& \$wopiProof) {/' \
  /var/www/nextcloud/apps/richdocuments/lib/Middleware/WOPIMiddleware.php
```

**`lib/Service/RemoteService.php`** строка ~73:

Guzzle закрывает stream после отправки, `finally` пытается закрыть ещё раз → PHP warning.

```bash
sed -i \
  's/\t\t\tfclose(\$stream);/\t\t\tif (is_resource(\$stream)) { fclose(\$stream); }/' \
  /var/www/nextcloud/apps/richdocuments/lib/Service/RemoteService.php
```

```bash
# Применить оба патча
systemctl reload php8.3-fpm
```

Подробнее — [EURO_OFFICE_WOPI.md](../EURO_OFFICE_WOPI.md).

## 7. Прочие приложения (по потребности)

```bash
occ app:install calendar
occ app:install contacts
```

## 8. Обслуживание

```bash
# Принудительное сканирование файлов
occ files:scan --all

# Статус установки
occ status
occ check
```

## 9. Проверочный чеклист

- [ ] `occ status` — installed: true
- [ ] `occ check` — нет критических предупреждений
- [ ] Вход через браузер: `https://nextcloud.lan`
- [ ] Загрузить `.docx` → кликнуть → должен открыться редактор Euro-Office
- [ ] Создать "Новую презентацию" → открыть → не "Загрузка не удалась"
- [ ] Redis: `redis-cli -h 192.168.88.40 -a PASS info clients` — видны подключения от NC
- [ ] Setupcheck: `.well-known` URLs — зелёный
- [ ] Setupcheck: Font loading — зелёный
