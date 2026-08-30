#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — единственная точка перезапуска PassWall
#
#  Перезапуск дорогой: заново заливаются списки в nftables, пересобирается
#  конфиг dnsmasq, поднимаются chinadns-ng и xray. А просить его умеют
#  сразу несколько сторон — vpn_watchdog, dns_watchdog, пакетный hotplug
#  на ifup, смена узла из панели.
#
#  Беда в том, что во время самого перезапуска xray и chinadns-ng
#  отсутствуют — то есть перезапуск создаёт ровно то условие, по которому
#  watchdog требует следующий перезапуск. Замкнутый круг.
#
#  29.08.2026 он сложился вживую: в 20:10:23 vpn_watchdog и dns_watchdog
#  в одну секунду запустили по рестарту, дальше нагрузка росла три окна
#  подряд (load 4.5 → 10.6 → 18.0) и роутер перестал отвечать.
#
#  Поэтому все обращаются сюда, а не к init-скрипту напрямую. Здесь лок
#  на время работы и пауза после: одновременно идёт максимум один
#  перезапуск, и не чаще раза в COOLDOWN секунд.
#
#  Запуск:  titan_pw_restart.sh "повод"
# ═══════════════════════════════════════════════════════════════════

set -u

LOG_TAG="titan_pw"
LOCK="/tmp/titan_pw_restart.lock"
STAMP="/tmp/titan_pw_restart_at"
COOLDOWN=300
REASON="${1:-повод не указан}"

log() { logger -t "$LOG_TAG" "$*"; }

# ── Уже идёт ─────────────────────────────────────────────────────
if [ -f "$LOCK" ]; then
    PID="$(cat "$LOCK" 2>/dev/null)"
    if [ -n "${PID:-}" ] && [ -d "/proc/$PID" ]; then
        log "перезапуск уже идёт (pid $PID), «$REASON» пропущен"
        exit 0
    fi
fi

# ── Только что перезапускали ─────────────────────────────────────
# Сервисам нужно время подняться. Без паузы watchdog, проснувшийся сразу
# после рестарта, увидит ещё не стартовавший xray и потребует новый.
LAST="$(cat "$STAMP" 2>/dev/null | tr -dc '0-9')"
NOW="$(date +%s)"
if [ -n "${LAST:-}" ] && [ "$((NOW - LAST))" -ge 0 ] && [ "$((NOW - LAST))" -lt "$COOLDOWN" ]; then
    log "перезапускали $((NOW - LAST))с назад, «$REASON» пропущен"
    exit 0
fi

echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT INT TERM
echo "$NOW" > "$STAMP"

# ── Половинчатая таблица nftables ────────────────────────────────
# Если app.sh упал на полпути, таблица inet passwall остаётся созданной,
# но без цепочек. Дальше каждый перезапуск сыплет «Could not process
# rule: No such file or directory», правила не встают, и вручную это
# лечится только сносом таблицы. Проверяем и сносим сами: firewall
# соберёт её заново. У живой таблицы цепочек больше десятка.
if nft list table inet passwall >/dev/null 2>&1; then
    CHAINS="$(nft list table inet passwall 2>/dev/null | grep -c '^[[:space:]]*chain')"
    case "${CHAINS:-}" in ""|*[!0-9]*) CHAINS=0 ;; esac
    if [ "$CHAINS" -lt 5 ]; then
        log "таблица inet passwall недостроена ($CHAINS цепочек) — сносим"
        nft delete table inet passwall 2>/dev/null || true
        /etc/init.d/firewall restart >/dev/null 2>&1 || true
    fi
fi

# ── Перезапуск ───────────────────────────────────────────────────
# timeout есть не во всех сборках. Без него init-скрипт умеет виснуть на
# procd-локе и держать его до перезагрузки — с ним висящий рестарт хотя бы
# отпустит лок и следующая попытка состоится.
log "перезапускаем PassWall: $REASON"
if command -v timeout >/dev/null 2>&1; then
    timeout 180 /etc/init.d/passwall restart >/dev/null 2>&1
else
    /etc/init.d/passwall restart >/dev/null 2>&1
fi
log "перезапуск завершён"
