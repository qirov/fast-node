#!/usr/bin/env bash
# ╔══════════════════════════════════════════════════════════════════╗
# ║  VPN Node Setup — Оптимизация ВМ для Remnawave/Xray            ║
# ║  Автор: ibmaga                                                   ║
# ║  Версия: 2.2.0                                                  ║
# ║                                                                  ║
# ║  Включает: BBR, sysctl tuning, RPS, swap, conntrack+timeouts,  ║
# ║  hashsize, UFW, fail2ban, DNS over TLS, logrotate, txqueuelen, ║
# ║  node_exporter (TLS), опциональный деплой remnanode             ║
# ║                                                                  ║
# ║  v2.2.0: docker-compose volumes для сертификатов (/opt/nginx)  ║
# ║  и unix-сокетов (/dev/shm); встроенная установка node_exporter ║
# ║  с TLS (self-signed) на порту 9101                              ║
# ╚══════════════════════════════════════════════════════════════════╝

set -euo pipefail

# ── Цвета ──────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# ── Логирование ───────────────────────────────────────────────────
log_info()    { echo -e "${WHITE}ℹ️  $*${NC}"; }
log_success() { echo -e "${GREEN}✅ $*${NC}"; }
log_warning() { echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error()   { echo -e "${RED}❌ $*${NC}" >&2; }
log_step()    { echo -e "\n${CYAN}━━━ $* ━━━${NC}\n"; }

# ── Режим работы ──────────────────────────────────────────────────
# APPLY_ONLY=true  — только применить sysctl на работающем сервере
# DEPLOY_ONLY=true — только развернуть remnanode (без оптимизации)
APPLY_ONLY="${APPLY_ONLY:-false}"
DEPLOY_ONLY="${DEPLOY_ONLY:-false}"

# ── Конфигурация node_exporter / путей ────────────────────────────
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-1.11.1}"
NODE_EXPORTER_PORT_DEFAULT="9101"   # VK Cloud: 9100 занят на уровне ОС
NODE_EXPORTER_DIR="/etc/node_exporter"
# Директория unix-сокетов (HAProxy на хосте ↔ Xray в контейнере)
SOCKET_DIR="/dev/shm"
# Директория сертификатов (Hysteria2 / Reality own-cert, acme.sh)
CERT_DIR="/opt/nginx"

# ── Проверки ──────────────────────────────────────────────────────
check_root() {
    if [[ "$(id -u)" != "0" ]]; then
        log_error "Скрипт должен запускаться от root (sudo)"
        exit 1
    fi
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        log_error "Поддерживаются только Ubuntu/Debian"
        exit 1
    fi
    log_success "ОС: $(grep PRETTY_NAME /etc/os-release | cut -d'"' -f2)"
}

# ── Определение сетевого интерфейса ──────────────────────────────
detect_interface() {
    local iface
    iface=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -1)
    if [[ -z "$iface" ]]; then
        iface=$(ip -o link show up | awk -F': ' '!/lo/{print $2}' | head -1)
    fi
    echo "$iface"
}

# ── Определение количества CPU ───────────────────────────────────
get_cpu_count() {
    nproc
}

# ── Расчёт RPS маски ─────────────────────────────────────────────
calc_rps_mask() {
    local cpus=$1
    printf '%x' $(( (1 << cpus) - 1 ))
}

# ── Определение RAM в ГБ ─────────────────────────────────────────
get_ram_gb() {
    awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo
}

# ── Расчёт swap размера ──────────────────────────────────────────
calc_swap_size() {
    local ram_gb=$1
    if (( ram_gb <= 2 )); then
        echo "2G"
    elif (( ram_gb <= 8 )); then
        echo "2G"
    elif (( ram_gb <= 16 )); then
        echo "4G"
    else
        echo "4G"
    fi
}

# ── Расчёт conntrack_max ─────────────────────────────────────────
# ~320 байт на запись, берём не более 10% RAM
calc_conntrack_max() {
    local ram_gb=$1
    if (( ram_gb <= 2 )); then
        echo 131072
    elif (( ram_gb <= 4 )); then
        echo 262144
    elif (( ram_gb <= 8 )); then
        echo 524288
    elif (( ram_gb <= 16 )); then
        echo 524288
    else
        echo 1048576
    fi
}

# ── Расчёт hashsize (стремимся к 1:4, не 1:8) ────────────────────
calc_conntrack_hashsize() {
    local conntrack_max=$1
    echo $(( conntrack_max / 4 ))
}

# ── Расчёт TCP буферов ───────────────────────────────────────────
calc_tcp_buffers() {
    local ram_gb=$1
    if (( ram_gb <= 2 )); then
        echo "8388608"    # 8 MB
    elif (( ram_gb <= 4 )); then
        echo "16777216"   # 16 MB
    elif (( ram_gb <= 8 )); then
        echo "26214400"   # 25 MB
    else
        echo "33554432"   # 32 MB
    fi
}

# ── Расчёт netdev параметров ─────────────────────────────────────
calc_netdev_budget() {
    local cpus=$1
    if (( cpus <= 2 )); then
        echo 300
    elif (( cpus <= 4 )); then
        echo 600
    else
        echo 1000
    fi
}

calc_dev_weight() {
    local cpus=$1
    if (( cpus <= 2 )); then
        echo 64
    elif (( cpus <= 4 )); then
        echo 128
    else
        echo 256
    fi
}

# ── Расчёт conntrack timeouts ────────────────────────────────────
# Для VPN/прокси: сессии реальные, но не 5 дней
# 600s = 10 минут для established — разумный компромисс
calc_conntrack_tcp_established() {
    echo 600
}

