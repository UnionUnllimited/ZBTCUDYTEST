#!/bin/sh
set -eu

# YouTube-only: автоподбор YouTube-стратегии Zapret-Manager + жёсткий YouTube-only Direct (PassWall).
# OpenWrt /bin/sh (ash). Без интерактива — безопасно для cron.

STRATEGIES_URL="${STRATEGIES_URL:-https://raw.githubusercontent.com/StressOzz/Zapret-Manager/main/Strategies_For_Youtube.md}"
DIRECT_FILE="${DIRECT_FILE:-}"
SYNC_ALL_DIRECT_FILES="${SYNC_ALL_DIRECT_FILES:-1}"   # 1 = синхронизировать все найденные direct_host
SELECTED_STRATEGY_FILE="${SELECTED_STRATEGY_FILE:-/tmp/youtube_selected_strategy.conf}"
TMP_DIR="${TMP_DIR:-/tmp/youtube_strategy_picker}"
APPLY_STRATEGY_CMD="${APPLY_STRATEGY_CMD:-}"
YT_CHECK_CMD="${YT_CHECK_CMD:-}"
ZAPRET_CONFIG_PATH="${ZAPRET_CONFIG_PATH:-/opt/zapret/config}"
OPENWRT_STRATEGY_PATH="${OPENWRT_STRATEGY_PATH:-/etc/zapret/youtube_strategy.conf}"
OPENWRT_RESTART_SERVICES="${OPENWRT_RESTART_SERVICES:-zapret}"
PASSWALL_RELOAD_AFTER_DIRECT="${PASSWALL_RELOAD_AFTER_DIRECT:-1}"
PASSWALL_HARD_RESTART_ON_FAIL="${PASSWALL_HARD_RESTART_ON_FAIL:-0}"

# STRICT YouTube-only list
YOUTUBE_DIRECT_DOMAINS="youtube.com
www.youtube.com
m.youtube.com
music.youtube.com
youtu.be
googlevideo.com
ytimg.com
youtubei.googleapis.com"

DIRECT_TARGET_FILES=""
DIRECT_FILE_EXPLICIT="$DIRECT_FILE"

log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log "Ошибка: не найдена команда '$1'"
        exit 1
    }
}

append_unique_line() {
    list="$1"
    line="$2"
    if [ -z "$list" ]; then
        printf '%s' "$line"
        return 0
    fi
    printf '%s\n' "$list" | grep -Fxq "$line" || {
        printf '%s\n%s' "$list" "$line"
        return 0
    }
    printf '%s' "$list"
}

# --- Установка Zapret из remittor/zapret-openwrt (zapret v1) ---
ensure_zapret_installed() {
    if [ -x /etc/init.d/zapret ]; then
        return 0
    fi

    log "Zapret не найден (/etc/init.d/zapret). Ставлю из remittor/zapret-openwrt..."

    if curl -fsSL https://raw.githubusercontent.com/remittor/zapret-openwrt/zap1/zapret/update-pkg.sh -o /tmp/zap.sh; then
        sh /tmp/zap.sh -u 1 || true
    fi

    if [ -x /etc/init.d/zapret ]; then
        log "Zapret установлен."
        return 0
    fi

    log "Ошибка: не удалось установить Zapret автоматически. Проверь интернет/DNS и повтори."
    exit 10
}

# --- Полная очистка zapret host-списков ---
clear_zapret_host_lists() {
    for f in \
        /opt/zapret/ipset/zapret-hosts-user.txt \
        /opt/zapret/ipset/zapret-hosts-user-exclude.txt
    do
        if [ -f "$f" ] && [ -s "$f" ]; then
            : > "$f"
            log "Очищен: $f"
        fi
    done
}

