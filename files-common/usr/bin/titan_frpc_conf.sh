#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — единственный источник конфига frpc
#
#  Раньше /etc/frp/frpc.ini собирался прямо в rc.local, то есть только
#  при загрузке. Если файл повреждался в работе — починить его было
#  некому: frpc_watchdog умел перезапускать процесс, но не смотрел, с
#  чем тот запускается.
#
#  31.08.2026 на стенде это и случилось: конфиг оказался нулевого
#  размера, время изменения — на пять часов позже загрузки. frpc при
#  пустом конфиге берёт свои умолчания и ломится на 0.0.0.0:7000, в
#  логе «connection refused». Сторож восемь часов подряд честно ловил
#  падение и честно перезапускал в пустоту. Удалённый доступ был потерян
#  молча и до ручного вмешательства — на устройстве у клиента так нельзя.
#
#  Теперь генерация здесь, а rc.local и frpc_watchdog.sh её вызывают.
#
#  Запуск:
#      titan_frpc_conf.sh          написать конфиг, если он негоден
#      titan_frpc_conf.sh --force  переписать в любом случае
#      titan_frpc_conf.sh --check  только проверить, ничего не менять
#
#  Возврат: 0 — конфиг на месте и не менялся, 1 — был переписан.
# ═══════════════════════════════════════════════════════════════════

set -u

CONF="/etc/frp/frpc.ini"
LOG_TAG="titan_frpc"

SERVER_ADDR="frp.pandora361.online"
SERVER_PORT="8443"
TOKEN="21658aa79e70daf3a9e7ededa24855dcdf791a8606a4da6f8d7cb594513202d2"
SK="27555c1d65fc7d8b4b26f95e6df64ec54b41246bd805fea4e0a96240568ea4fb"

MODE="${1:-auto}"

log() { logger -t "$LOG_TAG" "$*"; [ -t 1 ] && printf '%s\n' "$*"; return 0; }

# ── Годен ли текущий конфиг ──────────────────────────────────────
# Проверяем не только наличие файла: пустой или обрезанный он выглядит
# как обычный, а frpc молча уходит на свои умолчания.
conf_ok() {
    [ -s "$CONF" ] || return 1
    grep -q "^server_addr = ." "$CONF" 2>/dev/null || return 1
    grep -q "^server_port = ." "$CONF" 2>/dev/null || return 1
    grep -q "^token = ." "$CONF" 2>/dev/null || return 1
    grep -q "^\[luci" "$CONF" 2>/dev/null || return 1
    grep -q "^\[ssh" "$CONF" 2>/dev/null || return 1
    return 0
}

if [ "$MODE" = "--check" ]; then
    if conf_ok; then log "конфиг frpc в порядке"; exit 0; fi
    log "конфиг frpc негоден"
    exit 1
fi

if [ "$MODE" != "--force" ] && conf_ok; then
    exit 0
fi

MAC="$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':' | tr 'A-F' 'a-f')"
if [ -z "${MAC:-}" ]; then
    log "не удалось прочитать MAC br-lan — конфиг не тронут"
    exit 0
fi

# Пишем через временный файл: обрыв на середине не должен оставить
# половину конфига там, где раньше был рабочий.
mkdir -p /etc/frp
TMP="$CONF.tmp"
cat > "$TMP" << FRPEOF
[common]
server_addr = ${SERVER_ADDR}
server_port = ${SERVER_PORT}
token = ${TOKEN}
login_fail_exit = false

[luci${MAC}]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = 80
sk = ${SK}

[ssh${MAC}]
type = stcp
role = server
use_encryption = true
use_compression = false
local_ip = 127.0.0.1
local_port = 22
sk = ${SK}
FRPEOF

if [ -s "$TMP" ]; then
    mv "$TMP" "$CONF"
    log "конфиг frpc перезаписан (${SERVER_ADDR}:${SERVER_PORT}, MAC $MAC)"
    exit 1
fi

rm -f "$TMP" 2>/dev/null
log "не удалось записать конфиг — старый оставлен как есть"
exit 0