# ── Расчёт tcp_max_tw_buckets ────────────────────────────────────
calc_tw_buckets() {
    local ram_gb=$1
    if (( ram_gb <= 4 )); then
        echo 720000
    elif (( ram_gb <= 8 )); then
        echo 1440000
    else
        echo 2000000
    fi
}

# ── Расчёт txqueuelen ────────────────────────────────────────────
calc_txqueuelen() {
    local ram_gb=$1
    if (( ram_gb <= 4 )); then
        echo 2000
    else
        echo 10000
    fi
}

# ── Валидация IP ──────────────────────────────────────────────────
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    return 1
}

# ── Валидация порта ───────────────────────────────────────────────
validate_port() {
    local port=$1
    if [[ $port =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )); then
        return 0
    fi
    return 1
}

# Принимает одиночный порт (N) или диапазон (N:M, N<M) — для UDP port hopping
validate_udp_entry() {
    local e=$1
    if [[ $e =~ ^[0-9]+$ ]]; then
        validate_port "$e"
        return $?
    elif [[ $e =~ ^[0-9]+:[0-9]+$ ]]; then
        local lo=${e%%:*} hi=${e##*:}
        validate_port "$lo" && validate_port "$hi" && (( lo < hi )) && return 0
    fi
    return 1
}

# ══════════════════════════════════════════════════════════════════
#  ИНТЕРАКТИВНЫЙ ВВОД
# ══════════════════════════════════════════════════════════════════

interactive_setup() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║       VPN Node Setup v2.1 — Настройка ВМ            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local iface ram_gb cpus
    iface=$(detect_interface)
    ram_gb=$(get_ram_gb)
    cpus=$(get_cpu_count)

    # Предрасчёт всех параметров
    local conntrack_max tcp_buf_max hashsize tw_buckets netdev_budget dev_weight txqueuelen
    conntrack_max=$(calc_conntrack_max "$ram_gb")
    tcp_buf_max=$(calc_tcp_buffers "$ram_gb")
    hashsize=$(calc_conntrack_hashsize "$conntrack_max")
    tw_buckets=$(calc_tw_buckets "$ram_gb")
    netdev_budget=$(calc_netdev_budget "$cpus")
    dev_weight=$(calc_dev_weight "$cpus")
    txqueuelen=$(calc_txqueuelen "$ram_gb")

    echo -e "${WHITE}Обнаружено:${NC}"
    echo -e "  Интерфейс:       ${GREEN}$iface${NC}"
    echo -e "  CPU:             ${GREEN}${cpus} ядер${NC}"
    echo -e "  RAM:             ${GREEN}${ram_gb} ГБ${NC}"
    echo ""
    echo -e "${WHITE}Будет применено (авто):${NC}"
    echo -e "  conntrack_max:   ${CYAN}$conntrack_max${NC}  (~$(( conntrack_max * 320 / 1024 / 1024 )) MB RAM)"
    echo -e "  hashsize:        ${CYAN}$hashsize${NC}  (ratio 1:4 — быстрый поиск)"
    echo -e "  TCP buf max:     ${CYAN}$(( tcp_buf_max / 1024 / 1024 )) MB${NC}"
    echo -e "  tw_buckets:      ${CYAN}$tw_buckets${NC}"
    echo -e "  netdev_budget:   ${CYAN}$netdev_budget${NC}"
    echo -e "  dev_weight:      ${CYAN}$dev_weight${NC}"
    echo -e "  txqueuelen:      ${CYAN}$txqueuelen${NC}"
    echo -e "  RPS mask:        ${CYAN}0x$(calc_rps_mask "$cpus")${NC}  ($cpus ядер)"
    echo ""

    # ── Порты VLESS Reality ──
    echo -e "${WHITE}Введите порты для VLESS Reality (через запятую):${NC}"
    echo -e "${YELLOW}  Пример: 443,8443,9443${NC}"
    read -rp "Порты: " VLESS_PORTS_INPUT

    VLESS_PORTS=()
    IFS=',' read -ra PORT_ARRAY <<< "$VLESS_PORTS_INPUT"
    for port in "${PORT_ARRAY[@]}"; do
        port=$(echo "$port" | tr -d ' ')
        if validate_port "$port"; then
            VLESS_PORTS+=("$port")
        else
            log_error "Невалидный порт: $port"
            exit 1
        fi
    done

    if [[ ${#VLESS_PORTS[@]} -eq 0 ]]; then
        log_error "Не указано ни одного порта"
        exit 1
    fi
    log_success "Порты VLESS: ${VLESS_PORTS[*]}"
    echo ""

    # ── UDP-порты Hysteria2 (опционально) ──
    echo -e "${WHITE}UDP-порты Hysteria2 (Enter = нет; через запятую, поддержка диапазона):${NC}"
    echo -e "${YELLOW}  Пример: 443  |  36712  |  20000:50000 (port hopping)${NC}"
    read -rp "UDP-порты: " HYSTERIA_PORTS_INPUT

    HYSTERIA_PORTS=()
    if [[ -n "$HYSTERIA_PORTS_INPUT" ]]; then
        IFS=',' read -ra HY_ARRAY <<< "$HYSTERIA_PORTS_INPUT"
        for p in "${HY_ARRAY[@]}"; do
            p=$(echo "$p" | tr -d ' ')
            if validate_udp_entry "$p"; then
                HYSTERIA_PORTS+=("$p")
            else
                log_error "Невалидный UDP-порт/диапазон: $p"
                exit 1
            fi
        done
        log_success "UDP Hysteria2: ${HYSTERIA_PORTS[*]}"
    fi
    echo ""

    # ── NODE_PORT (API Remnawave) ──
    echo -e "${WHITE}NODE_PORT для API Remnawave (Enter = 2222):${NC}"
    read -rp "NODE_PORT: " NODE_PORT_INPUT
    NODE_PORT=${NODE_PORT_INPUT:-2222}

    if ! validate_port "$NODE_PORT"; then
        log_error "Невалидный NODE_PORT: $NODE_PORT"
        exit 1
    fi
    echo ""

    # ── Master IP ──
    echo -e "${WHITE}IP панели Remnawave (ограничение доступа к NODE_PORT):${NC}"
    read -rp "IP панели: " MASTER_IP

    if ! validate_ip "$MASTER_IP"; then
        log_error "Невалидный IP: $MASTER_IP"
        exit 1
    fi
    log_success "NODE_PORT $NODE_PORT → только $MASTER_IP"
    echo ""

    # ── Prometheus ──
    echo -e "${WHITE}IP Prometheus для node_exporter (Enter = пропустить установку):${NC}"
    read -rp "IP Prometheus: " PROMETHEUS_IP

    if [[ -n "$PROMETHEUS_IP" ]] && ! validate_ip "$PROMETHEUS_IP"; then
        log_error "Невалидный IP: $PROMETHEUS_IP"
        exit 1
    fi

    # Порт node_exporter спрашиваем только если будем ставить
    NODE_EXPORTER_PORT="$NODE_EXPORTER_PORT_DEFAULT"
    if [[ -n "$PROMETHEUS_IP" ]]; then
        echo -e "${WHITE}Порт node_exporter (Enter = ${NODE_EXPORTER_PORT_DEFAULT}, VK Cloud):${NC}"
        echo -e "${YELLOW}  На обычных провайдерах ставь 9100; на VK Cloud — 9101${NC}"
        read -rp "Порт: " NE_PORT_INPUT
        NODE_EXPORTER_PORT=${NE_PORT_INPUT:-$NODE_EXPORTER_PORT_DEFAULT}
        if ! validate_port "$NODE_EXPORTER_PORT"; then
            log_error "Невалидный порт node_exporter: $NODE_EXPORTER_PORT"
            exit 1
        fi
    fi
    echo ""

    # ── Swap ──
    echo -e "${WHITE}Настроить swap? (y/n, Enter = y):${NC}"
    read -rp "Swap: " SWAP_INPUT
    SETUP_SWAP=true
    if [[ "$SWAP_INPUT" =~ ^[Nn]$ ]]; then
        SETUP_SWAP=false
    fi
    echo ""

    # ── Деплой remnanode ──
    echo -e "${WHITE}Создать docker-compose.yml и запустить remnanode? (y/n, Enter = n):${NC}"
    read -rp "Деплой remnanode: " DEPLOY_INPUT
    DEPLOY_REMNANODE=false
    SECRET_KEY=""
    if [[ "$DEPLOY_INPUT" =~ ^[Yy]$ ]]; then
        DEPLOY_REMNANODE=true
        echo -e "${WHITE}Введите SECRET_KEY из панели Remnawave:${NC}"
        read -rp "SECRET_KEY: " SECRET_KEY
        if [[ -z "$SECRET_KEY" ]]; then
            log_error "SECRET_KEY не может быть пустым"
            exit 1
        fi
        log_success "Remnanode будет развёрнут с NODE_PORT=$NODE_PORT"
    fi
    echo ""

    # ── Подтверждение ──
    echo -e "${CYAN}━━━ Итоговые настройки ━━━${NC}"
    echo ""
    echo -e "  Интерфейс:        ${GREEN}$iface${NC}  (txqueuelen → $txqueuelen)"
    echo -e "  CPU / RAM:        ${GREEN}${cpus} ядер / ${ram_gb} ГБ${NC}"
    echo -e "  VLESS порты:      ${GREEN}${VLESS_PORTS[*]}${NC}"
    if [[ ${#HYSTERIA_PORTS[@]} -gt 0 ]]; then
        echo -e "  Hysteria2 UDP:    ${GREEN}${HYSTERIA_PORTS[*]}${NC}"
    fi
    echo -e "  NODE_PORT:        ${GREEN}$NODE_PORT (только $MASTER_IP)${NC}"
    echo -e "  Prometheus:       ${GREEN}${PROMETHEUS_IP:-не установлен}${NC}"
    if [[ -n "$PROMETHEUS_IP" ]]; then
        echo -e "  node_exporter:    ${GREEN}v${NODE_EXPORTER_VERSION}, TLS, порт ${NODE_EXPORTER_PORT} (→ $PROMETHEUS_IP)${NC}"
    fi
    if [[ "$SETUP_SWAP" == "true" ]]; then
        echo -e "  Swap:             ${GREEN}$(calc_swap_size "$ram_gb")${NC}"
    else
        echo -e "  Swap:             ${YELLOW}пропущен${NC}"
    fi
    if [[ "$DEPLOY_REMNANODE" == "true" ]]; then
        echo -e "  Remnanode:        ${GREEN}будет развёрнут${NC}"
    else
        echo -e "  Remnanode:        ${YELLOW}пропущен${NC}"
    fi
    echo ""
    echo -e "  ${WHITE}── Kernel parameters ──${NC}"
    echo -e "  conntrack_max:    ${CYAN}$conntrack_max${NC}"
    echo -e "  conntrack hashsz: ${CYAN}$hashsize${NC}  (/etc/modprobe.d/)"
    echo -e "  tcp_established:  ${CYAN}600s${NC}  (дефолт 432000s — 5 дней!)"
    echo -e "  tcp_fin_wait:     ${CYAN}30s${NC}"
    echo -e "  tcp_time_wait:    ${CYAN}30s${NC}"
    echo -e "  udp_timeout:      ${CYAN}30s${NC}"
    echo -e "  tcp buf max:      ${CYAN}$(( tcp_buf_max / 1024 / 1024 )) MB${NC}"
    echo -e "  tw_buckets:       ${CYAN}$tw_buckets${NC}"
    echo -e "  netdev_budget:    ${CYAN}$netdev_budget${NC}"
    echo -e "  dev_weight:       ${CYAN}$dev_weight${NC}"
    echo -e "  RPS:              ${CYAN}0x$(calc_rps_mask "$cpus")${NC}"
    echo ""

    read -rp "Начать настройку? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        log_warning "Отменено"
        exit 0
    fi

    export IFACE="$iface"
    export RAM_GB="$ram_gb"
    export CPUS="$cpus"
}

# ══════════════════════════════════════════════════════════════════
#  УСТАНОВКА
# ══════════════════════════════════════════════════════════════════

step_system_update() {
    log_step "1/11 — Обновление системы"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    apt-get install -y -qq curl wget mc htop btop iftop logrotate fail2ban ufw \
        openssl tar ethtool \
        >/dev/null 2>&1
    log_success "Система обновлена, пакеты установлены"
}

step_docker() {
    log_step "2/11 — Docker"
    if command -v docker &>/dev/null; then
        log_success "Docker уже установлен: $(docker --version)"
    else
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        log_success "Docker установлен: $(docker --version)"
    fi
}

step_sysctl() {
    log_step "3/11 — Оптимизация ядра (sysctl)"

    local conntrack_max tcp_buf_max hashsize tw_buckets netdev_budget dev_weight
    conntrack_max=$(calc_conntrack_max "$RAM_GB")
    tcp_buf_max=$(calc_tcp_buffers "$RAM_GB")
    hashsize=$(calc_conntrack_hashsize "$conntrack_max")
    tw_buckets=$(calc_tw_buckets "$RAM_GB")
    netdev_budget=$(calc_netdev_budget "$CPUS")
    dev_weight=$(calc_dev_weight "$CPUS")

    # ── Загрузка модулей ─────────────────────────────────────────
    modprobe tcp_bbr 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true

    # ── conntrack hashsize через modprobe.d ──────────────────────
    # Нельзя через sysctl.conf — модуль грузится позже
    echo "options nf_conntrack hashsize=${hashsize}" > /etc/modprobe.d/nf_conntrack.conf
    # Применяем сразу если модуль уже загружен
    if [[ -f /sys/module/nf_conntrack/parameters/hashsize ]]; then
        echo "$hashsize" > /sys/module/nf_conntrack/parameters/hashsize
        log_info "conntrack hashsize применён сейчас: $hashsize"
    fi

    # ── Пометки для модулей ──────────────────────────────────────
    echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf
    echo "tcp_bbr" >> /etc/modules-load.d/conntrack.conf

    cat > /etc/sysctl.d/99-vpn-node.conf << EOF
# ── VPN Node Optimization ─────────────────────────────────────────
# Сгенерировано vpn-node-setup.sh v2.1 ($(date +%Y-%m-%d))
# Сервер: RAM=${RAM_GB}GB, CPU=${CPUS} cores
# ─────────────────────────────────────────────────────────────────

# ── BBR ───────────────────────────────────────────────────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Backlog & Connections ─────────────────────────────────────────
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.ip_local_port_range = 1024 65535
net.ipv4.tcp_max_tw_buckets = ${tw_buckets}
net.ipv4.tcp_max_orphans = 262144

# ── TCP Buffers ───────────────────────────────────────────────────
net.core.rmem_max = ${tcp_buf_max}
net.core.wmem_max = ${tcp_buf_max}
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.core.optmem_max = 65536
net.ipv4.tcp_rmem = 4096 1048576 ${tcp_buf_max}
net.ipv4.tcp_wmem = 4096 1048576 ${tcp_buf_max}

# ── UDP Buffers ───────────────────────────────────────────────────
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192

# ── TCP Behaviour ─────────────────────────────────────────────────
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
net.ipv4.tcp_syn_retries = 2
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_orphan_retries = 2
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_syncookies = 1

# ── Network Device ────────────────────────────────────────────────
net.core.netdev_budget = ${netdev_budget}
net.core.netdev_budget_usecs = 8000
net.core.dev_weight = ${dev_weight}

# ── Conntrack ─────────────────────────────────────────────────────
# hashsize задаётся в /etc/modprobe.d/nf_conntrack.conf = ${hashsize}
net.netfilter.nf_conntrack_max = ${conntrack_max}

# ── Conntrack Timeouts ────────────────────────────────────────────
# Дефолт tcp_established = 432000s (5 дней!) — критично снизить
net.netfilter.nf_conntrack_tcp_timeout_established = 600
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 15
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.netfilter.nf_conntrack_generic_timeout = 60
net.netfilter.nf_conntrack_icmp_timeout = 15

# ── File Descriptors ──────────────────────────────────────────────
fs.file-max = 2000000
fs.nr_open = 2000000

# ── VM ────────────────────────────────────────────────────────────
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF

    sysctl --system >/dev/null 2>&1
    log_success "sysctl применён: conntrack_max=$conntrack_max, hashsize=$hashsize, tcp_buf=$(( tcp_buf_max/1024/1024 ))MB"
    log_success "conntrack tcp_established timeout: 600s (было 432000s)"
}

step_limits() {
    log_step "4/11 — Лимиты (nofile, systemd)"

    cat > /etc/security/limits.d/99-vpn-node.conf << 'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

    mkdir -p /etc/systemd/system.conf.d/
    cat > /etc/systemd/system.conf.d/limits.conf << 'EOF'
[Manager]
DefaultLimitNOFILE=1048576
EOF

    # Убедиться что PAM подключает limits
    if ! grep -q pam_limits /etc/pam.d/common-session 2>/dev/null; then
        echo "session required pam_limits.so" >> /etc/pam.d/common-session
        log_info "pam_limits добавлен в common-session"
    fi

    systemctl daemon-reload
    log_success "nofile limits: 1048576"
}

step_rps() {
    log_step "5/11 — RPS + txqueuelen"

    local rps_mask queues_dir txqueuelen
    rps_mask=$(calc_rps_mask "$CPUS")
    txqueuelen=$(calc_txqueuelen "$RAM_GB")

    # ── txqueuelen ───────────────────────────────────────────────
    # Увеличение буфера передачи — до 10x на путях с RTT > 50ms
    ip link set "$IFACE" txqueuelen "$txqueuelen" 2>/dev/null || true
    log_info "txqueuelen $IFACE → $txqueuelen"

    # ── RPS ──────────────────────────────────────────────────────
    queues_dir="/sys/class/net/${IFACE}/queues"
    if [[ ! -d "$queues_dir" ]]; then
        log_warning "Не удалось найти queues для $IFACE — RPS пропущен"
    else
        local hw_queues
        hw_queues=$(ls -d "${queues_dir}"/rx-* 2>/dev/null | wc -l)

        local skip_rps=false
        if (( hw_queues > 1 )) && command -v ethtool &>/dev/null; then
            local combined
            combined=$(ethtool -l "$IFACE" 2>/dev/null | awk '/Combined:/{val=$2} END{print val+0}')
            if (( combined >= CPUS )); then
                log_success "Multiqueue NIC ($combined queues) — RPS не нужен"
                skip_rps=true
            fi
        fi

        if [[ "$skip_rps" == "false" ]]; then
            for rxdir in "${queues_dir}"/rx-*; do
                echo "$rps_mask" > "${rxdir}/rps_cpus" 2>/dev/null || true
                echo 4096 > "${rxdir}/rps_flow_cnt" 2>/dev/null || true
            done
            echo 32768 > /proc/sys/net/core/rps_sock_flow_entries
            log_success "RPS: mask=0x${rps_mask} на $IFACE ($CPUS ядер)"
        fi
    fi

    # ── Persistent через systemd ──────────────────────────────────
    cat > /etc/systemd/system/rps-tuning.service << EOF
[Unit]
Description=RPS + txqueuelen tuning for ${IFACE}
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c '\
    ip link set ${IFACE} txqueuelen ${txqueuelen}; \
    for rx in /sys/class/net/${IFACE}/queues/rx-*; do \
        echo ${rps_mask} > \$rx/rps_cpus 2>/dev/null || true; \
        echo 4096 > \$rx/rps_flow_cnt 2>/dev/null || true; \
    done; \
    echo 32768 > /proc/sys/net/core/rps_sock_flow_entries'

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable rps-tuning.service >/dev/null 2>&1
    log_success "RPS + txqueuelen персистентны через systemd"
}

step_swap() {
    if [[ "${SETUP_SWAP}" != "true" ]]; then
        log_step "6/11 — Swap (пропущен)"
        # swappiness применяем в любом случае
        sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
        return 0
    fi

    log_step "6/11 — Swap"

    if swapon --show | grep -q '/'; then
        log_success "Swap уже настроен: $(swapon --show --noheadings | awk '{print $1, $3}')"
        return 0
    fi

    local swap_size
    swap_size=$(calc_swap_size "$RAM_GB")

    fallocate -l "$swap_size" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    log_success "Swap: $swap_size, swappiness=10"
}

step_dns() {
    log_step "7/11 — DNS over TLS"

    cat > /etc/systemd/resolved.conf << 'EOF'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google
DNSOverTLS=yes
DNSSEC=allow-downgrade
EOF

    systemctl restart systemd-resolved
    log_success "DNS: Cloudflare + Google over TLS"
}

step_firewall() {
    log_step "8/11 — Firewall (UFW) + Fail2ban"

    ufw --force reset >/dev/null 2>&1
    ufw default deny incoming >/dev/null 2>&1
    ufw default allow outgoing >/dev/null 2>&1

    ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1

    for port in "${VLESS_PORTS[@]}"; do
        ufw allow "$port"/tcp comment 'VLESS Reality' >/dev/null 2>&1
    done

    if [[ ${#HYSTERIA_PORTS[@]} -gt 0 ]]; then
        for uport in "${HYSTERIA_PORTS[@]}"; do
            ufw allow "$uport"/udp comment 'Hysteria2' >/dev/null 2>&1
        done
        log_success "UFW: Hysteria2 UDP(${HYSTERIA_PORTS[*]})"
    fi

    ufw allow from "$MASTER_IP" to any port "$NODE_PORT" proto tcp comment 'Remnanode API' >/dev/null 2>&1

    if [[ -n "${PROMETHEUS_IP:-}" ]]; then
        ufw allow from "$PROMETHEUS_IP" to any port "${NODE_EXPORTER_PORT}" proto tcp \
            comment 'node_exporter (Prometheus)' >/dev/null 2>&1
        log_success "UFW: node_exporter $NODE_EXPORTER_PORT → только $PROMETHEUS_IP"
    fi

    ufw --force enable >/dev/null 2>&1
    log_success "UFW: SSH, VLESS(${VLESS_PORTS[*]}), NODE_PORT($NODE_PORT→$MASTER_IP)"

    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local 2>/dev/null || true
    systemctl enable fail2ban >/dev/null 2>&1
    systemctl restart fail2ban >/dev/null 2>&1
    log_success "Fail2ban: enabled"
}

step_node_exporter() {
    if [[ -z "${PROMETHEUS_IP:-}" ]]; then
        log_step "9/11 — node_exporter (пропущен — Prometheus IP не указан)"
        return 0
    fi

    log_step "9/11 — node_exporter v${NODE_EXPORTER_VERSION} (TLS)"

    # ── Архитектура ──────────────────────────────────────────────
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        armv7l)  arch="armv7" ;;
        *)
            log_error "Неизвестная архитектура: $(uname -m) — node_exporter пропущен"
            return 1
            ;;
    esac

    local ver="${NODE_EXPORTER_VERSION}"
    local pkg="node_exporter-${ver}.linux-${arch}"
    local base="https://github.com/prometheus/node_exporter/releases/download/v${ver}"
    local tmp
    tmp=$(mktemp -d)

    # ── Скачивание + проверка sha256 ─────────────────────────────
    log_info "Скачиваю ${pkg}.tar.gz..."
    if ! wget -q -O "${tmp}/${pkg}.tar.gz" "${base}/${pkg}.tar.gz"; then
        log_error "Не удалось скачать node_exporter — пропускаю"
        rm -rf "$tmp"
        return 1
    fi
    wget -q -O "${tmp}/sha256sums.txt" "${base}/sha256sums.txt" || true
    if [[ -s "${tmp}/sha256sums.txt" ]]; then
        ( cd "$tmp" && grep " ${pkg}.tar.gz\$" sha256sums.txt | sha256sum -c - >/dev/null 2>&1 ) \
            && log_success "sha256 проверен" \
            || { log_error "sha256 mismatch — установка прервана"; rm -rf "$tmp"; return 1; }
    else
        log_warning "Не удалось получить sha256sums.txt — пропускаю проверку"
    fi

    # ── Установка бинаря ─────────────────────────────────────────
    tar xzf "${tmp}/${pkg}.tar.gz" -C "$tmp"
    install -m 0755 "${tmp}/${pkg}/node_exporter" /usr/local/bin/node_exporter
    rm -rf "$tmp"
    log_success "Бинарь: /usr/local/bin/node_exporter ($(node_exporter --version 2>&1 | head -1 | awk '{print $3}'))"

    # ── Self-signed TLS сертификат ───────────────────────────────
    mkdir -p "$NODE_EXPORTER_DIR"
    local server_ip
    server_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
    if [[ ! -f "${NODE_EXPORTER_DIR}/node_exporter.crt" ]]; then
        openssl req -x509 -nodes -newkey rsa:2048 \
            -keyout "${NODE_EXPORTER_DIR}/node_exporter.key" \
            -out "${NODE_EXPORTER_DIR}/node_exporter.crt" \
            -days 3650 -subj "/CN=$(hostname)" \
            ${server_ip:+-addext "subjectAltName=IP:${server_ip}"} >/dev/null 2>&1
        chmod 600 "${NODE_EXPORTER_DIR}/node_exporter.key"
        chmod 644 "${NODE_EXPORTER_DIR}/node_exporter.crt"
        log_success "Self-signed cert сгенерирован (CN=$(hostname)${server_ip:+, SAN IP:${server_ip}})"
    else
        log_info "Сертификат уже существует — пропускаю генерацию"
    fi

    # ── web-config.yml (exporter-toolkit TLS) ────────────────────
    cat > "${NODE_EXPORTER_DIR}/web-config.yml" << EOF
tls_server_config:
  cert_file: ${NODE_EXPORTER_DIR}/node_exporter.crt
  key_file: ${NODE_EXPORTER_DIR}/node_exporter.key
  min_version: TLS12
EOF

    # ── systemd unit (запуск от root) ────────────────────────────
    cat > /etc/systemd/system/node_exporter.service << EOF
[Unit]
Description=Prometheus Node Exporter (TLS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/node_exporter \\
    --web.listen-address=:${NODE_EXPORTER_PORT} \\
    --web.config.file=${NODE_EXPORTER_DIR}/web-config.yml \\
    --collector.systemd \\
    --collector.processes
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable node_exporter >/dev/null 2>&1
    systemctl restart node_exporter

    sleep 2
    if systemctl is-active --quiet node_exporter; then
        log_success "node_exporter активен: https://${server_ip:-<IP>}:${NODE_EXPORTER_PORT}/metrics"
        log_info "Prometheus scrape: scheme=https, tls_config.insecure_skip_verify=true"
    else
        log_warning "node_exporter не запустился — проверь: journalctl -u node_exporter -n 30"
    fi
}

step_logrotate() {
    log_step "10/11 — Директории и логирование"

    mkdir -p /opt/remnanode /var/log/remnanode

    cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    daily
    maxsize 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF

    log_success "Директории, logrotate"
}

step_remnanode() {
    if [[ "${DEPLOY_REMNANODE}" != "true" ]]; then
        log_step "11/11 — Remnanode (пропущен)"
        return 0
    fi

    log_step "11/11 — Деплой Remnanode"

    local REMNANODE_DIR="/opt/remnanode"
    mkdir -p "${REMNANODE_DIR}"
    # Директории для сертификатов и сокетов (монтируются в контейнер)
    mkdir -p "${CERT_DIR}"
    mkdir -p "${SOCKET_DIR}"

    # ── Скачиваем zapret.dat ─────────────────────────────────────
    log_info "Скачиваю zapret.dat..."
    mkdir -p /opt/remnawave/xray/share
    wget -q -O /opt/remnawave/xray/share/zapret.dat \
        https://github.com/kutovoys/ru_gov_zapret/releases/latest/download/zapret.dat \
        && log_success "zapret.dat скачан" \
        || log_warning "Не удалось скачать zapret.dat — продолжаю без него"

    # ── Создаём docker-compose.yml ───────────────────────────────
    # volumes:
    #   /dev/shm     — общая tmpfs для unix-сокетов (HAProxy ↔ Xray)
    #   /opt/nginx   — сертификаты для Hysteria2 / Reality own-cert (ro)
    cat > "${REMNANODE_DIR}/docker-compose.yml" << EOF
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: remnawave/node:latest
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    environment:
      - NODE_PORT=${NODE_PORT}
      - SECRET_KEY=${SECRET_KEY}
    volumes:
      - /var/log/remnanode:/var/log/remnanode
      - /opt/remnawave/xray/share/zapret.dat:/usr/local/bin/zapret.dat
      - ${SOCKET_DIR}:${SOCKET_DIR}
      - ${CERT_DIR}:${CERT_DIR}:ro
EOF

    log_success "docker-compose.yml → ${REMNANODE_DIR}/docker-compose.yml"
    log_info "Volumes: сокеты ${SOCKET_DIR} (rw), сертификаты ${CERT_DIR} (ro)"

    # ── Pull и запуск ────────────────────────────────────────────
    log_info "Pulling remnawave/node:latest..."
    cd "${REMNANODE_DIR}"
    docker compose pull -q
    log_success "Image pulled"

    log_info "Запускаю remnanode..."
    docker compose up -d
    sleep 3

    if docker ps --format '{{.Names}}' | grep -q '^remnanode$'; then
        log_success "remnanode запущен и работает"
    else
        log_warning "remnanode контейнер не найден в docker ps — проверьте логи:"
        log_warning "  docker compose -f ${REMNANODE_DIR}/docker-compose.yml logs"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  DEPLOY ONLY — только развернуть remnanode без оптимизации
# ══════════════════════════════════════════════════════════════════

deploy_only_mode() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   Быстрый деплой Remnanode (без оптимизации ВМ)     ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    # ── Docker ───────────────────────────────────────────────────
    if ! command -v docker &>/dev/null; then
        log_info "Docker не найден, устанавливаю..."
        apt-get update -qq
        apt-get install -y -qq curl wget >/dev/null 2>&1
        curl -fsSL https://get.docker.com | sh >/dev/null 2>&1
        systemctl enable docker >/dev/null 2>&1
        log_success "Docker установлен: $(docker --version)"
    else
        log_success "Docker: $(docker --version)"
    fi

    # ── NODE_PORT ────────────────────────────────────────────────
    echo -e "${WHITE}NODE_PORT для API Remnawave (Enter = 2222):${NC}"
    read -rp "NODE_PORT: " NODE_PORT_INPUT
    NODE_PORT=${NODE_PORT_INPUT:-2222}

    if ! validate_port "$NODE_PORT"; then
        log_error "Невалидный NODE_PORT: $NODE_PORT"
        exit 1
    fi

    # ── SECRET_KEY ───────────────────────────────────────────────
    echo -e "${WHITE}Введите SECRET_KEY из панели Remnawave:${NC}"
    read -rp "SECRET_KEY: " SECRET_KEY
    if [[ -z "$SECRET_KEY" ]]; then
        log_error "SECRET_KEY не может быть пустым"
        exit 1
    fi
    echo ""

    # ── Деплой ───────────────────────────────────────────────────
    DEPLOY_REMNANODE=true
    mkdir -p /opt/remnanode /var/log/remnanode

    # ── Logrotate для remnanode ──────────────────────────────────
    cat > /etc/logrotate.d/remnanode << 'EOF'
/var/log/remnanode/*.log {
    daily
    maxsize 50M
    rotate 5
    compress
    missingok
    notifempty
    copytruncate
}
EOF
    log_success "Logrotate для remnanode настроен"

    step_remnanode

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║       ✅ Remnanode развёрнут и запущен!              ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${YELLOW}Управление:${NC}"
    echo -e "  docker compose -f /opt/remnanode/docker-compose.yml logs -f"
    echo -e "  docker compose -f /opt/remnanode/docker-compose.yml restart"
    echo ""
    echo -e "${YELLOW}⚠️  Оптимизация ВМ не применялась.${NC}"
    echo -e "${YELLOW}   Для полной настройки запустите скрипт без --deploy-only${NC}"
    echo ""

    read -rp "Перезагрузить сервер сейчас? (y/n): " REBOOT_CONFIRM
    if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Перезагрузка через 5 секунд..."
        sleep 5
        reboot
    else
        log_warning "Контейнер уже работает, ребут не обязателен"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  APPLY ONLY — только sysctl на работающий сервер
# ══════════════════════════════════════════════════════════════════

apply_only_mode() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║   VPN Node Tuning — применение на работающий сервер ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo -e "${NC}"

    local iface ram_gb cpus
    iface=$(detect_interface)
    ram_gb=$(get_ram_gb)
    cpus=$(get_cpu_count)

    export IFACE="$iface"
    export RAM_GB="$ram_gb"
    export CPUS="$cpus"

    local conntrack_max tcp_buf_max hashsize tw_buckets netdev_budget dev_weight txqueuelen
    conntrack_max=$(calc_conntrack_max "$ram_gb")
    tcp_buf_max=$(calc_tcp_buffers "$ram_gb")
    hashsize=$(calc_conntrack_hashsize "$conntrack_max")
    tw_buckets=$(calc_tw_buckets "$ram_gb")
    netdev_budget=$(calc_netdev_budget "$cpus")
    dev_weight=$(calc_dev_weight "$cpus")
    txqueuelen=$(calc_txqueuelen "$ram_gb")

    echo -e "${WHITE}Сервер: ${GREEN}$(hostname)${NC}  RAM=${GREEN}${ram_gb}GB${NC}  CPU=${GREEN}${cpus}${NC}  iface=${GREEN}${iface}${NC}"
    echo ""

    log_step "Применение sysctl + conntrack"
    step_sysctl

    log_step "Применение RPS + txqueuelen"
    step_rps

    log_step "Применение limits"
    step_limits

    log_step "Swap (swappiness)"
    # Только swappiness, не создаём swap
    sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         ✅ Применено на работающий сервер!           ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Проверка:${NC}"
    echo -e "  sysctl net.ipv4.tcp_congestion_control"
    echo -e "  sysctl net.netfilter.nf_conntrack_max"
    echo -e "  sysctl net.netfilter.nf_conntrack_tcp_timeout_established"
    echo -e "  cat /sys/module/nf_conntrack/parameters/hashsize"
    echo -e "  cat /sys/class/net/${iface}/queues/rx-0/rps_cpus"
    echo -e "  ip link show ${iface} | grep txqueuelen"
    echo ""
    echo -e "${YELLOW}⚠️  Перезагрузка НЕ требуется — всё применено сейчас.${NC}"
    echo -e "${YELLOW}   Настройки сохранены и переживут reboot.${NC}"
}

# ══════════════════════════════════════════════════════════════════
#  ИТОГИ
# ══════════════════════════════════════════════════════════════════

print_summary() {
    local conntrack_max
    conntrack_max=$(calc_conntrack_max "$RAM_GB")
    local hashsize
    hashsize=$(calc_conntrack_hashsize "$conntrack_max")

    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║              ✅ Настройка завершена!                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "${WHITE}Что сделано:${NC}"
    echo -e "  ✅ Система обновлена"
    echo -e "  ✅ Docker установлен"
    echo -e "  ✅ BBR + fq включены"
    echo -e "  ✅ conntrack_max=$conntrack_max, hashsize=$hashsize (ratio 1:4)"
    echo -e "  ✅ tcp_established timeout: 600s (было 432000s)"
    echo -e "  ✅ TCP/UDP буферы оптимизированы"
    echo -e "  ✅ netdev_budget/dev_weight по CPU"
    echo -e "  ✅ txqueuelen → $(calc_txqueuelen "$RAM_GB")"
    echo -e "  ✅ RPS: 0x$(calc_rps_mask "$CPUS") ($CPUS ядер)"
    echo -e "  ✅ nofile limits: 1048576"
    if [[ "${SETUP_SWAP}" == "true" ]]; then
        echo -e "  ✅ Swap: $(calc_swap_size "$RAM_GB"), swappiness=10"
    fi
    echo -e "  ✅ DNS over TLS"
    echo -e "  ✅ UFW + Fail2ban"
    if [[ ${#HYSTERIA_PORTS[@]} -gt 0 ]]; then
        echo -e "  ✅ UFW: Hysteria2 UDP (${HYSTERIA_PORTS[*]})"
    fi
    if [[ -n "${PROMETHEUS_IP:-}" ]]; then
        echo -e "  ✅ node_exporter v${NODE_EXPORTER_VERSION} (TLS, порт ${NODE_EXPORTER_PORT})"
    fi
    echo -e "  ✅ Logrotate"
    if [[ "${DEPLOY_REMNANODE}" == "true" ]]; then
        echo -e "  ✅ Remnanode развёрнут и запущен"
        echo -e "     docker-compose.yml → /opt/remnanode/"
        echo -e "     zapret.dat → /opt/remnawave/xray/share/"
        echo -e "     volumes: сокеты ${SOCKET_DIR} (rw), сертификаты ${CERT_DIR} (ro)"
    fi
    echo ""
    echo -e "${YELLOW}Управление remnanode:${NC}"
    echo -e "  docker compose -f /opt/remnanode/docker-compose.yml logs -f"
    echo -e "  docker compose -f /opt/remnanode/docker-compose.yml restart"
    echo ""
    echo -e "${YELLOW}Проверка после ребута:${NC}"
    echo -e "  sysctl net.ipv4.tcp_congestion_control            # → bbr"
    echo -e "  sysctl net.netfilter.nf_conntrack_max              # → ${conntrack_max}"
    echo -e "  sysctl net.netfilter.nf_conntrack_tcp_timeout_established  # → 600"
    echo -e "  cat /sys/module/nf_conntrack/parameters/hashsize   # → ${hashsize}"
    echo -e "  cat /sys/class/net/${IFACE}/queues/rx-0/rps_cpus   # → $(calc_rps_mask "$CPUS")"
    echo -e "  ulimit -n                                           # → 1048576"
    if [[ -n "${PROMETHEUS_IP:-}" ]]; then
        echo -e "  systemctl status node_exporter                     # → active"
        echo -e "  curl -sk https://localhost:${NODE_EXPORTER_PORT}/metrics | head  # → метрики"
    fi
    echo ""

    read -rp "Перезагрузить сервер сейчас? (y/n): " REBOOT_CONFIRM
    if [[ "$REBOOT_CONFIRM" =~ ^[Yy]$ ]]; then
        log_info "Перезагрузка через 5 секунд..."
        sleep 5
        reboot
    else
        log_warning "Не забудьте перезагрузить: reboot"
    fi
}

# ══════════════════════════════════════════════════════════════════
#  MAIN
# ══════════════════════════════════════════════════════════════════

main() {
    # ── Парсинг аргументов ───────────────────────────────────────
    while [[ $# -gt 0 ]]; do
        case $1 in
            --deploy-only)
                DEPLOY_ONLY=true
                shift
                ;;
            --apply-only)
                APPLY_ONLY=true
                shift
                ;;
            *)
                shift
                ;;
        esac
    done

    check_root
    check_os

    # Режим deploy-only — только развернуть remnanode
    if [[ "${DEPLOY_ONLY}" == "true" ]]; then
        deploy_only_mode
        exit 0
    fi

    # Режим apply-only — только sysctl на работающий сервер
    if [[ "${APPLY_ONLY}" == "true" ]]; then
        apply_only_mode
        exit 0
    fi

    # Полная установка
    interactive_setup

    step_system_update
    step_docker
    step_sysctl
    step_limits
    step_rps
    step_swap
    step_dns
    step_firewall
    step_node_exporter
    step_logrotate
    step_remnanode

    print_summary
}

main "$@"
