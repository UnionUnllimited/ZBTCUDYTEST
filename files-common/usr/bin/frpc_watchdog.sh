#!/bin/sh
# FRP Watchdog — проверяет FRP соединение
# Если сервер недоступен — берёт новые параметры из manifest.json и переключается

LOG_TAG="frpc_watchdog"
TMP_DIR="/tmp/frpc_watchdog"
MANIFEST_FILE="$TMP_DIR/manifest.json"

# ── Зеркала ─────────────────────────────────────────────────────
MIRRORS="
https://github.com/UnionUnllimited/updates/releases/latest/download
https://origin.all-streams-24.ru/updates
https://1222.hb.ru-msk.vkcloud-storage.ru/updates
https://storage.yandexcloud.net/234588/updates
"

# ── Скачать файл с зеркал ───────────────────────────────────────
download() {
    local file="$1" dest="$2"
    for mirror in $MIRRORS; do
        mirror=$(echo "$mirror" | tr -d ' ')
        [ -z "$mirror" ] && continue
        curl -s --max-time 15 --retry 2 \
            "${mirror}/${file}" -o "${dest}.tmp" 2>/dev/null
        if [ -s "${dest}.tmp" ]; then
            mv "${dest}.tmp" "$dest"
            return 0
        fi
        rm -f "${dest}.tmp"
    done
    return 1
}

# ── Получить поле из manifest.json ──────────────────────────────
get_field() {
    local field="$1"
    grep "\"${field}\"" "$MANIFEST_FILE" 2>/dev/null | \
        sed 's/.*:.*"\(.*\)".*/\1/'
}

# ── Проверить FRP соединение ─────────────────────────────────────
check_frpc() {
    # Процесс запущен?
    pgrep -f "frpc -c" >/dev/null 2>&1 || return 1

    # Читаем текущий сервер из конфига
    local server
    server=$(grep "^server_addr" /etc/frp/frpc.ini 2>/dev/null | \
        awk '{print $3}')
    [ -z "$server" ] && return 1

    # Проверяем доступность сервера
    curl -s --max-time 10 "http://${server}" >/dev/null 2>&1 && return 0

    # Пинг до сервера
    ping -c2 -W3 "$server" >/dev/null 2>&1 && return 0

    return 1
}

# ── Применить новые FRP параметры ───────────────────────────────
apply_new_frpc() {
    local new_server new_port new_token new_sk

    new_server=$(get_field "frp_server")
    new_port=$(get_field "frp_port")
    new_token=$(get_field "frp_token")
    new_sk=$(get_field "frp_sk")

    # Проверяем что поля не пустые
    [ -z "$new_server" ] && return 1
    [ -z "$new_port" ]   && return 1
    [ -z "$new_token" ]  && return 1
    [ -z "$new_sk" ]     && return 1

    # Читаем текущие параметры
    local cur_server cur_token
    cur_server=$(grep "^server_addr" /etc/frp/frpc.ini 2>/dev/null | awk '{print $3}')
    cur_token=$(grep "^token" /etc/frp/frpc.ini 2>/dev/null | awk '{print $3}')

    # Если параметры не изменились — ничего не делаем
    if [ "$new_server" = "$cur_server" ] && [ "$new_token" = "$cur_token" ]; then
        return 0
    fi

    logger -t "$LOG_TAG" "Новый FRP сервер: $new_server:$new_port"

    # Применяем через update_frpc.sh
    /usr/bin/update_frpc.sh "$new_server" "$new_port" "$new_token" "$new_sk"
    logger -t "$LOG_TAG" "FRP переключён на $new_server"
}

# ── Основная логика ──────────────────────────────────────────────
mkdir -p "$TMP_DIR"

# Качаем manifest
download "manifest.json" "$MANIFEST_FILE" || {
    # Если manifest недоступен — просто проверяем что frpc запущен
    if ! pgrep -f "frpc -c" >/dev/null 2>&1; then
        logger -t "$LOG_TAG" "frpc не запущен — перезапускаем"
        /etc/init.d/frpc restart
    fi
    rm -rf "$TMP_DIR"
    exit 0
}

# Проверяем нужно ли менять параметры FRP
apply_new_frpc

# Проверяем что frpc работает
if ! check_frpc; then
    logger -t "$LOG_TAG" "FRP недоступен — перезапускаем"
    /etc/init.d/frpc restart
    sleep 10

    # Проверяем ещё раз
    if ! check_frpc; then
        logger -t "$LOG_TAG" "FRP всё ещё недоступен после перезапуска"
    else
        logger -t "$LOG_TAG" "FRP восстановлен после перезапуска"
    fi
fi

rm -rf "$TMP_DIR"
