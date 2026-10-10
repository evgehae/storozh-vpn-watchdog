#!/system/bin/sh
# Сторож VPN (версия читается динамически из module.prop)

# Ранний старт после boot — не ждём Launcher/SystemUI для тихого восстановления.
EARLY_BOOT_WINDOW=180
EARLY_INTERVAL=3
EARLY_BOOT_LOGGED=0

DATA=/data/adb
LOG=$DATA/warp_observer.log
DIAG=$DATA/warp_diag.log
PAUSE=$DATA/warp_pause
STATE_LASTPKG=$DATA/warp_last_vpn_pkg
CONF=$DATA/warp_watchdog.conf
PIDF=$DATA/warp_watchdog.pid
PDNS_BAK=$DATA/warp_pdns_orig
AIR_MARK=$DATA/warp_airplane_marker
TCURL=/data/data/com.termux/files/usr/bin/curl
LIB=/data/data/com.termux/files/usr/lib
CF_PKG=com.cloudflare.onedotonedotonedotone

# Телефон ещё не разблокирован первый раз после перезагрузки (FBE/BFU) — данные
# приложения WARP физически недоступны никому, включая root, пока не введён код
# разблокировки. Пытаться чинить VPN в этот момент бессмысленно и только впустую
# тратит попытки и раздувает паузу между ними. Проверяем по доступности собственной
# папки данных WARP: пуста/недоступна до разблокировки, появляется сразу после неё.
is_bfu() {
  [ -z "$(ls -A "/data/user/0/$CF_PKG/files" 2>/dev/null)" ] && \
  [ -z "$(ls -A "/data/user/0/$CF_PKG/shared_prefs" 2>/dev/null)" ]
}
CF_TILE=$CF_PKG/com.cloudflare.app.domain.quicksettingstile.QuickSettingsTileService
case $0 in */*) MODDIR=${0%/*};; *) MODDIR=.;; esac
MODPROP=$MODDIR/module.prop

# --- настройки по умолчанию (переопределяются в /data/adb/warp_watchdog.conf) ---
MANAGED_PKG=""          # пусто = тот VPN, что запомнила кнопка Action (по умолчанию WARP)
FALLBACK_PKG=""         # запасной VPN (ступень 5), пусто = выключено
FALLBACK_RETURN_MIN=15  # через сколько минут пробовать вернуться с запасного на основной
ALLOW_DNS_BOUNCE=1      # ступень 1: временно выключать Private DNS
ALLOW_NET_BOUNCE=0      # ступень 3: Wi-Fi / моб. данные выкл-вкл (по умолчанию ВЫКЛ — слишком тяжёлая мера для рядового сбоя)
PROACTIVE_REBIND=1      # после смены Wi-Fi/сети проверить WARP и перезапустить, если он реально сломан
REBIND_DELAY_SEC=40    # сколько ждать после смены сети перед проверкой (дать WARP шанс перепривязаться самому)
REBIND_DELAY_WIFI_SEC=55 # то же, но когда только что ПОЯВИЛСЯ Wi-Fi — ему обычно нужно больше времени на реальный маршрут
ALLOW_AIRPLANE=0        # ступень 4: режим полёта выкл-вкл (по умолчанию ВЫКЛ — самая тяжёлая мера)
SILENT_WAIT_SEC=25      # сколько ждать, что Always-on VPN поднимет тоннель САМ, прежде чем трогать плитку/шторку
ALLOW_TILE_UI=1         # 0 = вообще никогда не трогать плитку/шторку (жертвуем скоростью восстановления ради тишины)
ALLOW_ALWAYS_ON=1       # 0 = не выставлять Always-on VPN автоматически (если мешает ручному переключению VPN)
INTERVAL=30             # пауза между проверками, сек
PT=6                    # таймаут одной проверки, сек
NET_CONFIRM_SEC=3        # новое состояние сети должно продержаться столько секунд
FAST_INTERVAL=3          # быстрый цикл после смены сети/при подтверждённом сбое
MAX_VPN_RESTARTS=3      # не больше стольки принудительных перезапусков WARP за окно ниже
VPN_RESTART_WINDOW=600  # окно в секундах для лимита выше (10 мин)
MAX_RECOVERY_TIME=240  # жёсткий потолок на всю лестницу восстановления, сек — дальше принудительно прервать
[ -f "$CONF" ] && . "$CONF"

# --- состояние ---
V=down; CURPKG=""; WAITN=0
I=off; C=off; G=off; T_CF="-"; RES=0
HIST="00000000"; FAILSEQ=0; DOWNN=0
LAST_LOG_KEY=""; LAST_PROP_KEY=""; LAST_PROP_TS=0; PL=0
LAST_IFACE_SIG=""; IFACE_INIT=0; NETSW_UNTIL=0
COOL=300; COOL_UNTIL=0
LAST_OK_STEP=1; LAST_OK_TS=0; LAST_H3=0; LAST_H4=0
WIFI_ID=""; LAST_WIFI_ID=""; PEND_SIG=""; PEND_WIFI=""; PEND_SINCE=0; REBIND_AT=0; REBIND_TRIES=0; LAST_REBIND_TS=0; NETSW_TIMES=""
VPN_RESTART_TIMES=""  # временные метки последних force-stop/плитка через пробел, для лимита MAX_VPN_RESTARTS
PHYS_FAILN=0           # подряд неудачных phys() — сбрасываем DOWNN только после 2 подряд, ping у операторов ненадёжен
FB_SINCE=0; FORCE=0; LAST_DIAG_TS=0
FLICK=0; RECOV_TOTAL=0; RECOV_OK=0; SUMMARY_TS=$(date +%s); HEARTBEAT_TS=$SUMMARY_TS; ALWAYSON_TS=$SUMMARY_TS; BFU_LOGGED=0
FOREIGN_LOGGED=""

log() {
  echo "$(date '+%F %T') | $*" >> $LOG
  if [ $(( $(wc -c < $LOG) + 0 )) -gt 80000 ]; then
    tail -n 400 $LOG > $LOG.t; mv $LOG.t $LOG
  fi
}

notify() {
  cmd notification post -S bigtext -t "$1" 'warp_watchdog' "$2" </dev/null >/dev/null 2>&1
}

CURL=""
if [ -x "$TCURL" ]; then CURL=$TCURL
elif command -v curl >/dev/null 2>&1; then CURL=curl
fi
cu() {
  # Внешний timeout поверх собственного -m у curl — вторая линия защиты: если
  # сетевой стек под сломанным туннелем перестанет реагировать настолько, что
  # даже внутренний таймаут curl не сработает, весь процесс всё равно будет
  # принудительно снят снаружи, не утянув за собой цикл сторожа.
  if [ "$CURL" = "$TCURL" ]; then LD_LIBRARY_PATH=$LIB timeout 10 "$CURL" "$@"; else timeout 10 "$CURL" "$@"; fi
}

# ---------- состояние VPN (один вызов dumpsys за проверку) ----------
refresh_vpn() {
  DSA=$(timeout 5 dumpsys connectivity 2>/dev/null)
  DSV=$(echo "$DSA" | grep -F 'ni{VPN ')
  WIFI_ID=$(echo "$DSA" | grep -F 'ni{WIFI CONNECTED' | head -1 | grep -o 'network{[0-9]*}' | head -1)
  VL=$(echo "$DSV" | grep -F 'ni{VPN CONNECTED' | head -1)
  if [ -n "$VL" ]; then
    V=up; CURPKG=$(echo "$VL" | grep -oE 'VPN:[^ }]+' | head -1 | cut -d: -f2)
  elif echo "$DSV" | grep -qE 'VPN (CONNECTING|SUSPENDED)'; then
    V=wait; CURPKG=""
  else
    V=down; CURPKG=""
  fi
}

managed_pkg() {
  if [ -n "$MANAGED_PKG" ]; then echo "$MANAGED_PKG"; return; fi
  P=$(cat "$STATE_LASTPKG" 2>/dev/null)
  echo "${P:-$CF_PKG}"
}

target_pkg() {
  if [ "$V" = up ] && [ -n "$CURPKG" ]; then echo "$CURPKG"; else managed_pkg; fi
}

find_tile() {
  pkg=$1
  [ -z "$pkg" ] && return 1
  if [ "$pkg" = "$CF_PKG" ]; then echo "$CF_TILE"; return 0; fi
  CF="/data/adb/warp_tile_cache_$(echo "$pkg" | tr -c 'A-Za-z0-9' '_')"
  if [ -s "$CF" ]; then cat "$CF"; return 0; fi
  T=$(timeout 5 dumpsys package "$pkg" 2>/dev/null | grep -B2 'action.QS_TILE' | grep -oE "$pkg/[A-Za-z0-9_.\$]+" | head -1)
  if [ -n "$T" ]; then echo "$T" > "$CF"; echo "$T"; return 0; fi
  return 1
}

# Клик по плитке разворачивает шторку — это заметно и мешает. Используется ТОЛЬКО
# как последний резерв, когда Always-on VPN не поднял тоннель сам за SILENT_WAIT_SEC.
tile_click() {
  [ "$ALLOW_TILE_UI" = 0 ] && { log "Плитка отключена (ALLOW_TILE_UI=0), пропускаю нажатие"; return 1; }
  log "Резерв: разворачиваю шторку и жму плитку (тихое восстановление не сработало)"
  DPY=$(timeout 5 dumpsys power 2>/dev/null | grep -m1 'mWakefulness=' | grep -o 'Awake\|Asleep\|Dozing')
  if [ "$DPY" != "Awake" ]; then
    timeout 5 input keyevent 224 </dev/null >/dev/null 2>&1
    sleep 1
  fi
  timeout 5 cmd statusbar expand-settings </dev/null >/dev/null 2>&1
  sleep 1
  timeout 5 cmd statusbar click-tile "$1" </dev/null >/dev/null 2>&1
  sleep 1
  timeout 5 cmd statusbar collapse </dev/null >/dev/null 2>&1
}

# Считает force-stop как "перезапуск WARP" и не даёт превысить лимит за окно —
# иначе лестница может долбить WARP перезапусками чаще, чем он успевает подняться.
restart_budget_ok() {
  N0=$(date +%s); KEEP=""
  for t in $VPN_RESTART_TIMES; do [ $((N0-t)) -lt $VPN_RESTART_WINDOW ] && KEEP="$KEEP $t"; done
  VPN_RESTART_TIMES=$KEEP
  CNT=$(echo $VPN_RESTART_TIMES | wc -w)
  [ $CNT -lt $MAX_VPN_RESTARTS ]
}
restart_budget_use() { VPN_RESTART_TIMES="$VPN_RESTART_TIMES $(date +%s)"; }

# Ставит Always-on VPN на пакет, если ещё не стоит — тогда систма сама поднимает
# тоннель после force-stop/смены сети, без единого нажатия по плитке.
ensure_always_on() {
  [ "$ALLOW_ALWAYS_ON" = 0 ] && return 0
  CUR=$(timeout 5 settings get secure always_on_vpn_app 2>/dev/null)
  if [ "$CUR" != "$1" ]; then
    timeout 5 settings put secure always_on_vpn_app "$1" >/dev/null 2>&1
    timeout 5 settings put secure always_on_vpn_lockdown 0 >/dev/null 2>&1
    log "Always-on VPN выставлен на $1"
  fi
}

wait_for() {  # $1 up|down, $2 секунд (не дольше 2x по реальным часам)
  w=0; WS0=$(date +%s)
  while [ $w -lt $2 ] && [ $(( $(date +%s) - WS0 )) -lt $(($2*2)) ]; do
    refresh_vpn
    [ "$V" = "$1" ] && return 0
    sleep 2; w=$((w+2))
  done
  refresh_vpn
  [ "$V" = "$1" ]
}

# ---------- физическая сеть и проверки ----------
tcp_ok() {
  [ -z "$CURL" ] && return 1
  CODE=$(cu -4 --interface "$1" -s -m 3 -o /dev/null -w '%{http_code}' https://1.1.1.1/ 2>/dev/null)
  [ -n "$CODE" ] && [ "$CODE" != "000" ]
}

phys() {
  for i in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet_data[0-9]|wlan0)$'); do
    timeout 5 ping -I $i -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && return 0
    timeout 5 ping -I $i -c 1 -W 2 8.8.8.8 >/dev/null 2>&1 && return 0
    tcp_ok "$i" && return 0
  done
  return 1
}

wait_net() {  # $1 секунд
  w=0
  while [ $w -lt $1 ]; do
    phys && return 0
    sleep 3; w=$((w+3))
  done
  return 1
}

iface_sig() {
  for i in $(ls /sys/class/net 2>/dev/null | grep -E '^(rmnet_data[0-9]|wlan0)$'); do
    [ "$(cat /sys/class/net/$i/operstate 2>/dev/null)" = "up" ] && printf '%s,' "$i"
  done
}

in_call() { timeout 5 dumpsys telephony.registry 2>/dev/null | grep -qE 'mCallState=[12]'; }

# IP напрямую через туннель (без DNS)
p_ip() {
  if [ -z "$CURL" ]; then ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; return $?; fi
  B=$(cu -4 -s -m $PT --connect-timeout 4 https://1.1.1.1/cdn-cgi/trace 2>/dev/null)
  [ -n "$B" ] || return 1
  if [ "$CURPKG" = "$CF_PKG" ]; then echo "$B" | grep -qiE 'warp=(on|plus)'; return $?; fi
  return 0
}

# имя №1: cloudflare.com. Для WARP отдельно фиксирует WARP_STATE (см. выше) —
# успех/неуспех этой функции остаётся индикатором "работает ли интернет через тоннель",
# а WARP_STATE — отдельно, "проксирует ли именно WARP", даже если trace вообще не пришёл.
p_cf() {
  if [ -z "$CURL" ]; then T_CF="-"; ping -c 1 -W 3 www.cloudflare.com >/dev/null 2>&1; return $?; fi
  OUT=$(cu -4 -s -m $PT --connect-timeout 4 -w '\n%{time_total}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)
  T_CF=$(echo "$OUT" | tail -1)
  B=$(echo "$OUT" | sed '$d')
  if [ "$CURPKG" != "$CF_PKG" ]; then WARP_STATE="-"; [ -n "$B" ]; return $?; fi
  if [ -z "$B" ]; then WARP_STATE=unknown; return 1; fi
  if echo "$B" | grep -qiE 'warp=(on|plus)'; then WARP_STATE=on; return 0; else WARP_STATE=off; return 1; fi
}

# имя №2: gstatic (204 без тела, поэтому смотрим код, а не тело)
p_g() {
  if [ -z "$CURL" ]; then ping -c 1 -W 3 www.gstatic.com >/dev/null 2>&1; return $?; fi
  GC=$(cu -4 -s -m $PT --connect-timeout 4 -o /dev/null -w '%{http_code}' https://www.gstatic.com/generate_204 2>/dev/null)
  [ "$GC" = 204 ]
}

# WARP_STATE различает два разных состояния, которые раньше путались в одной проверке:
# "интернет вообще не отвечает" (DNS/tunnel) и "интернет отвечает, но сам WARP не проксирует"
# (warp=off в trace при VPN CONNECTED) — именно второе описано как основной баг у пользователя.
WARP_STATE="-"  # on|off|unknown(таймаут)|-(не WARP)

check() {
  I=off; C=off; G="-"; T_CF="-"
  # p_ip запускаем в фоне параллельно с p_cf/p_g, а не последовательно — иначе при
  # настоящем обрыве связи (когда все три проверки гарантированно таймаутят) один
  # цикл проверки может занимать до 18 сек вместо 6, и всё, что завязано на частые
  # повторные проверки (например, перепривязка после смены сети), на деле крутится
  # в 2-3 раза реже, чем задумано в коде.
  IPF=/data/adb/.wd_ipcheck_$$
  ( p_ip && echo 1 > "$IPF" || echo 0 > "$IPF" ) &
  IPPID=$!
  if p_cf; then C=on; else G=off; p_g && G=on; fi
  # Голый wait не имеет собственного тайм-аута — если фоновый curl внутри p_ip
  # зависнет глубже своего же -m 6 (например, сетевой стек под сломанным туннелем
  # перестал реагировать даже на сигналы завершения), wait ждал бы бесконечно и
  # утянул бы за собой весь цикл целиком. Ограничиваем ожидание жёстким потолком.
  WN=0
  while kill -0 "$IPPID" 2>/dev/null && [ $WN -lt 10 ]; do sleep 1; WN=$((WN+1)); done
  kill -9 "$IPPID" 2>/dev/null
  [ "$(cat "$IPF" 2>/dev/null)" = 1 ] && I=on
  rm -f "$IPF"
}

settle() {  # $1 макс. секунд; успех = 3 удачные проверки подряд
  t=0; okrow=0; SS0=$(date +%s)
  while [ $t -lt $1 ] && [ $(( $(date +%s) - SS0 )) -lt $(($1*2)) ]; do
    sleep 8; t=$((t+8))
    refresh_vpn
    if [ "$V" = up ] && p_cf; then
      okrow=$((okrow+1))
      [ $okrow -ge 3 ] && return 0
    else
      okrow=0
    fi
  done
  return 1
}

write_diag() {
  {
    echo "===== $(date '+%F %T') причина=$1 ====="
    echo "ip=$I cf=$C g=$G время_cf=$T_CF"
    if [ -n "$CURL" ]; then
      echo "trace(name)=$(cu -4 -s -m 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | tr '\n' ' ')"
      echo "DoH-обход резолвера: $(cu -4 --doh-url https://1.1.1.1/dns-query -s -m 8 -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null)"
    fi
    echo "физическая сеть: $(phys && echo ok || echo fail)"
    echo "интерфейсы: $(iface_sig)"
    echo "private_dns: $(timeout 5 settings get global private_dns_mode 2>/dev/null) / $(timeout 5 settings get global private_dns_specifier 2>/dev/null)"
    echo "VPN: $(timeout 5 dumpsys connectivity 2>/dev/null | grep -F 'ni{VPN ' | cut -c1-260)"
    echo "DNS по сетям:"
    timeout 5 dumpsys connectivity 2>/dev/null | grep -F 'NetworkAgentInfo{' | sed -n 's/.*ni{\([A-Z]*\).*DnsAddresses: \[\([^]]*\)\].*/  \1 dns=\2/p' | head -6
    # Полные сетевые записи (не только одна строка про VPN) — пригодится для разбора
    # затяжных/повторяющихся сбоев, когда одной строки недостаточно.
    echo "Сетевые агенты (полностью):"
    timeout 5 dumpsys connectivity 2>/dev/null | grep -F 'NetworkAgentInfo{' | cut -c1-400
    echo "Последние события перед сбоем:"
    tail -n 15 "$LOG" 2>/dev/null
  } >> "$DIAG" 2>&1
  if [ $(( $(wc -c < "$DIAG" 2>/dev/null) + 0 )) -gt 60000 ]; then
    tail -n 300 "$DIAG" > "$DIAG.t" && mv "$DIAG.t" "$DIAG"
  fi
}

