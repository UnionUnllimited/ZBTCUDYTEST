#!/bin/sh
# Atlanta Router — умное обновление с проверкой подписи
# Использование: update_all.sh [check|all|xray|passwall|zapret|frpc|panel|scripts]

LOG_TAG="atlanta_update"
TMP_DIR="/tmp/atlanta_update"
COMPONENT="${1:-check}"
PUBLIC_KEY="/etc/atlanta/public.key"

# ── Зеркала ─────────────────────────────────────────────────────
MIRRORS="
https://github.com/UnionUnllimited/updates/releases/latest/download
https://origin.all-streams-24.ru/updates
https://1222.hb.ru-msk.vkcloud-storage.ru/updates
https://storage.yandexcloud.net/234588/updates
"

# ── Скачать файл с зеркал ───────────────────────────────────────
download() {
    local file="$1" dest="$2" ok=1
    for mirror in $MIRRORS; do
        mirror=$(echo "$mirror" | tr -d ' ')
        [ -z "$mirror" ] && continue
        curl -s --max-time 30 --retry 2 \
            "${mirror}/${file}" -o "${dest}.tmp" 2>/dev/null
        if [ -s "${dest}.tmp" ]; then
            mv "${dest}.tmp" "$dest"
            logger -t "$LOG_TAG" "OK: $file"
            ok=0; break
        fi
        rm -f "${dest}.tmp"
    done
    [ $ok -ne 0 ] && logger -t "$LOG_TAG" "FAIL: $file"
    return $ok
}

# ── Проверить подпись файла ──────────────────────────────────────
verify_sig() {
    local file="$1"
    local sig="${file}.sig"

    # Качаем подпись
    download "$(basename $sig)" "$sig" || {
        logger -t "$LOG_TAG" "FAIL: подпись $(basename $sig) недоступна"
        return 1
    }

    # Проверяем подпись через usign
    if usign -V -m "$file" -p "$PUBLIC_KEY" -s "$sig" 2>/dev/null; then
        logger -t "$LOG_TAG" "OK: подпись $(basename $file) верна"
        return 0
    else
        logger -t "$LOG_TAG" "FAIL: подпись $(basename $file) НЕВЕРНА — отклоняем"
        rm -f "$file" "$sig"
        return 1
    fi
}

# ── Получить поле из manifest ────────────────────────────────────
remote_ver() {
    local comp="$1"
    grep "\"${comp}\"" "$TMP_DIR/manifest.json" 2>/dev/null | \
        sed 's/.*:.*"\(.*\)".*/\1/'
}

current_ver() {
    uci get "atl_panel.@main[0].ver_${1}" 2>/dev/null || echo "0"
}

save_ver() {
    uci set "atl_panel.@main[0].ver_${1}=${2}"
    uci commit atl_panel
}

needs_update() {
    local remote current
    remote=$(remote_ver "$1")
    current=$(current_ver "$1")
    [ -z "$remote" ] && return 1
    [ "$remote" != "$current" ] && return 0
    return 1
}

# ── Обновить Xray ────────────────────────────────────────────────
update_xray() {
    local ver=$(remote_ver "xray")
    logger -t "$LOG_TAG" "Обновляем xray $ver..."
    download "xray-linux-arm64.gz" "$TMP_DIR/xray.gz" || return 1
    verify_sig "$TMP_DIR/xray.gz" || return 1
    gzip -d "$TMP_DIR/xray.gz" -c > "$TMP_DIR/xray" 2>/dev/null || \
        cp "$TMP_DIR/xray.gz" "$TMP_DIR/xray"
    chmod +x "$TMP_DIR/xray"
    "$TMP_DIR/xray" version >/dev/null 2>&1 || {
        logger -t "$LOG_TAG" "FAIL: xray бинарь не работает"
        return 1
    }
    /etc/init.d/passwall stop
    cp "$TMP_DIR/xray" /usr/bin/xray
    /etc/init.d/passwall start
    save_ver "xray" "$ver"
    logger -t "$LOG_TAG" "OK: xray → $ver"
}

# ── Обновить PassWall ────────────────────────────────────────────
update_passwall() {
    local ver=$(remote_ver "passwall")
    logger -t "$LOG_TAG" "Обновляем passwall $ver..."
    download "luci_passwall.tar.gz" "$TMP_DIR/luci_passwall.tar.gz" || return 1
    verify_sig "$TMP_DIR/luci_passwall.tar.gz" || return 1
    /etc/init.d/passwall stop
    tar xzf "$TMP_DIR/luci_passwall.tar.gz" -C / 2>/dev/null
    sed -i 's/return (version or ""):gsub("\\n", ""):match("^([^-]+)")/return (version or ""):gsub("\\n", ""):match("^([^-]+)") or "0"/' \
        /usr/lib/lua/luci/passwall/api.lua 2>/dev/null
    /etc/init.d/passwall start
    save_ver "passwall" "$ver"
    logger -t "$LOG_TAG" "OK: passwall → $ver"
}

