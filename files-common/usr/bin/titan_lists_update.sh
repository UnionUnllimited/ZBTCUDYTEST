#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — обновление списков маршрутизации при подъёме WAN
#
#  Расписание раз в 12 часов держит сам PassWall: Loop Mode,
#  global_rules.update_week_mode='8' и update_interval_mode='12'.
#  Этот скрипт закрывает то, чего Loop Mode не умеет.
#
#  usr/share/passwall/tasks.sh начинает отсчёт с нуля и первый заход
#  делает только через полный интервал, а hotplug.d/iface/98-passwall
#  перезапускает passwall на каждом ifup — вместе с ним заново стартует
#  и tasks.sh со сброшенным счётчиком. На линии, которая переподключается
#  чаще раза в 12 часов, списки не обновятся никогда.
#
#  Поэтому при подъёме WAN обновляемся сами: роутер после простоя не
#  должен работать по устаревшему набору. Чтобы дёрганый PPPoE не гонял
#  закачку по кругу, между заходами держим паузу.
#
#  Запуск:
#      titan_lists_update.sh        обновить сейчас, без пауз
#      titan_lists_update.sh ifup   от hotplug: подождать сеть и
#                                   пропустить, если недавно обновлялись
# ═══════════════════════════════════════════════════════════════════

set -u

LOG_TAG="titan_lists"
LOG_FILE="/tmp/atl_panel_passwall_update.log"
STAMP="/tmp/titan_lists_at"
LOCK="/tmp/titan_lists.lock"
APP_PATH="/usr/share/passwall"
RULE_UPDATE="$APP_PATH/rule_update.lua"
MIN_GAP=21600
MODE="${1:-now}"

log() {
    logger -t "$LOG_TAG" "$*"
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
}

cleanup() { rm -f "$LOCK"; }

# ── Защита от параллельного запуска ──────────────────────────────
# Совпасть легко: тик Loop Mode и переподключение PPPoE в ту же минуту.
if [ -f "$LOCK" ]; then
    PID=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
        log "уже выполняется (pid $PID)"
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap cleanup EXIT INT TERM

[ -f "$RULE_UPDATE" ] || { log "$RULE_UPDATE не найден — PassWall не установлен"; exit 0; }

# ── Запуск от hotplug ────────────────────────────────────────────
if [ "$MODE" = ifup ]; then
    # Не лезем в первые минуты после загрузки, и это не про вежливость.
    #
    # rule_update.lua, если списки изменились, заканчивает вызовом
    # uci_save(true, true) — а это по коду api.lua коммит с применением,
    # то есть «/etc/init.d/passwall reload». WAN поднимается на 20–30
    # секунде, у PassWall при этом ещё идёт start_delay в минуту, и
    # перезапуск попадает ровно в момент его старта.
    #
    # Дальше срабатывает то, что описано в titan_pw_check.sh:
    # gen_nft_tables создаёт хуковые цепочки только при отсутствии
    # таблицы. Один процесс таблицу создаёт, второй видит её готовой и
    # проходит мимо — роутер остаётся без туннеля и без DNS у клиентов.
    #
    # Ровно это и отличало сборки от 155 и выше от 153, где хотплага не
    # было вовсе: списки тогда качались не при загрузке, и PassWall
    # собирал таблицу в одиночку.
    #
    # Поэтому ждём, пока PassWall закончит старт. Обновление списков
    # никуда не торопится, а вот сломанная таблица стоит роутеру связи.
    BOOT_QUIET=240
    UPTIME="$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)"
    if [ "$UPTIME" -lt "$BOOT_QUIET" ]; then
        log "аптайм ${UPTIME}с — ждём $((BOOT_QUIET - UPTIME))с, чтобы не мешать старту PassWall"
        sleep $((BOOT_QUIET - UPTIME))
    fi

    # Отметка живёт в /tmp и пропадает при перезагрузке — так и надо:
    # после ребута роутер должен сходить за списками сразу, пауза нужна
    # только против дёрганья WAN внутри одной сессии.
    LAST="$(cat "$STAMP" 2>/dev/null | tr -dc '0-9')"
    NOW="$(date +%s)"
    if [ -n "${LAST:-}" ] && [ "$((NOW - LAST))" -ge 0 ] && [ "$((NOW - LAST))" -lt "$MIN_GAP" ]; then
        log "списки обновлялись $(( (NOW - LAST) / 60 )) мин назад — пропускаем"
        exit 0
    fi
    # Интерфейс поднялся, но маршрут и DNS могут появиться секундой позже.
    # Ждём, пока зеркало реально ответит.
    URL="$(uci -q get passwall.@global_rules[0].chnlist_url 2>/dev/null | awk '{print $1}')"
    if [ -n "${URL:-}" ]; then
        i=0
        while [ "$i" -lt 24 ]; do
            curl -fsS --max-time 8 -o /dev/null "$URL" 2>/dev/null && break
            i=$((i + 1))
            sleep 5
        done
        if [ "$i" -ge 24 ]; then
            log "зеркало не ответило за две минуты — пропускаем, вернёмся на следующем ifup"
            exit 0
        fi
    fi
fi

# ── Обновление ───────────────────────────────────────────────────
# Аргументы те же, что PassWall передаёт из своего расписания: без
# второго аргумента скрипт берёт список того, что тянуть, из флагов
# chnlist_update и chnroute_update в global_rules.
log "обновляем списки маршрутизации (режим $MODE)"
lua "$RULE_UPDATE" log all cron >> "$LOG_FILE" 2>&1 || log "rule_update.lua завершился с ошибкой"

date +%s > "$STAMP" 2>/dev/null

for f in "$APP_PATH/rules/chnlist" "$APP_PATH/rules/chnroute"; do
    [ -s "$f" ] && log "$(basename "$f"): $(wc -l < "$f" | tr -d ' ') строк"
done

log "готово"