# ---------- запуск/перезапуск VPN ----------
vpn_enable() {  # $1 пакет: сначала тихое ожидание (Always-on), плитка — только если не помогло
  refresh_vpn
  [ "$V" = up ] && return 0
  ensure_always_on "$1"
  if [ "$V" = wait ]; then wait_for up 40 && return 0; fi
  if wait_for up "$SILENT_WAIT_SEC"; then log "$1 поднялся сам (Always-on), без плитки"; return 0; fi
  [ "$ALLOW_TILE_UI" = 0 ] && { log "ОШИБКА: $1 не поднялся сам, плитка отключена настройкой"; notify "Сторож VPN" "$1 не поднялся сам, включите вручную (плитка отключена настройкой)."; return 1; }
  T=$(find_tile "$1") || { log "Плитка для $1 не найдена — только уведомление"; notify "Сторож VPN" "$1 отключился, плитка не найдена, включите вручную."; return 1; }
  tile_click "$T"
  wait_for up 60 && return 0
  refresh_vpn
  if [ "$V" = down ]; then
    log "Не включился за 60 сек, повторное нажатие"
    tile_click "$T"
    wait_for up 60 && return 0
  elif [ "$V" = wait ]; then
    wait_for up 60 && return 0
  fi
  log "ОШИБКА: $1 не включился"
  rm -f "/data/adb/warp_tile_cache_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"
  notify "Сторож VPN" "Не удалось включить $1, включите вручную."
  return 1
}

