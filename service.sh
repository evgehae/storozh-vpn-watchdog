#!/system/bin/sh
MODDIR=${0%/*}
nohup sh "$MODDIR/run.sh" >/dev/null 2>&1 &
