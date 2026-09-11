#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — синхронизация локальных списков маршрутизации
#
#  PassWall качает по URL только gfwlist, chnlist и chnroute. Четыре
#  списка, которые решают всё остальное, он читает из локальных файлов:
#
#      rules/direct_host  rules/direct_ip   -> psw_white,  мимо туннеля
#      rules/proxy_host   rules/proxy_ip    -> psw_black,  в туннель
#
#  psw_white проверяется раньше psw_black (nftables.sh:480 против 497),
#  поэтому direct-списки перехватывают то, что proxy-список забрал
#  лишнего. Штатного способа обновлять их с зеркала нет — этим и занят
#  этот скрипт.
#
#  Запуск:
#      titan_lists_sync.sh        обновить сейчас
#      titan_lists_sync.sh ifup   от hotplug: подождать сеть и пропустить,
#                                 если недавно уже обновлялись
#      titan_lists_sync.sh -n     только проверить, ничего не менять
#
#  ── Почему так осторожно ──────────────────────────────────────────
#
#  Эти четыре файла определяют, куда пойдёт весь трафик роутера. Ошибка
#  здесь дороже, чем пропущенное обновление, поэтому три предохранителя.
#
#  1. Скачанное проверяется до установки. 31.08.2026 зеркало на неверном
#     пути отдавало {"error":"Not Found"} — 21 байт с кодом 404. Скрипт,
#     который пишет ответ в правила не глядя, стёр бы маршрутизацию на
#     всём парке.
#
#  2. Резкая усадка списка — отказ. Наполовину собранный или обрезанный
#     файл выглядит валидным: те же домены, просто меньше. Поэтому если
#     новый список короче установленного больше чем на SHRINK_PCT,
#     обновление отклоняется и пишется в лог. Разрастание не ограничено:
#     списки растут постоянно, это норма.
#
#  3. Перезапуск только при реальном изменении. Статические наборы
#     nftables наполняются при старте службы (nftables.sh:1015-1030),
#     то есть новые файлы без перезапуска не применятся. Но перезапуск
#     дорогой: 29.08.2026 два watchdog запустили его одновременно, и
#     нагрузка за три окна ушла с 4.5 на 18.0, роутер перестал отвечать.
#     Поэтому сверяем md5 и зовём titan_pw_restart.sh с его локом и
#     паузой, а не init-скрипт напрямую.
#
#  Зеркало обязано быть в direct: скачать списки через туннель, который
#  этими же списками и настраивается, не выйдет.
# ═══════════════════════════════════════════════════════════════════

set -u

LOG_TAG="titan_lists"
LOG_FILE="/tmp/titan_lists_sync.log"
STAMP="/tmp/titan_lists_sync_at"
LOCK="/tmp/titan_lists_sync.lock"
RULES="/usr/share/passwall/rules"
BASE="https://vbotrouters.titanvps.click/lists"
MIN_GAP=21600
SHRINK_PCT=40

MODE="now"
DRY=0
for a in "$@"; do
    case "$a" in
        ifup) MODE=ifup ;;
        -n)   DRY=1 ;;
    esac
done

log() {
    logger -t "$LOG_TAG" "$*"
    printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null
}

cleanup() { rm -f "$LOCK" /tmp/titan_lists_sync.*.tmp; }

# ── Защита от параллельного запуска ──────────────────────────────
if [ -f "$LOCK" ]; then
    PID=$(cat "$LOCK" 2>/dev/null)
    if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
        log "уже выполняется (pid $PID)"
        exit 0
    fi
fi
echo $$ > "$LOCK"
trap cleanup EXIT INT TERM

[ -d "$RULES" ] || { log "$RULES не найден — PassWall не установлен"; exit 0; }

# ── Запуск от hotplug ────────────────────────────────────────────
if [ "$MODE" = ifup ]; then
    # Отметка живёт в /tmp и пропадает при перезагрузке — так и надо:
    # после ребута списки нужны сразу, пауза защищает только от дёрганого
    # WAN внутри одной сессии.
    LAST="$(cat "$STAMP" 2>/dev/null | tr -dc '0-9')"
    NOW="$(date +%s)"
    if [ -n "${LAST:-}" ] && [ "$((NOW - LAST))" -ge 0 ] && [ "$((NOW - LAST))" -lt "$MIN_GAP" ]; then
        log "обновлялись $(( (NOW - LAST) / 60 )) мин назад — пропускаем"
        exit 0
    fi
    # Интерфейс поднялся, но маршрут и DNS появятся секундой позже.
    i=0
    while [ "$i" -lt 24 ]; do
        curl -fsS --max-time 8 -o /dev/null "$BASE/direct-ip.lst" 2>/dev/null && break
        i=$((i + 1))
        sleep 5
    done
    if [ "$i" -ge 24 ]; then
        log "зеркало не ответило за две минуты — вернёмся на следующем ifup"
        exit 0
    fi