vpn_hard_restart() {  # $1 пакет: force-stop убивает тоннель; дальше тихое ожидание, плитка — резерв
  if ! restart_budget_ok; then
    log "Лимит перезапусков WARP исчерпан ($MAX_VPN_RESTARTS за $((VPN_RESTART_WINDOW/60)) мин) — не долблю, жду"
    wait_for up "$SILENT_WAIT_SEC" && return 0
    return 1
  fi
  restart_budget_use
  ensure_always_on "$1"
  timeout 8 am force-stop "$1" >/dev/null 2>&1
  if ! wait_for down 20; then
    refresh_vpn
    if [ "$V" = up ]; then log "После force-stop VPN уже поднят системой"; return 0; fi
  fi
  if wait_for up "$SILENT_WAIT_SEC"; then log "$1 поднялся сам после force-stop (Always-on), без плитки"; return 0; fi
  [ "$ALLOW_TILE_UI" = 0 ] && { log "Тихое восстановление не сработало, плитка отключена настройкой"; return 1; }
  T=$(find_tile "$1") || { log "Плитка для $1 не найдена — только уведомление"; notify "Сторож VPN" "Сбой сети через $1. Плитка не найдена, включите вручную."; return 1; }
  tile_click "$T"
  wait_for up 45 && return 0
  # Двойная проверка с паузой — не путаем переходное состояние с "выключен",
  # иначе повторный клик по тумблеру рискует случайно выключить то, что уже почти поднялось.
  refresh_vpn; ST1=$V
  sleep 3
  refresh_vpn; ST2=$V
  if [ "$ST1" = down ] && [ "$ST2" = down ]; then
    log "VPN всё ещё выключен через 45 сек. Повтор: снова force-stop + плитка (не голый повторный клик — так гарантированно ON, а не переключение туда-обратно)"
    timeout 8 am force-stop "$1" >/dev/null 2>&1
    wait_for down 15
    tile_click "$T"
    wait_for up 45 && return 0
  else
    log "Состояние неоднозначно (не точно 'выключен'), повторное нажатие пропущено ради безопасности"
    wait_for up 30 && return 0
  fi
  rm -f "/data/adb/warp_tile_cache_$(echo "$1" | tr -c 'A-Za-z0-9' '_')"
  return 1
}

