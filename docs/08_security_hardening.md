# 08 — Базовое hardening LXC-контейнеров

## Общее для всех контейнеров

```bash
# Применять в каждом контейнере:

# Отключить root-вход по паролю через SSH
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
systemctl reload sshd

# Базовый файрвол (UFW)
apt-get install -y ufw
ufw default deny incoming
ufw default allow outgoing
ufw allow from 192.168.88.0/24    # разрешить внутреннюю сеть
ufw --force enable
```

## Специфика контейнеров

### nc-proxy — дополнительно открыть 80 и 443

```bash
ufw allow 80/tcp
ufw allow 443/tcp
```

### nc-db — ограничить доступ только с nc-app

```bash
# В pg_hba.conf уже ограничено на 192.168.88.20/32
# UFW дополнительно:
ufw delete allow from 192.168.88.0/24
ufw allow from 192.168.88.20 to any port 5432
```

### nc-cache — только с nc-app

```bash
ufw delete allow from 192.168.88.0/24
ufw allow from 192.168.88.20 to any port 6379
```

### nc-office — только с nc-proxy и nc-app

```bash
ufw delete allow from 192.168.88.0/24
ufw allow from 192.168.88.10 to any port 9980
ufw allow from 192.168.88.20 to any port 9980
```

## Параметры Proxmox для LXC

В конфигурации каждого контейнера `/etc/pve/lxc/<CTID>.conf`:

```
# Запретить привилегированные операции (уже включено при --unprivileged 1)
unprivileged: 1
# Запретить доступ к устройствам хоста
lxc.cap.drop: sys_time sys_module
```

## Резервное копирование

```bash
# На хосте Proxmox — настроить Proxmox Backup Server или vzdump
vzdump 201 202 203 204 \
  --mode snapshot \
  --storage local \
  --compress zstd \
  --mailto admin@example.com
```

Рекомендуется добавить задание в Proxmox DC → Backup → Add.
