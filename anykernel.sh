### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Melt Kernel by Pzqqt
do.devicecheck=1
do.modules=0
do.systemless=1
do.cleanup=1
do.cleanuponabort=0
device.name1=marble
device.name2=marblein
device.name3=
device.name4=
device.name5=
supported.versions=
supported.patchlevels=
supported.vendorpatchlevels=
'; } # end properties


### AnyKernel install

## boot shell variables
block=boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

# import functions/variables and setup patching - see for reference (DO NOT REMOVE)
. tools/ak3-core.sh

split_boot # skip ramdisk unpack

########## FLASH BOOT & VENDOR_DLKM START ##########

SHA1_STOCK="@SHA1_STOCK@"
SHA1_KSU="@SHA1_KSU@"

KEYCODE_UP=42
KEYCODE_DOWN=41

extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${bin}/extract.erofs -i "$img_file" -x -T8 -o "$out_dir" &> /dev/null
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2
	local partition_name

	partition_name=$(basename "$work_dir")

	${bin}/mkfs.erofs \
		--mount-point "/${partition_name}" \
		--fs-config-file "${work_dir}/../config/${partition_name}_fs_config" \
		--file-contexts  "${work_dir}/../config/${partition_name}_file_contexts" \
		-z lz4hc \
		"$out_file" "$work_dir"
}

is_mounted() { mount | grep -q " $1 "; }

sha1() { ${bin}/magiskboot sha1 "$1"; }

apply_patch() {
	# apply_patch <src_path> <src_sha1> <dst_sha1> <bs_patch>
	local src_path=$1
	local src_sha1=$2
	local dst_sha1=$3
	local bs_patch=$4
	local file_sha1

	file_sha1=$(sha1 $src_path)
	[ "$file_sha1" == "$dst_sha1" ] && return 0
	[ "$file_sha1" == "$src_sha1" ] && ${bin}/bspatch "$src_path" "$src_path" "$bs_patch"
	[ "$(sha1 $src_path)" == "$dst_sha1" ] || abort "! Failed to patch $src_path!"
}

get_keycheck_result() {
	# Default behavior:
	# - press Vol+: return true (0)
	# - press Vol-: return false (1)

	local rc_1 rc_2

	while true; do
		# The first execution responds to the button press event,
		# the second execution responds to the button release event.
		${bin}/keycheck; rc_1=$?
		${bin}/keycheck; rc_2=$?
		[ "$rc_1" == "$rc_2" ] || continue
		case "$rc_2" in
			"$KEYCODE_UP") return 0;;
			"$KEYCODE_DOWN") return 1;;
		esac
	done
}

