#!/bin/sh
# DNS Watchdog — проверяет chinadns-ng каждые 5 минут

LOG_TAG="dns_watchdog"

if ! pgrep -f chinadns-ng >/dev/null 2>&1; then
    logger -t "$LOG_TAG" "chinadns-ng не запущен — перезапускаем PassWall"
    /etc/init.d/passwall restart
    exit 0
fi

# Проверяем что DNS отвечает
DNS_OK=$(nslookup google.com 127.0.0.1 2>/dev/null | grep -c Address)
if [ "$DNS_OK" -eq 0 ]; then
    logger -t "$LOG_TAG" "DNS не отвечает — перезапускаем dnsmasq"
    /etc/init.d/dnsmasq restart
fi
