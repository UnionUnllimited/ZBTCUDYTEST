#!/bin/sh
# FRP Watchdog — проверяет FRP соединение и перезапускает при обрыве
# Параметры подключения берутся из /etc/frp/frpc.ini, а собирает его
# titan_frpc_conf.sh — и при загрузке из titan_boot.sh, и отсюда.
# Автоподмена сервера из manifest.json удалена — конфиг не перезаписывается.

LOG_TAG="frpc_watchdog"

# ── Не трогаем только что загрузившийся роутер ───────────────────
# frpc поднимается из hotplug на ifup, до этого его отсутствие нормально.
# Перезапускать нечего, а сеть в первые минуты и без нас занята.
UPTIME=$(awk '{print int($1)}' /proc/uptime)
[ "$UPTIME" -lt 300 ] && exit 0

# ── Адрес FRP-сервера прибиваем в /etc/hosts ─────────────────────
# Удалённый доступ не должен зависеть ни от DNS, ни от туннеля.
#
# 30.08.2026 роутер d4:0d:ab:03:4b:ce потерял связь так: провайдер
# клиента блокирует pandora361.online и отдаёт на него 0.0.0.0. В логе
# frpc это выглядело как «dial tcp 0.0.0.0:8443: connection refused».
# DNS при этом был полностью исправен — ya.ru резолвился нормально, а
# 8.8.8.8 на тот же домен отвечал правильным адресом.
#
# Внести домен в proxy-domains.lst мало: тогда его резолв уходит в
# туннель, и если туннель лёг — нет ни DNS для frp, ни удалённого
# доступа, чтобы это починить. Замкнутый круг.
#
# Поэтому спрашиваем публичный резолвер напрямую, мимо провайдера и мимо
# chinadns-ng, и держим ответ в /etc/hosts. Обновляем на каждом заходе:
# сменится IP сервера — запись поедет за ним сама, пока связь ещё есть.
pin_frp_host() {
    _host="$(grep "^server_addr" /etc/frp/frpc.ini 2>/dev/null | awk '{print $3}')"
    [ -n "${_host:-}" ] || return 0

    # Публичные резолверы по очереди: первый ответивший внятно выигрывает.
    _ip=""
    for _dns in 8.8.8.8 1.1.1.1 9.9.9.9; do
        _ip="$(nslookup "$_host" "$_dns" 2>/dev/null \
            | awk '/^Name:/{s=1} s && /^Address/{print $NF; exit}')"
        case "${_ip:-}" in
            ""|0.0.0.0|127.*|*:*) _ip="" ;;
            *) break ;;
        esac
    done
    [ -n "${_ip:-}" ] || return 0

    _cur="$(awk -v h="$_host" '$2==h {print $1; exit}' /etc/hosts 2>/dev/null)"
    [ "$_cur" = "$_ip" ] && return 0

    logger -t "$LOG_TAG" "адрес $_host закреплён: ${_cur:-нет} -> $_ip"
    sed -i "/[[:space:]]${_host}\$/d" /etc/hosts 2>/dev/null
    echo "$_ip $_host" >> /etc/hosts
    /etc/init.d/dnsmasq reload >/dev/null 2>&1
    return 1   # запись сменилась — вызывающий перезапустит frpc
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

# ── Основная логика ──────────────────────────────────────────────
# Сначала сам конфиг. Перезапускать frpc, не глядя на то, с чем он
# запускается, бессмысленно: 31.08.2026 на стенде frpc.ini оказался
# нулевого размера, frpc уходил на свои умолчания (0.0.0.0:7000), а
# сторож восемь часов подряд перезапускал его в пустоту и рапортовал
# «FRP всё ещё недоступен».
CONF_REBUILT=0
if [ -x /usr/bin/titan_frpc_conf.sh ]; then
    /usr/bin/titan_frpc_conf.sh || CONF_REBUILT=1
fi

# Затем закрепление адреса: если запись сменилась, frpc всё равно надо
# перезапускать — имя он разрешает один раз, при старте.
PIN_CHANGED=0
pin_frp_host || PIN_CHANGED=1

if [ "$CONF_REBUILT" = 1 ] || [ "$PIN_CHANGED" = 1 ] || ! check_frpc; then
    if [ "$CONF_REBUILT" = 1 ]; then
        logger -t "$LOG_TAG" "конфиг был негоден и пересобран — перезапускаем frpc"
    elif [ "$PIN_CHANGED" = 1 ]; then
        logger -t "$LOG_TAG" "адрес сервера обновлён — перезапускаем frpc"
    else
        logger -t "$LOG_TAG" "FRP недоступен — перезапускаем"
    fi
    /etc/init.d/frpc restart
    sleep 10

    # Проверяем ещё раз
    if ! check_frpc; then
        logger -t "$LOG_TAG" "FRP всё ещё недоступен после перезапуска"
    else
        logger -t "$LOG_TAG" "FRP восстановлен после перезапуска"
    fi
fi