fi

# ── Проверка скачанного ──────────────────────────────────────────
# kind=domain: строки вида example.com, без схемы и слэшей
# kind=ip:     строки вида 1.2.3.0/24 либо одиночные адреса
valid_lines() {
    kind="$1"; file="$2"
    if [ "$kind" = ip ]; then
        grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$' "$file" 2>/dev/null
    else
        grep -cE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' "$file" 2>/dev/null
    fi
}

# Минимум строк, ниже которого файл считается битым. Не «больше нуля»:
# усечённый ответ или страница ошибки могут дать одну-две валидные
# строки и пройти наивную проверку.
min_lines() {
    case "$1" in
        direct_ip)   echo 100 ;;
        direct_host) echo 200 ;;
        proxy_host)  echo 20 ;;
        proxy_ip)    echo 1 ;;
    esac
}

changed=0
failed=0

sync_one() {
    name="$1"; kind="$2"; url="$BASE/$3"
    tmp="/tmp/titan_lists_sync.$name.tmp"
    dst="$RULES/$name"

    if ! curl -fsS --max-time 60 --retry 2 --retry-delay 3 -o "$tmp" "$url" 2>/dev/null; then
        log "$name: не скачался с $url — оставляем прежний"
        failed=$((failed + 1))
        return
    fi

    got=$(valid_lines "$kind" "$tmp")
    got=${got:-0}
    need=$(min_lines "$name")
    if [ "$got" -lt "$need" ]; then
        log "$name: валидных строк $got при минимуме $need — отклонено, файл битый"
        failed=$((failed + 1))
        return
    fi

    # Усадка. Сравниваем с тем, что стоит сейчас: список может расти
    # сколько угодно, но резко похудеть — признак сбоя на сборке.
    if [ -s "$dst" ]; then
        had=$(valid_lines "$kind" "$dst")
        had=${had:-0}
        if [ "$had" -gt 0 ] && [ "$((got * 100 / had))" -lt "$((100 - SHRINK_PCT))" ]; then
            log "$name: было $had строк, стало $got — усадка больше ${SHRINK_PCT}%, отклонено"
            failed=$((failed + 1))
            return
        fi
    fi

    old_md5=$(md5sum "$dst" 2>/dev/null | awk '{print $1}')
    new_md5=$(md5sum "$tmp" 2>/dev/null | awk '{print $1}')
    if [ "$old_md5" = "$new_md5" ]; then
        return
    fi

    if [ "$DRY" = 1 ]; then
        log "$name: изменился ($got строк) — но запуск с -n, не трогаем"
        changed=$((changed + 1))
        return
    fi

    cp "$tmp" "$dst" 2>/dev/null && {
        log "$name: обновлён, $got строк"
        changed=$((changed + 1))
    }
}

sync_one direct_host domain direct-domains.lst
sync_one direct_ip   ip     direct-ip.lst
sync_one proxy_host  domain proxy-domains.lst
sync_one proxy_ip    ip     proxy-ip.lst

date +%s > "$STAMP" 2>/dev/null

# ── Применение ───────────────────────────────────────────────────
# Статические наборы заливаются при старте службы, поэтому без
# перезапуска новые файлы лежат мёртвым грузом. Но и перезапускать
# просто так нельзя — только когда что-то действительно изменилось.
if [ "$changed" -gt 0 ] && [ "$DRY" = 0 ]; then
    log "изменилось файлов: $changed — просим перезапуск"
    [ -x /usr/bin/titan_pw_restart.sh ] \
        && /usr/bin/titan_pw_restart.sh "обновились списки маршрутизации" \
        || log "titan_pw_restart.sh не найден — списки лежат, но не применены"
else
    log "изменений нет"
fi

[ "$failed" -gt 0 ] && log "не обновилось файлов: $failed"

exit 0
