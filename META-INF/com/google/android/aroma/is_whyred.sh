#!/sbin/sh

for p in "ro.product.device" "ro.build.product" "ro.product.vendor.device" "ro.vendor.product.device"; do
  [ "`getprop $p`" == "whyred" ] && exit 0;
done

exit 1
