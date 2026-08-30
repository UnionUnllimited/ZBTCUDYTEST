#!/bin/sh
# FRP Watchdog — проверяет FRP соединение и перезапускает при обрыве
# Параметры подключения берутся только из /etc/frp/frpc.ini (пишется в rc.local).
# Автоподмена сервера из manifest.json удалена — конфиг не перезаписывается.

LOG_TAG="frpc_watchdog"

# ── Не трогаем только что загрузившийся роутер ───────────────────
# frpc поднимается из hotplug на ifup, до этого его отсутствие нормально.
# Перезапускать нечего, а сеть в первые минуты и без нас занята.
UPTIME=$(awk '{print int($1)}' /proc/uptime)
[ "$UPTIME" -lt 300 ] && exit 0

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

# ── Основная логика ──────────────────────────────────────────────
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
