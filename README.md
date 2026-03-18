# Прокси Телеграм
### Команда для установки
```
curl -sSL https://raw.githubusercontent.com/AlexKeeper01/vps-auto-deploy/refs/heads/main/install.sh | sudo bash
```
### Просмотр файла с информацией
```
cat /root/vps-info.txt
```
# VPN
### Создание самоподписанного сертификата вручную через SSH
```
mkdir -p /etc/ssl/3xui
```
```
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/ssl/3xui/panel.key \
  -out /etc/ssl/3xui/panel.crt \
  -subj "/C=US/ST=State/L=City/O=Organization/CN=144.31.199.70"
```

### Установка панели 3x-ui
```
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
```
```
Choose SSL certificate setup method:
1. Let's Encrypt for Domain (90-day validity, auto-renews)
2. Let's Encrypt for IP Address (6-day validity, auto-renews)
3. Custom SSL Certificate (Path to existing files)
Note: Options 1 & 2 require port 80 open. Option 3 requires manual paths.
Choose an option (default 2 for IP): 3 <Выбрать этот вариант>

```
```
Please enter domain name certificate issued for: <Использовать IP-адрес как имя>
Certificate path: /etc/ssl/3xui/panel.crt
Private key path: /etc/ssl/3xui/panel.key
```
### Открытие порта панели м запуск
```
sudo ufw allow <ТУТ ПОРТ>/tcp
sudo x-ui start
```
### НЕ ЗАБЫВАЕМ СМЕНИТЬ ЛОГИН ПАРОЛЬ
### Настройка подключения
```
Протокол: vless
Порт: 443
Security: Reality
uTLS: chrome
Target: www.microsoft.com:443
SNI: www.microsoft.com
```
Нажать кнопку Get New Cert (или "Get New Keys"). Панель автоматически сгенерирует все необходимые криптографические ключи (Private Key, Public Key, Short IDs).
### Проверка настроек фаервола (UFW)
Необходимо открыть порты
```
sudo ufw allow 443/tcp
sudo ufw allow 80/tcp
sudo ufw reload
```
