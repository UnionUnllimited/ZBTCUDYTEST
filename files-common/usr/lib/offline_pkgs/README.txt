Пакеты, которые распаковываются в образ при сборке (build.yml, шаг
"Extract offline packages into files/"). Кладутся сюда вручную.

luci_passwall.tar.gz
    PassWall 26.8.26-r1
    Источник: Openwrt-Passwall/openwrt-passwall, релиз 26.8.26-1,
    файл 23.05-24.10_luci-app-passwall_26.8.26-r1_all.ipk, из него
    взят data.tar.gz.

    Почему ipk, а не apk для 25.12: apk-файлы новых релизов идут в
    формате ADB (apk-tools 3), а распаковщик в build.yml работает с
    gzip-tar и такой файл не читает. Пакет архитектурно-независимый
    (_all), это Lua-приложение для LuCI, содержимое одинаковое.

chinadns_dns_tcping.tar.gz
    chinadns-ng, dns2socks, tcping. Версия не зафиксирована.

ВАЖНО: распаковка идёт ПОСЛЕ копирования files-common, поэтому файлы
пакета перетирают одноимённые наши. Сейчас пересекается только
etc/config/passwall_server. Основной etc/config/passwall в пакете
отсутствует и не затрагивается.

При замене пакета обновляйте версию в этом файле — внутри тарболла
метаданных о версии нет, и установить её потом нечем.
