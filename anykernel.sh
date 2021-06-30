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

is_new_camblobs() {
  local so_file=/vendor/lib/hw/camera.sdm660.so
  [ -f $so_file ] || { echo 2; return; }
  strings $so_file | grep -q "xiaomi.watermark"
  echo $?
}

# Read value by user selected from aroma prop files
is_oc=$(aroma_get_value is_oc)                                   # OC: 1; Non-OC:2
uv_level=$(aroma_get_value uv_level)                             # No UV: 1; 80mv: 2
is_fixcam=$(aroma_get_value is_fixcam)                           # New blobs: 1; Old blobs: 2; Auto detection: 3
headphone_buttons_mode=$(aroma_get_value headphone_buttons_mode) # Stock: 1; Alternative: 2
energy_model=$(aroma_get_value energy_model)                     # CAF: 1; Kdrag0n-660: 2, Kdrag0n-636: 3, Hypeartist: 4
efficient_frequencies=$(aroma_get_value efficient_frequencies)   # Enable: 1, Disable: 2

# Remove Pure Spectrum module when installing EAS build
[ -d /data/adb/modules/pure_spectrum ] && touch /data/adb/modules/pure_spectrum/remove

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
[ "$is_oc" == "1" ] && flag_1="2" || flag_1="1"
[ -n "$uv_level" ] && flag_2="$uv_level" || flag_2="1"
dtb_img=${home}/dtbs/${flag_1}${flag_2}.dtb

# Unpack files
ui_print "- Unpacking files..."
${bin}/magiskboot decompress ${home}/dtbs/dtbs.tar.xz - | tar -xvC ${home}/dtbs
[ -f "$dtb_img" ] || abort "! Failed to extract dtbs!"
${bin}/magiskboot decompress ${home}/Image.xz ${home}/Image
[ -f ${home}/Image ] || abort "! Failed to extract Image!"

# Patch dtb file
dts_patch_files=""
if [ "$energy_model" != "1" ]; then
    case "$energy_model" in
        "2") {
            ui_print "- Use kdrag0n's EAS energy model (for sdm660)"
            if [ "$is_oc" == "1" ]; then
                dts_patch_files="$dts_patch_files ${home}/diff_patches/kdrag0n-energy-model-sdm660-oc.diff"
            else
                dts_patch_files="$dts_patch_files ${home}/diff_patches/kdrag0n-energy-model-sdm660-nooc.diff"
            fi
        };;
        "3") {
            ui_print "- Use kdrag0n's EAS energy model (for sdm636)"
            [ "$is_oc" == "1" ] && abort "! This energy model is not suitable with overclock!"
            dts_patch_files="$dts_patch_files ${home}/diff_patches/kdrag0n-energy-model-sdm636-nooc.diff"
        };;
        "4") {
            ui_print "- Use hypeartist's EAS energy model"
            if [ "$is_oc" == "1" ]; then
                dts_patch_files="$dts_patch_files ${home}/diff_patches/hypeartist-energy-model-oc.diff"
            else
                dts_patch_files="$dts_patch_files ${home}/diff_patches/hypeartist-energy-model-nooc.diff"
            fi
        };;
        *) abort "! Unknown parameter: energy_model: \"$energy_model\"";;
    esac
fi
if [ "$efficient_frequencies" == "1" ]; then
    if [ "$is_oc" == "1" ]; then
        dts_patch_files="$dts_patch_files ${home}/diff_patches/efficient-frequencies-oc.diff"
    else
        dts_patch_files="$dts_patch_files ${home}/diff_patches/efficient-frequencies-nooc.diff"
    fi
fi
if [ -n "$dts_patch_files" ]; then
    ui_print "- Recompiling dtb image..."
    dtb_img_splitted=`${bin}/dtp -i $dtb_img | awk '{print $NF}'` || abort "! Failed to split dtb file!"
    # ${dtb_img}-0: sdm660-mtp.dtb
    # ${dtb_img}-1: sdm636-mtp_e7s.dtb
    # We don't need to pay attention to the first dtb file
    dtb_img_splitted_1="${dtb_img}-1"
    [ -f "$dtb_img_splitted_1" ] || abort "! Can not found $dtb_img_splitted_1!"
    ${bin}/dtc -q -I dtb -O dts -o "${dtb_img_splitted_1}.dts" "$dtb_img_splitted_1" || abort "! Failed to decompile dtb file!"
    for diff_file in $dts_patch_files; do
        patch -i $diff_file "${dtb_img_splitted_1}.dts" || abort "! Failed to patch dts file!"
    done
    ${bin}/dtc -q -I dts -O dtb -o "$dtb_img_splitted_1" "${dtb_img_splitted_1}.dts" || abort "! Failed to recompile dtb file!"
    cat $dtb_img_splitted > "$dtb_img"_patched
    dtb_img="$dtb_img"_patched
fi

# Patch kernel Image
case "${flag_2}${is_fixcam}" in
    "12") [ "$(sha1 ${home}/Image)" == "@SHA1_STOCK@" ] || abort "! Image file is corrupted";;
    *) {
        ui_print "- Patching Image file..."
        case "${flag_2}${is_fixcam}" in
            "22") apply_patch ${home}/Image "@SHA1_10@" "@SHA1_STOCK@" ${home}/bs_patches/80uv.p;;
            "11") apply_patch ${home}/Image "@SHA1_01@" "@SHA1_STOCK@" ${home}/bs_patches/campatch.p;;
            "21") apply_patch ${home}/Image "@SHA1_11@" "@SHA1_STOCK@" ${home}/bs_patches/80uv_campatch.p;;
            *)    abort "! Unable to parse Aroma flags!";;
        esac
    };;
esac

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

# Compress Image
ui_print "- Compress Image..."
cat ${home}/Image | gzip -f > ${home}/Image.gz
[ $? == 0 ] || ${bin}/magiskboot compress=gzip ${home}/Image ${home}/Image.gz
[ -f ${home}/Image.gz ] || abort "! Failed to compress Image!"
rm -f ${home}/Image.xz ${home}/Image

sync

ui_print "- Preparation is complete, installation officially begin..."
############################## CUSTOM END ##############################

# Pzqqt: Skip ramdisk unpacking and repacking (we don't modify anything in the ramdisk)
# Idea from https://github.com/kdrag0n/proton_kernel_wahoo/commit/375fa432a5e04559ebb1e61b4f05f1fffee08c5f
# write_boot;
flash_boot;
flash_dtbo;

## end install
