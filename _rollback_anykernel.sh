### AnyKernel3 Ramdisk Mod Script
## osm0sis @ xda-developers

### AnyKernel setup
# global properties
properties() { '
kernel.string=Rollback kernel and vendor_dlkm image
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
no_block_display=true
. tools/ak3-core.sh
unset no_block_display

if [ -f ${home}/boot-orig.img ]; then
	mv ${home}/boot-orig.img ${home}/boot.img
	rm -f ${home}/boot_flashed
	flash_generic boot
fi
if [ -f ${home}/vendor_dlkm-orig.img ]; then
	mv ${home}/vendor_dlkm-orig.img ${home}/vendor_dlkm.img
	rm -f ${home}/vendor_dlkm_flashed
	flash_generic vendor_dlkm
fi

## end boot install
