# Nextcloud 34 — план развёртывания на Proxmox LXC

## Стек

| Компонент | Версия | LXC-контейнер |
|-----------|--------|---------------|
| Nextcloud | 34.x | `nc-app` |
| PostgreSQL | 16 | `nc-db` |
| Redis | 7.x | `nc-cache` |
| Euro-Office DocumentServer | latest (Docker) | `nc-office` |
| Nginx (reverse proxy + TLS) | 1.26+ | `nc-proxy` |

## Сетевая топология

```
Браузер / LAN
      │
      ▼
[nc-proxy]  192.168.88.10  — TLS-терминация, reverse proxy
      │                        nextcloud.lan → nc-app:8080
      │                        eurooffice.lan → nc-office:80
      │
      ├──► [nc-app]     192.168.88.20  — PHP 8.3-FPM + Nextcloud 34 + Nginx
      │         │
      │         ├──► [nc-db]     192.168.88.30  — PostgreSQL 16
      │         └──► [nc-cache]  192.168.88.40  — Redis 7
      │
      └──► [nc-office]  192.168.88.50  — Euro-Office DocumentServer (Docker)
```

## Интеграция редактора документов

Nextcloud подключается к Euro-Office через протокол **WOPI** (приложение `richdocuments`).

```
Браузер
  │  открывает iframe с JS-редактором Euro-Office
  ▼
nc-proxy (eurooffice.lan) → nc-office:80

nc-office (converter/docservice)
  │  WOPI: скачать файл, сохранить результат
  ▼
nc-proxy (nextcloud.lan) → nc-app:8080 → /wopi/files/...
```

## Порядок развёртывания

1. [01_proxmox_lxc.md](01_proxmox_lxc.md) — создание LXC-контейнеров
2. [02_postgresql.md](02_postgresql.md) — PostgreSQL 16
3. [03_redis.md](03_redis.md) — Redis 7
4. [04_nextcloud.md](04_nextcloud.md) — Nextcloud 34 + PHP 8.3
5. [05_collabora.md](05_collabora.md) — Euro-Office DocumentServer (Docker + WOPI)
6. [06_nginx.md](06_nginx.md) — Nginx reverse proxy + TLS
7. [07_nextcloud_config.md](07_nextcloud_config.md) — финальная конфигурация NC + richdocuments

## Дополнительная документация

- [EURO_OFFICE_WOPI.md](../EURO_OFFICE_WOPI.md) — подробное руководство по интеграции Euro-Office: все патчи, диагностика, типичные проблемы
- [DEPLOY.md](../DEPLOY.md) — полная пошаговая инструкция (Proxmox LXC)

## Требования к хосту Proxmox

- Proxmox VE 8.x
- Хранилище: ZFS или LVM thin
- Сеть: Linux Bridge (vmbr0), подключённый к LAN 192.168.88.0/24
- DNS: Mikrotik (или любой LAN DNS) с записями `nextcloud.lan` и `eurooffice.lan` → 192.168.88.10
- TLS: mkcert для LAN-сертификатов (или certbot для публичного домена)
