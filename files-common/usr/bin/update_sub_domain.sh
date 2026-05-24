#!/bin/sh
# Смена домена подписки PassWall
# Меняет только домен, хвост (токен) сохраняется
#
# Использование:
#   update_sub_domain.sh <новый_домен>
# Пример:
#   update_sub_domain.sh "new-subs.example.ru"
#
# Текущий URL: https://t--8g.atlanta-subs.ru/FKJsY-tT36skcFzS
# После:       https://new-subs.example.ru/FKJsY-tT36skcFzS
#
# Или полный URL:
#   update_sub_domain.sh "https://new-subs.example.ru/новый_токен"

NEW="$1"
[ -z "$NEW" ] && echo "ERROR: укажи новый домен или полный URL" && exit 1

# Получаем текущий URL
CURRENT_URL=$(uci get passwall.@subscribe_list[0].url 2>/dev/null)
if [ -z "$CURRENT_URL" ]; then
    echo "ERROR: URL подписки не найден в UCI"
    exit 1
fi

echo "Текущий URL: $CURRENT_URL"

# Определяем новый URL
if echo "$NEW" | grep -q "^https\?://"; then
    # Передан полный URL
    NEW_URL="$NEW"
else
    # Передан только домен — берём хвост от текущего URL
    TAIL=$(echo "$CURRENT_URL" | sed 's|https\?://[^/]*||')
    NEW_URL="https://${NEW}${TAIL}"
fi

echo "Новый URL:   $NEW_URL"
echo ""

# Применяем
/usr/bin/apply_sub.sh "$NEW_URL"
