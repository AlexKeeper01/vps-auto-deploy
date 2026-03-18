#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PURPLE='\033[0;35m'
NC='\033[0m'

# Функции для вывода
print_step() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} ${GREEN}➜${NC} $1"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_info() {
    echo -e "${CYAN}[i]${NC} $1"
}

# Обработка ошибок
trap 'print_error "Ошибка на строке $LINENO. Выполняю откат..."; cleanup' ERR

# Функция очистки при ошибке
cleanup() {
    print_warning "Произошла ошибка. Выполняю откат..."
    
    # Останавливаем контейнеры если они были запущены
    if [ -f "/opt/vps-infra/docker-compose.yml" ]; then
        cd /opt/vps-infra && docker compose down 2>/dev/null || true
    fi
    
    # Удаляем временные файлы
    rm -f /tmp/get-docker.sh 2>/dev/null || true
    
    print_error "Установка прервана. Проверьте логи выше."
    exit 1
}

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться с правами root (используйте sudo)"
   exit 1
fi

# Проверка версии Ubuntu
if ! command -v lsb_release &> /dev/null; then
    print_error "lsb_release не найден. Убедитесь, что это Ubuntu/Debian система"
    exit 1
fi

UBUNTU_VERSION=$(lsb_release -rs)
if [[ "$UBUNTU_VERSION" < "20.04" ]]; then
    print_error "Требуется Ubuntu 20.04 или новее"
    exit 1
fi

# Проверка доступности портов
check_port() {
    if command -v netstat &> /dev/null; then
        if netstat -tuln 2>/dev/null | grep -q ":$1 "; then
            print_warning "Порт $1 уже используется"
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$1 "; then
            print_warning "Порт $1 уже используется"
            return 1
        fi
    fi
    return 0
}

# Получение IP сервера
get_server_ip() {
    local ip=""
    ip=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null)
    if [ -z "$ip" ]; then
        ip=$(curl -4 -s --max-time 5 icanhazip.com 2>/dev/null)
    fi
    if [ -z "$ip" ]; then
        ip=$(hostname -I | awk '{print $1}')
    fi
    echo "$ip"
}

# Создание информационного файла
INFO_FILE="/root/vps-info.txt"
SERVER_IP=$(get_server_ip)

# Создаем файл с информацией
{
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              VPS INFRASTRUCTURE INFORMATION                  ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo "Создано: $(date)"
    echo "Хост: $(hostname)"
    echo "IP сервера: $SERVER_IP"
    echo "Ubuntu: $UBUNTU_VERSION"
    echo ""
} > "$INFO_FILE"

# Очистка экрана
clear
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              УСТАНОВКА MTProto PROXY                         ║"
echo "║              (Оптимизированная версия)                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_step "Начинаем установку MTProto Proxy"
print_step "Информация будет сохраняться в $INFO_FILE"

# Создание рабочей директории
mkdir -p /opt/vps-infra
cd /opt/vps-infra

# ==============================================
# Настройка системы для минимальной задержки
# ==============================================

print_step "Настройка системы для минимальной задержки..."

# Настройка часового пояса
timedatectl set-timezone Europe/Moscow 2>/dev/null || print_warning "Не удалось установить часовой пояс"

# Создание swap если мало RAM
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM" -lt 1024 ]; then
    print_step "Мало RAM ($TOTAL_RAM MB), создаю swap..."
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        print_success "Swap файл создан"
    fi
fi

# Оптимизация сетевых параметров для низкой задержки
print_step "Оптимизация сетевых параметров..."

cat >> /etc/sysctl.conf <<EOF

# Оптимизация сети для низкой задержки
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.ipv4.tcp_rmem = 4096 87380 134217728
net.ipv4.tcp_wmem = 4096 65536 134217728
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_sack = 1
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_fack = 1
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.udp_mem = 65536 131072 262144
EOF

# Применяем настройки
sysctl -p > /dev/null 2>&1
print_success "Сетевые параметры оптимизированы"

