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
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_step "Начинаем установку MTProto Proxy"
print_step "Информация будет сохраняться в $INFO_FILE"

# Создание рабочей директории
mkdir -p /opt/vps-infra
cd /opt/vps-infra

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
    xxd \
    net-tools \
    openssl \
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
# MTProto Proxy
# ==============================================

print_step "Настройка MTProto Proxy для Telegram..."

# Проверка порта
if check_port 8443; then
    # Генерация секрета
    MT_SECRET="ee$(head -c 15 /dev/urandom | xxd -ps)"
    
    # Создание docker-compose.yml
    cat > /opt/vps-infra/docker-compose.yml <<EOF
services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: telegram-proxy
    restart: always
    ports:
      - "8443:443"
    environment:
      - SECRET=$MT_SECRET
    volumes:
      - proxy-data:/data
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"
    healthcheck:
      test: ["CMD", "nc", "-z", "localhost", "8443"]
      interval: 30s
      timeout: 10s
      retries: 3

volumes:
  proxy-data:
EOF

    # Запуск контейнера
    cd /opt/vps-infra
    docker compose up -d
    
    # Проверка запуска
    sleep 5
    if docker ps | grep -q telegram-proxy; then
        print_success "MTProto Proxy запущен на порту 8443"
        
        {
            echo ""
            echo "=== Telegram MTProto Proxy ==="
            echo "Сервер: $SERVER_IP"
            echo "Порт: 8443"
            echo "Секрет: $MT_SECRET"
            echo "Ссылка для подключения:"
            echo "tg://proxy?server=$SERVER_IP&port=8443&secret=$MT_SECRET"
            echo ""
        } >> "$INFO_FILE"
    else
        print_error "MTProto Proxy не запустился"
    fi
else
    print_warning "Порт 8443 занят, пропускаем установку MTProto"
fi

# ==============================================
# Настройка firewall
# ==============================================

print_step "Настройка firewall..."

if command -v ufw &> /dev/null; then
    # Базовые правила
    ufw default deny incoming
    ufw default allow outgoing
    
    # Открытие портов
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    
    # Включение firewall
    ufw --force enable > /dev/null 2>&1
    
    print_success "Firewall настроен"
    ufw status numbered | head -n 5
else
    print_warning "UFW не найден, пропускаем настройку firewall"
fi

# ==============================================
# Настройка автоматического обновления
# ==============================================

print_step "Настройка автоматического обновления..."

cat > /etc/cron.daily/vps-updates <<'EOF'
#!/bin/bash
apt-get update
apt-get upgrade -y
apt-get autoremove -y

# Обновление Docker контейнеров
cd /opt/vps-infra && docker compose pull 2>/dev/null
cd /opt/vps-infra && docker compose up -d 2>/dev/null

# Очистка старых образов
docker system prune -f 2>/dev/null
EOF

chmod +x /etc/cron.daily/vps-updates
print_success "Автоматическое обновление настроено"

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
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Вывод информации
if [ -f "$INFO_FILE" ]; then
    cat "$INFO_FILE"
fi

echo ""
echo -e "${YELLOW}📋 Доступные команды:${NC}"
echo -e "  ${GREEN}vps-info${NC} - показать информацию о сервере"
echo -e "  ${GREEN}docker ps${NC} - список запущенных контейнеров"
echo -e "  ${GREEN}cd /opt/vps-infra && docker compose logs${NC} - логи MTProto"
echo ""
echo -e "${YELLOW}📁 Полная информация сохранена в:${NC} $INFO_FILE"
echo ""

# Проверка статуса сервисов
print_step "Проверка статуса сервисов..."
if docker ps 2>/dev/null | grep -q telegram-proxy; then
    print_success "MTProto Proxy: работает"
else
    print_warning "MTProto Proxy: не запущен"
fi

print_step "Готово! Сервер настроен и готов к работе."
