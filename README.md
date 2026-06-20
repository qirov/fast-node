# 🚀 Node Setup

Скрипт оптимизации ВМ для нод на базе Remnawave/Xray-core.

Одна команда — полная настройка сервера с интерактивным вводом портов и IP панели.

## ⚡ Быстрый старт

### Полная настройка ВМ + деплой

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qirow/fast-node/main/setup.sh)
```

### Только деплой remnanode (без оптимизации)

Быстро поднять контейнер для теста — пропускает всю оптимизацию, ставит Docker если нет, спрашивает только `NODE_PORT` и `SECRET_KEY`:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qirov/fast-node/main/setup.sh) --deploy-only
```

### Только применить sysctl (на работающий сервер)

Применить kernel-тюнинг без переустановки пакетов и без ребута:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/qirov/fast-node/main/setup.sh) --apply-only
```

## 🔀 Режимы работы

| Режим | Флаг | Что делает |
|-------|------|-----------|
| **Полный** | *(без флагов)* | Обновление системы, Docker, sysctl, RPS, swap, UFW, fail2ban, DNS, logrotate + опционально деплой remnanode |
| **Deploy only** | `--deploy-only` | Только Docker + docker-compose.yml + pull + запуск remnanode |
| **Apply only** | `--apply-only` | Только sysctl/conntrack/RPS/limits на работающий сервер без ребута |

## 📋 Что спрашивает скрипт

### Полный режим

- **Порты VLESS Reality** (через запятую, например: `443,8443,9443`)
- **NODE_PORT** для API Remnawave (по умолчанию `2222`)
- **IP панели Remnawave** — NODE_PORT будет открыт только для этого IP
- **IP Prometheus** (опционально) — если указан, ставится node_exporter с TLS и открывается UFW только для этого IP
- **Порт node_exporter** (спрашивается только если указан IP Prometheus; по умолчанию `9101`)
- **Swap** — да/нет (рекомендуется для защиты от OOM)
- **Деплой remnanode** — да/нет, если да — запрашивает SECRET_KEY
- **Reboot** — автоматически предложит перезагрузку в конце

### Deploy only

- **NODE_PORT** (по умолчанию `2222`)
- **SECRET_KEY** из панели Remnawave
- **Reboot** — предложит, но не обязателен (контейнер уже работает)

## 📋 Что настраивается (полный режим)

| Компонент | Что делает |
|-----------|-----------|
| **BBR** | TCP congestion control — быстрее чем cubic |
| **sysctl** | TCP буферы, backlog, conntrack, keepalive |
| **RPS** | Распределение пакетов по всем ядрам CPU |
| **Swap** | Защита от OOM-kill (опционально, размер по RAM) |
| **Conntrack** | Автоматический расчёт по RAM (131K–1M) |
| **nofile** | Лимит файловых дескрипторов 1048576 |
| **UFW** | Firewall с комментариями, NODE_PORT только для IP панели |
| **Fail2ban** | Защита SSH от брутфорса |
| **DNS over TLS** | Cloudflare + Google DoT |
| **Docker** | Установка если отсутствует |
| **node_exporter** | Опционально: v1.11.1, TLS (self-signed), systemd, порт 9101 |
| **Logrotate** | Ротация логов remnanode (50MB, 5 файлов) |
| **Remnanode** | Опционально: docker-compose.yml (+volumes сертификатов и сокетов), pull, запуск |

## 🧮 Автоматические расчёты по RAM

| RAM | Conntrack max | TCP buf max | Swap |
|-----|--------------|-------------|------|
| ≤2 ГБ | 131,072 | 8 МБ | 2 ГБ |
| 3–4 ГБ | 262,144 | 16 МБ | 2 ГБ |
| 5–8 ГБ | 524,288 | 25 МБ | 2 ГБ |
| 9–16 ГБ | 524,288 | 32 МБ | 4 ГБ |
| >16 ГБ | 1,048,576 | 32 МБ | 4 ГБ |

## 🔧 RPS (Receive Packet Steering)

На VPS с single-queue VirtIO NIC (99% серверов) все пакеты обрабатывает одно ядро CPU. Скрипт автоматически:

1. Определяет интерфейс и количество RX queues
2. Если single-queue — включает RPS на все ядра
3. Если multiqueue (≥ кол-во CPU) — пропускает
4. Создаёт systemd service для persistence после ребута

## 📁 Что создаётся

```
/opt/remnanode/
│   └── docker-compose.yml             # Деплой remnanode (+volumes: /dev/shm, /opt/nginx:ro)
/opt/remnawave/xray/share/
│   └── zapret.dat                      # Если выбран деплой remnanode
/var/log/remnanode/                     # Логи Xray
/etc/sysctl.d/99-vpn-node.conf         # BBR, TCP буферы, conntrack
/etc/security/limits.d/99-vpn-node.conf # nofile limits
/etc/systemd/system/rps-tuning.service  # RPS persistent
/etc/logrotate.d/remnanode              # Ротация логов
/etc/node_exporter/                     # Бинарь TLS: cert + key + web-config.yml (если указан Prometheus)
/etc/systemd/system/node_exporter.service
```

## ✅ Проверка после ребута

```bash
sysctl net.ipv4.tcp_congestion_control          # → bbr
sysctl net.netfilter.nf_conntrack_max            # → 524288
sysctl net.netfilter.nf_conntrack_tcp_timeout_established  # → 600
cat /sys/module/nf_conntrack/parameters/hashsize # → 131072
cat /sys/class/net/eth0/queues/rx-0/rps_cpus     # → f (4 ядра) или ff (8 ядер)
ulimit -n                                         # → 1048576
swapon --show                                     # → /swapfile (если включён)
ufw status                                        # → правила на месте
docker ps                                         # → remnanode (если деплоили)
systemctl status node_exporter                    # → active (если указан Prometheus IP)
curl -sk https://localhost:9101/metrics | head    # → метрики node_exporter
```

## 🔧 Управление remnanode

```bash
# Логи
docker compose -f /opt/remnanode/docker-compose.yml logs -f

# Рестарт
docker compose -f /opt/remnanode/docker-compose.yml restart

# Обновление образа
docker compose -f /opt/remnanode/docker-compose.yml pull
docker compose -f /opt/remnanode/docker-compose.yml up -d

# Обновление zapret.dat
wget -O /opt/remnawave/xray/share/zapret.dat \
    https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat
docker compose -f /opt/remnanode/docker-compose.yml restart
```

## ⚠️ Важно

- Поддерживается **только Ubuntu/Debian**
- Требуется **root** доступ
- В полном режиме скрипт предложит **reboot** — для полного применения настроек ребут обязателен
- В `--deploy-only` ребут не обязателен — контейнер уже запущен
- `--apply-only` не требует ребута — всё применяется сразу
- Access log Xray **не рекомендуется** для production (гигабайты записей)

## 🔄 Повторный запуск

Скрипт можно запускать повторно. В полном режиме UFW сбрасывается и создаётся заново, sysctl конфиги перезаписываются без дублирования. `--deploy-only` перезапишет docker-compose.yml и пересоздаст контейнер.

## 📝 Лицензия

MIT
