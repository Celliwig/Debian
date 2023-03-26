#!/bin/bash

#################################################################################################
#												#
# Script to build a USB key containing Debian ISO images copied to individual paritions.	#
# The main install disc (DVD 1) is downloaded according to specified architecture.		#
# Will also download additional ISO images according to the packages specified. 		#
#												#
#################################################################################################

# Functions
##############
# Print usage
usage () {
	echo "Download Debian ISO images & build a USB key from them."
	echo
	echo "$0 <options>"
	echo "Options:"
	echo "	-a <architecture>	Add architecture to download"
	echo "	-d <device path>	Device path of USB key"
	echo "	-I <ISO image path>	Path to ISO image to add"
	echo "	-p <package>		Add a package to download the relavent ISO image for"
	echo "	-t <directory>		Directory to use as temporary storage for downloading files"
}

# Check for command
command_check () {
echo hello
	cmd=${1}
	cmd_path=`command -v ${cmd}`
	if [ ${?} -ne 0 ]; then
		echo "Error: Failed to find command - ${cmd}" >&2
		exit 1
	fi
	echo "${cmd_path}"
	return 0
}

# Check architecture is valid
arch_check () {
	arch=${1}
	case ${arch} in
	i386| \
	amd64| \
	arm64| \
	armel| \
	armhf)
		return 0
		;;
	esac
	return 1
}

# Sudo requests privileges, return priv status
sudo_priv_check () {
	# Request/Check sudo privileges
	sudo -v &> /dev/null
	return ${?}
}

# Defines
##############
CMD_SGDISK=`command_check sgdisk`				# Path to sgdisk command

TXT_UNDERLINE="\033[1m\033[4m"					# Used to pretty print output
TXT_NORMAL="\033[0m"

# Variables
##############
DEV_PATH=							# USB device path
DIR_PWD=`pwd`							# Current directory
DIR_TMP="${DIR_PWD}/tmp"					# Directory to use for temporary storage
LST_ARCH=""							# Architecture list
LST_ISO=""							# ISO image path list
LST_PKG=""							# Package list

# Parse arguments
while getopts ":ha:d:p:t:I:" arg; do
	case ${arg} in
	a)
		arch_check ${OPTARG}
		if [ ${?} -ne 0 ]; then
			echo "Invalid architecture: ${OPTARG}"
			exit
		fi
		if [ -n "${LST_ARCH}" ]; then LST_ARCH+=" "; fi
		LST_ARCH+=${OPTARG}
		;;
	d)
		DEV_PATH=${OPTARG}
		;;
	h)
		usage
		exit 0
		;;
	I)
		if [ -n "${LST_ISO}" ]; then LST_ISO+=" "; fi
		LST_ISO+=${OPTARG}
		;;
	p)
		if [ -n "${LST_PKG}" ]; then LST_PKG+=" "; fi
		LST_PKG+=${OPTARG}
		;;
	t)
		DIR_TMP=${OPTARG}
		;;
	*)
		echo "$0: Unknown argument"
		exit 1
		;;
	esac
done

# Main
##############

# Check user ID
########################
# Don't run as root as the downloads could do unforeseen things
if [ `id -u` -eq 0 ]; then
	echo "Error: This script should not be run as root" >&2
	exit 1
fi

# User confirmation
########################
echo "The device ${DEV_PATH} will be completely wiped."
read -r -p "ARE YOU SURE YOU WISH TO CONTINUE? (y/N): " DOCONTINUE
if [[ $DOCONTINUE = [Yy] ]]; then
	echo
else
	echo "Operation canceled"
	exit 1
fi

# Sudo privileges
########################
sudo_priv_check
if [ ${?} -ne 0 ]; then
	echo "Error: Failed to get sudo privileges." >&2
	exit 1
fi
echo

# Sanity check
########################
echo -e "${TXT_UNDERLINE}Running sanity checks:${TXT_NORMAL}"

# Check device
if [ -z "${DEV_PATH}" ]; then
	echo "\n	Error: No device specified" >&2
	exit 1
fi
if [ ! -b "${DEV_PATH}" ]; then
	echo "\n	Error: Not a block device - ${DEV_PATH}" >&2
	exit 1
fi
mount |grep "${DEV_PATH}" &> /dev/null
if [ $? -eq 0 ]; then
	echo "\n	Error: Device mounted - ${DEV_PATH}" >&2
	exit 1
fi
DEV_SIZE_BYTES=`sudo blockdev --getsize64 ${DEV_PATH}`
DEV_SIZE_GIG=$((DEV_SIZE_BYTES/1073741824))
if [ ${DEV_SIZE_GIG} -gt 4 ]; then
	echo "	Detected: ${DEV_PATH} (${DEV_SIZE_GIG} GB)"
else
	echo "	Error: The device ${DEV_PATH}, is too small." >&2
	exit 1
fi

echo

# Create EFI partition
########################
echo -e "${TXT_UNDERLINE}Creating EFI partition: ${DEV_PATH}${TXT_NORMAL}"
