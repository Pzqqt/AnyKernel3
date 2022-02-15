# AnyKernel3 Ramdisk Mod Script
# osm0sis @ xda-developers

## AnyKernel setup
# begin properties
# Pzqqt: disable do.devicecheck (we check device in advance in Aroma Installer)
properties() { '
kernel.string=Panda Kernel by Pzqqt
do.devicecheck=0
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=whyred
device.name2=
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
'; } # end properties

# shell variables
block=/dev/block/bootdevice/by-name/boot;
is_slot_device=0;
ramdisk_compression=auto;


## AnyKernel methods (DO NOT CHANGE)
# import patching functions/variables - see for reference
. tools/ak3-core.sh;


## AnyKernel install
# Pzqqt: Skip ramdisk unpacking and repacking (we don't modify anything in the ramdisk)
# Idea from https://github.com/kdrag0n/proton_kernel_wahoo/commit/375fa432a5e04559ebb1e61b4f05f1fffee08c5f
# dump_boot;
split_boot;

############################## CUSTOM BY PANDA KERNEL ##############################

# Since the busybox or AnyKernel3 has been installed in the $AKHOME/bin and added to the beginning of $PATH,
# I can use busybox's tools directly and preferentially here.
# Nice job osm0sis!

aroma_show_progress() {
  # aroma_show_progress <amount> <time>
  # Note: In Aroma Installer, the unit of parameter "time" is milliseconds.
  show_progress $1 "-${2}"
}

aroma_get_value() {
  [ -f /tmp/aroma/${1}.prop ] && cat /tmp/aroma/${1}.prop | head -n1 | cut -d'=' -f2 || echo ""
}

sha1() { ${bin}/magiskboot sha1 "$1"; }

apply_patch() {
  # apply_patch <src_path> <dst_sha1> <src_sha1> <patch>
  local file_sha1=$(sha1 $1)
  [ "$file_sha1" == "$2" ] && return 0
  [ "$file_sha1" == "$3" ] && ${bin}/bspatch "$1" "$1" "$4"
  [ "$(sha1 $1)" == "$2" ] || abort "! Failed to patch $1!"
}

apply_fdt_patch() {
  # apply_fdt_patch <dtb_img> <fdt_patch_file>
  [ -f "$2" ] || abort "! Can not found fdt patch file: $2!"
  cat $2 | grep -vE '^#' | while read line; do
    [ -n "$line" ] && {
      ${bin}/fdtput $1 $line || abort "! Failed to apply fdt patch: $2"
    }
  done
}

is_new_camblobs() {
  local so_file=/vendor/lib/hw/camera.sdm660.so
  [ -f $so_file ] || { echo 2; return; }
  strings $so_file | grep -q "xiaomi.watermark"
  echo $?
}

parse_uv_level() {
  case "$1" in
    "1") echo 0;;
    "2") echo 20000;;  # 20 mV
    "3") echo 40000;;  # 40 mV
    "4") echo 80000;;  # 80 mV
    "5") echo 100000;; # 100 mV
    "6") echo 120000;; # 120 mV
    "7") echo 140000;; # 140 mV
    "8") echo 160000;; # 160 mV
    *) echo 0;;
  esac
}

# Read value by user selected from aroma prop files
is_oc=$(aroma_get_value is_oc)                                   # OC: 1; Non-OC:2
uv_confirm=$(aroma_get_value uv_confirm)                         # No UV: 1; UV:2
cpu_pow_uv_level=$(aroma_get_value cpu_pow_uv_level)
cpu_perf_uv_level=$(aroma_get_value cpu_perf_uv_level)
gpu_uv_level=$(aroma_get_value gpu_uv_level)
is_fixcam=$(aroma_get_value is_fixcam)                           # New blobs: 1; Old blobs: 2; Auto detection: 3
headphone_buttons_mode=$(aroma_get_value headphone_buttons_mode) # Stock: 1; Alternative: 2
qti_haptics=$(aroma_get_value qti_haptics)                       # qpnp haptic: 1; qti haptics: 2
is_spectrum=$(aroma_get_value spectrum)                          # Yes: 1; No:2

# Install Pure Spectrum module
spectrum_module_path=/data/adb/modules/pure_spectrum
if [ "$is_spectrum" == "1" ]; then
    ui_print "- Installing Pure Spectrum module..."
    mkdir -p `dirname $spectrum_module_path`
    rm -rf $spectrum_module_path
    tar -xzvf ${home}/magisk_modules/pure_spectrum.tar.gz -C `dirname $spectrum_module_path`
    if [ "$(aroma_get_value lang)" == "2" ]; then
        moddescription="使用一种很清真的方法实现 Spectrum 而无需修改 ramdisk （注：该模块由 Panda 内核安装，会在安装其他内核后自动移除）"
    else
        moddescription="Use a special method to implement Spectrum. No need to modify ramdisk. (Note: This module is installed by Panda kernel, and will be automatically removed after installing other kernels)"
    fi
    echo "description=$moddescription" >> ${spectrum_module_path}/module.prop
else
    [ -d $spectrum_module_path ] && touch ${spectrum_module_path}/remove
fi

