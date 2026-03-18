#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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
    if [ -f "/opt/telemt/docker-compose.yml" ]; then
        cd /opt/telemt && docker compose down 2>/dev/null || true
    fi
    
    # Удаляем временные файлы
    rm -f /tmp/get-docker.sh 2>/dev/null || true
    rm -f /tmp/telemt-*.tar.gz 2>/dev/null || true
    
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
            return 1
        fi
    elif command -v ss &> /dev/null; then
        if ss -tuln | grep -q ":$1 "; then
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

# Генерация случайного порта
generate_port() {
    while : ; do
        PORT=$((RANDOM % 64511 + 1024))
        if check_port $PORT; then
            echo $PORT
            return 0
        fi
    done
}

# Создание информационного файла
INFO_FILE="/root/telemt-info.txt"
SERVER_IP=$(get_server_ip)
PROXY_PORT=$(generate_port)
TLS_DOMAIN="www.google.com"  # Можно заменить на другой популярный сайт

# Создаем файл с информацией
{
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              TELEMT PROXY INFORMATION                        ║"
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
echo "║              УСТАНОВKA TELEMT PROXY                          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_step "Начинаем установку Telemt Proxy"
print_step "Информация будет сохраняться в $INFO_FILE"

# Создание рабочей директории
mkdir -p /opt/telemt
cd /opt/telemt

# ==============================================
# Настройка системы
# ==============================================

print_step "Настройка системы..."

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
    net-tools \
    openssl \
    jq \
    netcat-openbsd > /dev/null 2>&1

print_success "Система настроена"

# ==============================================
# Установка Docker
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
    print_success "Docker установлен"
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
# Настройка Telemt
# ==============================================

print_step "Настройка Telemt Proxy для Telegram..."

# Генерация секрета
TELEMT_SECRET=$(openssl rand -hex 16)
print_success "Сгенерирован секретный ключ"

# Выбор домена для маскировки
echo ""
print_info "Выберите домен для маскировки трафика (рекомендуется популярный сайт):"
echo "  1) www.google.com"
echo "  2) www.cloudflare.com"
echo "  3) www.microsoft.com"
echo "  4) www.github.com"
echo "  5) Ввести свой домен"
read -p "Ваш выбор (1-5): " domain_choice

case $domain_choice in
    1) TLS_DOMAIN="www.google.com" ;;
    2) TLS_DOMAIN="www.cloudflare.com" ;;
    3) TLS_DOMAIN="www.microsoft.com" ;;
    4) TLS_DOMAIN="www.github.com" ;;
    5) 
        read -p "Введите домен (например: example.com): " custom_domain
        TLS_DOMAIN=$custom_domain
        ;;
    *) TLS_DOMAIN="www.google.com" ;;
esac

print_success "Выбран домен маскировки: $TLS_DOMAIN"

# Создание конфигурационного файла telemt.toml
cat > /opt/telemt/telemt.toml <<EOF
[general]
[general.modes]
tls = true

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[censorship]
tls_domain = "$TLS_DOMAIN"

[access.users]
user1 = "$TELEMT_SECRET"
EOF

print_success "Конфигурационный файл создан"

# Создание docker-compose.yml для Telemt
cat > /opt/telemt/docker-compose.yml <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt-proxy
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    ports:
      - "$PROXY_PORT:443/tcp"
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
EOF

print_success "Docker Compose файл создан"

# Запуск контейнера
print_step "Запускаем Telemt контейнер..."
cd /opt/telemt
docker compose up -d

