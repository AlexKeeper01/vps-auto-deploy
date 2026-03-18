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
echo "║         Telemt Proxy - Мастер-установка с диагностикой      ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# ==============================================
# ДИАГНОСТИКА СЕТИ
# ==============================================
print_step "Диагностика сети..."

SERVER_IP=$(curl -4 -s --max-time 5 ifconfig.me 2>/dev/null || curl -4 -s --max-time 5 icanhazip.com 2>/dev/null || hostname -I | awk '{print $1}')
print_info "Внешний IP сервера: $SERVER_IP"

# Проверка доступности Telegram
print_step "Проверка доступности серверов Telegram..."

TELEGRAM_IPS=("149.154.167.51" "149.154.175.50" "91.108.56.165")
TELEGRAM_OK=0

for ip in "${TELEGRAM_IPS[@]}"; do
    if ping -c 2 -W 3 $ip >/dev/null 2>&1; then
        print_success "Сервер $ip доступен"
        TELEGRAM_OK=$((TELEGRAM_OK + 1))
    else
        print_warning "Сервер $ip НЕ доступен по ping"
        # Проверим через nc
        if nc -zv -w 3 $ip 443 2>/dev/null; then
            print_success "Сервер $ip доступен по порту 443"
            TELEGRAM_OK=$((TELEGRAM_OK + 1))
        else
            print_error "Сервер $ip полностью недоступен"
        fi
    fi
done

# Проверка DNS
print_step "Проверка DNS..."
if nslookup google.com >/dev/null 2>&1; then
    print_success "DNS работает"
else
    print_warning "Проблемы с DNS, меняем на Google DNS"
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 8.8.4.4" >> /etc/resolv.conf
fi

# Если все серверы Telegram недоступны
if [ $TELEGRAM_OK -eq 0 ]; then
    print_error "НИ ОДИН сервер Telegram не доступен!"
    print_info "Это значит, что ваш хостинг БЛОКИРУЕТ Telegram."
    print_info "Прокси НЕ БУДЕТ работать, пока вы не смените хостера"
    print_info "Или не настроите дополнительный прокси (upstream)"
    
    echo ""
    print_warning "Продолжить установку? (y/n)"
    read -r answer
    if [[ ! "$answer" =~ ^[YyДд]$ ]]; then
        exit 1
    fi
fi

# ==============================================
# ОСТАНОВКА СТАРОГО ПРОКСИ
# ==============================================
print_step "Остановка старых прокси..."

# Остановка MTProto если есть
cd /opt/vps-infra 2>/dev/null && docker compose down 2>/dev/null && cd /

# Остановка Telemt если есть
cd /opt/telemt 2>/dev/null && docker compose down 2>/dev/null && cd /

# Удаление старых директорий
rm -rf /opt/telemt 2>/dev/null
rm -f /usr/local/bin/telemt-* 2>/dev/null

# ==============================================
# УСТАНОВКА DOCKER
# ==============================================
print_step "Установка Docker..."
if ! command -v docker &> /dev/null; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh > /dev/null 2>&1
    rm -f /tmp/get-docker.sh
    print_success "Docker установлен"
fi

# ==============================================
# ВЫБОР РЕЖИМА РАБОТЫ
# ==============================================
echo ""
print_info "Выберите режим работы Telemt:"
echo "  1) Универсальный (tls) - рекомендуется"
echo "  2) Совместимый (secure)"
echo "  3) Классический (classic) - для старых версий"
echo "  4) Тестовый - перебор всех режимов"
read -p "Ваш выбор (1-4): " mode_choice

# Генерация секрета
SECRET=$(openssl rand -hex 16)

# Создание директории
mkdir -p /opt/telemt
cd /opt/telemt

# Базовый конфиг
cat > /opt/telemt/telemt.toml <<EOF
[general]
public_ip = "$SERVER_IP"

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[censorship]
tls_domain = "www.google.com"

[access.users]
user1 = "$SECRET"
EOF

# Добавление режима в зависимости от выбора
case $mode_choice in
    1)
        cat >> /opt/telemt/telemt.toml <<EOF

[general.modes]
classic = false
secure = false
tls = true
EOF
        MODE_NAME="TLS (рекомендуемый)"
        ;;
    2)
        cat >> /opt/telemt/telemt.toml <<EOF