# Set Android version flag
api=`file_getprop /system/build.prop ro.build.version.release`
if [ -n "$api" ]; then
    patch_cmdline "androidboot.version" "androidboot.version=${api}"
else
    patch_cmdline "androidboot.version" ""
fi

# Wired headphone buttons mode
if [ "$headphone_buttons_mode" == "2" ]; then
    patch_cmdline "androidboot.wiredbtnaltmode" "androidboot.wiredbtnaltmode=1"
else
    patch_cmdline "androidboot.wiredbtnaltmode" ""
fi

# Camera blobs
if [ "$is_fixcam" == "3" ]; then
    is_fixcam="2"
    case "`is_new_camblobs`" in
        "0") {
            ui_print "- You are using NEW camera blobs"
            is_fixcam="1"
        };;
        "1") {
            ui_print "- You are using OLD camera blobs"
        };;
        *) {
            ui_print "! Failed to check camera blobs version!"
            ui_print "! Continue as OLD camera blobs"
        };;
    esac
fi

# Select dtb file
if [ "$is_oc" == "1" ]; then
    dtb_img=${home}/dtbs/oc.dtb
else
    dtb_img=${home}/dtbs/nooc.dtb
fi
[ -f "$dtb_img" ] || abort "! Cannot found $dtb_img!"

# Unpack files
ui_print "- Unpacking files..."
set_progress 0.1
${bin}/magiskboot decompress ${home}/Image.xz ${home}/Image
[ -f ${home}/Image ] || abort "! Failed to extract Image!"
set_progress 0.2

# Patch dtb file
fdt_patch_files=""
if [ "$qti_haptics" == "2" ]; then
    fdt_patch_files="$fdt_patch_files ${home}/fdt_patches/qti-haptics.fdtp"
fi
if [ -n "$fdt_patch_files" ]; then
    ui_print "- Patching dtb file..."
    for fdt_patch_file in $fdt_patch_files; do
        apply_fdt_patch $dtb_img $fdt_patch_file
    done
    sync
fi
if [ "$uv_confirm" == "2" ]; then
    ui_print "- Applying UV changes..."
    cpu_pow_uv=$(parse_uv_level $cpu_pow_uv_level)
    cpu_perf_uv=$(parse_uv_level $cpu_perf_uv_level)
    gpu_uv=$(parse_uv_level $gpu_uv_level)
    [ "$cpu_pow_uv" != "0" ]  && ${bin}/fdtput $dtb_img /soc/cprh-ctrl@179c8000/thread@0/regulator qcom,custom-voltage-reduce $cpu_pow_uv -tu
    [ "$cpu_perf_uv" != "0" ] && ${bin}/fdtput $dtb_img /soc/cprh-ctrl@179c4000/thread@0/regulator qcom,custom-voltage-reduce $cpu_perf_uv -tu
    [ "$gpu_uv" != "0" ]      && ${bin}/fdtput $dtb_img /soc/cpr4-ctrl@05061000/thread@0/regulator qcom,custom-voltage-reduce $gpu_uv -tu
    sync
fi

# Patch kernel Image
if [ "$is_fixcam" == "1" ]; then
    ui_print "- Patching Image file..."
    apply_patch ${home}/Image "@SHA1_01@" "@SHA1_STOCK@" ${home}/bs_patches/new_camera_blobs.p
else
    [ "$(sha1 ${home}/Image)" == "@SHA1_STOCK@" ] || abort "! Image file is corrupted"
fi

# Use new dtb file
cp -f $dtb_img ${split_img}/kernel_dtb

# If Magisk is detected, patch the kernel Image, now
${bin}/magiskboot cpio "$(ls ${split_img}/ramdisk.cpio* 2>/dev/null | tail -n1)" test
export magisk_patched=$?
if [ $((magisk_patched & 3)) -eq 1 ]; then
    ui_print "- Magisk detected! Patching Image file again..."
    ${bin}/magiskboot hexpatch ${home}/Image 736B69705F696E697472616D667300 77616E745F696E697472616D667300
    if [ "$(file_getprop ${home}/anykernel.sh do.modules)$(file_getprop ${home}/anykernel.sh do.systemless)" == "11" ]; then
        strings ${home}/Image | grep -E 'Linux version.*#' > ${home}/vertmp
    fi
fi
set_progress 0.3

# Compress Image
ui_print "- Compress Image..."
aroma_show_progress 0.2 7000
cat ${home}/Image | gzip -f > ${home}/Image.gz
[ $? == 0 ] || ${bin}/magiskboot compress=gzip ${home}/Image ${home}/Image.gz
[ -f ${home}/Image.gz ] || abort "! Failed to compress Image!"
rm -f ${home}/Image.xz ${home}/Image

sync

ui_print "- Preparation is complete, installation officially begin..."
aroma_show_progress 0.5 2500
############################## CUSTOM END ##############################

# Pzqqt: Skip ramdisk unpacking and repacking (we don't modify anything in the ramdisk)
# Idea from https://github.com/kdrag0n/proton_kernel_wahoo/commit/375fa432a5e04559ebb1e61b4f05f1fffee08c5f
# write_boot;
flash_boot;
flash_dtbo;

## end install
