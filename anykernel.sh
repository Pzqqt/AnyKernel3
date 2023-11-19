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

dump_boot # use split_boot to skip ramdisk unpack, e.g. for devices with init_boot ramdisk

########## FLASH BOOT & VENDOR_DLKM START ##########

SHA1_STOCK="@SHA1_STOCK@"
SHA1_KSU="@SHA1_KSU@"

KEYCODE_UP=42
KEYCODE_DOWN=41

extract_erofs() {
	local img_file=$1
	local out_dir=$2

	${bin}/extract.erofs -i $img_file -x -T8 -o $out_dir &> /dev/null
}

mkfs_erofs() {
	local work_dir=$1
	local out_file=$2

	local partition_name=$(basename $work_dir)

	${bin}/mkfs.erofs \
		--mount-point /${partition_name} \
		--fs-config-file ${work_dir}/../config/${partition_name}_fs_config \
		--file-contexts  ${work_dir}/../config/${partition_name}_file_contexts \
		-z lz4hc \
		$out_file $work_dir
}

is_mounted() { mount | grep -q " $1 "; }

sha1() { ${bin}/magiskboot sha1 "$1"; }

apply_patch() {
	# apply_patch <src_path> <src_sha1> <dst_sha1> <bs_patch>
	local src_path=$1
	local src_sha1=$2
	local dst_sha1=$3
	local bs_patch=$4

	local file_sha1=$(sha1 $src_path)
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
	local prompt_text=$1
	local r_keycode

	ui_print " "
	ui_print "# $prompt_text"
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

# Check snapshot status
# Technical details: https://blog.xzr.moe/archives/30/
${bin}/snapshotupdater_static dump &>/dev/null
rc=$?
if [ "$rc" != 0 ]; then
	ui_print "Cannot get snapshot status via snapshotupdater_static! rc=$rc."
	if $BOOTMODE; then
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

# Check super device size
block_device_size=$(blockdev --getsize64 /dev/block/by-name/super) || \
	abort "! Failed to get super block device size (by blockdev)!"
ui_print "Super block device size (read by blockdev): $block_device_size"
block_device_size_lp=$(${bin}/lpdump 2>/dev/null | grep -E 'Size: [[:digit:]]+ bytes$' | head -n1 | awk '{print $2}') || \
	abort "! Failed to get super block device size (by lpdump)!"
ui_print "Super block device size (read by lpdump): $block_device_size_lp"
[ "$block_device_size" == "9663676416" ] && [ "$block_device_size_lp" == "9663676416" ] || \
	abort "! Super block device size mismatch!"
unset block_device_size block_device_size_lp

# Check vendor_dlkm partition status
[ -d /vendor_dlkm ] || mkdir /vendor_dlkm
is_mounted /vendor_dlkm || \
	mount /vendor_dlkm -o ro || mount /dev/block/mapper/vendor_dlkm${slot} /vendor_dlkm -o ro || \
		abort "! Failed to mount /vendor_dlkm"

strings ${home}/Image 2>/dev/null | grep -E -m1 'Linux version.*#' > ${home}/vertmp

skip_update_flag=false
do_backup_flag=false
if [ -f /vendor_dlkm/lib/modules/vertmp ]; then
	[ "$(cat /vendor_dlkm/lib/modules/vertmp)" == "$(cat ${home}/vertmp)" ] && skip_update_flag=true
else
	do_backup_flag=true
fi
umount /vendor_dlkm

if $skip_update_flag; then
	case $(basename "$ZIPFILE" .zip) in
		*-force) skip_update_flag=false;;
	esac
fi

# KernelSU
install_ksu_flag=false
[ -f ${split_img}/ramdisk.cpio ] || abort "! Cannot found ramdisk.cpio!"
${bin}/magiskboot cpio ${split_img}/ramdisk.cpio test
magisk_patched=$?
keycode_select "Choose whether to install KernelSU support." && {
	if [ $((magisk_patched & 3)) -eq 1 ]; then
		ui_print "- Magisk detected!"
		ui_print "- We don't recommend using Magisk and KernelSU at the same time!"
		ui_print "- If any problems occur, it's your own responsibility!"
		ui_print " "
		sleep 3
	fi
	ui_print "- Patching Kernel image..."
	apply_patch ${home}/Image "$SHA1_STOCK" "$SHA1_KSU" ${home}/bs_patches/ksu.p
	install_ksu_flag=true
}
$install_ksu_flag || {
	[ "$(sha1 ${home}/Image)" == "$SHA1_STOCK" ] || abort "! Kernel image is corrupted!"
}
export magisk_patched
unset install_ksu_flag

# Fix unable to mount image as read-write in recovery
$BOOTMODE || setenforce 0

ui_print " "
if $skip_update_flag; then
	ui_print "- No need to update /vendor_dlkm partition."
