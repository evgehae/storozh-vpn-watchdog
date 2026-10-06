#!/system/bin/sh
MODDIR=${0%/*}
LOG=/data/adb/warp_observer.log
RUNPID=/data/adb/warp_run.pid
WDPID=/data/adb/warp_watchdog.pid

is_ours() { [ -n "$1" ] && [ -r "/proc/$1/cmdline" ] && tr '\0' ' ' < "/proc/$1/cmdline" | grep -q warp_watchdog; }

# Основной путь: гасим по PID-файлам, если они указывают на реально существующий
# наш процесс — это точечно и безопасно.
OLD=$(cat $RUNPID 2>/dev/null)
if [ "$OLD" != "$$" ] && is_ours "$OLD"; then kill "$OLD" 2>/dev/null; fi
OLDW=$(cat $WDPID 2>/dev/null)
if is_ours "$OLDW"; then kill "$OLDW" 2>/dev/null; fi
sleep 1

# Аварийная зачистка: если после этого в системе всё ещё остались процессы с cmdline
# из нашего модуля (PID-файл не совпал — например, после ручной переустановки без
# перезагрузки) — гасим и их, но только как резерв, не основной механизм.
for p in /proc/[0-9]*; do
  PID=${p#/proc/}
  [ "$PID" = "$$" ] && continue
  CMD=$(tr '\0' ' ' < "$p/cmdline" 2>/dev/null)
  case "$CMD" in
    *warp_watchdog/run.sh*|*warp_watchdog/watchdog.sh*) kill "$PID" 2>/dev/null ;;
  esac
done
sleep 1
echo $$ > $RUNPID

while true; do
  sh "$MODDIR/watchdog.sh"
  echo "$(date '+%F %T') | Сторож VPN: процесс неожиданно завершился, перезапуск через 10 сек" >> "$LOG"
  sleep 10
done
