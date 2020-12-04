#!/system/bin/sh

################################################################################
##                                                                            ##
##                          cloudroid init script                             ##
##                                                                            ##
################################################################################

####                                                                   VARIABLES

# termux info
TERMUX_UID="$(awk '($1 == "com.termux") { print $2; exit }' /data/system/packages.list)"
TERMUX_DATA="$(awk '($1 == "com.termux") { print $4; exit }' /data/system/packages.list)"
TERMUX_BIN="$TERMUX_DATA/files/usr/bin"
TERMUX_HOME="$TERMUX_DATA/files/home"

# directories/files used by cloudroid
TEMP="/cache"
MODDIR=${0%/*}
SWAPFILE="/data/adb/swapfile"
CLOUDROID_ROOT="cloudroid"
CLOUDROID_CLI_SCRIPT="cloudroid-start"

# main parameters for cloudroid
SWAPFILE_SIZE="$(awk '($1 == "MemTotal:") { print int($2 * 512) }' /proc/meminfo)"
CLOUD_PARTITION=""
LMK_PRAMS_MINFREE="0,0,0,0,65536,65536"
LINUX_VM_SWAPPINESS="10"
SENSITIVE_TWEAKS_DELAY="30"

####                                                            HELPER FUNCTIONS

# logging helper
cloudroid_log() {
	date +"[%c] CLOUDROID: $(printf "%s" "$@" | sed 's/%/%%/g')"
}

####                                                            TWEAKS FUNCTIONS

# set selinux mode to permissive
cloudroid_set_selinux_permissive() {
	cloudroid_log "setting selinux policy to permissive"
	setenforce permissive
	cloudroid_log "new selinux policy ->"
	getenforce
}

# disable zram and enable swapfile
cloudroid_enable_swapfile() {
	cloudroid_log "disabling current swaps & setting up swapfile"
	if [ ! -f "/proc/swaps" ]; then
		cloudroid_log "skipping swapfile setup -> '/proc/swaps' not present on platform"
		return
	fi

	# disable previous swaps
	{
		read -r # ignore first line (header)
		while IFS=" " read -r swap _; do
			cloudroid_log "disabling swap '$swap'"
			swapoff "$swap"
		done
	} </proc/swaps

	# create swapfile if it doesn't exist or update the size if there's one
	if blkid "$SWAPFILE" | grep -F -q 'TYPE="swap"' &&
		[ "$SWAPFILE_SIZE" -eq "$(stat -c %s $SWAPFILE)" ]; then
		cloudroid_log "not touching existing swapfile '$SWAPFILE' with size $SWAPFILE_SIZE"
	else
		cloudroid_log "preparing new swapfile '$SWAPFILE' with size $SWAPFILE_SIZE"
		dd if=/dev/zero of="$SWAPFILE" count=512 bs="$((SWAPFILE_SIZE / 512))"
		mkswap "$SWAPFILE"
	fi

	# adjust swapfile permissions and mount it
	cloudroid_log "adjusting swapfile '$SWAPFILE' permissions"
	chown root:root "$SWAPFILE"
	chmod 600 "$SWAPFILE"
	cloudroid_log "swapfile '$SWAPFILE' permissions ->"
	ls -l "$SWAPFILE"
	cloudroid_log "mounting swapfile '$SWAPFILE'"
	swapon "$SWAPFILE"
	cloudroid_log "current swaps ->"
	cat /proc/swaps
}

# make kvm available to all users (needed for qemu)
cloudroid_expose_kvm() {
	cloudroid_log "setting up kvm"
	if [ ! -c "/dev/kvm" ]; then
		cloudroid_log "skipping kvm setup -> '/dev/kvm' not present on platform"
		return
	fi

	# set r/w permissions for everybody
	chmod 666 /dev/kvm
	cloudroid_log "new kvm permissions ->"
	ls -l /dev/kvm
}

# install cloudroid-start script in termux (used to create and start instances)
cloudroid_termux_install_script() {
	cloudroid_log "installing '$CLOUDROID_CLI_SCRIPT' script in termux"
	cp "$MODDIR/termux/$CLOUDROID_CLI_SCRIPT" "$TERMUX_BIN/$CLOUDROID_CLI_SCRIPT"
	sed -i "1s|^#!/bin/bash$|#!$TERMUX_BIN/bash|" "$TERMUX_BIN/$CLOUDROID_CLI_SCRIPT"
	chown "$TERMUX_UID":"$TERMUX_UID" "$TERMUX_BIN/$CLOUDROID_CLI_SCRIPT"
	chmod 700 "$TERMUX_BIN/$CLOUDROID_CLI_SCRIPT"
	cloudroid_log "'$CLOUDROID_CLI_SCRIPT' script status ->"
	ls -l "$TERMUX_BIN/$CLOUDROID_CLI_SCRIPT"
}

# mount the cloud partition (should be used only if internal storage is small)
cloudroid_termux_mount_cloud_partition() {
	cloudroid_log "mounting cloud partition"
	if [ -z "$CLOUD_PARTITION" ]; then
		cloudroid_log "skipping cloud partition mounting -> not configured"
		return
	fi

	mount -o noatime "$CLOUD_PARTITION" "$TERMUX_HOME/$CLOUDROID_ROOT"
	cloudroid_log "cloud partition status ->"
	mount | grep -F "$CLOUD_PARTITION"
}

# disable mediatek hps hotplug strategy & bring all cpus online
cloudroid_disable_mediatek_hps() {
	cloudroid_log "disabling mediatek hotplug strategy/scheduler (hps) & bringing all cpus online"
	if [ ! -d "/proc/hps/" ]; then
		cloudroid_log "skipping hps setup -> '/proc/hps/' not present on platform"
		return
	fi

	# disable mediatek hps
	echo 0 | tee /proc/hps/enabled >/dev/null
	cloudroid_log "hps strategy status ->"
	cat /proc/hps/enabled
	# bring all cpus online
	echo 1 | tee /sys/devices/system/cpu/cpu*/online >/dev/null
	cloudroid_log "cpus online status ->"
	awk '{ print FILENAME, $0 }' /sys/devices/system/cpu/cpu*/online
}

