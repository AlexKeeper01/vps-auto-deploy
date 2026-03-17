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
    sqlite3 \
    expect \
    jq

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
# 3X-UI (V2Ray Panel) - Полностью автоматическая установка
# ==============================================

print_step "Настраиваем 3X-UI (V2Ray)..."

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

# Создаем временный файл для лога установки
TEMP_LOG=$(mktemp)

print_step "Запускаем установку 3X-UI (установщик сам сгенерирует данные)..."

# Запускаем установку с автоматическим ответом "n" на вопрос о кастомизации порта
/usr/bin/expect << 'EOF' > $TEMP_LOG 2>&1
set timeout 120
spawn /tmp/xui-install.sh
expect {
    "Do you want to continue" { send "y\r"; exp_continue }
    "Would you like to customize the Panel Port settings" { send "n\r"; exp_continue }
    eof
}
EOF

# Ждем завершения установки
sleep 5

print_step "Анализируем данные установки..."

# Извлекаем данные из лога установки
XUI_INFO=$(grep -A 20 "Panel Installation Complete" $TEMP_LOG)

# Парсим данные
XUI_USER=$(echo "$XUI_INFO" | grep "Username:" | awk '{print $2}' | tr -d '\r' | head -1)
XUI_PASSWORD=$(echo "$XUI_INFO" | grep "Password:" | awk '{print $2}' | tr -d '\r' | head -1)
XUI_PORT=$(echo "$XUI_INFO" | grep "Port:" | awk '{print $2}' | tr -d '\r' | head -1)
WEB_PATH=$(echo "$XUI_INFO" | grep "WebBasePath:" | awk '{print $2}' | tr -d '\r' | head -1)
ACCESS_URL=$(echo "$XUI_INFO" | grep "Access URL:" | awk '{print $3}' | tr -d '\r' | head -1)

# Если не нашли в логе, пробуем из конфига
if [ -z "$XUI_PORT" ] && [ -f "/usr/local/x-ui/bin/config.json" ]; then
    XUI_PORT=$(grep -o '"port":[0-9]*' /usr/local/x-ui/bin/config.json | head -1 | grep -o '[0-9]*')
    XUI_USER=$(grep -o '"username":"[^"]*"' /usr/local/x-ui/bin/config.json | head -1 | cut -d'"' -f4)
    XUI_PASSWORD=$(grep -o '"password":"[^"]*"' /usr/local/x-ui/bin/config.json | head -1 | cut -d'"' -f4)
    WEB_PATH=$(grep -o '"webBasePath":"[^"]*"' /usr/local/x-ui/bin/config.json | head -1 | cut -d'"' -f4)
    ACCESS_URL="http://$SERVER_IP:$XUI_PORT$WEB_PATH"
fi

# Проверяем, запущен ли сервис
if systemctl is-active --quiet x-ui; then
    print_step "3X-UI успешно установлен"
else
    print_warning "3X-UI не запустился автоматически, пробуем запустить..."
    systemctl start x-ui
    sleep 2
fi

# Открываем порты в firewall
if command -v ufw &> /dev/null; then
    print_step "Открываем порты для 3X-UI..."
    ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    ufw allow 8448/tcp comment 'V2Ray Port'
fi

# Записываем информацию о 3X-UI
{
    echo "=== 3X-UI (V2Ray VPN) ==="
    echo "🔧 ДАННЫЕ СГЕНЕРИРОВАНЫ УСТАНОВЩИКОМ:"
    echo ""
    echo "🌐 ВЕБ-ИНТЕРФЕЙС УПРАВЛЕНИЯ:"
    if [ ! -z "$ACCESS_URL" ]; then
        echo "   URL: $ACCESS_URL"
    else
        echo "   URL: http://$SERVER_IP:$XUI_PORT$WEB_PATH"
    fi
    echo "   Логин: $XUI_USER"
    echo "   Пароль: $XUI_PASSWORD"
    echo "   Порт: $XUI_PORT"
    if [ ! -z "$WEB_PATH" ] && [ "$WEB_PATH" != "null" ] && [ "$WEB_PATH" != "/" ]; then
        echo "   Секретный путь: $WEB_PATH"
    fi
    echo ""
    echo "📡 НАСТРОЙКА КЛИЕНТА (VLESS + XTLS + Reality):"
    echo "   1. Зайдите в веб-интерфейс по ссылке выше"
    echo "   2. Перейдите в раздел 'Входящие подключения' (Inbounds)"
    echo "   3. Нажмите '➕ Добавить'"
    echo "   4. Выберите протокол: VLESS + XTLS + Reality"
    echo "   5. Настройте параметры:"
    echo "      - Порт: 8448 (или любой свободный)"
    echo "      - SNI: www.microsoft.com (или любой популярный сайт)"
    echo "      - Нажмите 'Сгенерировать' для ключей"
    echo "   6. Сохраните и получите ссылку для клиента"
    echo ""
    echo "📱 КЛИЕНТЫ ДЛЯ ТЕЛЕФОНА:"
    echo "   Android: V2rayNG, NekoBox (скачать с официального сайта)"
    echo "   iOS: Streisand, FoXray, V2Box (в App Store)"
    echo ""
    echo "⚠️ ВАЖНО: Эти данные были сгенерированы автоматически!"
    echo "   Сохраните их в надежном месте, они больше нигде не появятся."
    echo ""
} >> $INFO_FILE

print_step "3X-UI (V2Ray) установлен"

# ==============================================
# Настройка firewall
# ==============================================

if command -v ufw &> /dev/null; then
    print_step "Настраиваем фаервол..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    ufw allow 8448/tcp comment 'V2Ray Port'
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
print_step "📋 Скопируйте эти данные и сохраните в надежном месте!"
print_step "🌐 Для входа в панель 3X-UI используйте ссылку из файла выше"
