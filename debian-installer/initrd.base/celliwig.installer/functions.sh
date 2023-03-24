#!/bin/sh

# Echo message to stdout and log
#################################
echo_log () {
	echo "celliwig-installer: ${@}"
	logger -t celliwig-installer "${@}"
}
echon_log () {
	echo -n "celliwig-installer: ${@}"
	logger -t celliwig-installer "${@}"
}

# Return the Debian architecture
debian_arch () {
	case `uname -m` in
		aarch64)
			echo -n "arm64"
			exit 0
			;;
		armv?l)
			echo -n "armhf"
			exit 0
			;;
		i?86)
			echo -n "i386"
			exit 0
			;;
		x86_64)
			echo -n "amd64"
			exit 0
			;;
		*)
			echo -n "unknown"
			exit -1
			;;
	esac
}

# Return the kernel version
kernel_version () {
	KRNL_VERSION=`uname -r| sed -E 's|([0-9]+\.[0-9]+\.[0-9]+-[0-9]+)-.*|\1|'`
	echo "${KRNL_VERSION}"
}

# Return the specified kernel argument
kernel_arg () {
	KRNL_CMDLINE="/proc/cmdline"
	KRNL_ARG="${1}"
	DEFAULT="${2}"

	# Taken from bin/user-params
	# sed out multi-word quoted value settings
	for item in $(sed -e 's/[^ =]*="[^"]*[ ][^"]*"//g' -e "s/[^ =]*='[^']*[ ][^']*'//g" "${KRNL_CMDLINE}"); do
		key_match="${item%=*}"
		# Remove trailing '?' for debconf variables set with '?='
		key="${key_match%\?}"
		val="${item#*=}"
		#echo "Key: ${key}      Value: ${val}"

		if [ "${key}" = "${KRNL_ARG}" ]; then
			echo -n "${val}"
			exit 0
		fi
	done

	echo -n "${DEFAULT}"
	exit 1
}

get_vgname () {
	# Get the VG name if set on the kernel cmdline,
	# otherwise default to hostname
	LVM_VG=`kernel_arg 'celliwig.lvm.vg' $(hostname)`
	# Covert to uppercase, strip non alpha-num characters
	# Busybox sed doesn't have '\u', so use tr instead
	# tr doesn't support set names, so use sequences
	LVM_VG=`echo ${LVM_VG}| tr -d -c 'a-zA-Z0-9-' | tr 'a-z' 'A-Z'`
	if [ -n "${LVM_VG}" ]; then
		echo -n "${LVM_VG}"
		exit 0
	else
		echo ""
		exit 1
	fi
}