keycode_select() {
	local r_keycode

	ui_print " "
	while [ $# != 0 ]; do
		ui_print "# $1"
		shift
	done
	ui_print "#"
	ui_print "# Vol+ = Yes, Vol- = No."
	ui_print "# Please press the key..."
	get_keycheck_result
	r_keycode=$?
	ui_print "#"
	if [ "$r_keycode" -eq "0" ]; then
		ui_print "- You chose Yes."
	else
		ui_print "- You chose No."
	fi
	ui_print " "
	return $r_keycode
}

get_size() {
	local _path=$1
	local _size

	if [ -d "$_path" ]; then
		du -bs $_path | awk '{print $1}'
		return
	fi
	if [ -b "$_path" ]; then
		_size=$(blockdev --getsize64 $_path) && {
			echo $_size
			return
		}
	fi
	wc -c < $_path
}

bytes_to_mb() {
	echo $1 | awk '{printf "%.1fM", $1 / 1024 / 1024}'
}

check_super_device_size() {
	# Check super device size
	local block_device_size block_device_size_lp

	block_device_size=$(get_size /dev/block/by-name/super) || \
		abort "! Failed to get super block device size (by blockdev)!"
	block_device_size_lp=$(${bin}/lpdump 2>/dev/null | grep -E 'Size: [[:digit:]]+ bytes$' | head -n1 | awk '{print $2}') || \
		abort "! Failed to get super block device size (by lpdump)!"
	ui_print "- Super block device size:"
	ui_print "  - Read by blockdev: $block_device_size"
	ui_print "  - Read by lpdump: $block_device_size_lp"
	[ "$block_device_size" == "9663676416" ] && [ "$block_device_size_lp" == "9663676416" ] || \
		abort "! Super block device size mismatch!"
}

is_oss_kernel_rom() {
	[ -f /vendor/bin/sensor-notifier ] && return 0

	# Check if it's new OSS dtbo
	# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/f4dfb9210dc907b335441bfa78720773f679f841
	m16t_touch_node=$(find /proc/device-tree/ | grep -E -m1 '/m16t-touch.*/compatible$') && m16t_touch_prop=$(cat "$m16t_touch_node") && {
		test "$m16t_touch_prop" == "goodix,9916r-spi" || return 0
	}
	unset m16t_touch_node m16t_touch_prop

	# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/393374ee4d02edbc27f3b6b57b965a7fbe87d33b
	ir_spi_node=$(find /proc/device-tree/ | grep -E -m1 '/ir-spi.*/compatible$') && ir_spi_prop=$(cat "$ir_spi_node") && {
		test "$ir_spi_prop" == "ir-spi-led" && return 0
	}
	unset ir_spi_node ir_spi_prop

	return 1
}

# Check firmware
if strings /dev/block/bootdevice/by-name/xbl_config${slot} | grep -q 'led_blink'; then
	ui_print "HyperOS firmware detected!"
	is_hyperos_fw=true
else
	ui_print "MIUI14 firmware detected!"
	is_hyperos_fw=false
fi

# Check rom type
is_oss_kernel_rom && abort "Error: Melt Kernel does not seem to support your rom:/"
is_miui_rom=false
[ -f /system/framework/MiuiBooster.jar ] && is_miui_rom=true

# Staging unmodified partition images
mkdir -p ${home}/_orig
cp ${home}/boot.img ${home}/_orig/boot.img

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${bin}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print " "
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if ${BOOTMODE}; then
		ui_print "If you are installing the kernel in an app, try using another app."
		ui_print "Recommend KernelFlasher:"
		ui_print "  https://github.com/capntrips/KernelFlasher/releases"
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
snapshot_status=$(${bin}/snapshotupdater_static dump 2>/dev/null | grep '^Update state:' | awk '{print $3}')
ui_print "Current snapshot state: $snapshot_status"
if [ "$snapshot_status" != "none" ]; then
	ui_print " "
	ui_print "Seems like you just installed a rom update."
	if [ "$snapshot_status" == "merging" ]; then
		ui_print "Please use the rom for a while to wait for"
		ui_print "the system to complete the snapshot merge."
		ui_print "It's also possible to use the \"Merge Snapshots\" feature"
		ui_print "in TWRP's Advanced menu to instantly merge snapshots."
	else
		ui_print "Please try to reboot to system once before installing!"
	fi
	abort "Aborting..."
fi
unset rc snapshot_status

[ -f ${home}/Image.7z ] || abort "! Cannot found ${home}/Image.7z!"
ui_print " "
ui_print "- Unpacking kernel image..."
${bin}/7za x ${home}/Image.7z -o${home}/ && [ -f ${home}/Image ] || abort "! Failed to unpack ${home}/Image.7z!"
rm ${home}/Image.7z
[ "$(sha1 ${home}/Image)" == "$SHA1_STOCK" ] || abort "! Kernel image is corrupted!"

# Check vendor_dlkm partition status
[ -d /vendor_dlkm ] || mkdir /vendor_dlkm
is_mounted /vendor_dlkm || \
	mount /vendor_dlkm -o ro || mount /dev/block/mapper/vendor_dlkm${slot} /vendor_dlkm -o ro || \
		abort "! Failed to mount /vendor_dlkm"

strings ${home}/Image 2>/dev/null | grep -E -m1 'Linux version.*#' > ${home}/vertmp

do_backup_flag=false
if [ ! -f /vendor_dlkm/lib/modules/vertmp ]; then
	do_backup_flag=true
fi
is_fixed_qbc_driver=false
if [ "$(sha1 /vendor_dlkm/lib/modules/qti_battery_charger.ko)" == "b5aa013e06e545df50030ec7b03216f41306f4d4" ]; then
	is_fixed_qbc_driver=true
fi
umount /vendor_dlkm

# KernelSU
[ -f ${split_img}/ramdisk.cpio ] || abort "! Cannot found ramdisk.cpio!"
${bin}/magiskboot cpio ${split_img}/ramdisk.cpio test
magisk_patched=$?
if ${bin}/magiskboot cpio ${split_img}/ramdisk.cpio "exists kernelsu.ko"; then
	ui_print "- KernelSU LKM detected!"
	ui_print "- Then you can only install Melt Kernel without KernelSU support!"
	if [ $((magisk_patched & 3)) -eq 1 ]; then
		ui_print "- Magisk detected!"
		ui_print "- Oh brother, it's crazy!"
		sleep 3
	fi
elif keycode_select "Choose whether to install KernelSU support."; then
	if [ $((magisk_patched & 3)) -eq 1 ]; then
		ui_print "- Magisk detected!"
		ui_print "- We don't recommend using Magisk and KernelSU at the same time!"
		ui_print "- If any problems occur, it's your own responsibility!"
		ui_print " "
		sleep 3
	fi
	ui_print "- Patching Kernel image..."
	apply_patch ${home}/Image "$SHA1_STOCK" "$SHA1_KSU" ${home}/bs_patches/ksu.p
fi
export magisk_patched

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

ui_print " "
ui_print "- Unpacking kernel modules..."
if ${is_hyperos_fw}; then
	modules_pkg=${home}/_modules_hyperos.7z
else
	modules_pkg=${home}/_modules_miui.7z
fi
[ -f $modules_pkg ] || abort "! Cannot found ${modules_pkg}!"
${bin}/7za x $modules_pkg -o${home}/ && [ -d ${home}/_vendor_boot_modules ] && [ -d ${home}/_vendor_dlkm_modules ] || \
	abort "! Failed to unpack ${modules_pkg}!"
unset modules_pkg

vendor_dlkm_modules_options_file=${home}/_vendor_dlkm_modules/modules.options
[ -f $vendor_dlkm_modules_options_file ] || touch $vendor_dlkm_modules_options_file

# goodix_core.ko
if keycode_select \
    "Always enable 360HZ touch sampling rate?" \
    " " \
    "Note:" \
    "Always enabling 360HZ will NOT improve the daily" \
    "use experience and increase power consumption." \
    "If you regret it, you can install this kernel again" \
    "and choose No at this step."; then
	echo "options goodix_core force_high_report_rate=y" >> $vendor_dlkm_modules_options_file
fi

# qti_battery_charger.ko / qti_battery_charger_main.ko
if ${is_hyperos_fw}; then
	modname_qti_battery_charger=qti_battery_charger_main
else
	modname_qti_battery_charger=qti_battery_charger
fi

qti_battery_charger_mod_options=""
if keycode_select \
    "Make device show more realistic battery percentage?" \
    " " \
    "Note:" \
    "This will sometimes make it difficult to charge" \
    "the device to 100%."; then
	qti_battery_charger_mod_options="${qti_battery_charger_mod_options} report_real_capacity=y"
fi

do_fix_battery_usage=false
skip_option_fix_battery_usage=false
if ${is_fixed_qbc_driver}; then
	do_fix_battery_usage=true
	skip_option_fix_battery_usage=true
elif ${is_miui_rom} || cat /system/build.prop | grep -qi 'aospa'; then
	skip_option_fix_battery_usage=true
fi
if ! ${skip_option_fix_battery_usage}; then
	if keycode_select \
	    "Fix battery usage issue with AOSP rom?" \
	    " " \
	    "Note:" \
	    "Select Yes if you are using AOSP rom and find" \
	    "abnormal battery usage data in the system." \
	    "Select No if you are using MIUI/HyperOS/AOSPA rom."; then
		do_fix_battery_usage=true
	fi
fi
if ${do_fix_battery_usage}; then
	qti_battery_charger_mod_options="${qti_battery_charger_mod_options} fix_battery_usage=y"
fi
unset do_fix_battery_usage skip_option_fix_battery_usage is_fixed_qbc_driver

if [ -n "${qti_battery_charger_mod_options}" ]; then
	qti_battery_charger_mod_options=$(echo "$qti_battery_charger_mod_options" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
	echo "options ${modname_qti_battery_charger} ${qti_battery_charger_mod_options}" >> $vendor_dlkm_modules_options_file
fi
unset modname_qti_battery_charger qti_battery_charger_mod_options

# OSS msm_drm.ko
if ${is_hyperos_fw}; then
	if keycode_select \
	    "Using open source display drivers?" \
	    " " \
	    "Note:" \
	    "Select No if you don't know what this means."; then
		oss_msm_drm=${home}/_alt/OSS-msm_drm.ko
		[ -f $oss_msm_drm ] || abort "! Cannot found ${oss_msm_drm}!"
		cp $oss_msm_drm ${home}/_vendor_dlkm_modules/msm_drm.ko -f
		unset oss_msm_drm
	fi
fi

# Alternative wired headset buttons mode
use_wired_btn_altmode=false
skip_option_wired_btn_altmode=false
if ${is_miui_rom}; then
	skip_option_wired_btn_altmode=true
fi
if ! ${skip_option_wired_btn_altmode}; then
	if keycode_select \
	    "Use alternative wired headset buttons mode?" \
	    " " \
	    "Note:" \
	    "Select Yes if you find that the volume buttons on" \
	    "your wired headset are not working properly." \
	    "Select No if you are using MIUI/HyperOS rom."; then
		use_wired_btn_altmode=true
	fi
fi
if ${use_wired_btn_altmode}; then
	echo "options machine_dlkm waipio_wired_btn_altmode=y" >> $vendor_dlkm_modules_options_file
fi
unset use_wired_btn_altmode skip_option_wired_btn_altmode

unset vendor_dlkm_modules_options_file

# Do not load millet related modules in AOSP rom
if ! ${is_miui_rom}; then
	for module_name in millet_core millet_binder millet_hs millet_oem_cgroup millet_pkg millet_sig; do
		echo "blocklist $module_name" >> ${home}/_vendor_dlkm_modules/modules.blocklist
	done
fi

ui_print " "
if true; then  # I don't want to adjust the indentation of the code block below, so leave it as is.
	do_check_super_device_size=false

	# Dump vendor_dlkm partition image
	dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img
	cp ${home}/vendor_dlkm.img ${home}/_orig/vendor_dlkm.img
	vendor_dlkm_block_size=$(get_size /dev/block/mapper/vendor_dlkm${slot})

	# Backup kernel and vendor_dlkm image
	if ${do_backup_flag}; then
		ui_print "- It looks like you are installing Melt Kernel for the first time."

		if keycode_select "Backup the current kernel?"; then
			ui_print "- Backing up kernel, vendor_boot, and vendor_dlkm partition..."

			backup_package=/sdcard/Melt-restore-kernel-$(file_getprop /system/build.prop ro.build.version.incremental)-$(date +"%Y%m%d-%H%M%S").zip

			dd if=/dev/block/bootdevice/by-name/vendor_boot${slot} of=${home}/vendor_boot.img

			${bin}/7za a -tzip -bd $backup_package \
				${home}/META-INF ${bin} ${home}/LICENSE ${home}/_restore_anykernel.sh \
				${split_img}/kernel ${home}/vendor_dlkm.img ${home}/vendor_boot.img
			${bin}/7za rn -bd $backup_package kernel Image
			${bin}/7za rn -bd $backup_package _restore_anykernel.sh anykernel.sh
			sync

			ui_print " "
			ui_print "- The current kernel, vendor_boot, vendor_dlkm have been backedup to:"
			ui_print "  $backup_package"
			ui_print "- If you encounter an unexpected situation,"
			ui_print "  or want to restore the stock kernel,"
			ui_print "  please flash it in TWRP or some supported apps."
			ui_print " "
			rm ${home}/vendor_boot.img
			touch ${home}/do_backup_flag

			if ! $BOOTMODE && [ ! -d /twres ]; then
				ui_print "======================================================================"
				ui_print "! Warning: Please transfer the backup file you just generated"
				ui_print "! to another device via ADB, as it will be lost after reboot!"
				ui_print "======================================================================"
				ui_print " "
				sleep 3
			fi

			unset backup_package
		fi
	fi

	ui_print "- Unpacking /vendor_dlkm partition..."
	extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm
	mkdir -p $extract_vendor_dlkm_dir
	vendor_dlkm_is_ext4=false
	extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true
	sync

	if ${vendor_dlkm_is_ext4}; then
		ui_print "- /vendor_dlkm seems to be in ext4 file system."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o ro -t ext4 || \
			abort "! Unsupported file system!"
		vendor_dlkm_full_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $2}')
		vendor_dlkm_used_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $3}')
		vendor_dlkm_free_space=$(df -B1 | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $4}')
		vendor_dlkm_stock_modules_size=$(get_size ${extract_vendor_dlkm_dir}/lib/modules)
		ui_print "- /vendor_dlkm partition space:"
		ui_print "  - Total space: $(bytes_to_mb $vendor_dlkm_full_space)"
		ui_print "  - Used space:  $(bytes_to_mb $vendor_dlkm_used_space)"
		ui_print "  - Free space:  $(bytes_to_mb $vendor_dlkm_free_space)"
		umount $extract_vendor_dlkm_dir

		vendor_dlkm_new_modules_size=$(get_size ${home}/_vendor_dlkm_modules)
		vendor_dlkm_need_size=$((vendor_dlkm_used_space - vendor_dlkm_stock_modules_size + vendor_dlkm_new_modules_size + 10*1024*1024))
		if [ "$vendor_dlkm_need_size" -ge "$vendor_dlkm_full_space" ]; then
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."

			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img
			vendor_dlkm_resized_size=$(echo $vendor_dlkm_need_size | awk '{printf "%dM", ($1 / 1024 / 1024 + 1)}')
			${bin}/resize2fs ${home}/vendor_dlkm.img $vendor_dlkm_resized_size || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_resized_size}."
			# e2fsck again
			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img

			do_check_super_device_size=true
			unset vendor_dlkm_resized_size
		else
			ui_print "- /vendor_dlkm partition has sufficient space."
		fi

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		unset vendor_dlkm_full_space vendor_dlkm_used_space vendor_dlkm_free_space vendor_dlkm_stock_modules_size vendor_dlkm_new_modules_size vendor_dlkm_need_size
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	rm -f ${extract_vendor_dlkm_modules_dir}/*
	cp ${home}/_vendor_dlkm_modules/* ${extract_vendor_dlkm_modules_dir}/ || \
		abort "! Failed to update modules! No enough free space?"
	cp ${home}/vertmp ${extract_vendor_dlkm_modules_dir}/vertmp
	sync

	if ${vendor_dlkm_is_ext4}; then
		set_perm 0 0 0644 ${extract_vendor_dlkm_modules_dir}/*
		chcon u:object_r:vendor_file:s0 ${extract_vendor_dlkm_modules_dir}/*
		umount $extract_vendor_dlkm_dir
	else
		for f in "${extract_vendor_dlkm_modules_dir}"/*; do
			echo "vendor_dlkm/lib/modules/$(basename $f) 0 0 0644" >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config
		done
		echo '/vendor_dlkm/lib/modules/.+ u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts
		ui_print "- Repacking /vendor_dlkm image..."
		rm -f ${home}/vendor_dlkm.img
		mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || \
			abort "! Failed to repack the vendor_dlkm image!"
		rm -rf ${extract_vendor_dlkm_dir}

		if [ "$(get_size ${home}/vendor_dlkm.img)" -gt "$vendor_dlkm_block_size" ]; then
			do_check_super_device_size=true
		else
			# Fill the erofs image file to the same size as the vendor_dlkm partition
			truncate -c -s $vendor_dlkm_block_size ${home}/vendor_dlkm.img
		fi
	fi

	if ${do_check_super_device_size}; then
		ui_print " "
		ui_print "- The generated image file is larger than the partition size."
		ui_print "- Checking super partition size..."
		check_super_device_size  # If the check here fails, it will be aborted directly.
		ui_print "- Pass!"
	fi

	unset do_check_super_device_size vendor_dlkm_block_size vendor_dlkm_is_ext4 extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir
fi

unset do_backup_flag

flash_boot # skip ramdisk repack
flash_generic vendor_dlkm

########## FLASH BOOT & VENDOR_DLKM END ##########

# Remove files no longer needed to avoid flashing again.
rm ${home}/Image
rm ${home}/boot.img
rm ${home}/boot-new.img
rm ${home}/vendor_dlkm.img

unset magisk_patched
rm ${home}/magisk_patched

touch ${home}/rollback_if_abort_flag

########## FLASH VENDOR_BOOT START ##########

## vendor_boot shell variables
block=vendor_boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto
no_magisk_check=true

# reset for vendor_boot patching
reset_ak

# vendor_boot install
dump_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

vendor_boot_modules_dir=${ramdisk}/lib/modules
rm ${vendor_boot_modules_dir}/*
cp ${home}/_vendor_boot_modules/* ${vendor_boot_modules_dir}/
set_perm 0 0 0644 ${vendor_boot_modules_dir}/*

write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk

########## FLASH VENDOR_BOOT END ##########

unset is_hyperos_fw is_miui_rom

# Patch vbmeta
ui_print " "
for vbmeta_blk in /dev/block/bootdevice/by-name/vbmeta*; do
	ui_print "- Patching ${vbmeta_blk} ..."
	${bin}/vbmeta-disable-verification $vbmeta_blk || {
		ui_print "! Failed to patching ${vbmeta_blk}!"
		ui_print "- If the device won't boot after the installation,"
		ui_print "  please manually disable AVB in TWRP."
	}
done

## end boot install
