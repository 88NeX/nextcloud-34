# 01 — Создание LXC-контейнеров на Proxmox

**Хост Proxmox:** `192.168.88.144` (root)  
**Web UI:** https://192.168.88.144:8006  
**SSH:** `ssh root@192.168.88.144`

## Параметры контейнеров

| CT ID | Имя | CPU | RAM | Диск | IP |
|-------|-----|-----|-----|------|----|
| 200 | nc-proxy | 2 | 512 MB | 8 GB | 192.168.88.10/24 |
| 201 | nc-app | 4 | 2048 MB | 32 GB | 192.168.88.20/24 |
| 202 | nc-db | 2 | 1024 MB | 20 GB | 192.168.88.30/24 |
| 203 | nc-cache | 2 | 512 MB | 4 GB | 192.168.88.40/24 |
| 204 | nc-office | 4 | 2048 MB | 10 GB | 192.168.88.50/24 |

## 1. Подготовка сети на хосте Proxmox

Сеть `192.168.88.0/24` — существующая LAN (роутер на `192.168.88.1`).
Контейнеры подключаются к **vmbr0** (бридж, смотрящий в LAN), отдельный мост и NAT не нужны.

```bash
# Проверить, какой бридж подключён к LAN
ip link show type bridge
# Обычно vmbr0 — убедиться в /etc/network/interfaces:
#
# auto vmbr0
# iface vmbr0 inet static
#     address 192.168.88.144/24  ← IP хоста Proxmox
#     gateway 192.168.88.1
#     bridge-ports enp3s0        ← реальный сетевой интерфейс
#     bridge-stp off
#     bridge-fd 0
#
# Если бридж уже настроен — этот шаг пропустить.
```

## 2. Скачать шаблон Debian 12

```bash
pveam update
pveam download local debian-12-standard_12.7-1_amd64.tar.zst
```

## 3. Создание контейнеров (выполнять на хосте Proxmox)

### nc-proxy (200)

```bash
pct create 200 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-proxy \
  --cores 2 --memory 512 --swap 256 \
  --rootfs local-lvm:8 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.10/24,gw=192.168.88.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 \
  --start 1
```

### nc-app (201)

```bash
pct create 201 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-app \
  --cores 4 --memory 2048 --swap 1024 \
  --rootfs local-lvm:32 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.20/24,gw=192.168.88.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 \
  --start 1
```

### nc-db (202)

```bash
pct create 202 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-db \
  --cores 2 --memory 1024 --swap 512 \
  --rootfs local-lvm:20 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.30/24,gw=192.168.88.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 \
  --start 1
```

### nc-cache (203)

```bash
pct create 203 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-cache \
  --cores 2 --memory 512 --swap 0 \
  --rootfs local-lvm:4 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.40/24,gw=192.168.88.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 \
  --start 1
```

### nc-office (204)

```bash
pct create 204 local:vztmpl/debian-12-standard_12.7-1_amd64.tar.zst \
  --hostname nc-office \
  --cores 4 --memory 2048 --swap 1024 \
  --rootfs local-lvm:10 \
  --net0 name=eth0,bridge=vmbr0,ip=192.168.88.50/24,gw=192.168.88.1 \
  --nameserver 1.1.1.1 \
  --unprivileged 1 --features nesting=1 \
  --start 1
```

## 4. Базовая настройка каждого контейнера

Выполнять в каждом (пример для nc-app):

```bash
pct exec 201 -- bash -c "
apt-get update && apt-get upgrade -y
apt-get install -y curl wget gnupg2 ca-certificates lsb-release apt-transport-https
timedatectl set-timezone Europe/Moscow
echo 'fs.inotify.max_user_watches=524288' >> /etc/sysctl.conf
sysctl -p
"
```

## Заметки

- `--unprivileged 1` — безопасный режим; для Collabora достаточно
- `nesting=1` — нужен если внутри контейнера потребуется Docker (для Collabora можно установить нативно)
- Collabora можно запускать через Docker внутри LXC — тогда для CT 204 добавить `keyctl=1` в features