# ---------- лестница ступеней ----------
step_dns() {
  log "Ступень 1: сброс DNS-кэша и Private DNS"
  timeout 5 ndc resolver flushdefaultif >/dev/null 2>&1
  if [ "$ALLOW_DNS_BOUNCE" = 1 ]; then
    PM=$(timeout 5 settings get global private_dns_mode 2>/dev/null)
    if [ -z "$PM" ] || [ "$PM" = null ]; then PM=opportunistic; fi
    echo "$PM" > "$PDNS_BAK"
    timeout 5 settings put global private_dns_mode off >/dev/null 2>&1
    sleep 3
    timeout 5 settings put global private_dns_mode "$PM" >/dev/null 2>&1
    rm -f "$PDNS_BAK"
  fi
  # Если отдельно стоит модуль CF DNS-прокси (подменяет зависающий встроенный резолвер
  # WARP) — на этой же ступени перезапускаем и его. Модуля может не быть вовсе, тогда
  # это просто ничего не делает.
  CFDNS_PID=/data/adb/cfdns_proc.pid
  if [ -f "$CFDNS_PID" ]; then
    P=$(cat "$CFDNS_PID" 2>/dev/null)
    [ -n "$P" ] && kill "$P" 2>/dev/null && log "Также перезапускаю CF DNS-прокси (отдельный модуль)"
  fi
  return 0
}

step_vpn() {
  # Свежая проверка прямо перед действием: если за время между решением цикла и этим
  # шагом пользователь вручную переключился на другой (не управляемый) VPN — не трогаем его.
  refresh_vpn
  if [ "$V" = up ] && [ -n "$CURPKG" ] && [ "$CURPKG" != "$(managed_pkg)" ] && [ "$CURPKG" != "$FALLBACK_PKG" ]; then
    log "Перед ступенью 2 обнаружен другой активный VPN ($CURPKG) — не вмешиваюсь"
    return 1
  fi
  TP=$(target_pkg)
  log "Ступень 2: полный перезапуск $TP (force-stop + плитка)"
  vpn_hard_restart "$TP"
}

step_net() {
  log "Ступень 3: перезапуск сети"
  if [ "$(cat /sys/class/net/wlan0/operstate 2>/dev/null)" = up ]; then
    timeout 5 svc wifi disable >/dev/null 2>&1; sleep 4; timeout 5 svc wifi enable >/dev/null 2>&1
  else
    timeout 5 svc data disable >/dev/null 2>&1; sleep 4; timeout 5 svc data enable >/dev/null 2>&1
  fi
  sleep 8
  wait_net 45 || log "Физическая сеть не вернулась за 45 сек"
  sleep 5
  vpn_hard_restart "$(managed_pkg)"
}

air_set() {  # $1 enable|disable
  if [ "$1" = enable ]; then AV=1; AS=true; else AV=0; AS=false; fi
  cmd connectivity airplane-mode "$1" >/dev/null 2>&1
  if [ "$(timeout 5 settings get global airplane_mode_on 2>/dev/null)" != "$AV" ]; then
    timeout 5 settings put global airplane_mode_on $AV >/dev/null 2>&1
    timeout 5 am broadcast -a android.intent.action.AIRPLANE_MODE --ez state $AS >/dev/null 2>&1
  fi
}

