#!/bin/bash

# ==============================================
# VPS Infrastructure Installer для Ubuntu
# ==============================================

set -e  # Прерывать выполнение при любой ошибке

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция для вывода сообщений
print_step() {
    echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} ${GREEN}$1${NC}"
}

print_error() {
    echo -e "${RED}[ОШИБКА]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"
}

# Проверка, что скрипт запущен от root или с sudo
if [[ $EUID -ne 0 ]]; then
   print_error "Этот скрипт должен запускаться с правами root (используйте sudo)"
   exit 1
fi

# Создаём файл для информации
INFO_FILE="/root/vps-infra-info.txt"
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

# Проверяем версию Ubuntu
UBUNTU_VERSION=$(lsb_release -rs)
print_step "Обнаружена Ubuntu версии $UBUNTU_VERSION"

if [[ "$UBUNTU_VERSION" < "20.04" ]]; then
    print_error "Требуется Ubuntu 20.04 или новее"
    exit 1
fi

# Обновляем пакеты
print_step "Обновляем список пакетов..."
apt-get update

# Устанавливаем необходимые пакеты
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

# Устанавливаем Docker
if ! command -v docker &> /dev/null; then
    print_step "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com -o get-docker.sh
    sh get-docker.sh
    print_step "Docker установлен"
else
    print_step "Docker уже установлен"
fi

# Устанавливаем Docker Compose
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
# Установка MTProto Proxy для Telegram
# ==============================================

print_step "Настраиваем MTProto Proxy для Telegram..."

# Генерируем секретный ключ
SECRET=$(head -c 16 /dev/urandom | xxd -ps)
SERVER_IP=$(curl -s ifconfig.me)

# Создаём директорию для конфигов
mkdir -p /opt/vps-infra

# Создаём docker-compose.yml для прокси
cat > /opt/vps-infra/docker-compose.yml <<EOF
version: '3'

services:
  mtproto-proxy:
    image: telegrammessenger/proxy:latest
    container_name: telegram-proxy
    restart: always
    ports:
      - "443:443"
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

# Запускаем прокси
cd /opt/vps-infra
docker-compose up -d

# Записываем информацию о Telegram прокси
{
    echo "=== Telegram MTProto Proxy ==="
    echo "Сервер: $SERVER_IP"
    echo "Порт: 443"
    echo "Секрет: $SECRET"
    echo "Ссылка для подключения:"
    echo "tg://proxy?server=$SERVER_IP&port=443&secret=$SECRET"
    echo ""
} >> $INFO_FILE

print_step "MTProto Proxy установлен"

# Настраиваем фаервол
if command -v ufw &> /dev/null; then
    print_step "Настраиваем фаервол..."
    ufw allow 22/tcp comment 'SSH'
    ufw allow 443/tcp comment 'MTProto Proxy'
    ufw --force enable
    print_step "Фаервол настроен"
fi

# ==============================================
# ФИНАЛЬНЫЙ ВЫВОД
# ==============================================

print_step "========================================="
print_step "УСТАНОВКА ЗАВЕРШЕНА!"
print_step "========================================="
echo ""

# Показываем содержимое файла с информацией
cat $INFO_FILE

echo ""
print_step "Вся информация сохранена в файле: $INFO_FILE"
print_step "Вы можете скопировать его на свой компьютер:"
echo "scp root@$SERVER_IP:$INFO_FILE ./"
