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

# Открываем порт 80
if command -v ufw &> /dev/null; then
    ufw allow 80/tcp comment 'HTTP'
fi

# Скачиваем последнюю версию (правильный URL)
print_step "Скачиваем 3X-UI..."
wget -O /tmp/x-ui-linux-amd64.tar.gz https://github.com/MHSanaei/3x-ui/releases/latest/download/x-ui-linux-amd64.tar.gz

if [ $? -ne 0 ]; then
    print_error "Не удалось скачать 3X-UI"
    exit 1
fi

print_step "✅ Скачивание успешно"

# Распаковываем
cd /tmp
tar -xzf x-ui-linux-amd64.tar.gz
chmod +x x-ui/x-ui x-ui/bin/xray-linux-* x-ui/x-ui.sh

# Создаем директорию для установки
mkdir -p /usr/local/x-ui/bin

# Копируем файлы
cp -r x-ui/* /usr/local/x-ui/
cp x-ui/x-ui.sh /usr/bin/x-ui
cp -f x-ui/x-ui.service /etc/systemd/system/

# Генерируем случайные данные
SERVER_IP=$(curl -4 -s ifconfig.me)
XUI_PORT=$(shuf -i 20000-60000 -n 1)
XUI_USER=$(head -c 8 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 10)
XUI_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)
WEB_PATH=$(head -c 16 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16)

# Настраиваем конфиг
cat > /usr/local/x-ui/bin/config.json <<EOF
{
  "port": $XUI_PORT,
  "username": "$XUI_USER",
  "password": "$XUI_PASSWORD",
  "webBasePath": "$WEB_PATH",
  "ssl": {
    "enabled": false,
    "port": 443
  }
}
EOF

# Запускаем сервис
systemctl daemon-reload
systemctl enable x-ui
systemctl start x-ui

# Ждем запуска
sleep 3

# Открываем порты
if command -v ufw &> /dev/null; then
    ufw allow $XUI_PORT/tcp comment '3X-UI Panel'
    ufw allow 8448/tcp comment 'V2Ray Port'
fi

# Записываем информацию
{
    echo "=== 3X-UI (V2Ray VPN) ==="
    echo "🌐 Веб-интерфейс: http://$SERVER_IP:$XUI_PORT/$WEB_PATH"
    echo "🔑 Логин: $XUI_USER"
    echo "🔑 Пароль: $XUI_PASSWORD"
    echo ""
    echo "📡 НАСТРОЙКА КЛИЕНТА:"
    echo "   1. Зайди в панель по ссылке выше"
    echo "   2. Перейди в 'Входящие подключения'"
    echo "   3. Нажми '➕ Добавить'"
    echo "   4. Выбери VLESS + XTLS + Reality"
    echo "   5. Укажи порт: 8448"
    echo "   6. SNI: www.microsoft.com"
    echo "   7. Нажми 'Сгенерировать' и сохрани"
    echo ""
} >> $INFO_FILE

print_step "✅ 3X-UI успешно установлен на порту $XUI_PORT"

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