[general.modes]
classic = false
secure = true
tls = false
EOF
        MODE_NAME="Secure"
        ;;
    3)
        cat >> /opt/telemt/telemt.toml <<EOF

[general.modes]
classic = true
secure = false
tls = false
EOF
        MODE_NAME="Classic"
        ;;
    4)
        # Для тестового режима создадим несколько конфигов
        MODE_NAME="Тестовый (будет создано 3 конфига)"
        ;;
esac

# ==============================================
# ВЫБОР ПОРТА
# ==============================================
echo ""
print_info "Выберите порт для прокси:"
echo "  1) 443 (стандартный HTTPS)"
echo "  2) 20536 (как было раньше)"
echo "  3) 8443 (альтернативный)"
echo "  4) Случайный порт"
read -p "Ваш выбор (1-4): " port_choice

case $port_choice in
    1) PORT=443 ;;
    2) PORT=20536 ;;
    3) PORT=8443 ;;
    4) PORT=$((RANDOM % 64511 + 1024)) ;;
    *) PORT=20536 ;;
esac

# ==============================================
# СОЗДАНИЕ DOCKER-COMPOSE
# ==============================================
cat > /opt/telemt/docker-compose.yml <<EOF
services:
  telemt:
    image: ghcr.io/telemt/telemt:latest
    container_name: telemt-proxy
    restart: unless-stopped
    environment:
      RUST_LOG: "info"
    ports:
      - "$PORT:443/tcp"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
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
EOF

# ==============================================
# НАСТРОЙКА UFW
# ==============================================
print_step "Настройка firewall..."
if command -v ufw &> /dev/null; then
    ufw allow 22/tcp comment 'SSH'
    ufw allow $PORT/tcp comment 'Telemt Proxy'
    echo "y" | ufw enable > /dev/null 2>&1
    print_success "Открыт порт $PORT"
fi

# ==============================================
# ЗАПУСК И ТЕСТИРОВАНИЕ
# ==============================================
print_step "Запуск Telemt..."
cd /opt/telemt
docker compose up -d
sleep 10

# Проверка запуска
if ! docker ps | grep -q telemt-proxy; then
    print_error "Telemt не запустился!"
    docker compose logs
    exit 1
fi

print_success "Telemt запущен на порту $PORT"

