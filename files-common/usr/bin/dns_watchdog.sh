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

# ── Не трогаем только что загрузившийся роутер ───────────────────
# PassWall стартует не сразу: global_delay.start_delay даёт ему минуту,
# плюс время на заливку списков. Проверка внутри этого окна увидит
# отсутствующий chinadns-ng и потребует перезапуск ровно тогда, когда
# сервис ещё только поднимается. Так 29.08.2026 и началась лавина.
UPTIME=$(awk '{print int($1)}' /proc/uptime)
[ "$UPTIME" -lt 300 ] && exit 0

# Перезапуск PassWall — только через общую точку: она держит лок и паузу,
# чтобы мы с vpn_watchdog не пускали два рестарта внахлёст.
pw_restart() {
    if [ -x /usr/bin/titan_pw_restart.sh ]; then
        /usr/bin/titan_pw_restart.sh "$1"
    else
        $TMO ${TMO:+120} /etc/init.d/passwall restart
    fi
}

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
    logger -t "$LOG_TAG" "chinadns-ng не запущен"
    pw_restart "dns_watchdog: нет процесса chinadns-ng"
    exit 0
fi

# ── ответ резолвера ──────────────────────────────────────────────
DNS_OK=$(nslookup google.com 127.0.0.1 2>/dev/null | grep -c Address)
if [ "$DNS_OK" -eq 0 ]; then
    logger -t "$LOG_TAG" "DNS не отвечает — перезапускаем dnsmasq"
    $TMO ${TMO:+60} /etc/init.d/dnsmasq restart
fi
