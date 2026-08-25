#!/bin/sh
# DNS Watchdog — проверяет chinadns-ng и системный dnsmasq каждые 5 минут

LOG_TAG="dns_watchdog"

# timeout есть не во всех сборках: в BASE_PACKAGES его нет, в busybox
# этой прошивки апплет не собран. Без обёртки init-скрипт умеет виснуть
# на procd-локе и держать его до перезагрузки, поэтому используем, если
# доступен, но не зависим от него.
if command -v timeout >/dev/null 2>&1; then
    TMO="timeout"
else
    TMO=""
fi

# ── confdir ──────────────────────────────────────────────────────
# Без этого каталога dnsmasq не стартует вообще: пишет "cannot access
# directory" и уходит в crash loop. Внешне роутер при этом выглядит
# здоровым — PassWall поднимает свой экземпляр и клиенты не замечают,
# — но служебные процессы остаются без резолва, и первым отваливается
# frpc, то есть удалённый доступ.
CONFDIR="$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null)"
[ -n "$CONFDIR" ] || CONFDIR="/etc/dnsmasq.d"

if [ ! -d "$CONFDIR" ]; then
    logger -t "$LOG_TAG" "нет $CONFDIR — создаём, без него dnsmasq не стартует"
    mkdir -p "$CONFDIR"
    $TMO ${TMO:+60} /etc/init.d/dnsmasq restart
    exit 0
fi

# ── chinadns-ng ──────────────────────────────────────────────────
if ! pgrep -f chinadns-ng >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "chinadns-ng не запущен — перезапускаем PassWall"
    $TMO ${TMO:+120} /etc/init.d/passwall restart
    exit 0
fi

# ── ответ резолвера ──────────────────────────────────────────────
DNS_OK=$(nslookup google.com 127.0.0.1 2>/dev/null | grep -c Address)
if [ "$DNS_OK" -eq 0 ]; then
    logger -t "$LOG_TAG" "DNS не отвечает — перезапускаем dnsmasq"
    $TMO ${TMO:+60} /etc/init.d/dnsmasq restart
fi
