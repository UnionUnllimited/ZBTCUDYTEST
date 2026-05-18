#!/bin/sh
SUB_URL="$1"
[ -z "$SUB_URL" ] && echo "ERROR: no URL" && exit 1

uci set passwall.@subscribe_list[0].url="$SUB_URL"
uci commit passwall

for node in $(uci show passwall | grep "\.group='AtlantaRouter'" | cut -d'.' -f2); do
    uci delete passwall.$node 2>/dev/null
done
uci delete passwall.fNDZDacw.balancing_node 2>/dev/null
uci commit passwall

lua /usr/share/passwall/subscribe.lua start @subscribe_list[0] manual
echo "OK: $SUB_URL"
