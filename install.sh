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
    net-tools

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

print_step "Настраиваем MTProto Proxy для Telegram..."

SECRET=$(head -c 16 /dev/urandom | xxd -ps)
SERVER_IP=$(curl -4 -s ifconfig.me)

mkdir -p /opt/vps-infra

cat > /opt/vps-infra/docker-compose.yml <<EOF
version: '3'

services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: telegram-proxy
    restart: always
    ports:
      - "8443:443"
    environment:
      - SECRET=$SECRET
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
    echo "Секрет: $SECRET"
    echo "Ссылка для подключения:"
    echo "tg://proxy?server=$SERVER_IP&port=8443&secret=$SECRET"
    echo ""
} >> $INFO_FILE

print_step "MTProto Proxy установлен на порту 8443"

print_step "Настраиваем WireGuard VPN..."

# Пароль для веб-интерфейса
WG_PASSWORD=$(head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 12)

# Сначала удаляем последнюю строку с volumes из файла (чтобы добавить её позже)
sed -i '$d' /opt/vps-infra/docker-compose.yml

# Добавляем сервис WireGuard (без новой секции volumes)
cat >> /opt/vps-infra/docker-compose.yml <<EOF

  wireguard:
    image: weejewel/wg-easy:latest
    container_name: wireguard
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    restart: always
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    environment:
      - WG_HOST=${SERVER_IP}
      - PASSWORD=${WG_PASSWORD}
      - WG_PORT=51820
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      - WG_PERSISTENT_KEEPALIVE=25
    volumes:
      - wireguard-data:/etc/wireguard

volumes:
  proxy-data:
  wireguard-data:
EOF

# Перезапускаем docker-compose
cd /opt/vps-infra
docker-compose up -d

# Открываем порты в firewall
if command -v ufw &> /dev/null; then
    print_step "Открываем порты для WireGuard..."
    ufw allow 51820/udp comment 'WireGuard'
    ufw allow 51821/tcp comment 'WireGuard Web UI'
fi

# Записываем информацию о WireGuard
{
    echo "=== WireGuard VPN ==="
    echo "Веб-интерфейс: http://$SERVER_IP:51821"
    echo "Пароль: $WG_PASSWORD"
    echo "Порт WireGuard: 51820/udp"
    echo "Для подключения:"
    echo "1. Зайдите в веб-интерфейс по ссылке выше"
    echo "2. Создайте нового клиента (New Client)"
    echo "3. Скачайте конфиг или отсканируйте QR-код"
    echo ""
} >> $INFO_FILE

print_step "WireGuard VPN установлен на порту 51821"

if command -v ufw &> /dev/null; then
    print_step "Настраиваем фаервол..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 8443/tcp comment 'MTProto Proxy'
    ufw --force enable
    print_step "Фаервол настроен, порт 8443 открыт"
fi

print_step "========================================="
print_step "УСТАНОВКА ЗАВЕРШЕНА!"
print_step "========================================="
echo ""

cat $INFO_FILE

echo ""
print_step "Вся информация сохранена в файле: $INFO_FILE"
