#!/bin/sh

FILES="
buildroot-2026.02/output/images/rootfs.romfs
buildroot-2026.02/output/images/xipImage
buildroot-2026.02/output/target/lib/ld-uClibc-1.0.56.so
buildroot-2026.02/output/target/lib/libuClibc-1.0.56.so
rootfs/init
rootfs/lib/ld-uClibc-1.0.56.so
rootfs/lib/libuClibc-1.0.56.so
rootfs/usr/lib/libts.so.0
rootfs/usr/lib/ts/dejitter.so
rootfs/usr/lib/ts/input.so
rootfs/usr/lib/ts/linear.so
rootfs/usr/lib/ts/pthres.so
"

for FILE in $FILES; do
  if [ ! -f "$FILE" ]; then
    echo "❌ $FILE is missing!"
    exit 1
  fi
done
