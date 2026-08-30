#!/bin/sh
# ═══════════════════════════════════════════════════════════════════
#  Titan Router — сторож системного dnsmasq
#
#  Остался от прежнего, куда более обширного watchdog'а. Тот проверял
#  ещё и процесс chinadns-ng, и резолв, и при неудаче перезапускал весь
#  PassWall. Всё это убрано как дублирующее:
#
#    - за процессами PassWall следит его собственный monitor.sh, он
#      запускается при global_delay.start_daemon=1 и поднимает конкретный
#      упавший процесс, а не перезапускает всё разом;
#    - за связностью узлов следит балансировщик (probeInterval 2m);
#    - за хук-цепочками в nftables следит titan_pw_check.sh.
#
#  Здесь осталось единственное, о чём PassWall не знает и знать не может:
#  каталог /etc/dnsmasq.d для СИСТЕМНОГО dnsmasq. Без него тот не
#  стартует вообще — пишет «cannot access directory» и уходит в crash
#  loop. Снаружи роутер при этом выглядит здоровым: PassWall поднимает
#  свой экземпляр dnsmasq и клиенты ничего не замечают, — но служебные
#  процессы остаются без резолва, и первым отваливается frpc, то есть
#  удалённый доступ.
#
#  Каталог держится на одном файле atlanta.conf: пропал он — исчез и
#  каталог.
# ═══════════════════════════════════════════════════════════════════

LOG_TAG="dns_watchdog"

# timeout есть не во всех сборках: в BASE_PACKAGES его нет, в busybox
# этой прошивки апплет не собран. Проверено на ZBT — «timeout: not found».
if command -v timeout >/dev/null 2>&1; then
    TMO="timeout"
else
    TMO=""
fi

CONFDIR="$(uci -q get dhcp.@dnsmasq[0].confdir 2>/dev/null)"
[ -n "$CONFDIR" ] || CONFDIR="/etc/dnsmasq.d"

if [ ! -d "$CONFDIR" ]; then
    logger -t "$LOG_TAG" "нет $CONFDIR — создаём, без него dnsmasq не стартует"
    mkdir -p "$CONFDIR"
    $TMO ${TMO:+60} /etc/init.d/dnsmasq restart
fi