detect_direct_targets() {
    if [ -n "$DIRECT_FILE_EXPLICIT" ]; then
        DIRECT_TARGET_FILES="$DIRECT_FILE_EXPLICIT"
        DIRECT_FILE="$DIRECT_FILE_EXPLICIT"
        return 0
    fi

    found=""
    for candidate in \
        /usr/share/passwall/rules/direct_host \
        /etc/passwall/direct_host \
        /tmp/etc/passwall/direct_host
    do
        if [ -e "$candidate" ]; then
            found="$(append_unique_line "$found" "$candidate")"
            [ "$SYNC_ALL_DIRECT_FILES" = "1" ] || break
        fi
    done

    [ -z "$found" ] && found="/usr/share/passwall/rules/direct_host"
    DIRECT_TARGET_FILES="$found"
    DIRECT_FILE="$(printf '%s\n' "$DIRECT_TARGET_FILES" | sed -n '1p')"
}

reload_passwall_if_needed() {
    [ "$PASSWALL_RELOAD_AFTER_DIRECT" = "1" ] || return 0
    [ -x /etc/init.d/passwall ] || return 0

    if /etc/init.d/passwall reload >/dev/null 2>&1; then
        log "PassWall: выполнен мягкий reload"
        return 0
    fi

    if [ "$PASSWALL_HARD_RESTART_ON_FAIL" = "1" ]; then
        /etc/init.d/passwall restart >/dev/null 2>&1 || \
            log "Предупреждение: не удалось применить обновление PassWall (restart тоже не удался)"
    else
        log "Предупреждение: reload PassWall не удался; hard restart отключен (PASSWALL_HARD_RESTART_ON_FAIL=0)"
    fi
}

ensure_direct_files() {
    detect_direct_targets
    for file in $DIRECT_TARGET_FILES; do
        [ -n "$file" ] || continue
        mkdir -p "$(dirname "$file")"
        touch "$file"
    done
}

# --- ЖЁСТКО: direct_host = ТОЛЬКО YouTube, никаких других строк ---
write_youtube_only_direct() {
    file="$1"
    tmp="$(mktemp)"
    printf '%s\n' "$YOUTUBE_DIRECT_DOMAINS" | awk 'NF { if(!seen[$0]++) print $0 }' > "$tmp"
    mv "$tmp" "$file"
    log "Direct (YouTube-only) перезаписан: $file"
}

enforce_youtube_only_direct_all() {
    ensure_direct_files
    changed_any=0

    for file in $DIRECT_TARGET_FILES; do
        [ -n "$file" ] || continue
        tmp_cmp="$(mktemp)"
        printf '%s\n' "$YOUTUBE_DIRECT_DOMAINS" | awk 'NF { if(!seen[$0]++) print $0 }' > "$tmp_cmp"

        if ! cmp -s "$tmp_cmp" "$file" 2>/dev/null; then
            mv "$tmp_cmp" "$file"
            log "Direct (YouTube-only) обновлён: $file"
            changed_any=1
        else
            rm -f "$tmp_cmp"
        fi
    done

    [ "$changed_any" = "1" ] && reload_passwall_if_needed || true
}

check_youtube() {
    if [ -n "$YT_CHECK_CMD" ]; then
        sh -c "$YT_CHECK_CMD"
        return $?
    fi

    curl -fsS --max-time 8 https://www.youtube.com/generate_204 >/dev/null && \
    curl -fsS --max-time 8 https://i.ytimg.com/generate_204 >/dev/null
}