# Получение ссылки
sleep 5
if command -v jq &> /dev/null; then
    LINK=$(curl -s http://127.0.0.1:9091/v1/users | jq -r '.users[0].link' 2>/dev/null)
else
    LINK=$(curl -s http://127.0.0.1:9091/v1/users | grep -o 'tg://[^"]*')
fi

if [ -z "$LINK" ]; then
    # Ручная сборка
    LINK="tg://proxy?server=$SERVER_IP&port=$PORT&secret=$SECRET"
fi

# ==============================================
# ДИАГНОСТИКА ПОСЛЕ ЗАПУСКА
# ==============================================
print_step "Диагностика после запуска..."

# Проверка логов на ошибки подключения
ERRORS=$(docker compose logs --tail 50 | grep -i "fail\|error\|warn" | grep -v "Read-only file system" | head -10)
if [ -n "$ERRORS" ]; then
    print_warning "Найдены предупреждения в логах:"
    echo "$ERRORS"
fi

# Проверка соединения с Telegram из контейнера
print_step "Проверка соединения из контейнера..."
docker exec telemt-proxy sh -c "nc -zv 149.154.167.51 443 2>&1" || print_warning "Нет доступа к Telegram из контейнера"

# ==============================================
# ТЕСТОВЫЙ РЕЖИМ - ПЕРЕБОР
# ==============================================
if [ "$mode_choice" -eq 4 ]; then
    print_step "Тестовый режим - создаю конфиги для всех режимов..."
    
    # Сохраняем текущий конфиг как TLS
    cp telemt.toml telemt-tls.toml
    
    # Secure режим
    sed 's/tls = true/secure = true\nsecure = true\ntls = false/' telemt.toml > telemt-secure.toml
    
    # Classic режим
    cat > telemt-classic.toml <<EOF
[general]
public_ip = "$SERVER_IP"

[general.modes]
classic = true
secure = false
tls = false

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[access.users]
user1 = "$SECRET"
EOF
    
    print_info "Созданы конфиги:"
    echo "  TLS:     /opt/telemt/telemt-tls.toml"
    echo "  Secure:  /opt/telemt/telemt-secure.toml" 
    echo "  Classic: /opt/telemt/telemt-classic.toml"
    echo ""
    echo "Для смены режима:"
    echo "  cp /opt/telemt/telemt-РЕЖИМ.toml /opt/telemt/telemt.toml"
    echo "  cd /opt/telemt && docker compose restart"
fi

# ==============================================
# СОЗДАНИЕ УТИЛИТ
# ==============================================
cat > /usr/local/bin/telemt-info <<'EOF'
#!/bin/bash
echo "=== Telemt Proxy Information ==="
echo "IP: $(grep public_ip /opt/telemt/telemt.toml 2>/dev/null | cut -d'"' -f2)"
echo "Порт: $(grep -A5 ports /opt/telemt/docker-compose.yml 2>/dev/null | grep -o '[0-9]*:443' | cut -d: -f1)"
echo "Режим: $(grep -A3 modes /opt/telemt/telemt.toml 2>/dev/null | grep -v '^\[' | grep true | head -1)"
echo ""
echo "Ссылки для подключения:"
curl -s http://127.0.0.1:9091/v1/users 2>/dev/null | grep -o 'tg://[^"]*' || echo "Не удалось получить ссылку"
echo ""
echo "Статус:"
docker ps --filter "name=telemt-proxy" --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

cat > /usr/local/bin/telemt-diagnose <<'EOF'
#!/bin/bash
echo "=== Диагностика Telemt ==="
echo "1. Проверка контейнера:"
docker ps | grep telemt-proxy

echo -e "\n2. Последние 20 строк логов:"
docker logs --tail 20 telemt-proxy

echo -e "\n3. Проверка соединения с Telegram:"
docker exec telemt-proxy sh -c "nc -zv 149.154.167.51 443 2>&1"

echo -e "\n4. Открытые порты:"
ss -tulpn | grep -E ":(22|$PORT|443)" 2>/dev/null

echo -e "\n5. Доступность из интернета (проверьте вручную):"
echo "   https://portcheckers.com/ - введите IP и порт"
EOF

chmod +x /usr/local/bin/telemt-*

# ==============================================
# ФИНАЛЬНЫЙ ВЫВОД
# ==============================================
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
echo "🔧 Режим:         $MODE_NAME"
echo "🔑 Секрет:        $SECRET"
echo ""
echo "📱 ССЫЛКА ДЛЯ TELEGRAM:"
echo -e "${GREEN}$LINK${NC}"
echo ""
echo -e "${YELLOW}🛠 ДОСТУПНЫЕ КОМАНДЫ:${NC}"
echo "──────────────────────────────"
echo "telemt-info      - информация о прокси"
echo "telemt-diagnose  - диагностика проблем"
echo "telemt-logs      - просмотр логов"
echo "telemt-restart   - перезапуск"
echo "telemt-stop      - остановка"
echo "telemt-start     - запуск"
echo ""
echo -e "${YELLOW}📁 Файлы конфигурации:${NC}"
echo "  /opt/telemt/telemt.toml"
echo "  /opt/telemt/docker-compose.yml"
echo ""

# Финальная диагностика
if [ $TELEGRAM_OK -eq 0 ]; then
    print_error "ВНИМАНИЕ: Серверы Telegram недоступны с вашего VPS!"
    print_info "Прокси НЕ БУДЕТ работать, пока вы не решите эту проблему."
    print_info "Варианты:"
    echo "  1. Сменить хостинг на другой (не российский)"
    echo "  2. Использовать дополнительный прокси (upstream) - нужен платный SOCKS5"
    echo "  3. Попробовать другие режимы работы (secure/classic)"
elif [ $TELEGRAM_OK -lt 3 ]; then
    print_warning "Часть серверов Telegram недоступна - возможны перебои"
else
    print_success "Все серверы Telegram доступны - прокси должен работать"
fi

echo ""
print_step "Готово! Скопируйте ссылку выше в Telegram."
