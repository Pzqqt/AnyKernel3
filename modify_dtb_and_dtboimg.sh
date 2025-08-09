#!/usr/bin/bash

# These are necessary tools
for f in "mkdtboimg.py" "fdtget" "fdtput" "avbtool"; do
	which $f &>/dev/null || {
		echo "! Error: $f not found!"
		exit 1
	}
done

cd ${0%/*}

for f in "dtb" "dtbo.img"; do
	if ! [ -f "./$f" ]; then
		echo "! Error: ./$f not found!"
		exit 1
	fi
done

###############################################################################
# Prepare
###############################################################################

dtbo_unpack_output=$(mktemp -d)

trap "rm -rf \"$dtbo_unpack_output\"; exit" SIGINT SIGTERM SIGQUIT SIGHUP

cp ./dtbo.img "${dtbo_unpack_output}/dtbo.img"

(
	cd "$dtbo_unpack_output"
	mkdtboimg.py dump ./dtbo.img -b dtbo &>/dev/null
	rm ./dtbo.img
)

# Only keep marble's dtbo
marble_dtbo=
for dtbo_file in "$dtbo_unpack_output"/*; do
	if [ "$(fdtget $dtbo_file / model -ts)" == "Marble based on Qualcomm Technologies, Inc SM7475" ]; then
		marble_dtbo="$dtbo_file"
		break
	fi
done
if [ -z "$marble_dtbo" ]; then
	echo "! Can not found Marble dtbo file!"
	exit 1
fi

get_phandle() {
	local dtb_file="$1"
	local node="$2"

	fdtget "$dtb_file" "$node" "phandle" -tx
}

###############################################################################
# dtb
###############################################################################

echo "- Patching dtb ..."

P_CPU0=$(get_phandle ./dtb "/cpus/cpu@0")
P_CPU1=$(get_phandle ./dtb "/cpus/cpu@100")
P_CPU2=$(get_phandle ./dtb "/cpus/cpu@200")
P_CPU3=$(get_phandle ./dtb "/cpus/cpu@300")
P_CPU4=$(get_phandle ./dtb "/cpus/cpu@400")
P_CPU5=$(get_phandle ./dtb "/cpus/cpu@500")
P_CPU6=$(get_phandle ./dtb "/cpus/cpu@600")
P_CPU7=$(get_phandle ./dtb "/cpus/cpu@700")
P_S3E=$(get_phandle ./dtb "/soc/rsc@17a00000/rpmh-regulator-smpe3/regulator-pmr735a-s3")
P_qmp_aop=$(get_phandle ./dtb "/soc/qcom,qmp-aop")

# ARM: dts: qcom: Define tmecrashdump address offset for tz-log driver usage
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/fd74d352a4ce55a00aaa2e14fce09d98db4744d6
fdtput ./dtb "/soc/tz-log@146AA720" "tmecrashdump-address-offset" 0x81CA0000 -tx

# ARM: dts: qcom: Add cooling cell property for CPU nodes for cape
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/da2a9732fa85a65401bc1beeacb3442ffb38bfec
fdtput ./dtb "/cpus/cpu@100" '#cooling-cells' 2 -tu
fdtput ./dtb "/cpus/cpu@200" '#cooling-cells' 2 -tu
fdtput ./dtb "/cpus/cpu@300" '#cooling-cells' 2 -tu
fdtput ./dtb "/cpus/cpu@500" '#cooling-cells' 2 -tu
fdtput ./dtb "/cpus/cpu@600" '#cooling-cells' 2 -tu

# ARM: dts: qcom: Add thermal devicetree changes for qultivate
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/a24e5321d3c96e0908865091351948fd3cf7182c
fdtput ./dtb "/soc/qcom,cpu-pause/cpu0-pause"     "qcom,cdev-alias" "thermal-pause-1" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu1-pause"     "qcom,cdev-alias" "thermal-pause-2" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu2-pause"     "qcom,cdev-alias" "thermal-pause-4" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu3-pause"     "qcom,cdev-alias" "thermal-pause-8" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu5-pause"     "qcom,cdev-alias" "thermal-pause-20" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu6-pause"     "qcom,cdev-alias" "thermal-pause-40" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu7-pause"     "qcom,cdev-alias" "thermal-pause-80" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/apc1-pause"     "qcom,cdev-alias" "thermal-pause-E0" -ts
fdtput ./dtb "/soc/qcom,cpu-pause/cpu-6-7-pause"  "qcom,cdev-alias" "thermal-pause-C0" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu0-hotplug" "qcom,cdev-alias" "cpu-hotplug0" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu1-hotplug" "qcom,cdev-alias" "cpu-hotplug1" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu2-hotplug" "qcom,cdev-alias" "cpu-hotplug2" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu3-hotplug" "qcom,cdev-alias" "cpu-hotplug3" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu5-hotplug" "qcom,cdev-alias" "cpu-hotplug5" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu6-hotplug" "qcom,cdev-alias" "cpu-hotplug6" -ts
fdtput ./dtb "/soc/qcom,cpu-hotplug/cpu7-hotplug" "qcom,cdev-alias" "cpu-hotplug7" -ts

fdtput ./dtb "/soc/qcom,cpu-voltage-cdev/qcom,apc1-cluster" "qcom,cpus" -d
fdtput ./dtb "/soc/qcom,cpu-voltage-cdev/qcom,apc1-cluster" "qcom,cluster0" "$P_CPU4" "$P_CPU5" "$P_CPU6" -tx
fdtput ./dtb "/soc/qcom,cpu-voltage-cdev/qcom,apc1-cluster" "qcom,cluster1" "$P_CPU7" -tx

fdtput ./dtb "/soc/qcom,cpufreq-cdev" "qcom,cpus" -d
fdtput ./dtb -cp "/soc/qcom,cpufreq-cdev/cpu-cluster0"
fdtput ./dtb "/soc/qcom,cpufreq-cdev/cpu-cluster0" "qcom,cpus" "$P_CPU0" "$P_CPU1" "$P_CPU2" "$P_CPU3" -tx
fdtput ./dtb -cp "/soc/qcom,cpufreq-cdev/cpu-cluster1"
fdtput ./dtb "/soc/qcom,cpufreq-cdev/cpu-cluster1" "qcom,cpus" "$P_CPU4" "$P_CPU5" "$P_CPU6" -tx
fdtput ./dtb -cp "/soc/qcom,cpufreq-cdev/cpu-cluster2"
fdtput ./dtb "/soc/qcom,cpufreq-cdev/cpu-cluster2" "qcom,cpus" "$P_CPU7" -tx

trip=$(fdtget ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev" "trip" -tx)
fdtput ./dtb -r "/soc/thermal-zones/ddr/cooling-maps/gold_cdev"
fdtput ./dtb -cp "/soc/thermal-zones/ddr/cooling-maps/gold_cdev0"
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev0" "trip" "$trip" -tx
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev0" "cooling-device" "$P_CPU4" 0xffffffff 0xffffffff -tx
fdtput ./dtb -cp "/soc/thermal-zones/ddr/cooling-maps/gold_cdev1"
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev1" "trip" "$trip" -tx
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev1" "cooling-device" "$P_CPU5" 0xffffffff 0xffffffff -tx
fdtput ./dtb -cp "/soc/thermal-zones/ddr/cooling-maps/gold_cdev2"
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev2" "trip" "$trip" -tx
fdtput ./dtb "/soc/thermal-zones/ddr/cooling-maps/gold_cdev2" "cooling-device" "$P_CPU6" 0xffffffff 0xffffffff -tx
unset trip

# ARM: dts: msm: Add IPA regulator configuration
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/e5c053276f288e40791be316bb0b16e0b7379176
fdtput ./dtb "/soc/qcom,cnss-qca6490@b0000000" "vdd-wlan-ipa-supply" "$P_S3E" -tx
fdtput ./dtb "/soc/qcom,cnss-qca6490@b0000000" "qcom,vdd-wlan-ipa-config" 2200000 2200000 0 0 0 -tu

# ARM: dts: msm: Add ipa support for Bluetooth node
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/f4cd18877e0085e8ff9d4e62aaf5fdca399fe2ce
fdtput ./dtb "/soc/bt_qca6490" "mboxes" "$P_qmp_aop" 0x0 -tx
fdtput ./dtb "/soc/bt_qca6490" "qcom,vreg_ipa" "s3e" -ts
fdtput ./dtb "/soc/bt_qca6490" "qcom,vreg_ipa-supply" "$P_S3E" -tx
fdtput ./dtb "/soc/bt_qca6490" "qcom,vreg_ipa-config" 2200000 2200000 0 1 -tu

# ARM: dts: msm: limit memory dump range to low 8G
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/a6046a44a423b4e8c5113a819eb6b36fb6d18b94
fdtput ./dtb "/reserved-memory/mem_dump_region" "alloc-ranges" 0x0 0x00000000 0x1 0xffffffff -tx

# ARM: dts: msm: Fix the frequency to clock mismatch on cape
# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/bf394ed1d8cd191a58c9a7e35a72126d7cf732c7
fdtput ./dtb "/soc/qcom,pcie@1c00000" "max-clock-frequency-hz" 0 0 0 19200000 0 0 0 0 0 0 0 100000000 0 0 0 -tu
fdtput ./dtb "/soc/qcom,pcie@1c08000" "max-clock-frequency-hz" 0 0 0 19200000 0 0 0 0 0 0 0 100000000 0 0 0 0 -tu

###############################################################################
# dtbo-0: For MIUI / HyperOS / AOSPA
###############################################################################

cp "$marble_dtbo" ./dtbo-0

do_aw882xx_hack() {
	local dtbo_file=$1
	local node
	local aw882xx_node

	for node in $(fdtget "$dtbo_file" / -l | grep -E 'fragment@[[:digit:]]+'); do
		if fdtget "$dtbo_file" "/${node}/__overlay__" -l | grep -qE 'aw882xx_smartpa@[[:digit:]]+'; then
			aw882xx_node="/${node}/__overlay__"
			break
		fi
	done

	if [ -z "$aw882xx_node" ]; then
		echo "! Can not found aw882xx_smartpa node in ${dtbo_file}!"
		return 1
	fi

	for node in $(fdtget "$dtbo_file" "$aw882xx_node" -l); do
		# Enable fade in/out
		fdtput "$dtbo_file" "${aw882xx_node}/${node}" "fade-flag" 1 -tu

		# Synchronously load the firmware
		fdtput "$dtbo_file" "${aw882xx_node}/${node}" "sync-load" 1 -tu

		# Synchronously mute
		fdtput "$dtbo_file" "${aw882xx_node}/${node}" "mute-sync" 1 -tu
	done
}

echo "- Patching dtbo-0 ..."

do_aw882xx_hack ./dtbo-0 && sync || exit 1

###############################################################################
# dtbo-1: For rom based on OSS kernel
###############################################################################

cp ./dtbo-0 ./dtbo-1

do_panel_hack() {
	local dtbo_file=$1
	local symbol
	local node

	for symbol in "dsi_m16t_36_02_0a_dsc_vid" "dsi_m16t_36_0d_0b_dsc_vid"; do
		node=$(fdtget "$dtbo_file" "/__symbols__" "$symbol" -ts) || {
			echo "! Can not found ${symbol} node in ${dtbo_file}!"
			return 1
		}

		# Correct physical panel dimensions
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/9d5dd22ada720f73713fe44d77153e3189e852e2
		fdtput "$dtbo_file" "${node}" "qcom,mdss-pan-physical-width-dimension"  70  -tu
		fdtput "$dtbo_file" "${node}" "qcom,mdss-pan-physical-height-dimension" 154 -tu

		# Disable 30Hz timing
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/b1588abf069a73668643a128b621c738dbd6f9ac
		fdtput "$dtbo_file" "${node}" "qcom,dsi-supported-dfps-list" 60 120 90 -tu

		# Bump minimal brightness to 8
		# https://github.com/cupid-development/android_kernel_xiaomi_sm8450-devicetrees/commit/f0b4ec403959815341a7a77765e90eea82996487
		fdtput "$dtbo_file" "${node}" "qcom,mdss-dsi-bl-min-level" 8 -tu
	done
}

do_xiaomi_touch_hack() {
	local dtbo_file=$1
	local fingerprint_screen_node fingerprint_screen_parent_node fingerprint_screen_panel_val lf_fingerprint_screen_panel_val

	fingerprint_screen_node=$(fdtget "$dtbo_file" /__symbols__ fingerprint_screen -ts)
	fingerprint_screen_parent_node=$(dirname $fingerprint_screen_node)
	fingerprint_screen_panel_val=$(fdtget "$dtbo_file" "$fingerprint_screen_node" panel -tu)
	fdtput "$dtbo_file" -c "${fingerprint_screen_parent_node}/xiaomi-touch"
	fdtput "$dtbo_file" "${fingerprint_screen_parent_node}/xiaomi-touch" "panel-primary" $fingerprint_screen_panel_val -tu

	if fdtget "$dtbo_file" "/__local_fixups__/${fingerprint_screen_node}" -l; then
		lf_fingerprint_screen_panel_val=$(fdtget "$dtbo_file" "/__local_fixups__/${fingerprint_screen_node}" panel -tu)
		fdtput "$dtbo_file" -c "/__local_fixups__${fingerprint_screen_parent_node}/xiaomi-touch"
		fdtput "$dtbo_file" "/__local_fixups__${fingerprint_screen_parent_node}/xiaomi-touch" "panel-primary" $lf_fingerprint_screen_panel_val -tu
	fi
}

echo "- Patching dtbo-1 ..."

do_panel_hack ./dtbo-1 && do_xiaomi_touch_hack ./dtbo-1 && sync || exit 1

###############################################################################
# Make dtbo.img
###############################################################################

for dtbo_file in ./dtbo-0 ./dtbo-1; do
	echo "- Making ${dtbo_file}.img ..."
	mkdtboimg.py create ${dtbo_file}.img $dtbo_file
	avbtool add_hash_footer --partition_name dtbo --partition_size $((24 * 1024 * 1024)) --image ${dtbo_file}.img
	rm $dtbo_file
done

###############################################################################
# Cleanup
###############################################################################

echo "- Cleaning up ..."

rm -rf "$dtbo_unpack_output"

echo "- Done!"
