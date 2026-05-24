#!/bin/sh
# Обновление FRP конфигурации
# Использование:
#   update_frpc.sh <server_addr> <server_port> <token> <sk>
# Пример:
#   update_frpc.sh "origin.all-streams-24.ru" "8443" "newtoken123" "newsk456"

SERVER_ADDR="$1"
SERVER_PORT="$2"
TOKEN="$3"
SK="$4"

# Проверка аргументов
if [ -z "$SERVER_ADDR" ] || [ -z "$SERVER_PORT" ] || [ -z "$TOKEN" ] || [ -z "$SK" ]; then
    echo "Использование: update_frpc.sh <server_addr> <server_port> <token> <sk>"
    echo ""
    echo "Текущий конфиг:"
    cat /etc/frp/frpc.ini 2>/dev/null || echo "  /etc/frp/frpc.ini не найден"
    exit 1
fi

# Берём MAC текущего устройства
MAC=$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':' | tr 'A-F' 'a-f')
if [ -z "$MAC" ]; then
    echo "ERROR: не удалось получить MAC br-lan"
    exit 1
fi

echo "Обновляем FRP конфиг..."
echo "  Server:  $SERVER_ADDR:$SERVER_PORT"
echo "  MAC:     $MAC"

mkdir -p /etc/frp
cat > /etc/frp/frpc.ini << FRPEOF
[common]
server_addr = ${SERVER_ADDR}
server_port = ${SERVER_PORT}
token = ${TOKEN}

[luci${MAC}]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = 80
sk = ${SK}

[ssh${MAC}sshd40dab1261f6]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = 22
sk = ${SK}
FRPEOF

echo "Конфиг записан. Перезапускаем frpc..."
/etc/init.d/frpc restart
sleep 3

# Проверяем что запустился
if pgrep -f "frpc -c" >/dev/null 2>&1; then
    echo "OK: frpc запущен"
else
    echo "ERROR: frpc не запустился — проверь параметры"
    exit 1
fi
