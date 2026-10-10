ui_print "- Сторож VPN v4 (WARP Watchdog)"
rm -f /data/adb/service.d/warp_watchdog.sh /data/adb/service.d/warp_observer.sh
rm -f /data/adb/service.d/warp_watchdog.sh.off /data/adb/service.d/warp_observer.sh.off

CONF=/data/adb/warp_watchdog.conf
if [ ! -f "$CONF" ]; then
  cat > "$CONF" << 'CONFEOF'
# Настройки Сторожа VPN (перезагрузка после правки)
# Запасной VPN для ступени 5, например com.cyberportal.connect. Пусто = выключено
FALLBACK_PKG=""
FALLBACK_RETURN_MIN=15
# Ступень 1: временно выключать Private DNS
ALLOW_DNS_BOUNCE=1
# По умолчанию ВЫКЛЮЧЕНО — слишком тяжёлые меры для рядового сбоя. Включайте сами, если нужно.
ALLOW_NET_BOUNCE=0
ALLOW_AIRPLANE=0
# После смены Wi-Fi/сети — проверить, реально ли сломан WARP, и только тогда чинить
PROACTIVE_REBIND=1
REBIND_DELAY_SEC=40
REBIND_DELAY_WIFI_SEC=55
# Сколько ждать, что VPN поднимется сам (Always-on), прежде чем трогать плитку/шторку
SILENT_WAIT_SEC=25
ALLOW_TILE_UI=1
ALLOW_ALWAYS_ON=1
# Пауза между проверками, когда всё в порядке, сек. В первые 3 мин после загрузки
# и во время активного сбоя/смены сети опрос и так ускоряется автоматически.
INTERVAL=30
# Не больше стольки принудительных перезапусков WARP за окно ниже
MAX_VPN_RESTARTS=3
VPN_RESTART_WINDOW=600
# Жёсткий потолок на всю лестницу восстановления, сек
MAX_RECOVERY_TIME=240
CONFEOF
  ui_print "- Создан /data/adb/warp_watchdog.conf"
else
  # Лечим конкретные поломанные значения, которые самодельная версия 1.6.4 когда-то
  # принудительно прописала в конфиг (MAX_RECOVERY_TIME=75 и т.п.) — такой файл иначе
  # выглядит как "пользователь так настроил" и навсегда остаётся сломанным при апгрейде.
  heal_if() {  # $1=ключ $2=плохое_значение $3=новое_значение
    grep -q "^$1=$2\$" "$CONF" && sed -i "s/^$1=$2\$/$1=$3/" "$CONF" && \
      ui_print "- Починено: $1 было $2 (от сломанной 1.6.4), стало $3"
  }
  heal_if MAX_RECOVERY_TIME 75 240
  heal_if SILENT_WAIT_SEC 10 25
  heal_if REBIND_DELAY_SEC 8 40
  heal_if REBIND_DELAY_WIFI_SEC 10 55
  heal_if INTERVAL 10 30

  # Дальше — дописываем только отсутствующие ключи безопасными значениями.
  # Ничего, кроме починенного выше, поверх вашего файла не перезаписываем.
  add() { grep -q "^$1=" "$CONF" || printf '%s\n' "$2" >> "$CONF"; }
  add REBIND_DELAY_SEC 'REBIND_DELAY_SEC=40'
  add REBIND_DELAY_WIFI_SEC 'REBIND_DELAY_WIFI_SEC=55'
  add SILENT_WAIT_SEC 'SILENT_WAIT_SEC=25'
  add ALLOW_TILE_UI 'ALLOW_TILE_UI=1'
  add ALLOW_ALWAYS_ON 'ALLOW_ALWAYS_ON=1'
  add MAX_VPN_RESTARTS 'MAX_VPN_RESTARTS=3'
  add VPN_RESTART_WINDOW 'VPN_RESTART_WINDOW=600'
  add MAX_RECOVERY_TIME 'MAX_RECOVERY_TIME=240'
  ui_print "- Настройки дополнены новыми параметрами (старые сохранены)"
  ui_print "- ВНИМАНИЕ: ALLOW_NET_BOUNCE и ALLOW_AIRPLANE в вашем файле НЕ менялись —"
  ui_print "  если хотите новые безопасные дефолты (выкл.), поправьте их в конфиге вручную."
fi

ui_print "- Лестница восстановления: от лёгких мер к тяжёлым, с паузами между попытками"
ui_print "- Отдельно отличает 'WARP выключен' от 'WARP включён, но не проксирует'"
ui_print "- Перепривязка после смены сети чинит, только если WARP реально сломан"
ui_print "- Лимит принудительных перезапусков WARP и потолок времени на всю лестницу"
ui_print "- Action снова умеет переключать управляемый VPN: нажмите Action (пауза),"
ui_print "  подключите нужный VPN вручную, нажмите Action ещё раз (снять паузу) —"
ui_print "  сторож запомнит именно его. Умная проверка warp=on/off при этом работает"
ui_print "  только для самого WARP, для других VPN — только общая проверка интернета."
ui_print "- Статус одной командой: su -c 'sh /data/adb/modules/warp_watchdog/watchdog.sh status'"
ui_print "- Перезагрузите устройство"
