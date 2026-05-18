# Atlanta Router Firmware

OpenWrt прошивка с PassWall + Zapret для обхода блокировок.

## Устройства

| Устройство | Profile | WAN | LAN |
|---|---|---|---|
| ZBT Z8103AX-C | `zbtlink_zbt-z8103ax-c` | eth1 | eth0 |
| Cudy TR3000 v1 | `cudy_tr3000-v1` | eth0 (2.5G) | eth1 |

## Структура

```
files-common/   общие файлы (passwall, zapret, frpc, скрипты)
files-zbt/      специфика ZBT (network, wireless)
files-cudy/     специфика Cudy TR3000 (network, wireless)
```

## После прошивки

- LAN: 192.168.14.1
- WiFi: Atlanta-2.4 / Atlanta-5 (пароль: 11111111)
- Пароль root: задан в uci-defaults
