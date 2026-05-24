#!/bin/sh
# VPN Watchdog — проверяет PassWall каждые 10 минут

PROXY="socks5://127.0.0.1:1080"
TEST_URL="http://cp.cloudflare.com/"
TIMEOUT=10
LOG_TAG="vpn_watchdog"

# Проверяем что PassWall вообще включён
PW_ENABLED=$(uci get passwall.@global[0].enabled 2>/dev/null)
[ "$PW_ENABLED" != "1" ] && exit 0

# Проверяем xray процесс
if ! pgrep -f "xray run" >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "xray не запущен — перезапускаем PassWall"
    /etc/init.d/passwall restart
    exit 0
fi

# Проверяем реальный доступ через прокси
CODE=$(curl -s --max-time "$TIMEOUT" --proxy "$PROXY" \
    -o /dev/null -w "%{http_code}" "$TEST_URL" 2>/dev/null)

if [ "$CODE" = "204" ] || [ "$CODE" = "200" ]; then
    exit 0
fi

logger -t "$LOG_TAG" "VPN недоступен (code=$CODE) — перезапускаем PassWall"
/etc/init.d/passwall restart
