#!/bin/bash
set -e

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

print_step() { echo -e "${BLUE}[$(date +'%H:%M:%S')]${NC} ${GREEN}➜${NC} $1"; }
print_error() { echo -e "${RED}[ОШИБКА]${NC} $1" >&2; }
print_warning() { echo -e "${YELLOW}[ВНИМАНИЕ]${NC} $1"; }
print_success() { echo -e "${GREEN}[✓]${NC} $1"; }
print_info() { echo -e "${CYAN}[i]${NC} $1"; }

# Проверка прав root
if [[ $EUID -ne 0 ]]; then
   print_error "Запустите с sudo"
   exit 1
fi

clear
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         Telemt Proxy - Прямая установка (host network)      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Получаем внешний IP
print_step "Определение IP сервера..."
SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
print_success "Внешний IP: $SERVER_IP"

# Проверка доступности Telegram
print_step "Проверка доступности Telegram..."
if ping -c 2 -W 3 149.154.167.51 >/dev/null 2>&1; then
    print_success "Сервер Telegram доступен"
    TELEGRAM_OK=1
else
    print_warning "Сервер Telegram не пингуется, проверяем порт 443..."
    if nc -zv -w 3 149.154.167.51 443 2>/dev/null; then
        print_success "Порт 443 открыт"
        TELEGRAM_OK=1
    else
        print_error "Telegram НЕ ДОСТУПЕН с вашего сервера!"
        print_info "Прокси может не работать из-за блокировок хостера"
    fi
fi

# Остановка старых прокси
print_step "Остановка старых прокси..."
cd /opt/telemt 2>/dev/null && docker compose down 2>/dev/null && cd /
rm -rf /opt/telemt 2>/dev/null
rm -f /usr/local/bin/telemt-* 2>/dev/null

# Установка Docker
print_step "Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm -f /tmp/get-docker.sh
    print_success "Docker установлен"
fi

# Генерация секрета
SECRET=$(openssl rand -hex 16)
print_success "Сгенерирован секрет: $SECRET"

# Порт для прокси (фиксированный 8443)
PORT=8443
print_info "Используем порт: $PORT"

# Создание директории
mkdir -p /opt/telemt
cd /opt/telemt

# Создание конфига
print_step "Создание конфигурации..."
cat > /opt/telemt/telemt.toml <<EOF
[general]
public_ip = "$SERVER_IP"

[general.modes]
classic = true
secure = false
tls = false

[censorship]
tls_domain = "www.google.com"

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[access.users]
user1 = "$SECRET"
EOF

# Создание docker-compose.yml с host network
cat > /opt/telemt/docker-compose.yml <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt-proxy
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    network_mode: "host"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
EOF

# Настройка UFW
print_step "Настройка firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp comment 'SSH'
    ufw allow $PORT/tcp comment 'Telemt Proxy'
    echo "y" | ufw enable > /dev/null 2>&1
    print_success "Открыт порт $PORT"
fi

# Запуск
print_step "Запуск Telemt..."
cd /opt/telemt
docker compose up -d
sleep 5

# Проверка запуска
if ! docker ps | grep -q telemt-proxy; then
    print_error "Ошибка запуска!"
    docker compose logs
    exit 1
fi

# Формирование ссылки (правильная!)
LINK="tg://proxy?server=$SERVER_IP&port=$PORT&secret=$SECRET"

# Создание утилит
cat > /usr/local/bin/telemt-info <<'EOF'
#!/bin/bash
echo "=== Telemt Proxy (прямое подключение) ==="
cat /opt/telemt/telemt.toml | grep -E "public_ip|user1" | sed 's/user1/secret/'
echo "Порт: 8443"
echo ""
echo "Ссылка для Telegram:"
grep -o 'tg://[^"]*' /usr/local/bin/telemt-info 2>/dev/null || echo "Ссылка в конце установки"
EOF

cat > /usr/local/bin/telemt-logs <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose logs -f
EOF

cat > /usr/local/bin/telemt-restart <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose restart
echo "Telemt перезапущен"
EOF

cat > /usr/local/bin/telemt-stop <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose down
echo "Telemt остановлен"
EOF

cat > /usr/local/bin/telemt-start <<'EOF'
#!/bin/bash
cd /opt/telemt && docker compose up -d
echo "Telemt запущен"
EOF

chmod +x /usr/local/bin/telemt-*

# Финальный вывод
clear
echo -e "${GREEN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              УСТАНОВКА ЗАВЕРШЕНА                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

echo -e "${YELLOW}📋 ИНФОРМАЦИЯ О ПРОКСИ:${NC}"
echo "──────────────────────────────"
echo "🌐 IP сервера:    $SERVER_IP"
echo "🔌 Порт:          $PORT"
echo "🔧 Режим:         Classic (прямое подключение)"
echo "🔑 Секрет:        $SECRET"
echo ""
echo -e "${GREEN}📱 ССЫЛКА ДЛЯ TELEGRAM:${NC}"
echo "$LINK"
echo ""
echo -e "${YELLOW}🛠 КОМАНДЫ:${NC}"
echo "──────────────────────────────"
echo "telemt-info      - информация"
echo "telemt-logs      - логи"
echo "telemt-restart   - перезапуск"
echo "telemt-stop      - остановка"
echo "telemt-start     - запуск"
echo ""

# Финальная проверка
print_step "Проверка работы..."
sleep 3
if docker ps | grep -q telemt-proxy; then
    print_success "Telemt работает"
    print_info "Проверьте логи: telemt-logs"
    print_info "Если не работает - проверьте доступность порта $PORT снаружи"
else
    print_error "Что-то пошло не так"
fi