step_air() {
  log "Ступень 4: режим полёта"
  touch "$AIR_MARK"
  air_set enable; sleep 6
  air_set disable; sleep 3
  if [ "$(timeout 5 settings get global airplane_mode_on 2>/dev/null)" = 0 ]; then rm -f "$AIR_MARK"; fi
  sleep 10
  wait_net 60 || log "Физическая сеть не вернулась за 60 сек"
  sleep 5
  vpn_hard_restart "$(managed_pkg)"
}

step_fb() {
  log "Ступень 5: переключаемся на запасной VPN ($FALLBACK_PKG)"
  T=$(find_tile "$FALLBACK_PKG") || { log "Плитка запасного VPN не найдена"; return 1; }
  tile_click "$T"
  if wait_for up 60; then FB_SINCE=$(date +%s); return 0; fi
  return 1
}

step_wait() {
  case $1 in
    1) echo 35;; 2) echo 80;; 3) echo 100;; 4) echo 120;; *) echo 60;;
  esac
}

run_step() {  # код 2 = ступень пропущена
  case $1 in
    1) [ "$V" = up ] || return 2; step_dns;;
    2) step_vpn;;
    3) [ "$ALLOW_NET_BOUNCE" = 1 ] || return 2
       if [ "$FORCE" != 1 ] && [ $(( $(date +%s) - LAST_H3 )) -lt 600 ]; then log "Ступень 3 пропущена: не чаще раза в 10 мин"; return 2; fi
       LAST_H3=$(date +%s); step_net;;
    4) [ "$ALLOW_AIRPLANE" = 1 ] || return 2
       if [ "$FORCE" != 1 ] && [ $(( $(date +%s) - LAST_H4 )) -lt 600 ]; then log "Ступень 4 пропущена: не чаще раза в 10 мин"; return 2; fi
       LAST_H4=$(date +%s); step_air;;
    5) [ -n "$FALLBACK_PKG" ] || return 2; step_fb;;
    *) return 2;;
  esac
}

recover_inner() {  # $1 hard|flap  $2 dns|tunnel|down
  KIND=$1; CAUSE=$2
  if in_call; then log "Идёт звонок — восстановление отложено"; return 1; fi
  NR=$(date +%s); RECOV_START=$NR
  RECOV_TOTAL=$((RECOV_TOTAL+1))
  MAX=4; [ -n "$FALLBACK_PKG" ] && MAX=5
  [ "$KIND" = flap ] && MAX=2
  S=1; case "$CAUSE" in tunnel|warp_broken) S=2;; esac
  if [ "$CAUSE" = down ]; then
    log "СБОЙ: VPN выключен при живой сети. Включаем"
    vpn_enable "$(managed_pkg)"
    if settle 45; then
      log "VPN поднят, имена работают"; RECOV_OK=$((RECOV_OK+1)); COOL=300; COOL_UNTIL=$(date +%s); return 0
    fi
    S=2
  else
    SELFTAG=""
  [ $((NR-LAST_REBIND_TS)) -lt 90 ] && SELFTAG=" [в течение 90с после нашей же перепривязки — возможно, самосбой]"
  [ $((NR-LAST_OK_TS)) -lt 90 ] && SELFTAG="$SELFTAG [в течение 90с после нашего же восстановления]"
  log "СБОЙ ($KIND, причина: $CAUSE)$SELFTAG. Запуск лестницы восстановления"
  fi
  if [ $((NR-LAST_OK_TS)) -lt 1200 ] && [ "$LAST_OK_STEP" -gt "$S" ]; then S=$LAST_OK_STEP; [ $S -gt 2 ] && S=2; fi
  [ $S -gt $MAX ] && S=$MAX
  while [ $S -le $MAX ]; do
    if [ -f "$PAUSE" ]; then log "Пауза включена во время восстановления — останавливаюсь"; return 1; fi
    if [ $(( $(date +%s) - RECOV_START )) -ge $MAX_RECOVERY_TIME ]; then
      log "Превышен общий лимит лестницы ($MAX_RECOVERY_TIME с) — прерываю принудительно"
      break
    fi
    T0=$(date +%s); run_step $S; RC=$?
    if [ $RC -ne 2 ]; then
      if settle "$(step_wait $S)"; then
        log "Имена работают после ступени $S ($(( $(date +%s) - T0 )) с)"
        RECOV_OK=$((RECOV_OK+1)); LAST_OK_STEP=$S; LAST_OK_TS=$(date +%s)
        COOL=300; COOL_UNTIL=$((LAST_OK_TS+120))
        [ $S -ge 2 ] && notify "Сторож VPN" "VPN восстановлен (ступень $S)"
        return 0
      fi
      log "Ступень $S не помогла ($(( $(date +%s) - T0 )) с)"
    fi
    S=$((S+1))
  done
  log "Лестница пройдена, не помогло. Следующая попытка через $((COOL/60)) мин"
  notify "Сторож VPN" "Восстановить VPN не удалось, следующая попытка через $((COOL/60)) мин."
  COOL_UNTIL=$(( $(date +%s) + COOL ))
  COOL=$((COOL*2)); [ $COOL -gt 1800 ] && COOL=1800
  return 1
}

# wakelock на время лестницы: иначе телефон засыпает посреди ступени и она тянется десятки минут
wl_on()  { echo warp_watchdog > /sys/power/wake_lock 2>/dev/null; }
wl_off() { echo warp_watchdog > /sys/power/wake_unlock 2>/dev/null; }
# Постоянная защита от убийства процесса системой в простое, С ТАЙМАУТОМ (не вечная!):
# продлевается на каждом цикле опроса. Если процесс умрёт и перестанет её продлевать —
# блокировка сама отвалится максимум через 45 сек, а не будет держать телефон разряженным
# до следующей ручной перезагрузки — это и есть разница между "защитой" и "новой поломкой".
wl_idle_refresh() { echo "warp_watchdog_idle 45000000000" > /sys/power/wake_lock 2>/dev/null; }
recover() {
  wl_on; recover_inner "$@"; RCR=$?; wl_off
  refresh_vpn; LAST_WIFI_ID=$WIFI_ID; LAST_IFACE_SIG=$(iface_sig); REBIND_AT=0
  return $RCR
}