# Настройка планировщика для сетевых очередей
if command -v ethtool &> /dev/null; then
    for iface in $(ls /sys/class/net/ | grep -v lo); do
        ethtool -G $iface rx 4096 tx 4096 2>/dev/null || true
    done
fi

# Обновление системы
print_step "Обновляем список пакетов..."
apt-get update -qq

print_step "Устанавливаем необходимые пакеты..."
apt-get install -y -qq \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    wget \
    ufw \
    xxd \
    net-tools \
    openssl \
    netcat-openbsd \
    ethtool \
    irqbalance \
    haveged \
    tuned \
    htop \
    iotop \
    iftop \
    nethogs > /dev/null 2>&1

# Установка и настройка tuned для производительности
systemctl enable irqbalance haveged 2>/dev/null
systemctl start irqbalance haveged 2>/dev/null

print_success "Система настроена"

# ==============================================
# Установка Docker с оптимизациями
# ==============================================

print_step "Проверяем Docker..."

if ! command -v docker &> /dev/null; then
    print_step "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm -f /tmp/get-docker.sh
    
    if ! command -v docker &> /dev/null; then
        print_error "Docker не установился"
        exit 1
    fi
    
    # Настройка Docker для лучшей производительности
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<EOF
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "storage-opts": [
    "overlay2.override_kernel_check=true"
  ],
  "userland-proxy": false,
  "ip-forward": true,
  "iptables": true,
  "mtu": 1450
}
EOF
    
    systemctl restart docker
    print_success "Docker установлен и оптимизирован"
else
    print_success "Docker уже установлен"
fi

# Проверка Docker Compose
if ! command -v docker-compose &> /dev/null; then
    print_step "Устанавливаем Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose 2>/dev/null
    chmod +x /usr/local/bin/docker-compose
    print_success "Docker Compose установлен"
else
    print_success "Docker Compose уже установлен"
fi

# ==============================================
# MTProto Proxy с оптимизациями
# ==============================================

print_step "Настройка оптимизированного MTProto Proxy для Telegram..."

# Проверка порта
if check_port 8443; then
    # Генерация секрета (можно использовать fake TLS для лучшей маскировки)
    print_info "Выберите тип секрета:"
    echo "1) Обычный секрет (стандартный)"
    echo "2) Fake TLS секрет (рекомендуется для обхода блокировок)"
    read -p "Выберите опцию (1/2): " secret_type
    
    if [ "$secret_type" = "2" ]; then
        # Генерация Fake TLS секрета (начинается с ee)
        MT_SECRET="ee$(head -c 15 /dev/urandom | xxd -ps)"
        print_info "Создан Fake TLS секрет"
    else
        # Обычный секрет
        MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
    fi
    
    # Создание оптимизированного docker-compose.yml
    cat > /opt/vps-infra/docker-compose.yml <<EOF
services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: telegram-proxy
    restart: always
    network_mode: host
    environment:
      - SECRET=$MT_SECRET
      - WORKERS=2
    volumes:
      - proxy-config:/data
    logging:
      driver: "json-file"
      options:
        max-size: "5m"
        max-file: "2"
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    cap_add:
      - NET_ADMIN
      - SYS_NICE
    sysctls:
      - net.core.rmem_max=134217728
      - net.core.wmem_max=134217728
      - net.ipv4.tcp_rmem=4096 87380 134217728
      - net.ipv4.tcp_wmem=4096 65536 134217728
      - net.core.netdev_max_backlog=5000

volumes:
  proxy-config:
EOF

    # Запуск контейнера
    cd /opt/vps-infra
    docker compose up -d
    
    # Проверка запуска и оптимизация контейнера
    sleep 5
    if docker ps | grep -q telegram-proxy; then
        print_success "MTProto Proxy запущен"
        
        # Дополнительные оптимизации для контейнера
        PROXY_PID=$(docker inspect -f '{{.State.Pid}}' telegram-proxy 2>/dev/null)
        if [ -n "$PROXY_PID" ] && [ "$PROXY_PID" != "0" ]; then
            # Приоритет процесса
            renice -n -5 -p $PROXY_PID 2>/dev/null || true
            
            # Привязка к ядрам CPU (если есть)
            CPU_CORES=$(nproc)
            if [ "$CPU_CORES" -gt 1 ]; then
                taskset -cp 0-$((CPU_CORES-1)) $PROXY_PID 2>/dev/null || true
            fi
        fi
        
        {
            echo ""
            echo "=== Telegram MTProto Proxy (Оптимизированная версия) ==="
            echo "Сервер: $SERVER_IP"
            echo "Порт: 8443"
            echo "Секрет: $MT_SECRET"
            echo "Тип: $([ "$secret_type" = "2" ] && echo "Fake TLS (рекомендуется)" || echo "Обычный")"
            echo ""
            echo "Ссылки для подключения:"
            echo "Обычная: tg://proxy?server=$SERVER_IP&port=8443&secret=$MT_SECRET"
            
            if [ "$secret_type" = "2" ]; then
                echo "Fake TLS (для обхода блокировок):"
                echo "tg://proxy?server=$SERVER_IP&port=8443&secret=$MT_SECRET"
            fi
            
            echo ""
            echo "Статистика пинга:"
            echo "ping -c 5 $SERVER_IP"
            echo ""
        } >> "$INFO_FILE"
        
        # Тест пинга
        print_step "Тестирование задержки..."
        PING_RESULT=$(ping -c 3 $SERVER_IP 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
        if [ -n "$PING_RESULT" ]; then
            print_success "Средний пинг: ${PING_RESULT}ms"
            {
                echo "Средний пинг до сервера: ${PING_RESULT}ms"
            } >> "$INFO_FILE"
        fi
    else
        print_error "MTProto Proxy не запустился"
    fi
else
    print_warning "Порт 8443 занят, пропускаем установку MTProto"
fi

# ==============================================
# Настройка firewall с QoS
# ==============================================

print_step "Настройка firewall и QoS..."

if command -v ufw &> /dev/null; then
    # Базовые правила
    ufw default deny incoming
    ufw default allow outgoing
    
    # Открытие портов
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    
    # Приоритезация трафика (QoS)
    if command -v tc &> /dev/null; then
        # Создаем скрипт для QoS
        cat > /etc/network/if-up.d/qos <<'EOF'
#!/bin/bash
# Приоритезация трафика MTProto
tc qdisc add dev eth0 root handle 1: htb default 30
tc class add dev eth0 parent 1: classid 1:1 htb rate 1000mbit
tc class add dev eth0 parent 1:1 classid 1:10 htb rate 500mbit prio 0
tc class add dev eth0 parent 1:1 classid 1:20 htb rate 300mbit prio 1
tc class add dev eth0 parent 1:1 classid 1:30 htb rate 200mbit prio 2

# Приоритет для MTProto трафика (порт 8443)
tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 \
    match ip dport 8443 0xffff flowid 1:10
tc filter add dev eth0 protocol ip parent 1:0 prio 1 u32 \
    match ip sport 8443 0xffff flowid 1:10
EOF
        chmod +x /etc/network/if-up.d/qos
    fi
    
    # Включение firewall
    ufw --force enable > /dev/null 2>&1
    
    print_success "Firewall настроен с QoS приоритезацией"
    ufw status numbered | head -n 5
else
    print_warning "UFW не найден, пропускаем настройку firewall"
fi

# ==============================================
# Настройка мониторинга производительности
# ==============================================

print_step "Настройка мониторинга производительности..."

# Скрипт для мониторинга задержки
cat > /usr/local/bin/check-latency <<'EOF'
#!/bin/bash
echo "=== Мониторинг задержки MTProto Proxy ==="
echo "Пинг до сервера:"
ping -c 5 $(hostname -I | awk '{print $1}') | tail -1

echo ""
echo "Состояние сетевых очередей:"
netstat -s | grep -i "retransmit\|loss"

echo ""
echo "Загрузка CPU:"
top -bn1 | grep "Cpu(s)"

echo ""
echo "Использование памяти:"
free -h

echo ""
echo "Активные соединения MTProto:"
ss -tunap | grep 8443 | wc -l
EOF

chmod +x /usr/local/bin/check-latency

# Настройка автоматического обновления с мониторингом
print_step "Настройка автоматического обновления..."

cat > /etc/cron.daily/vps-updates <<'EOF'
#!/bin/bash
# Обновление системы
apt-get update
apt-get upgrade -y
apt-get autoremove -y

# Обновление Docker контейнеров
cd /opt/vps-infra && docker compose pull 2>/dev/null
cd /opt/vps-infra && docker compose up -d 2>/dev/null

# Очистка старых образов
docker system prune -f 2>/dev/null

# Логирование задержки
echo "$(date): $(ping -c 3 localhost | tail -1)" >> /var/log/latency.log
EOF

chmod +x /etc/cron.daily/vps-updates

# Скрипт для просмотра статистики задержки
cat > /usr/local/bin/latency-stats <<'EOF'
#!/bin/bash
if [ -f "/var/log/latency.log" ]; then
    echo "=== Статистика задержки ==="
    tail -20 /var/log/latency.log
else
    echo "Лог задержки еще не создан"
fi
EOF

chmod +x /usr/local/bin/latency-stats

print_success "Мониторинг производительности настроен"

# ==============================================
# Создание скрипта для быстрого доступа к информации
# ==============================================

cat > /usr/local/bin/vps-info <<'EOF'
#!/bin/bash
if [ -f "/root/vps-info.txt" ]; then
    cat /root/vps-info.txt
else
    echo "Файл информации не найден"
fi
echo ""
echo "Docker контейнеры:"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Docker не запущен"
echo ""
echo "Статистика производительности:"
echo "CPU: $(top -bn1 | grep "Cpu(s)" | awk '{print $2}')% used"
echo "RAM: $(free -h | awk '/^Mem:/ {print $3"/"$2}')"
echo "Активные соединения: $(ss -tunap | grep 8443 | wc -l)"
EOF

chmod +x /usr/local/bin/vps-info
print_success "Создан скрипт для просмотра информации: vps-info"

# ==============================================
# Финальный вывод
# ==============================================

clear
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!                    ║"
echo "║              (Оптимизированная версия)                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Вывод информации
if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
fi

echo ""
echo -e "${YELLOW}📋 Доступные команды:${NC}"
echo -e "  ${GREEN}vps-info${NC} - показать информацию о сервере"
echo -e "  ${GREEN}check-latency${NC} - проверить текущую задержку"
echo -e "  ${GREEN}latency-stats${NC} - показать статистику задержки"
echo -e "  ${GREEN}docker ps${NC} - список запущенных контейнеров"
echo -e "  ${GREEN}cd /opt/vps-infra && docker compose logs${NC} - логи MTProto"
echo -e "  ${GREEN}htop${NC} - мониторинг ресурсов в реальном времени"
echo ""
echo -e "${YELLOW}📁 Полная информация сохранена в:${NC} $INFO_FILE"
echo ""

# Проверка статуса сервисов
print_step "Проверка статуса сервисов..."
if docker ps 2>/dev/null | grep -q telegram-proxy; then
    print_success "MTProto Proxy: работает"
    
    # Финальный тест задержки
    FINAL_PING=$(ping -c 2 $SERVER_IP 2>/dev/null | tail -1 | awk -F '/' '{print $5}')
    if [ -n "$FINAL_PING" ]; then
        print_success "Текущая задержка: ${FINAL_PING}ms"
    fi
else
    print_warning "MTProto Proxy: не запущен"
fi

# Проверка оптимизаций
print_step "Проверка оптимизаций..."
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    print_success "BBR congestion control: включен"
fi

if systemctl is-active haveged >/dev/null 2>&1; then
    print_success "haveged (энтропия): работает"
fi

print_step "Готово! Сервер оптимизирован для минимальной задержки."
