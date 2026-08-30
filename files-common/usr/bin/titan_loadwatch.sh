#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — ловушка для всплесков нагрузки
#
#  29.08.2026 роутер ушёл в полку: load 18, панель не отвечает, помогла
#  только перезагрузка. Разбираться потом оказалось не по чему — syslog
#  живёт в RAM и умирает вместе с перезагрузкой, а перезагрузка тут и
#  есть способ выйти из полки. Замкнутый круг: симптом уносит улики.
#
#  Раз в минуту смотрим loadavg. Пока тихо — ничего не пишем и флеш не
#  трогаем вовсе. Как только перевалило за порог, дописываем срез в файл
#  в /etc: он переживёт и перезагрузку, и sysupgrade (перечислен в
#  sysupgrade.conf).
#
#  Смотреть: cat /etc/titan_load.log
# ═══════════════════════════════════════════════════════════════════

set -u

THRESHOLD=5
OUT="/etc/titan_load.log"
MAX_LINES=400
STAMP="/tmp/titan_loadwatch_at"
MIN_GAP=300

LOAD1="$(awk '{print $1}' /proc/loadavg 2>/dev/null)"
[ -n "${LOAD1:-}" ] || exit 0

# В sh нет дробной арифметики — сравниваем по целой части. Порог целый,
# так что точности хватает: 4.9 не интересно, 5.0 уже да.
LOAD_INT="${LOAD1%%.*}"
case "$LOAD_INT" in ""|*[!0-9]*) exit 0 ;; esac
[ "$LOAD_INT" -ge "$THRESHOLD" ] || exit 0

# Пока полка держится, незачем писать на флеш каждую минуту.
LAST="$(cat "$STAMP" 2>/dev/null | tr -dc '0-9')"
NOW="$(date +%s)"
if [ -n "${LAST:-}" ] && [ "$((NOW - LAST))" -ge 0 ] && [ "$((NOW - LAST))" -lt "$MIN_GAP" ]; then
    exit 0
fi
echo "$NOW" > "$STAMP"

# top -bn1 бесполезен: без предыдущего замера все проценты нулевые.
# Берём два прохода и оставляем второй — там уже реальный CPU.
{
    echo "════ $(date '+%F %T')  loadavg: $(cat /proc/loadavg 2>/dev/null) ════"
    echo "-- аптайм --"
    uptime
    echo "-- процессы по CPU --"
    top -bn2 -d1 2>/dev/null | tail -22
    echo "-- память --"
    free
    echo "-- swap --"
    cat /proc/swaps 2>/dev/null
    echo "-- наши и пассвалловские --"
    ps w 2>/dev/null \
        | grep -E "passwall|xray|chinadns|dnsmasq|watchdog|rule_update|titan_" \
        | grep -v grep
    echo
} >> "$OUT" 2>&1

# Файл лежит во флеше, расти без предела ему нельзя.
LINES="$(wc -l < "$OUT" 2>/dev/null | tr -d ' ')"
case "$LINES" in
    ""|*[!0-9]*) ;;
    *)
        if [ "$LINES" -gt "$MAX_LINES" ]; then
            tail -n "$MAX_LINES" "$OUT" > "$OUT.tmp" 2>/dev/null \
                && mv "$OUT.tmp" "$OUT"
        fi
        ;;
esac

logger -t titan_loadwatch "нагрузка $LOAD1 — срез записан в $OUT"