update_prop() {
  [ -f "$MODPROP" ] || return 0
  if [ -f "$PAUSE" ]; then D1="🔴"; S1="на паузе"; else D1="🟢"; S1="активен"; fi
  if [ "$RES" = 0 ]; then D2="🟢"; S2="сеть ок"; elif [ "$RES" = 1 ]; then D2="🟡"; S2="нестабильно"; else D2="🔴"; S2="сбой DNS"; fi
  TXT="description=$D1 Сторож $S1 | $D2 $S2 — $(date '+%H:%M') | восстановлений: $RECOV_OK/$RECOV_TOTAL"
  grep -v '^description=' "$MODPROP" > "$MODPROP.tmp" 2>/dev/null && echo "$TXT" >> "$MODPROP.tmp" && cat "$MODPROP.tmp" > "$MODPROP" 2>/dev/null
  rm -f "$MODPROP.tmp"
}

# ---------- ручные команды: sh watchdog.sh check | step N ----------
case "$1" in
  check)
    refresh_vpn; check
    echo "vpn=$V pkg=$CURPKG управляемый=$(managed_pkg) ip=$I cf=$C($T_CF) g=$G физ=$(phys && echo ok || echo fail)"
    exit 0;;
  step)
    FORCE=1; refresh_vpn
    echo "Ступень $2 (ручной запуск)..."
    run_step "$2"; echo "код=$?"
    settle 60 && echo "После ступени имена работают" || echo "После ступени имена НЕ работают"
    exit 0;;
  status)
    refresh_vpn; check
    [ -f "$PAUSE" ] && PS=пауза || PS=активен
    MYVER=$(grep '^version=' "${0%/*}/module.prop" 2>/dev/null | cut -d= -f2)
    [ -z "$MYVER" ] && MYVER=$(grep '^version=' /data/adb/modules/warp_watchdog/module.prop 2>/dev/null | cut -d= -f2)
    echo "сторож: $PS, версия ${MYVER:-?}"
    echo "vpn=$V pkg=$CURPKG управляемый=$(managed_pkg) always_on=$(timeout 5 settings get secure always_on_vpn_app 2>/dev/null)"
    echo "ip=$I cf=$C warp=$WARP_STATE g=$G"
    echo "лог: $(tail -n 5 "$LOG" 2>/dev/null)"
    exit 0;;
  diag)
    # Ручная, более тяжёлая диагностика — не запускается автоматически внутри лестницы,
    # чтобы не замедлять восстановление. Вызывать самим, когда нужно разобрать конкретный
    # случай подробнее, чем то, что уже и так копится в $DIAG на каждом сбое.
    echo "=== WARP DIAG @ $(date '+%F %T') ==="
    echo "--- dumpsys connectivity (сетевые агенты) ---"
    timeout 5 dumpsys connectivity 2>/dev/null | grep -F 'NetworkAgentInfo{'
    echo "--- logcat, последние строки по пакету WARP (может быть пусто — релизные сборки часто не пишут сюда) ---"
    timeout 5 logcat -d -t 400 2>/dev/null | grep -iE "$CF_PKG|cloudflare|warp" | tail -40
    echo "--- хвост $DIAG (последние сбои) ---"
    tail -n 60 "$DIAG" 2>/dev/null
    echo "=== END ==="
    exit 0;;
esac

# ---------- старт ----------
echo $$ > "$PIDF"
dumpsys deviceidle whitelist +$CF_PKG >/dev/null 2>&1
[ -n "$FALLBACK_PKG" ] && dumpsys deviceidle whitelist +$FALLBACK_PKG >/dev/null 2>&1
# безопасность: вернуть настройки, если прошлый запуск оборвался посреди ступени
if [ -f "$PDNS_BAK" ]; then timeout 5 settings put global private_dns_mode "$(cat "$PDNS_BAK")" >/dev/null 2>&1; rm -f "$PDNS_BAK"; fi
if [ -f "$AIR_MARK" ]; then air_set disable; rm -f "$AIR_MARK"; fi

MYVER=$(grep '^version=' "${0%/*}/module.prop" 2>/dev/null | cut -d= -f2)
[ -z "$MYVER" ] && MYVER=$(grep '^version=' /data/adb/modules/warp_watchdog/module.prop 2>/dev/null | cut -d= -f2)
log "===== Сторож VPN ${MYVER:-(версия неизвестна)} запущен, проверка: ${CURL:-ping} ====="
log "Private DNS: $(timeout 5 settings get global private_dns_mode 2>/dev/null) / $(timeout 5 settings get global private_dns_specifier 2>/dev/null)"
while [ "$(getprop sys.boot_completed)" != 1 ]; do sleep 5; done
# Настоящее время загрузки устройства, не время запуска ЭТОГО процесса — если сторож
# перезапускается сам (неважно, из-за чего), это не должно выглядеть как новая
# перезагрузка телефона и включать заново ускоренный опрос первые 3 минуты.
REAL_BOOT_START=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0) ))
sleep 10

# Раннее окно после загрузки: повышенная частота проверок, UI не требуется.
BOOT_START=$REAL_BOOT_START
SCRIPT_START=$(date +%s)
if [ $(( SCRIPT_START - BOOT_START )) -gt $EARLY_BOOT_WINDOW ]; then
  log "===== Сторож VPN: внутренний перезапуск (не перезагрузка телефона — аптайм $(( (SCRIPT_START-BOOT_START)/60 )) мин) ====="
fi
log "BOOT: ранний запуск сторожа (окно ${EARLY_BOOT_WINDOW} с, UI не требуется)"
EARLY_MODE=1

