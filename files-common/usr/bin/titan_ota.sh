#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — обновление прошивки по воздуху
#
#  Запускается из cron ночью. Сам берёт случайную задержку внутри часа,
#  чтобы весь парк не ломился к источнику в одну секунду.
#
#  Адрес манифеста берётся из uci и по умолчанию пуст — пока он не
#  задан, скрипт молча выходит и ничего не делает:
#      uci set atl_panel.main.ota_url='https://…/manifest.json'
#      uci commit atl_panel
#
#  Зеркал может быть несколько, перебираются по порядку до первого
#  ответившего. Каждое отдаёт свой манифест со ссылками на свои же
#  образы, поэтому упавший хост выпадает из схемы целиком:
#      uci delete atl_panel.main.ota_url
#      uci add_list atl_panel.main.ota_url='https://первый/manifest.json'
#      uci add_list atl_panel.main.ota_url='https://второй/manifest.json'
#      uci commit atl_panel
#
#  Ручной запуск — из консоли или кнопкой в панели («Обновить роутер»
#  в меню, дальше карточка «Обновление прошивки»):
#      titan_ota.sh check   посмотреть, что доступно, без установки
#      titan_ota.sh now     обновить немедленно, минуя волну и задержку
# ═══════════════════════════════════════════════════════════════════

set -u

LOG_TAG="titan_ota"
VERSION_FILE="/etc/titan_version"
STATE_FILE="/etc/titan_ota_state"
STATUS_FILE="/etc/titan_ota_status"
LOCK="/tmp/titan_ota.lock"
WORK="/tmp/titan_ota"
MODE="${1:-auto}"

log() { logger -t "$LOG_TAG" "$*"; [ "$MODE" != auto ] && printf '%s\n' "$*"; }
die() { [ -n "${2:-}" ] && set_status "$2"; log "$1"; cleanup; exit 1; }
cleanup() { rm -rf "$WORK"; rm -f "$LOCK"; }

# Статус последнего похода за манифестом — его читает /cgi-bin/stats
# и отдаёт в панель. Пишем в /etc, чтобы переживал перезагрузку:
# проверка ночная, а опрос из панели может прийти когда угодно.
set_status() { echo "$1 $(date +%s)" > "$STATUS_FILE"; }

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

# ── Адреса манифеста ─────────────────────────────────────────────
# uci отдаёт список через пробел, поэтому одиночная option и список
# из add_list разбираются одинаково.
OTA_URLS="$(uci -q get atl_panel.main.ota_url 2>/dev/null || true)"
[ -n "$OTA_URLS" ] || { log "ota_url не задан — выходим"; exit 0; }

# ── Не трогаем только что загрузившийся роутер ───────────────────
# Первые минуты после старта сеть и туннель могут быть нестабильны.
UPTIME=$(awk '{print int($1)}' /proc/uptime)
if [ "$MODE" = auto ] && [ "$UPTIME" -lt 600 ]; then
    log "роутер загрузился $UPTIME с назад — рано"
    exit 0
fi

# ── Случайная задержка внутри часа ───────────────────────────────
if [ "$MODE" = auto ]; then
    SLEEP=$(( $(head -c2 /dev/urandom | od -An -tu2 | tr -d ' ') % 3600 ))
    log "ждём ${SLEEP}с перед проверкой"
    sleep "$SLEEP"
fi

mkdir -p "$WORK"

# ── Манифест ─────────────────────────────────────────────────────
# Перебираем зеркала до первого ответившего.
OTA_URL=""
for u in $OTA_URLS; do
    if curl -fsSL --max-time 60 --retry 1 "$u" -o "$WORK/manifest.json" \
       && [ -s "$WORK/manifest.json" ]; then
        OTA_URL="$u"
        log "манифест взят с $u"
        break
    fi
    log "зеркало не ответило: $u"
    rm -f "$WORK/manifest.json"
done
[ -n "$OTA_URL" ] || die "ни одно зеркало не отдало манифест"

# jsonfilter есть в базовой поставке; на всякий случай грубый запасной разбор
jget() {
    if command -v jsonfilter >/dev/null 2>&1; then
        jsonfilter -i "$WORK/manifest.json" -e "$1" 2>/dev/null | head -n1
    else
        sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\).*/\1/p" \
            "$WORK/manifest.json" | head -n1
    fi
}

NEW_VER="$(jget '@.version' version)"
ROLLOUT="$(jget '@.rollout' rollout)"
NOTES="$(jget '@.notes' notes)"
[ -n "$NEW_VER" ] || die "в манифесте нет version"
case "$NEW_VER" in *[!0-9]*) die "version не число: $NEW_VER";; esac
[ -n "$ROLLOUT" ] || ROLLOUT=100

CUR_VER="$(cat "$VERSION_FILE" 2>/dev/null | tr -dc '0-9')"
[ -n "$CUR_VER" ] || CUR_VER=0

BOARD="$(cat /tmp/sysinfo/board_name 2>/dev/null)"
[ -n "$BOARD" ] || die "не удалось определить модель"

log "текущая версия $CUR_VER, доступна $NEW_VER, модель $BOARD"
[ -n "$NOTES" ] && log "что нового: $NOTES"

if [ "$NEW_VER" -le "$CUR_VER" ]; then
    log "обновление не требуется"
    set_status no_update
    exit 0
fi

