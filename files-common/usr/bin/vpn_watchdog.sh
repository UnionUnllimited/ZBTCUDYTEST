#!/bin/sh
# VPN Watchdog — проверяет PassWall каждые 10 минут

PROXY="socks5://127.0.0.1:1080"
TEST_URL="http://cp.cloudflare.com/"
TIMEOUT=10
LOG_TAG="vpn_watchdog"

# ── Не трогаем только что загрузившийся роутер ───────────────────
# PassWall стартует не сразу: global_delay.start_delay даёт ему минуту,
# плюс время на заливку списков. Проверка внутри этого окна увидит
# отсутствующий xray и потребует перезапуск ровно тогда, когда сервис
# ещё только поднимается. Так 29.08.2026 и началась лавина рестартов.
UPTIME=$(awk '{print int($1)}' /proc/uptime)
[ "$UPTIME" -lt 300 ] && exit 0

# Проверяем что PassWall вообще включён
PW_ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null)
[ "$PW_ENABLED" != "1" ] && exit 0

# Перезапуск только через общую точку: она держит лок и паузу, чтобы мы
# с dns_watchdog не пускали два рестарта внахлёст.
pw_restart() {
    if [ -x /usr/bin/titan_pw_restart.sh ]; then
        /usr/bin/titan_pw_restart.sh "$1"
    else
        /etc/init.d/passwall restart
    fi
}

# Проверяем xray процесс
if ! pgrep -f "xray run" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "xray не запущен"
    pw_restart "vpn_watchdog: нет процесса xray"
    exit 0
fi

# Проверяем реальный доступ через прокси
CODE=$(curl -s --max-time "$TIMEOUT" --proxy "$PROXY" \
    -o /dev/null -w "%{http_code}" "$TEST_URL" 2>/dev/null)

if [ "$CODE" = "204" ] || [ "$CODE" = "200" ]; then
    exit 0
fi

logger -t "$LOG_TAG" "VPN недоступен (code=$CODE)"
pw_restart "vpn_watchdog: туннель не отвечает (code=$CODE)"
