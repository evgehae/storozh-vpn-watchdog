#!/system/bin/sh
F=/data/adb/warp_pause
LASTPKG=/data/adb/warp_last_vpn_pkg
vpn_pkg() { dumpsys connectivity 2>/dev/null | grep -F 'ni{VPN CONNECTED' | grep -oE 'VPN:[^ }]+' | head -1 | cut -d: -f2; }

if [ -f "$F" ]; then
  rm -f "$F"
  echo "Пауза СНЯТА."
  PKG=$(vpn_pkg)
  if [ -n "$PKG" ]; then
    echo "$PKG" > "$LASTPKG"
    echo "Управляемый VPN: $PKG"
  else
    echo "VPN сейчас не подключён — управляемый VPN не менялся."
  fi
  echo "Сторож снова следит."
else
  touch "$F"
  echo "Пауза ВКЛЮЧЕНА. Сторож ничего не делает."
  echo "Чтобы сменить управляемый VPN: подключите нужный,"
  echo "и нажмите Action ещё раз, чтобы снять паузу."
fi
echo ""
echo "Управляемый сейчас: $(cat $LASTPKG 2>/dev/null || echo 'WARP (по умолчанию)')"
echo ""
echo "Последние строки лога:"
tail -n 6 /data/adb/warp_observer.log 2>/dev/null | cut -c1-120
