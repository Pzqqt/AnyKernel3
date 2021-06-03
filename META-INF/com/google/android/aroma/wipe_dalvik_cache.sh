#!/sbin/sh

# Wipe /data/dalvik-cache & /cache partition

[ -d /data/dalvik-cache ] && rm -rf /data/dalvik-cache

mount | grep " /cache " &>/dev/null || mount -o rw /cache
rm -rf /cache/*
