#!/bin/bash

#################################################################################################
#												#
# Script to build a USB key containing Debian ISO images copied to individual paritions.	#
# The main install disc (DVD 1) is downloaded according to specified architecture.		#
# Will also download additional ISO images according to the packages specified. 		#
#												#
#################################################################################################

# Functions
#############################
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

# Print msg for return code, and exit on fail
okay_failedexit () {
        if [ $1 -eq 0 ]; then
                echo "Okay"
        else
                echo "Failed"
                exit
        fi
}

# Check for command
command_check () {
	cmd=${1}
	cmd_path=`command -v ${cmd}`
	if [ ${?} -ne 0 ]; then
		echo "Error: Failed to find command - ${cmd}" >&2
		exit 1
	fi
	#echo "${cmd_path}"
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
	sudo -v &>/dev/null
	return ${?}
}

# Check the type of block device
device_type_check () {
	dev_type=$1
	sudo lsblk -dn ${dev_type} |sed 's|^[a-z0-9]*\s*[0-9:]*\s*[0-9]*\s*[0-9.]*.\s*[0-9]*\s*\([a-z]*\)\s*$|\1|'
}

# Check that a partition on a device has been created
# and return it's path
device_part_check () {
	device_path="${1}"
	partition_num="${2}"
	partition_path=

	sudo partprobe "${device_path}" &>/dev/null
	if [ -b "${device_path}p${partition_num}" ]; then
		partition_path="${device_path}p${partition_num}"
	elif [ -b "${device_path}${partition_num}" ]; then
		partition_path="${device_path}${partition_num}"
	else
		echo "Failed to find partition"
		return 1
	fi
	partition_type=`device_type_check ${partition_path}`
	if [[ "${partition_type}" != "part" ]]; then
		echo "Unknown partition type - ${partition_type}"
		return 1
	fi

	echo "${partition_path}"
	return 0
}

# Create an appropriately sized partition on device,
# and copy ISO image to it
device_add_iso_image () {
	device_path="${1}"
	partition_num="${2}"
	iso_image_path="${3}"
	iso_image_name="${4}"

	# Check that the given file is actually ISO image
	isoinfo -i "${iso_image_path}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "Invalid ISO image"
		return 1
	fi

	# Calculate sector count
	iso_image_size=`wc -c "${iso_image_path}" | sed 's|^\([0-9]*\)\s.*$|\1|'`
	device_sector_size=`sudo blockdev --getpbsz "${device_path}"`
	sector_count=$((${iso_image_size}/${device_sector_size}))

	# Create partiton
	sudo sgdisk --new=${partition_num}:0:+${sector_count} --typecode=${partition_num}:8300 --change-name=${partition_num}:${iso_image_name} "${device_path}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "Failed to create partition"
		return 1
	fi
	# Check partition
	iso_image_partition=`device_part_check "${device_path}" ${partition_num}`
	if [ ${?} -ne 0 ]; then
		echo "${iso_image_partition}"
		return 1
	fi

	# Copy ISO image to partition
	err_msg=`sudo dd if="${iso_image_path}" of="${iso_image_partition}" bs=${device_sector_size} status=noxfer 2>&1`
	if [ ${?} -ne 0 ]; then
		echo "Failed to copy ISO image - ${err_msg}"
		return 1
	fi

	return 0
}

# Copy EFI file from ISO image to EFI partition
efi_copy_from_iso () {
	path_source="${1}"
	path_target="${2}"

	# Copy EFI binaries
	path_efi_bin="/EFI/boot/"
	sudo cp "${path_source}${path_efi_bin}"* "${path_target}${path_efi_bin}"
	if [ ${?} -ne 0 ]; then
		echo "Failed to copy ${path_efi_bin}"
		return 1
	fi

	# Copy GRUB resources
	path_grub_rsc="/boot/grub/"
	for tmp_rsc in `find "${path_source}${path_grub_rsc}" -maxdepth 1 -mindepth 1 ! -name grub.cfg ! -name efi.img`; do
		sudo cp -r "${tmp_rsc}" "${path_target}${path_grub_rsc}"
		if [ ${?} -ne 0 ]; then
			echo "Failed to copy ${path_grub_rsc}"
			return 1
		fi
	done

	return 0
}

# Check for used commands
#############################
command_check blockdev						# Check for 'blockdev' command
command_check dd						# Check for 'dd' command
command_check isoinfo						# Check for 'isoinfo' command
command_check lsblk						# Check for 'lsblk' command
command_check mkfs.vfat						# Check for 'mkfs.vfat' command
command_check partprobe						# Check for 'partprobe' command
command_check sed						# Check for 'sed' command
command_check sgdisk						# Check for 'sgdisk' command
command_check sudo						# Check for 'sudo' command