# disable doze mode
cloudroid_disable_deviceidle() {
	cloudroid_log "disabling doze mode"
	dumpsys deviceidle disable
	cloudroid_log "new doze mode status ->"
	dumpsys deviceidle enabled
}

# tweak android lmk
cloudroid_tune_android_lmk() {
	cloudroid_log "adjusting android lmk parameters"
	chown root:root /sys/module/lowmemorykiller/parameters/minfree
	chmod 644 /sys/module/lowmemorykiller/parameters/minfree
	echo "$LMK_PRAMS_MINFREE" | tee /sys/module/lowmemorykiller/parameters/minfree >/dev/null
	cloudroid_log "current android lmk parameters ->"
	awk '{ print FILENAME, $0 }' /sys/module/lowmemorykiller/parameters/*
}

# tweak swap
cloudroid_tune_vm_swappiness() {
	cloudroid_log "adjusting swappiness"
	echo "$LINUX_VM_SWAPPINESS" | tee /proc/sys/vm/swappiness >/dev/null
	cloudroid_log "current swappiness ->"
	awk '{ print FILENAME, $0 }' /proc/sys/vm/swappiness
}

####                                                               MAIN FUNCTION

# main function
cloudroid_init() {
	# redirect all output to a log file in cache
	exec >"$TEMP/cloudroid-init.log" 2>&1

	# wait for the device to boot
	cloudroid_log "waiting for device to boot"
	while [ ! "$(getprop sys.boot_completed)" ]; do sleep 1; done
	cloudroid_log "boot completed -> begin setup"

	# check if termux is installed
	cloudroid_log "checking if termux app is installed"
	if [ -z "$TERMUX_UID" ] || [ -z "$TERMUX_DATA" ]; then
		cloudroid_log "aborting setup -> package 'com.termux' is not installed"
		exit 1
	fi
	cloudroid_log "termux app installed -> continue"

	# check if the cloudroid control point exists
	cloudroid_log "checking for '$CLOUDROID_ROOT' folder in termux home"
	if [ ! -d "$TERMUX_HOME/$CLOUDROID_ROOT" ]; then
		cloudroid_log "aborting setup -> folder '$CLOUDROID_ROOT' is missing from termux home"
		exit 1
	fi
	cloudroid_log "'$CLOUDROID_ROOT' folder present in termux home -> continue"

	# cloudroid init starting
	cloudroid_log "setup started"

	# early tweaks
	cloudroid_set_selinux_permissive
	cloudroid_enable_swapfile
	cloudroid_expose_kvm
	cloudroid_termux_install_script
	cloudroid_termux_mount_cloud_partition

	# sleep for late post-boot tweaks
	cloudroid_log "sleeping $SENSITIVE_TWEAKS_DELAY seconds for timing sensitive tweaks"
	sleep $SENSITIVE_TWEAKS_DELAY

	# late tweaks
	cloudroid_disable_mediatek_hps
	cloudroid_disable_deviceidle
	cloudroid_tune_android_lmk
	cloudroid_tune_vm_swappiness

	# cloudroid init finished
	cloudroid_log "setup finished"
}

cloudroid_init