else
	# Dump vendor_dlkm partition image
	dd if=/dev/block/mapper/vendor_dlkm${slot} of=${home}/vendor_dlkm.img

	# Backup kernel and vendor_dlkm image
	if $do_backup_flag; then
		ui_print "- It looks like you are installing Melt Kernel for the first time."

		keycode_select "Backup the current kernel?" && {
			ui_print "- Backing up kernel, vendor_boot, and vendor_dlkm partition..."

			build_prop=/system/build.prop
			[ -d /system_root/system ] && build_prop=/system_root/$build_prop
			backup_package=/sdcard/Melt-restore-kernel-$(file_getprop $build_prop ro.build.version.incremental)-$(date +"%Y%m%d-%H%M%S").zip

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

			unset build_prop backup_package
		}
	fi

	ui_print "- Unpacking /vendor_dlkm partition..."
	extract_vendor_dlkm_dir=${home}/_extract_vendor_dlkm
	mkdir -p $extract_vendor_dlkm_dir
	vendor_dlkm_is_ext4=false
	extract_erofs ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir || vendor_dlkm_is_ext4=true
	sync

	if $vendor_dlkm_is_ext4; then
		ui_print "- /vendor_dlkm partition seems to be in ext4 file system."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o ro -t ext4 || \
			abort "! Unsupported file system!"
		vendor_dlkm_free_space=$(df -k | grep -E "[[:space:]]$extract_vendor_dlkm_dir\$" | awk '{print $4}')
		ui_print "- /vendor_dlkm partition free space: $vendor_dlkm_free_space"
		umount $extract_vendor_dlkm_dir

		[ "$vendor_dlkm_free_space" -gt 10240 ] || {
			# Resize vendor_dlkm image
			ui_print "- /vendor_dlkm partition does not have enough free space!"
			ui_print "- Trying to resize..."

			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img
			vendor_dlkm_current_size_mb=$(du -bm ${home}/vendor_dlkm.img | awk '{print $1}')
			vendor_dlkm_target_size_mb=$((vendor_dlkm_current_size_mb + 10))
			${bin}/resize2fs ${home}/vendor_dlkm.img "${vendor_dlkm_target_size_mb}M" || \
				abort "! Failed to resize vendor_dlkm image!"
			ui_print "- Resized vendor_dlkm.img size: ${vendor_dlkm_target_size_mb}M."
			# e2fsck again
			${bin}/e2fsck -f -y ${home}/vendor_dlkm.img

			unset vendor_dlkm_current_size_mb vendor_dlkm_target_size_mb
		}

		ui_print "- Trying to mount vendor_dlkm image as read-write..."
		mount ${home}/vendor_dlkm.img $extract_vendor_dlkm_dir -o rw -t ext4 || \
			abort "! Failed to mount vendor_dlkm.img as read-write!"

		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/lib/modules
	else
		extract_vendor_dlkm_modules_dir=${extract_vendor_dlkm_dir}/vendor_dlkm/lib/modules
	fi

	ui_print "- Updating /vendor_dlkm image..."
	if [ "$(sha1 ${extract_vendor_dlkm_modules_dir}/qti_battery_charger.ko)" == "b5aa013e06e545df50030ec7b03216f41306f4d4" ]; then
		cp -f ${extract_vendor_dlkm_modules_dir}/qti_battery_charger.ko ${home}/_vendor_dlkm_modules/qti_battery_charger.ko
	fi
	rm -f ${extract_vendor_dlkm_modules_dir}/*
	cp ${home}/_vendor_dlkm_modules/* ${extract_vendor_dlkm_modules_dir}/
	cp ${home}/vertmp ${extract_vendor_dlkm_modules_dir}/vertmp
	sync

	if $vendor_dlkm_is_ext4; then
		set_perm 0 0 0644 ${extract_vendor_dlkm_modules_dir}/*
		chcon u:object_r:vendor_file:s0 ${extract_vendor_dlkm_modules_dir}/*
		umount $extract_vendor_dlkm_dir
	else
		for f in $(ls -1 $extract_vendor_dlkm_modules_dir); do
			echo "vendor_dlkm/lib/modules/$f 0 0 0644" >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_fs_config
		done
		echo '/vendor_dlkm/lib/modules/.+ u:object_r:vendor_file:s0' >> ${extract_vendor_dlkm_dir}/config/vendor_dlkm_file_contexts
		ui_print "- Repacking /vendor_dlkm image..."
		rm -f ${home}/vendor_dlkm.img
		mkfs_erofs ${extract_vendor_dlkm_dir}/vendor_dlkm ${home}/vendor_dlkm.img || \
			abort "! Failed to repack the vendor_dlkm image!"
		rm -rf ${extract_vendor_dlkm_dir}
	fi

	unset vendor_dlkm_is_ext4 vendor_dlkm_free_space extract_vendor_dlkm_dir extract_vendor_dlkm_modules_dir blocklist_expr
fi

unset no_needed_kos skip_update_flag do_backup_flag

write_boot # use flash_boot to skip ramdisk repack, e.g. for devices with init_boot ramdisk

########## FLASH BOOT & VENDOR_DLKM END ##########

# Remove files no longer needed to avoid flashing again.
rm ${home}/Image
rm ${home}/boot.img
rm ${home}/boot-new.img
rm ${home}/vendor_dlkm.img

########## FLASH VENDOR_BOOT START ##########

## vendor_boot shell variables
block=vendor_boot
is_slot_device=1
ramdisk_compression=auto
patch_vbmeta_flag=auto

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

# Patch vbmeta
ui_print " "
for vbmeta_blk in /dev/block/bootdevice/by-name/vbmeta${slot} /dev/block/bootdevice/by-name/vbmeta_system${slot}; do
	ui_print "- Patching ${vbmeta_blk} ..."
	${bin}/vbmeta-disable-verification $vbmeta_blk || {
		ui_print "! Failed to patching ${vbmeta_blk}!"
		ui_print "- If the device won't boot after the installation,"
		ui_print "  please manually disable AVB in TWRP."
	}
done

## end boot install