# Defines
#############################
PATH_EFI_EFIBOOT="/EFI/boot"					# Path to EFI GRUB binaries
PATH_EFI_BOOTGRUB="/boot/grub"					# Path to GRUB resources
PATH_EFI_HASHES="/hashes"					# Base directory of store for hashes/signatures
TXT_UNDERLINE="\033[1m\033[4m"					# Used to pretty print output
TXT_NORMAL="\033[0m"

# Variables
#############################
DEV_PATH=							# USB device path
DIR_PWD=`pwd`							# Current directory
DIR_MNT="${DIR_PWD}/mnt"					# Directory to use for mount points
DIR_MNT_EXISTS=0						# Flag whether mount directory was created or not
DIR_TMP="${DIR_PWD}/tmp"					# Directory to use for temporary storage
DIR_TMP_EXISTS=0						# Flag whether tmp directory was created or not
ERR_SKIP=0							# If set, skip any remaining items
LST_ARCH=""							# Architecture list
LST_ISO=()							# ISO image path array
LST_PKG=""							# Package list
PARTITION_NUM=1							# Partition counter
PATH_EFI_DEV=							# USB key EFI partition path
PATH_EFI_MNT="${DIR_MNT}/efi"					# USB key EFI partition mount path
PATH_ISO_DEV=							# ISO image partition path
PATH_ISO_MNT="${DIR_MNT}/iso"					# ISO image partition mount path

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
		LST_ISO+=( "${OPTARG}" )
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

##########################################################
# Main
##########################################################

# Check user ID
#############################
# Don't run as root as the downloads could do unforeseen things
if [ `id -u` -eq 0 ]; then
	echo "Error: This script should not be run as root" >&2
	exit 1
fi

# User confirmation
#############################
echo "The device ${DEV_PATH} will be completely wiped."
read -r -p "ARE YOU SURE YOU WISH TO CONTINUE? (y/N): " DOCONTINUE
if [[ $DOCONTINUE = [Yy] ]]; then
	echo
else
	echo "Operation canceled"
	exit 1
fi

# Sudo privileges
#############################
sudo_priv_check
if [ ${?} -ne 0 ]; then
	echo "Error: Failed to get sudo privileges." >&2
	exit 1
fi
echo

# Sanity check
#############################
echo -e "${TXT_UNDERLINE}Running sanity checks:${TXT_NORMAL}"
# Check device
if [ -z "${DEV_PATH}" ]; then
	echo "	Error: No device specified" >&2
	exit 1
fi
if [ ! -b "${DEV_PATH}" ]; then
	echo "	Error: Not a block device - ${DEV_PATH}" >&2
	exit 1
fi
DEV_TYPE=`device_type_check ${DEV_PATH}`
if [[ "${DEV_TYPE}" != "disk" ]] && [[ "${DEV_TYPE}" != "loop" ]]; then
	echo "	Error: Wrong device type - ${DEV_TYPE}" >&2
	exit 1
fi
mount |grep "${DEV_PATH}" &>/dev/null
if [ $? -eq 0 ]; then
	echo "	Error: Device mounted - ${DEV_PATH}" >&2
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

# Create directories
#############################
echo -e "${TXT_UNDERLINE}Creating directories:${TXT_NORMAL}"
if [ -d "${DIR_MNT}" ]; then DIR_MNT_EXISTS=1; fi
echo -n "	Create .${PATH_EFI_MNT#${DIR_PWD}}: "
mkdir -p "${PATH_EFI_MNT}" &>/dev/null
okay_failedexit $?
echo -n "	Create .${PATH_ISO_MNT#${DIR_PWD}}: "
mkdir -p "${PATH_ISO_MNT}" &>/dev/null
okay_failedexit $?
if [ -d "${DIR_TMP}" ]; then DIR_TMP_EXISTS=1; fi
echo -n "	Create .${DIR_TMP#${DIR_PWD}}: "
mkdir -p "${DIR_TMP}" &>/dev/null
okay_failedexit $?
echo

# Create EFI partition
#############################
echo -e "${TXT_UNDERLINE}Creating EFI partition: ${DEV_PATH}${TXT_NORMAL}"
echo -n "	Wiping partition table: "
sudo sgdisk --zap-all "${DEV_PATH}" &>/dev/null
okay_failedexit $?
echo -n "	Create EFI System partition (256MB): "
sudo sgdisk --new=1:0:+256M --typecode=1:ef00 --change-name=1:DI-EFI "${DEV_PATH}" &>/dev/null
okay_failedexit $?
PATH_EFI_DEV=`device_part_check "${DEV_PATH}" 1`
if [ ${?} -ne 0 ]; then
	echo "	Error: ${PATH_EFI_DEV}" >&2
	exit 1
