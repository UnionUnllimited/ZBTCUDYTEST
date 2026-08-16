# Titan Router Firmware

OpenWrt-прошивка с PassWall для обхода блокировок.

## Устройства

| Устройство | Profile | WAN | LAN |
|---|---|---|---|
| ZBT Z8103AX-C | `zbtlink_zbt-z8103ax-c` | eth1 | lan1–lan3 |
| Cudy TR3000 v1 | `cudy_tr3000-v1` | eth0 (2.5G) | eth1 |
| Cudy WR3000S v1 | `cudy_wr3000s-v1` | wan | lan1–lan4 |
| Cudy WR3000E v1 | `cudy_wr3000e-v1` | wan | lan1–lan4 |

## Структура

```
files-common/   общее: passwall, frpc, панель, скрипты, watchdog
files-zbt/      ZBT Z8103AX-C
files-cudy/     Cudy TR3000 v1
files-wr3000s/  Cudy WR3000S v1
files-wr3000e/  Cudy WR3000E v1
```

Сборка склеивает `files-common` с профилем устройства и собирает образ
через OpenWrt Image Builder. Запускается пушем в `main`.

## После прошивки

- Панель: `http://192.168.14.1/` — логин `admin`, пароль `admin`
- LuCI: `http://192.168.14.1/cgi-bin/luci` — логин `root`
- Wi-Fi: `Titan-2.4` и `Titan-5`, **открытые, без пароля** — клиент
  задаёт пароль в мастере настройки при первом входе в панель
- Пароль root вычисляется из MAC адреса br-lan, см. `etc/rc.local`
- IPv6 отключён полностью

Прошивать только **без сохранения настроек**: с сохранением остаётся
старый `/etc/config`, и профиль устройства не применяется.

## Обновления

Автообновление по `manifest.json` удалено. Кнопка «Обновить роутер» в
панели запускает `update.sh` из репозитория `routeratl` вручную.
