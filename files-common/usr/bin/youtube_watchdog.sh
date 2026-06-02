#!/bin/sh
LOG="/tmp/youtube_watchdog.log"

DIRECT_FILE=""
for f in \
    /usr/share/passwall/rules/direct_host \
    /etc/passwall/direct_host \
    /tmp/dnsmasq.d/direct_host
do
    [ -f "$f" ] && { DIRECT_FILE="$f"; break; }
done

# Если YouTube не в Direct — добавляем и перезапускаем
youtube_in_direct() {
    [ -n "$DIRECT_FILE" ] && grep -q "youtube.com" "$DIRECT_FILE" 2>/dev/null
}

check_youtube() {
    curl -fsS --connect-timeout 5 --max-time 10 \
        "https://www.youtube.com/generate_204" \
        -o /dev/null 2>/dev/null && return 0
    return 1
}

if ! youtube_in_direct; then
    echo "$(date): YouTube не в Direct List — запускаем автоподбор" >> "$LOG"
    SYNC_ALL_DIRECT_FILES=1 PASSWALL_RELOAD_AFTER_DIRECT=1 \
        /usr/bin/youtube_strategy_autoselect.sh >> "$LOG" 2>&1
elif ! check_youtube; then
    echo "$(date): YouTube в Direct но недоступен — запускаем автоподбор" >> "$LOG"
    SYNC_ALL_DIRECT_FILES=1 PASSWALL_RELOAD_AFTER_DIRECT=1 \
        /usr/bin/youtube_strategy_autoselect.sh >> "$LOG" 2>&1
else
    echo "$(date): YouTube OK" >> "$LOG"
fi