fi
PARTITION_NUM=$((${PARTITION_NUM}+1))
echo -n "	Formating EFI System partition (${PATH_EFI_DEV}): "
sudo mkfs.vfat -F32 -n DI-EFI "${PATH_EFI_DEV}" &>/dev/null
okay_failedexit $?
echo -n "	Mounting EFI System partition (.${PATH_EFI_MNT#${DIR_PWD}}): "
sudo mount -t vfat "${PATH_EFI_DEV}" "${PATH_EFI_MNT}" &>/dev/null
okay_failedexit $?
echo "	Creating directories:"
echo -n "		.${PATH_EFI_MNT#${DIR_PWD}}${PATH_EFI_EFIBOOT}: "
sudo mkdir -p "${PATH_EFI_MNT}${PATH_EFI_EFIBOOT}" &>/dev/null
okay_failedexit $?
echo -n "		.${PATH_EFI_MNT#${DIR_PWD}}${PATH_EFI_BOOTGRUB}: "
sudo mkdir -p "${PATH_EFI_MNT}${PATH_EFI_BOOTGRUB}" &>/dev/null
okay_failedexit $?
echo -n "		.${PATH_EFI_MNT#${DIR_PWD}}${PATH_EFI_HASHES}: "
sudo mkdir -p "${PATH_EFI_MNT}${PATH_EFI_HASHES}" &>/dev/null
okay_failedexit $?
echo

# Add specified ISO images
#############################
if [ -n "${LST_ISO}" ] && [ ${ERR_SKIP} -eq 0 ]; then
	echo -e "${TXT_UNDERLINE}Add specified ISO images:${TXT_NORMAL}"
	for tmp_index in ${!LST_ISO[@]}; do
		tmp_iso_img="${LST_ISO[${tmp_index}]}"
		tmp_iso_filename=`basename "${tmp_iso_img}"`
		echo -n "	Adding ${tmp_iso_filename}: "
		err_msg=`device_add_iso_image "${DEV_PATH}" "${PARTITION_NUM}" "${tmp_iso_img}" "${tmp_iso_filename}"`
		if [ ${?} -eq 0 ]; then
			echo "Okay"
		else
			echo "${err_msg}"
			ERR_SKIP=1
			break;
		fi
		echo -n "		Mounting ISO image: "
		sudo mount "/dev/disk/by-partlabel/${tmp_iso_filename}" "${PATH_ISO_MNT}" &>/dev/null
		if [ ${?} -eq 0 ]; then
			echo "Okay"
		else
			echo "Failed"
			ERR_SKIP=1
			break;
		fi
		echo -n "		Checking if bootable: "
		if [ -d "${PATH_ISO_MNT}/boot" ]; then
			echo "Yes"

			echo -n "		Copying EFI files: "
			err_msg=`efi_copy_from_iso "${PATH_ISO_MNT}" "${PATH_EFI_MNT}"`
			if [ ${?} -eq 0 ]; then
				echo "Okay"
			else
				echo "${err_msg}"
				ERR_SKIP=1
				break;
			fi
		else
			echo "No"
		fi
		echo -n "		Unmounting ISO image: "
		sudo umount "${PATH_ISO_MNT}" &>/dev/null
		if [ ${?} -eq 0 ]; then
			echo "Okay"
		else
			echo "Failed"
			ERR_SKIP=1
			break;
		fi
		PARTITION_NUM=$((${PARTITION_NUM}+1))
	done
	echo
fi

# Clean up
#############################
echo -e "${TXT_UNDERLINE}Clean Up:${TXT_NORMAL}"
echo -n "	Unmounting EFI System partition: "
sudo umount "${PATH_EFI_MNT}" &>/dev/null
okay_failedexit $?
if [ ${DIR_MNT_EXISTS} -eq 0 ]; then
	echo -n "	Deleting .${DIR_MNT#${DIR_PWD}}: "
	rm -rf "${DIR_MNT}" &>/dev/null
	okay_failedexit $?
fi
if [ ${DIR_TMP_EXISTS} -eq 0 ]; then
	echo -n "	Deleting .${DIR_TMP#${DIR_PWD}}: "
	rm -rf "${DIR_TMP}" &>/dev/null
	okay_failedexit $?
fi
echo

if [ ${ERR_SKIP} -eq 1 ]; then
	echo "!!! Failed to create USB key !!!"
fi