# Проверка запуска
sleep 5
if docker ps | grep -q telemt-proxy; then
    print_success "Telemt Proxy запущен на порту $PROXY_PORT"
    
    # Получение ссылки через API
    sleep 2
    PROXY_LINK=$(curl -s http://127.0.0.1:9091/v1/users | jq -r '.users[0].link // empty')
    
    if [ -z "$PROXY_LINK" ]; then
        # Формируем ссылку вручную если API не ответил
        PROXY_LINK="tg://proxy?server=$SERVER_IP&port=$PROXY_PORT&secret=$TELEMT_SECRET"
    fi
    
    {
        echo ""
        echo "=== Telemt Proxy ==="
        echo "Сервер: $SERVER_IP"
        echo "Порт: $PROXY_PORT"
        echo "Секрет: $TELEMT_SECRET"
        echo "Домен маскировки: $TLS_DOMAIN"
        echo ""
        echo "📱 Ссылка для подключения:"
        echo "$PROXY_LINK"
        echo ""
        echo "🔧 Команды для управления:"
        echo "  Просмотр логов: cd /opt/telemt && docker compose logs -f"
        echo "  Перезапуск: cd /opt/telemt && docker compose restart"
        echo "  Остановка: cd /opt/telemt && docker compose down"
        echo "  Обновление: cd /opt/telemt && docker compose pull && docker compose up -d"
        echo ""
    } >> "$INFO_FILE"
else
    print_error "Telemt Proxy не запустился"
    docker compose logs
    exit 1
fi

# ==============================================
# Настройка firewall
# ==============================================

print_step "Настройка firewall..."

if command -v ufw &> /dev/null; then
    # Базовые правила
    ufw --force reset > /dev/null 2>&1
    ufw default deny incoming
    ufw default allow outgoing
    
    # Открытие портов
    ufw allow 22/tcp comment 'SSH'
    ufw allow $PROXY_PORT/tcp comment 'Telemt Proxy'
    
    # Включение firewall с подтверждением
    echo "y" | ufw enable > /dev/null 2>&1
    
    print_success "Firewall настроен. Открыты порты: 22, $PROXY_PORT"
    ufw status numbered | head -n 5
else
    print_warning "UFW не найден, пропускаем настройку firewall"
fi

# ==============================================
# Настройка автоматического обновления
# ==============================================

print_step "Настройка автоматического обновления..."

cat > /etc/cron.daily/telemt-updates <<'EOF'
#!/bin/bash
# Обновление системы
apt-get update
apt-get upgrade -y
apt-get autoremove -y

# Обновление Telemt контейнера
if [ -d "/opt/telemt" ]; then
    cd /opt/telemt
    docker compose pull 2>/dev/null
    docker compose up -d 2>/dev/null
fi

# Очистка старых образов Docker
docker system prune -f 2>/dev/null
EOF

chmod +x /etc/cron.daily/telemt-updates
print_success "Автоматическое обновление настроено"

# ==============================================
# Создание скриптов для управления
# ==============================================

# Скрипт для просмотра информации
cat > /usr/local/bin/telemt-info <<'EOF'
#!/bin/bash
if [ -f "/root/telemt-info.txt" ]; then
    cat /root/telemt-info.txt
else
    echo "Файл информации не найден"
fi
echo ""
echo "Telemt статус:"
docker ps --filter "name=telemt-proxy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || echo "Telemt не запущен"
EOF

# Скрипт для просмотра логов
cat > /usr/local/bin/telemt-logs <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose logs -f
EOF

# Скрипт для перезапуска
cat > /usr/local/bin/telemt-restart <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose restart
echo "Telemt перезапущен"
EOF

# Скрипт для остановки
cat > /usr/local/bin/telemt-stop <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose down
echo "Telemt остановлен"
EOF

# Скрипт для запуска
cat > /usr/local/bin/telemt-start <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose up -d
echo "Telemt запущен"
EOF

chmod +x /usr/local/bin/telemt-*
print_success "Созданы скрипты управления: telemt-{info,logs,restart,stop,start}"

# ==============================================
# Финальный вывод
# ==============================================

clear
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              УСТАНОВКА TELEMT УСПЕШНО ЗАВЕРШЕНА!             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Вывод информации
if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
fi

echo ""
echo -e "${YELLOW}📋 Доступные команды:${NC}"
echo -e "  ${GREEN}telemt-info${NC}    - показать информацию о прокси"
echo -e "  ${GREEN}telemt-logs${NC}    - просмотр логов в реальном времени"
echo -e "  ${GREEN}telemt-restart${NC} - перезапустить прокси"
echo -e "  ${GREEN}telemt-stop${NC}    - остановить прокси"
echo -e "  ${GREEN}telemt-start${NC}   - запустить прокси"
echo -e "  ${GREEN}docker ps${NC}      - список всех контейнеров"
echo ""
echo -e "${YELLOW}📁 Полная информация сохранена в:${NC} $INFO_FILE"
echo ""

# Проверка статуса
print_step "Проверка статуса сервисов..."
if docker ps 2>/dev/null | grep -q telemt-proxy; then
    print_success "Telemt Proxy: работает (порт $PROXY_PORT)"
    
    # Показываем ссылку еще раз
    echo ""
    print_info "📱 Ссылка для подключения (скопируйте в Telegram):"
    echo -e "${GREEN}$PROXY_LINK${NC}"
else
    print_warning "Telemt Proxy: не запущен"
fi

echo ""
print_step "Готово! Сервер настроен и готов к работе."