URL="$(jget "@.images[\"$BOARD\"].url" url)"
SHA="$(jget "@.images[\"$BOARD\"].sha256" sha256)"
SIZE="$(jget "@.images[\"$BOARD\"].size" size)"
[ -n "$URL" ] || die "в манифесте нет образа для $BOARD" no_image
[ -n "$SHA" ] || die "в манифесте нет sha256 для $BOARD" no_image

# ── Волна раскатки ───────────────────────────────────────────────
# Роутер вычисляет свой номер от 0 до 99 по хешу собственного MAC.
# Обновляется, только если номер попал в открытую долю парка. Это даёт
# устойчивое разбиение: один и тот же роутер всегда в одной волне,
# и неудачная версия задевает часть парка, а не весь сразу.
MAC="$(cat /sys/class/net/br-lan/address 2>/dev/null | tr -d ':')"
BUCKET=$(( 0x$(printf '%s' "$MAC" | sha256sum | cut -c1-2) * 100 / 256 ))
log "волна: роутер $BUCKET, открыто $ROLLOUT"
if [ "$MODE" = auto ] && [ "$BUCKET" -ge "$ROLLOUT" ]; then
    log "ещё не наша волна — ждём расширения"
    set_status not_in_rollout
    exit 0
fi

# ── Защита от бесконечного цикла ─────────────────────────────────
# Если версия в манифесте не совпадает с той, что реально внутри
# образа, роутер поставит его, после перезагрузки увидит прежнюю
# версию у себя и пойдёт ставить снова — и так каждую ночь. Считаем
# попытки и после трёх останавливаемся, чтобы ошибка публикации не
# превратилась в вечную переустановку на всём парке.
LAST_VER="$(awk '{print $1}' "$STATE_FILE" 2>/dev/null)"
LAST_TRIES="$(awk '{print $2}' "$STATE_FILE" 2>/dev/null)"
case "$LAST_TRIES" in ""|*[!0-9]*) LAST_TRIES=0;; esac
if [ "$LAST_VER" = "$NEW_VER" ] && [ "$LAST_TRIES" -ge 3 ]; then
    die "версия $NEW_VER ставилась $LAST_TRIES раза, а роутер всё ещё на $CUR_VER — в образе другая версия, остановлено"
fi

# Досюда режим check доходит, только если версия новее и образ для этой
# модели в манифесте есть, — значит обновление действительно доступно.
# Панель читает статус и показывает его в карточке обновления.
[ "$MODE" = check ] && {
    set_status update_available
    log "проверка завершена, установка не запускалась"
    exit 0
}

# ── Место под образ ──────────────────────────────────────────────
# /tmp это RAM. Качать вслепую нельзя: нехватка памяти посреди
# записи в флеш — это кирпич.
AVAIL=$(df -k /tmp | awk 'NR==2{print $4}')
NEED=$(( ${SIZE:-30000000} / 1024 + 20000 ))
[ "$AVAIL" -gt "$NEED" ] || die "мало памяти: свободно ${AVAIL}К, нужно ${NEED}К"

# ── Скачивание ───────────────────────────────────────────────────
IMG="$WORK/firmware.bin"
log "качаем $URL"
curl -fsSL --max-time 900 --retry 2 "$URL" -o "$IMG" || die "образ не скачался" download_failed
[ -s "$IMG" ] || die "образ пуст" download_failed

# ── Проверка целостности ─────────────────────────────────────────
# Главная защита от кирпича: оборванная закачка, записанная в флеш —
# это выезд к клиенту.
GOT="$(sha256sum "$IMG" | cut -d' ' -f1)"
if [ "$GOT" != "$SHA" ]; then
    die "sha256 не совпал: ожидали $SHA, получили $GOT" sha_mismatch
fi
log "sha256 совпал"

# ── Проверка совместимости ───────────────────────────────────────
# -T проверяет образ, ничего не записывая: та ли модель, не побит ли.
if ! sysupgrade -T "$IMG" >/dev/null 2>&1; then
    die "sysupgrade отверг образ — не для этой модели или повреждён" flash_failed
fi
log "образ принят проверкой sysupgrade"

# ── Установка ────────────────────────────────────────────────────
# Настройки сохраняем: /etc/titan_installed лежит в sysupgrade.conf,
# по нему установщик поймёт, что роутер уже настроен, и не тронет
# Wi-Fi и пароль панели клиента.
# Отмечаем попытку до записи: если прошивка не поднимется, счётчик
# уже увеличен и цикл не начнётся.
if [ "$LAST_VER" = "$NEW_VER" ]; then
    echo "$NEW_VER $((LAST_TRIES + 1))" > "$STATE_FILE"
else
    echo "$NEW_VER 1" > "$STATE_FILE"
fi
sync
log "ставим версию $NEW_VER, роутер перезагрузится"
rm -f "$LOCK"
trap - EXIT INT TERM
# Успехом считаем момент перед записью: образ скачан, хеш сверен,
# sysupgrade -T принял. Дальше решает уже он сам.
#
# После sysupgrade ничего не проверяем: он закрывает все сессии, стартует
# запись и ВОЗВРАЩАЕТ управление, поэтому судить по коду возврата нельзя —
# он одинаков и при успешной прошивке, и при неудаче. Настоящий провал
# ловится иначе: после перезагрузки версия не изменится, сработает
# счётчик попыток и после третьей обновление остановится.
set_status ok
sysupgrade "$IMG"