while true; do
  N=$(date +%s)
  if is_bfu; then
    if [ "$BFU_LOGGED" != 1 ]; then
      log "Телефон ещё не разблокирован после загрузки — WARP не может подключиться физически (шифрование), жду молча, лестницу не трогаю"
      BFU_LOGGED=1
    fi
    sleep 5
    continue
  fi
  if [ "$BFU_LOGGED" = 1 ]; then
    log "Телефон разблокирован — проверяю WARP с чистого листа"
    BFU_LOGGED=0
    COOL=300; COOL_UNTIL=0
  fi
  [ $((N-SUMMARY_TS)) -ge 86400 ] && { log "СВОДКА за сутки: сбоев проверки=$FLICK, восстановлений=$RECOV_TOTAL, успешно=$RECOV_OK"; FLICK=0; RECOV_TOTAL=0; RECOV_OK=0; SUMMARY_TS=$N; }
  # Дешёвый "пульс" раз в ~20 минут — если процесс в следующий раз умрёт молча, будет видно
  # последнюю минуту, когда он точно был жив, а не только сам факт тишины между двумя сбоями.
  [ $((N-HEARTBEAT_TS)) -ge 1200 ] && { log "пульс: сторож жив, аптайм телефона $(( (N-BOOT_START)/60 )) мин"; HEARTBEAT_TS=$N; }
  wl_idle_refresh

  refresh_vpn
  # Раз в ~10 минут, только когда всё и так в порядке — проверяем, не перехватил ли
  # Always-on VPN кто-то другой (другое приложение, сброс настроек и т.п.), не дожидаясь,
  # пока это проявится настоящим сбоем.
  if [ "$V" = up ] && [ "$CURPKG" = "$(managed_pkg)" ] && [ $((N-ALWAYSON_TS)) -ge 600 ]; then
    ensure_always_on "$(managed_pkg)"
    ALWAYSON_TS=$N
  fi
  IFACE_SIG=$(iface_sig)
  if [ "$IFACE_INIT" = 1 ] && { [ "$IFACE_SIG" != "$LAST_IFACE_SIG" ] || [ "$WIFI_ID" != "$LAST_WIFI_ID" ]; }; then
    if [ "$IFACE_SIG" = "$PEND_SIG" ] && [ "$WIFI_ID" = "$PEND_WIFI" ] && [ $((N-PEND_SINCE)) -ge $NET_CONFIRM_SEC ]; then
      # то же новое значение держится уже 2-ю проверку подряд — это реальная смена сети
      log "Смена сети: [${LAST_IFACE_SIG:-нет}] -> [${IFACE_SIG:-нет}], Wi-Fi ${LAST_WIFI_ID:--} -> ${WIFI_ID:--}. Ускоренная проверка 3 мин"
      NETSW_UNTIL=$((N+180))
      # Считаем недавние смены сети — если их накопилось 3+ за последние 5 минут,
      # это не обычное разовое переключение, а нестабильный физический сигнал
      # (например, слабый Wi-Fi, телефон мечется между ним и мобильным). В этом
      # случае активная перепривязка на каждое отдельное дрожание только зря крутит
      # карусель перезапусков — спокойнее положиться на обычную лестницу с её
      # нарастающей паузой, которая и так подхватит реальный сбой, если он останется.
      NSW=""
      for t in $NETSW_TIMES; do [ $((N-t)) -lt 300 ] && NSW="$NSW $t"; done
      NSW="$NSW $N"; NETSW_TIMES=$NSW
      NSWC=$(echo $NETSW_TIMES | wc -w)
      if [ "$PROACTIVE_REBIND" = 1 ] && [ $NSWC -lt 3 ]; then
        if [ -n "$WIFI_ID" ] && [ -z "$LAST_WIFI_ID" ]; then D=$REBIND_DELAY_WIFI_SEC; else D=$REBIND_DELAY_SEC; fi
        REBIND_AT=$((N+D)); REBIND_TRIES=0
      elif [ $NSWC -ge 3 ]; then
        log "Сеть нестабильна ($NSWC смен за 5 мин) — пропускаю активную перепривязку, жду обычную лестницу"
        REBIND_AT=0
      fi
      LAST_IFACE_SIG=$IFACE_SIG; LAST_WIFI_ID=$WIFI_ID
    elif [ "$IFACE_SIG" != "$PEND_SIG" ] || [ "$WIFI_ID" != "$PEND_WIFI" ]; then
      # новое значение увидели впервые — ждём подтверждения на следующей проверке,
      # не дёргаем VPN сразу, чтобы не реагировать на секундное дребезжание ID сети
      PEND_SIG=$IFACE_SIG; PEND_WIFI=$WIFI_ID; PEND_SINCE=$N
    fi
  else
    LAST_IFACE_SIG=$IFACE_SIG; LAST_WIFI_ID=$WIFI_ID
  fi
  IFACE_INIT=1
  MP=$(managed_pkg)
  if [ "$V" = up ] && [ -z "$(cat "$STATE_LASTPKG" 2>/dev/null)" ] && [ -n "$CURPKG" ]; then echo "$CURPKG" > "$STATE_LASTPKG"; MP=$CURPKG; fi

  check

  if [ -f "$PAUSE" ]; then P=1; else P=0; fi
  if [ "$P" != "$PL" ]; then
    if [ $P = 1 ]; then log "Пауза включена"; else log "Пауза снята"; fi
    PL=$P
  fi

  # --- оценка результата ---
  RES=0
  FOREIGN=0
  if [ "$V" = up ]; then
    WAITN=0
    if [ -n "$CURPKG" ] && [ "$CURPKG" != "$MP" ] && [ "$CURPKG" != "$FALLBACK_PKG" ]; then
      FOREIGN=1
    fi
  fi

  CAUSE=""
  if [ "$V" = up ] && [ $FOREIGN = 0 ]; then
    if [ $C = on ]; then RES=0; FAILSEQ=0
    elif [ "$WARP_STATE" = off ]; then
      # trace дошёл, ответ получен, но WARP сам говорит "не проксирую" — это не таймаут и не DNS,
      # это именно сломанный WARP при формально живом VPN-соединении.
      CAUSE=warp_broken; RES=2; FAILSEQ=$((FAILSEQ+1))
    elif [ $G = on ]; then RES=1
    else
      if [ $I = on ]; then CAUSE=dns; elif phys; then CAUSE=tunnel; else CAUSE=net; fi
      if [ $CAUSE = net ]; then RES=0; FAILSEQ=0; else RES=2; FAILSEQ=$((FAILSEQ+1)); fi
    fi
    HIST="${HIST#?}$RES"
    [ $RES -ne 0 ] && FLICK=$((FLICK+1))
  fi

  KEY="ip=$I cf=$C g=$G vpn=$V pkg=$CURPKG"
  if [ "$KEY" != "$LAST_LOG_KEY" ]; then
    log "ip=$I cf=$C(${T_CF}s) g=$G vpn=$V pkg=$CURPKG"
    LAST_LOG_KEY=$KEY
  fi
  if [ $FOREIGN = 1 ]; then
    if [ "$FOREIGN_LOGGED" != "$CURPKG" ]; then log "Активен чужой VPN ($CURPKG), управляемый: $MP — не вмешиваюсь (Action: пауза → подключить → снять паузу, чтобы сменить)"; FOREIGN_LOGGED=$CURPKG; fi
  else
    FOREIGN_LOGGED=""
  fi

  PROPKEY="$KEY|$P|$RES"
  if [ "$PROPKEY" != "$LAST_PROP_KEY" ] || [ $((N-LAST_PROP_TS)) -ge 300 ]; then
    update_prop; LAST_PROP_KEY=$PROPKEY; LAST_PROP_TS=$N
  fi

  # --- решение ---
  TRIG=""; WHY=""
  if [ $P = 1 ]; then
    FAILSEQ=0; DOWNN=0
  elif [ "$V" = down ]; then
    if phys; then DOWNN=$((DOWNN+1)); PHYS_FAILN=0
    else
      PHYS_FAILN=$((PHYS_FAILN+1))
      # ping часто ложно "не отвечает" у операторов — не сбрасываем прогресс на одном сбое,
      # только если физическая сеть НЕ отвечает два раза подряд
      [ $PHYS_FAILN -ge 2 ] && { DOWNN=0; PHYS_FAILN=0; }
    fi
    [ $DOWNN -ge 2 ] && { TRIG=hard; WHY=down; }
  elif [ "$V" = wait ]; then
    WAITN=$((WAITN+1))
    if [ $WAITN -ge 10 ]; then log "VPN завис в состоянии подключения — считаем выключенным"; WAITN=0; TRIG=hard; WHY=tunnel; fi
  elif [ $FOREIGN = 0 ]; then
    BADN=$(echo "$HIST" | tr -d '0' | wc -c); BADN=$((BADN-1))
    if [ $FAILSEQ -ge 2 ]; then TRIG=hard; WHY=$CAUSE
    elif [ $BADN -ge 4 ]; then TRIG=flap; WHY=dns; [ $I = off ] && WHY=tunnel
    fi
  fi

  [ -n "$TRIG" ] && [ -z "$WHY" ] && WHY=dns
  if [ -n "$TRIG" ] && [ $N -ge $COOL_UNTIL ]; then
    # диагностика в фоне: не задерживаем начало восстановления ради сбора логов
    [ $((N-LAST_DIAG_TS)) -ge 300 ] && { write_diag "$TRIG/$WHY" & LAST_DIAG_TS=$N; }
    recover "$TRIG" "$WHY"
    HIST="00000000"; FAILSEQ=0; DOWNN=0; LAST_LOG_KEY=""
  fi

  # --- перепривязка VPN после смены сети: только если WARP реально сломан после смены ---
  if [ $REBIND_AT -gt 0 ] && [ $N -ge $REBIND_AT ] && [ $P = 0 ]; then
    if [ "$V" = up ] && [ $FOREIGN = 0 ]; then
      REBIND_AT=0
      p_cf >/dev/null 2>&1  # свежий замер warp=on/off именно сейчас, после смены сети
      if [ "$C" = on ] || [ "$WARP_STATE" = on ]; then
        log "После смены сети WARP в порядке (warp=on) — не трогаю"
      elif ! p_ip && [ $REBIND_TRIES -lt 4 ]; then
        # на новой сети пока нет вообще никакой связности (даже по IP) — не её вина WARP,
        # сеть ещё не готова. Не чиним, просто проверим ещё раз чуть позже.
        REBIND_TRIES=$((REBIND_TRIES+1)); REBIND_AT=$((N+10))
        log "После смены сети связности ещё нет вообще (не только WARP) — жду ещё (попытка $REBIND_TRIES/4)"
      elif [ $((N-LAST_REBIND_TS)) -ge 300 ] && ! in_call; then
        log "После смены сети WARP не в порядке (warp=$WARP_STATE) — перезапускаю"
        LAST_REBIND_TS=$N
        wl_on
        T0=$(date +%s)
        vpn_hard_restart "$(target_pkg)"
        if settle 45; then log "После перепривязки имена работают ($(( $(date +%s) - T0 )) с)"; else log "После перепривязки имена не работают ($(( $(date +%s) - T0 )) с), дальше по проверкам"; fi
        wl_off
        HIST="00000000"; FAILSEQ=0; LAST_LOG_KEY=""
        refresh_vpn; LAST_WIFI_ID=$WIFI_ID; LAST_IFACE_SIG=$(iface_sig)
      else
        # Ни одно условие не подошло (например, идёт звонок, или недавно уже была
        # перепривязка) — раньше тут молча обнулялся таймер без единой строки в лог,
        # и механизм мог замолчать на неопределённое время без всякого следа. Теперь
        # честно пишем причину и переназначаем короткую повторную проверку.
        if in_call; then
          log "После смены сети WARP не в порядке, но идёт звонок — отложено"
        else
          log "После смены сети WARP не в порядке, но перепривязка была недавно — отложено"
        fi
        REBIND_AT=$((N+20))
      fi
    else
      REBIND_TRIES=$((REBIND_TRIES+1))
      if [ $REBIND_TRIES -ge 6 ]; then REBIND_AT=0; else REBIND_AT=$((N+15)); fi
    fi
  fi

  # --- возврат с запасного VPN на основной ---
  if [ -n "$FALLBACK_PKG" ] && [ "$V" = up ] && [ "$CURPKG" = "$FALLBACK_PKG" ] && [ $P = 0 ] \
     && [ $FB_SINCE -gt 0 ] && [ $((N-FB_SINCE)) -ge $((FALLBACK_RETURN_MIN*60)) ]; then
    log "Пробуем вернуться на основной VPN ($MP)"
    TM=$(find_tile "$MP")
    if [ -n "$TM" ]; then
      tile_click "$TM"; wait_for up 60
      refresh_vpn
      if [ "$CURPKG" = "$MP" ] && settle 45; then
        log "Основной VPN снова работает"; FB_SINCE=0
      else
        log "Основной VPN не готов, остаёмся на запасном"
        TF=$(find_tile "$FALLBACK_PKG"); [ -n "$TF" ] && tile_click "$TF"
        wait_for up 60; FB_SINCE=$(date +%s)
      fi
    else
      FB_SINCE=$(date +%s)
    fi
  fi

  # Пауза между проверками: быстро (10с) при активном сбое или в первые 3 мин после смены
  # сети/загрузки; медленно ($INTERVAL=30с) в остальное время, когда всё и так в порядке —
  # иначе телефон опрашивается слишком часто и ловит больше обычных коротких зависаний
  # как "сбои", даже когда реальной проблемы нет.
  NOW_BOOT=$(( $(date +%s) - BOOT_START ))
  if [ "$RES" != 0 ] || [ $N -lt $NETSW_UNTIL ] || [ "$NOW_BOOT" -lt "$EARLY_BOOT_WINDOW" ]; then
    sleep "$EARLY_INTERVAL"
  else
    EARLY_MODE=0
    sleep "$INTERVAL"
  fi
done
