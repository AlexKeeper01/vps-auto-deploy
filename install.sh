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

# Создаём docker-compose только для MTProto
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
# 3X-UI (V2Ray Panel)
# ==============================================

print_step "Настраиваем 3X-UI (V2Ray)..."

# Генерируем случайные логин/пароль для панели
XUI_USER="admin"
XUI_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)
XUI_PORT=$(shuf -i 10000-65000 -n 1)  # Случайный порт для панели

# Устанавливаем 3X-UI
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << EOF
$XUI_PORT
$XUI_USER
$XUI_PASSWORD
$XUI_PASSWORD
EOF

# Открываем порты в firewall
if command -v ufw &> /dev/null; then
    print_step "Открываем порты для 3X-UI..."
    ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    ufw allow 8448/tcp comment 'V2Ray VLESS'  # Порт для подключений
fi

# Ждем запуска панели
sleep 5

# Получаем информацию о панели
XUI_INFO=$(/usr/local/x-ui/x-ui setting -show 2>/dev/null || echo "")

# Записываем информацию о 3X-UI
{
    echo "=== 3X-UI (V2Ray) ==="
    echo "Веб-интерфейс: http://$SERVER_IP:$XUI_PORT"
    echo "Логин: $XUI_USER"
    echo "Пароль: $XUI_PASSWORD"
    echo ""
    echo "🔧 Как настроить клиента:"
    echo "1. Зайдите в веб-интерфейс по ссылке выше"
    echo "2. Нажмите '➕ Добавить' → выберите протокол (рекомендую VLESS + XTLS + Reality)"
    echo "3. Настройте:"
    echo "   - Порт: 8448 (или любой свободный)"
    echo "   - SNI: www.microsoft.com (или любой популярный сайт)"
    echo "   - Нажмите 'Сгенерировать' для ключей"
    echo "4. Сохраните и получите ссылку/QR-код для подключения"
    echo ""
    echo "📱 Клиенты для телефона:"
    echo "   Android: V2rayNG, NekoBox"
    echo "   iOS: Streisand, FoXray, V2Box"
    echo ""
} >> $INFO_FILE

print_step "3X-UI (V2Ray) установлен на порту $XUI_PORT"

# ==============================================
# Настройка firewall
# ==============================================

if command -v ufw &> /dev/null; then
    print_step "Настраиваем фаервол..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    ufw allow 8448/tcp comment 'V2Ray'
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
print_step "Вся информация сохранена в файле: $INFO_FILE"
