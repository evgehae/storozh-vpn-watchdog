#!/system/bin/sh
echo warp_watchdog > /sys/power/wake_unlock 2>/dev/null
echo warp_watchdog_idle > /sys/power/wake_unlock 2>/dev/null
for p in warp_watchdog.pid warp_run.pid warp_pause warp_pdns_orig warp_airplane_marker; do rm -f /data/adb/$p; done
