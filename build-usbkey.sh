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

# Check architecture is valid
arch_check () {
	arch=$1
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

# Defines
##############
CMD_SGDISK=							# Path to sgdisk command (unset means not installed)

# Define commands
CMD_SGDISK=`command -v sgdisk`

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

# Check device
if [ -z "${DEV_PATH}" ]; then
	echo "Error: No device specified"
	exit 1
fi
if [ ! -b "${DEV_PATH}" ]; then
	echo "Error: Not a block device - ${DEV_PATH}"
	exit 1
fi