# ── Обновить Zapret ──────────────────────────────────────────────
update_zapret() {
    local ver=$(remote_ver "zapret")
    logger -t "$LOG_TAG" "Обновляем zapret $ver..."
    download "zapret_all.tar.gz" "$TMP_DIR/zapret_all.tar.gz" || return 1
    verify_sig "$TMP_DIR/zapret_all.tar.gz" || return 1
    /etc/init.d/zapret stop
    tar xzf "$TMP_DIR/zapret_all.tar.gz" -C / 2>/dev/null
    /etc/init.d/zapret start
    save_ver "zapret" "$ver"
    logger -t "$LOG_TAG" "OK: zapret → $ver"
}

# ── Обновить FRP ─────────────────────────────────────────────────
update_frpc() {
    local ver=$(remote_ver "frpc")
    logger -t "$LOG_TAG" "Обновляем frpc $ver..."
    download "frpc-linux-arm64" "$TMP_DIR/frpc" || return 1
    verify_sig "$TMP_DIR/frpc" || return 1
    chmod +x "$TMP_DIR/frpc"
    "$TMP_DIR/frpc" --version >/dev/null 2>&1 || {
        logger -t "$LOG_TAG" "FAIL: frpc бинарь не работает"
        return 1
    }
    /etc/init.d/frpc stop
    cp "$TMP_DIR/frpc" /usr/bin/frpc
    /etc/init.d/frpc start
    save_ver "frpc" "$ver"
    logger -t "$LOG_TAG" "OK: frpc → $ver"
}

# ── Обновить панель ──────────────────────────────────────────────
update_panel() {
    local ver=$(remote_ver "panel")
    logger -t "$LOG_TAG" "Обновляем панель $ver..."
    download "panel.tar.gz" "$TMP_DIR/panel.tar.gz" || return 1
    verify_sig "$TMP_DIR/panel.tar.gz" || return 1
    tar xzf "$TMP_DIR/panel.tar.gz" -C /www/ 2>/dev/null
    chmod +x /www/cgi-bin/* 2>/dev/null
    find /www/cgi-bin/ -type f -exec sed -i 's/\r//' {} \;
    /etc/init.d/uhttpd restart
    save_ver "panel" "$ver"
    logger -t "$LOG_TAG" "OK: панель → $ver"
}

# ── Обновить скрипты ─────────────────────────────────────────────
update_scripts() {
    local ver=$(remote_ver "scripts")
    logger -t "$LOG_TAG" "Обновляем скрипты $ver..."
    download "scripts.tar.gz" "$TMP_DIR/scripts.tar.gz" || return 1
    verify_sig "$TMP_DIR/scripts.tar.gz" || return 1
    tar xzf "$TMP_DIR/scripts.tar.gz" -C / 2>/dev/null
    chmod +x /usr/bin/*.sh /usr/bin/frpc 2>/dev/null
    find /usr/bin/ -name "*.sh" -exec sed -i 's/\r//' {} \;
    save_ver "scripts" "$ver"
    logger -t "$LOG_TAG" "OK: скрипты → $ver"
}

# ── Показать статус ──────────────────────────────────────────────
show_status() {
    echo "=== Версии компонентов ==="
    for comp in xray passwall zapret frpc panel scripts; do
        local remote current status
        remote=$(remote_ver "$comp")
        current=$(current_ver "$comp")
        [ "$remote" = "$current" ] && status="OK" || status="ОБНОВИТЬ"
        printf "%-12s текущая=%-12s доступная=%-12s [%s]\n" \
            "$comp" "$current" "${remote:-недоступна}" "$status"
    done
}

# ── Основная логика ──────────────────────────────────────────────
mkdir -p "$TMP_DIR"

# Проверяем публичный ключ
[ ! -f "$PUBLIC_KEY" ] && {
    logger -t "$LOG_TAG" "FAIL: публичный ключ не найден: $PUBLIC_KEY"
    echo "FAIL: публичный ключ не найден"
    exit 1
}

# Качаем manifest и проверяем его подпись
download "manifest.json" "$TMP_DIR/manifest.json" || {
    echo "Нет доступа к серверу обновлений"
    rm -rf "$TMP_DIR"
    exit 1
}
verify_sig "$TMP_DIR/manifest.json" || {
    echo "FAIL: manifest.json подпись неверна — обновление отменено"
    rm -rf "$TMP_DIR"
    exit 1
}

case "$COMPONENT" in
    check)      show_status ;;
    all)
        show_status
        echo ""
        UPDATED=0
        for comp in xray passwall zapret frpc panel scripts; do
            if needs_update "$comp"; then
                update_${comp}
                UPDATED=$((UPDATED+1))
            else
                echo "  $comp — актуален"
            fi
        done
        echo ""
        [ $UPDATED -eq 0 ] && echo "Всё актуально" || \
            echo "Обновлено: $UPDATED компонентов"
        ;;
    xray|passwall|zapret|frpc|panel|scripts)
        update_${COMPONENT} ;;
    *)
        echo "Использование: $0 [check|all|xray|passwall|zapret|frpc|panel|scripts]"
        exit 1 ;;
esac

rm -rf "$TMP_DIR"
logger -t "$LOG_TAG" "Готово: $COMPONENT"
