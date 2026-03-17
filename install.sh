#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_step() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} ${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться с правами root (используйте sudo)"
   exit 1
fi

INFO_FILE="/root/vps-info.txt"
{
    echo "=== VPS INFRASTRUCTURE INFORMATION ==="
    echo "Создано: $(date)"
    echo "Хост: $(hostname)"
    echo "IP сервера: $(curl -s ifconfig.me)"
    echo "========================================"
    echo ""
} > $INFO_FILE

print_step "Начинаем установку VPS Infrastructure"
print_step "Информация будет сохраняться в $INFO_FILE"

UBUNTU_VERSION=$(lsb_release -rs)
print_step "Обнаружена Ubuntu версии $UBUNTU_VERSION"

if [[ "$UBUNTU_VERSION" < "20.04" ]]; then
    print_error "Требуется Ubuntu 20.04 или новее"
    exit 1
fi

print_step "Обновляем список пакетов..."
apt-get update

print_step "Устанавливаем необходимые пакеты..."
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    curl \
    software-properties-common \
    git \
    wget \
    ufw \
    xxd \
    net-tools \
    sqlite3

if ! command -v docker &> /dev/null; then
    print_step "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    print_step "Docker установлен"
else
    print_step "Docker уже установлен"
fi

if ! command -v docker-compose &> /dev/null; then
    print_step "Устанавливаем Docker Compose..."
    curl -L "https://github.com/docker/compose/releases/latest/download/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    print_step "Docker Compose установлен"
else
    print_step "Docker Compose уже установлен"
fi

print_step "Базовая подготовка завершена!"

# ==============================================
# MTProto Proxy
# ==============================================

print_step "Настраиваем MTProto Proxy для Telegram..."

MT_SECRET=$(head -c 16 /dev/urandom | xxd -ps)
SERVER_IP=$(curl -4 -s ifconfig.me)

mkdir -p /opt/vps-infra

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

volumes:
  proxy-data:
EOF

cd /opt/vps-infra
docker-compose up -d

{
    echo "=== Telegram MTProto Proxy ==="
    echo "Сервер: $SERVER_IP"
    echo "Порт: 8443"
    echo "Секрет: $MT_SECRET"
    echo "Ссылка для подключения:"
    echo "tg://proxy?server=$SERVER_IP&port=8443&secret=$MT_SECRET"
    echo ""
} >> $INFO_FILE

print_step "MTProto Proxy установлен на порту 8443"

# ==============================================
# 3X-UI (V2Ray Panel) - Простая установка
# ==============================================

print_step "Настраиваем 3X-UI (V2Ray)..."

# Открываем порт 80 (нужен для процесса установки)
if command -v ufw &> /dev/null; then
    print_step "Открываем порт 80 для установщика 3X-UI..."
    ufw allow 80/tcp comment 'HTTP for 3X-UI setup'
    # Не включаем --force, чтобы не перезапускать фаервол сейчас
fi

# Удаляем предыдущую установку, если была
if systemctl list-units --full -all | grep -Fq "x-ui.service"; then
    systemctl stop x-ui
    systemctl disable x-ui
    rm -rf /usr/local/x-ui
    rm -rf /etc/x-ui
fi

# Скачиваем скрипт установки
wget -O /tmp/xui-install.sh https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh
chmod +x /tmp/xui-install.sh

# Устанавливаем expect (если еще не установлен)
apt-get install -y expect

print_step "Запускаем автоматическую установку 3X-UI..."

# Создаем expect скрипт для автоматической установки
cat > /tmp/xui-install.exp <<'EOF'
#!/usr/bin/expect
set timeout 120
set output_file [open /tmp/xui-install.log w]

spawn /tmp/xui-install.sh

expect {
    "Do you want to continue" { 
        send "y\r"
        puts $output_file "Answered: y to continue"
        exp_continue
    }
    "Would you like to customize the Panel Port settings" {
        send "n\r"
        puts $output_file "Answered: n to port customization"
        exp_continue
    }
    "Please press any key to continue" {
        send "\r"
        puts $output_file "Pressed any key"
        exp_continue
    }
    "Panel Installation Complete" {
        puts $output_file "Installation complete"
        exp_continue
    }
    timeout {
        puts $output_file "Timeout occurred"
        exit 1
    }
    eof {
        puts $output_file "EOF reached"
        close $output_file
    }
}
EOF

chmod +x /tmp/xui-install.exp

# Запускаем expect скрипт
/tmp/xui-install.exp

# Ждем немного для завершения
sleep 3

print_step "Установка 3X-UI завершена"

# Показываем результаты установки
echo ""
print_step "=== РЕЗУЛЬТАТ УСТАНОВКИ 3X-UI ==="
echo ""

# Извлекаем данные из лога
if [ -f "/tmp/xui-install.log" ]; then
    echo "📋 Лог установки:"
    grep -A 15 "Panel Installation Complete" /tmp/xui-install.log || echo "   Секция завершения не найдена в логе"
fi

# Проверяем конфиг
if [ -f "/usr/local/x-ui/bin/config.json" ]; then
    echo ""
    echo "🔧 Конфигурация из файла:"
    grep -o '"port":[0-9]*' /usr/local/x-ui/bin/config.json | head -1
    grep -o '"username":"[^"]*"' /usr/local/x-ui/bin/config.json | head -1
    echo "   (пароль зашифрован в конфиге)"
fi

# Проверяем порт через netstat
XUI_PORT=$(netstat -tulpn 2>/dev/null | grep x-ui | grep LISTEN | head -1 | awk '{print $4}' | cut -d':' -f2)
if [ ! -z "$XUI_PORT" ]; then
    echo ""
    echo "🌐 Панель запущена на порту: $XUI_PORT"
    echo "   URL: http://$SERVER_IP:$XUI_PORT"
fi

echo ""

# Открываем порты в firewall
if command -v ufw &> /dev/null; then
    print_step "Открываем порты для 3X-UI..."
    if [ ! -z "$XUI_PORT" ]; then
        ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    fi
    ufw allow 8448/tcp comment 'V2Ray Port'
fi

# ==============================================
# Настройка firewall
# ==============================================

if command -v ufw &> /dev/null; then
    print_step "Настраиваем фаервол..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    ufw --force enable
    print_step "Фаервол настроен"
fi

# ==============================================
# Финальный вывод
# ==============================================

print_step "========================================="
print_step "УСТАНОВКА ЗАВЕРШЕНА!"
print_step "========================================="
echo ""

cat $INFO_FILE

echo ""
print_step "✅ Вся информация сохранена в файле: $INFO_FILE"