parse_strategies() {
    source_file="$1"
    mkdir -p "$TMP_DIR"
    rm -f "$TMP_DIR"/strategy_*.conf

    awk -v out_dir="$TMP_DIR" '
        BEGIN { in_code=0; sid="" }
        /^```/ {
            in_code = !in_code
            if (!in_code) sid=""
            next
        }
        in_code && /^#Yv[0-9]+$/ {
            sid = substr($0, 2)
            file = out_dir "/strategy_" sid ".conf"
            print "" > file
            close(file)
            next
        }
        in_code && sid != "" && /^--/ {
            print >> file
        }
    ' "$source_file"
}

set_zapret_nfqws_opt() {
    strategy_file="$1"

    if [ ! -f "$ZAPRET_CONFIG_PATH" ]; then
        log "Предупреждение: $ZAPRET_CONFIG_PATH не найден, применяю только файл стратегии"
        return 0
    fi

    nfqws_opt="$(awk '/^--/ {printf "%s ", $0} END {print ""}' "$strategy_file" | sed 's/[[:space:]]*$//')"
    [ -n "$nfqws_opt" ] || {
        log "Предупреждение: пустой NFQWS_OPT из $strategy_file"
        return 1
    }

    tmp_cfg="$(mktemp)"
    awk -v new_line="NFQWS_OPT=\"${nfqws_opt}\"" '
        BEGIN { done=0 }
        /^NFQWS_OPT="/ && done==0 { print new_line; done=1; next }
        { print }
        END { if (done==0) print new_line }
    ' "$ZAPRET_CONFIG_PATH" > "$tmp_cfg"

    cp "$ZAPRET_CONFIG_PATH" "${ZAPRET_CONFIG_PATH}.bak" 2>/dev/null || true
    mv "$tmp_cfg" "$ZAPRET_CONFIG_PATH"
    log "Обновлен NFQWS_OPT в $ZAPRET_CONFIG_PATH"
}

restart_openwrt_services() {
    for svc in $OPENWRT_RESTART_SERVICES; do
        [ -x "/etc/init.d/$svc" ] && /etc/init.d/"$svc" restart || true
    done
}

apply_strategy_openwrt() {
    strategy_id="$1"
    strategy_file="$2"

    mkdir -p "$(dirname "$OPENWRT_STRATEGY_PATH")"
    cp "$strategy_file" "$OPENWRT_STRATEGY_PATH"
    log "Стратегия $strategy_id сохранена в $OPENWRT_STRATEGY_PATH"

    set_zapret_nfqws_opt "$strategy_file"
    restart_openwrt_services
}

apply_strategy() {
    strategy_id="$1"
    strategy_file="$2"

    cp "$strategy_file" "$SELECTED_STRATEGY_FILE"
    log "Подготовлена стратегия $strategy_id -> $SELECTED_STRATEGY_FILE"

    if [ -n "$APPLY_STRATEGY_CMD" ]; then
        STRATEGY_ID="$strategy_id" STRATEGY_FILE="$SELECTED_STRATEGY_FILE" sh -c "$APPLY_STRATEGY_CMD"
        return 0
    fi

    [ -f /etc/openwrt_release ] && apply_strategy_openwrt "$strategy_id" "$strategy_file" || \
        log "APPLY_STRATEGY_CMD не задан. Только сохраняю стратегию в $SELECTED_STRATEGY_FILE"
}

main() {
    require_cmd curl
    require_cmd sed
    require_cmd grep
    require_cmd awk
    require_cmd find
    require_cmd cmp
    require_cmd mktemp

    ensure_zapret_installed

    # Очищаем zapret host-списки при каждом запуске
    clear_zapret_host_lists

    mkdir -p "$TMP_DIR"
    strategies_md="$TMP_DIR/Strategies_For_Youtube.md"

    detect_direct_targets
    log "Direct-файлы: $(printf '%s' "$DIRECT_TARGET_FILES" | tr '\n' ' ')"
    log "Загружаю стратегии YouTube: $STRATEGIES_URL"

    curl -fsSL "$STRATEGIES_URL" -o "$strategies_md"
    parse_strategies "$strategies_md"

    strategy_files="$(find "$TMP_DIR" -maxdepth 1 -type f -name 'strategy_Yv*.conf' | sort -V)"
    if [ -z "$strategy_files" ]; then
        log "Стратегии не найдены в markdown-файле"
        exit 1
    fi

    for file in $strategy_files; do
        strategy_id="$(basename "$file" .conf | sed 's/^strategy_//')"
        log "Пробую стратегию: $strategy_id"
        apply_strategy "$strategy_id" "$file"
        sleep 2

        if check_youtube; then
            log "Стратегия $strategy_id рабочая"
            enforce_youtube_only_direct_all
            clear_zapret_host_lists
            exit 0
        fi

        log "Стратегия $strategy_id не подошла"
    done

    log "Рабочая стратегия не найдена"

    for f in $DIRECT_TARGET_FILES; do
        : > "$f"
        log "Direct очищен: $f"
    done

    clear_zapret_host_lists
    reload_passwall_if_needed
    exit 2
}

main "$@"
