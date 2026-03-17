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

print_step "Устанавливаем 3X-UI VPN..."

# Открываем порт 80 (нужен для установки)
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp comment 'HTTP for setup'
fi

# Скачиваем и запускаем официальный установщик
print_step "Запускаем официальный установщик 3X-UI..."
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) << EOF
y
n
2

n

EOF

print_step "Установка завершена, собираем данные..."

# Ждем, пока все запустится
sleep 10

# Получаем IP сервера
SERVER_IP=$(curl -4 -s ifconfig.me)

# Пытаемся найти порт, логин и пароль
# Сначала ищем в логе установки
if [ -f "/tmp/x-ui-install.log" ]; then
    XUI_PORT=$(grep -oP 'Port: \K\d+' /tmp/x-ui-install.log | head -1)
    XUI_USER=$(grep -oP 'Username: \K\S+' /tmp/x-ui-install.log | head -1)
    XUI_PASSWORD=$(grep -oP 'Password: \K\S+' /tmp/x-ui-install.log | head -1)
    WEB_PATH=$(grep -oP 'WebBasePath: \K\S+' /tmp/x-ui-install.log | head -1)
fi

# Если не нашли в логе, смотрим через netstat
if [ -z "$XUI_PORT" ]; then
    XUI_PORT=$(netstat -tulpn 2>/dev/null | grep x-ui | grep LISTEN | head -1 | awk '{print $4}' | awk -F: '{print $NF}')
fi

# Если порт нашли, открываем его
if [ ! -z "$XUI_PORT" ]; then
    if command -v ufw &> /dev/null; then
        ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    fi
fi

# Открываем стандартный порт для клиентов (можно будет настроить позже)
if command -v ufw &> /dev/null; then
    ufw allow 8448/tcp comment 'V2Ray Clients'
fi

# Записываем всё, что нашли (или хотя бы то, что знаем)
{
    echo "=== 3X-UI (V2Ray VPN) ==="
    echo "🌐 Веб-интерфейс: http://$SERVER_IP:${XUI_PORT:-порт неизвестен}${WEB_PATH:-}"
    echo "🔑 Логин: ${XUI_USER:-admin}"
    echo "🔑 Пароль: ${XUI_PASSWORD:-admin}"
    echo ""
    echo "📡 Информация для подключения клиентов:"
    echo "   1. Зайди в панель по ссылке выше"
    echo "   2. Перейди в 'Входящие подключения' → '➕ Добавить'"
    echo "   3. Выбери протокол (VLESS + XTLS + Reality)"
    echo "   4. Укажи порт: 8448 (или любой свободный)"
    echo "   5. Нажми 'Сгенерировать' и сохрани"
    echo ""
} >> $INFO_FILE

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
