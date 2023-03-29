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
	echo "	-D <only|done>		Either only download files, or assume done already"
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

	# Sync cache to disk
	sudo sync &>/dev/null

	return 0
}

# Copy EFI file from ISO image to EFI partition
efi_copy_from_iso () {
	path_source="${1}"
	path_target="${2}"

	# Copy EFI binaries
	path_efi_bin="/EFI/boot/"
	sudo cp "${path_source}${path_efi_bin}"* "${path_target}${path_efi_bin}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "Failed to copy ${path_efi_bin}"
		return 1
	fi

	# Copy GRUB resources
	path_grub_rsc="/boot/grub/"
	for tmp_rsc in `find "${path_source}${path_grub_rsc}" -maxdepth 1 -mindepth 1 ! -name grub.cfg ! -name efi.img`; do
		sudo cp -r "${tmp_rsc}" "${path_target}${path_grub_rsc}" &>/dev/null
		if [ ${?} -ne 0 ]; then
			echo "Failed to copy ${path_grub_rsc}"
			return 1
		fi
	done

	return 0
}

# Download files from a given URL
isosrc_download_files () {
	isosrc_url="${1}"
	isosrc_path_save="${2}"

	# Accept files from ISO source
	#   SHA*SUMS - SHAx hashes of the files
	#   SHA*SUMS.sign - Corresponding signature file
	#   *.iso - ISO image files
	#   *.jigdo - Used by 'jigdo' to create ISO image
	#   *.template - Used by 'jigdo' to create ISO image
	##########################################################
	isosrc_files_accept="SHA*SUMS,SHA*SUMS.sign,*.iso,*.jigdo,*.template"
	# Used for testing (ignores the ISO files)
	#isosrc_files_accept="SHA*SUMS,SHA*SUMS.sign,*.jigdo,*.template"

	# Reject files from ISO source
	##########################################################
	isosrc_files_reject="robots.txt"

	# Download files using wget
	#   -q: quiet
	#   -nd: don't create directory hierarchy
	#   --https-only: only use https sources
	#   -r: recursive retrieving
	#   -l1: set max recursion level to 1
	#   -np: do not ascend to parent
	#   -A: comma seperate list of files to accept
	#   -P: save location
	##########################################################
	err_msg=`wget -nv -nd --https-only -r -l1 -np -A "${isosrc_files_accept}" -R "${isosrc_files_reject}" -P "${isosrc_path_save}" "${isosrc_url}" 2>&1 1>/dev/null`
	if [ ${?} -ne 0 ]; then
		echo "${err_msg}"
		return 1
	fi

	return 0
}

#verify_hash_files () {
#}

verify_iso_images () {
	source_path="${1}"
	padding="${2}"
	retval=1

	# Create text padding
	padding_txt=""
	for (( i=1; i<=${padding}; i++ )); do
		padding_txt+="	"
	done

	# Change to source directory
	cd "${source_path}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "${padding_txt}Failed to change directory"
		return 1
	fi
	# Search for hash files
	for tmp_hashfile in `ls SHA*SUMS`; do
		# Extend credentials timestamp
		# As this may take some time
		sudo_priv_check

		case "${tmp_hashfile}" in
		SHA256SUMS)
			echo -n "${padding_txt}SHA256SUMS: "
			sha256sum --ignore-missing --quiet -c SHA256SUMS &>/dev/null
			if [ ${?} -eq 0 ]; then
				echo "Okay"
				retval=0
			else
				echo "Failed"
				retval=1
				break
			fi
			;;
		SHA512SUMS)
			echo -n "${padding_txt}SHA512SUMS: "
			sha512sum --ignore-missing --quiet -c SHA512SUMS &>/dev/null
			if [ ${?} -eq 0 ]; then
				echo "Okay"
				retval=0
			else
				echo "Failed"
				retval=1
				break
			fi
			;;
		*)
			echo "${padding_txt}Unknown hashfile"
			retval=1
			break;
			;;
		esac
	done
	cd - &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "${padding_txt}Failed to change directory"
		return 1
	fi

	return ${retval}
}

verify_files_copy () {
	source_path="${1}"
	target_path="${2}"

	# Create target path if necessary
	sudo mkdir -p "${target_path}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "Failed to create target path - ${target_path}"
		return 1
	fi

	# Copy hash files and signatures
	sudo cp "${source_path}"/SHA*SUMS* "${target_path}" &>/dev/null
	if [ ${?} -ne 0 ]; then
		echo "Failed to copy files"
		return 1
	fi

	return 0
}

# Check for used commands
#############################
command_check blockdev						# Check for 'blockdev' command
command_check dd						# Check for 'dd' command
command_check isoinfo						# Check for 'isoinfo' command
command_check jigdo-lite					# Check for 'jigdo-lite' command
command_check lsblk						# Check for 'lsblk' command
command_check mkfs.vfat						# Check for 'mkfs.vfat' command
command_check partprobe						# Check for 'partprobe' command
command_check sed						# Check for 'sed' command
command_check sgdisk						# Check for 'sgdisk' command
command_check sudo						# Check for 'sudo' command
command_check wget						# Check for 'wget' command
command_check zgrep						# Check for 'zgrep' command

# Defines
#############################
# ISO source (Debian)
ISOSRC_DEBIAN_URLBASE="https://cdimage.debian.org/debian-cd/###VERSION###/###ARCHITECTURE###/###TYPE###/"
ISOSRC_DEBIAN_VER="current"
ISOSRC_DEBIAN_TYPE_HTTPS="iso-dvd"
ISOSRC_DEBIAN_TYPE_JIGDO="jigdo-dvd"
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
DLOAD_ONLY=0							# When set, only download selected files
DLOAD_DONE=0							# When set, skip downloading files
LST_ARCH=""							# Architecture list
LST_ISO=()							# ISO image path array
LST_PKG=""							# Package list
PARTITION_NUM=1							# Partition counter
PATH_DLOAD_HTTPS="/https"					# Path to store downloaded files (https)
PATH_DLOAD_JIGDO="/jigdo"					# Path to store downloaded files (jigdo)
PATH_EFI_DEV=							# USB key EFI partition path
PATH_EFI_MNT="${DIR_MNT}/efi"					# USB key EFI partition mount path
PATH_ISO_DEV=							# ISO image partition path
PATH_ISO_MNT="${DIR_MNT}/iso"					# ISO image partition mount path
PATH_JIGDO_CACHE="/jigdo-cache"					# Temporary directory for jigdo files
SKIP_REMAINING=0						# If set, skip any remaining items

# Parse arguments
while getopts ":ha:d:D:p:t:I:" arg; do
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
	D)
		case ${OPTARG} in
		only)
			DLOAD_ONLY=1
			;;
		done)
			DLOAD_DONE=1
			;;
		*)
			echo "Error: unknown argument for -D"
			exit 1
			;;
		esac
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
echo -n "	Create .${DIR_TMP#${DIR_PWD}}${PATH_DLOAD_HTTPS}: "
mkdir -p "${DIR_TMP}${PATH_DLOAD_HTTPS}" &>/dev/null
okay_failedexit $?
echo -n "	Create .${DIR_TMP#${DIR_PWD}}${PATH_DLOAD_JIGDO}: "
mkdir -p "${DIR_TMP}${PATH_DLOAD_JIGDO}" &>/dev/null
okay_failedexit $?
echo -n "	Create .${DIR_TMP#${DIR_PWD}}${PATH_JIGDO_CACHE}: "
mkdir -p "${DIR_TMP}${PATH_JIGDO_CACHE}" &>/dev/null
okay_failedexit $?
echo

# Download files using HTTPS & jigdo if necessary
##########################################################
if [ ${DLOAD_DONE} -eq 0 ]; then
	echo -e "${TXT_UNDERLINE}Downloading files:${TXT_NORMAL}"
	if [ -n "${LST_ARCH}" ]; then
		echo "	Downloading base ISOs using HTTPS:"
		for tmp_arch in ${LST_ARCH}; do
			download_path="${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}"
			download_url=`echo "${ISOSRC_DEBIAN_URLBASE}" | sed -e "s|###VERSION###|${ISOSRC_DEBIAN_VER}|" -e "s|###ARCHITECTURE###|${tmp_arch}|" -e "s|###TYPE###|${ISOSRC_DEBIAN_TYPE_HTTPS}|"`
			echo "		Architecture: ${tmp_arch}"
			# Delete existing directory (and files)
			rm -rf "${download_path}" &>/dev/null
			echo -n "			Creating .${download_path#${DIR_PWD}}: "
			mkdir -p "${download_path}" &>/dev/null
			if [ ${?} -eq 0 ]; then
				echo "Okay"
			else
				echo "Failed"
				SKIP_REMAINING=1
				break;
			fi
			echo -n "			Downloading ${download_url}: "
			err_msg=`isosrc_download_files "${download_url}" "${download_path}"`
			if [ ${?} -eq 0 ]; then
				echo "Okay"
			else
				echo "Failed: ${err_msg}"
				SKIP_REMAINING=1
				break;
			fi
		done

		# Check if any packages listed
		if [ -n "${LST_PKG}" ] && [ ${SKIP_REMAINING} -eq 0 ]; then
			# Directory to cache downloaded packages
			jigdo_cachedir="${DIR_TMP}${PATH_JIGDO_CACHE}"

			# Check jigdo default mirror
			echo -n "	Checking jigdo default mirror [~/.jigdo-lite]: "
			grep "debianMirror='http://ftp.uk.debian.org/debian/'" ~/.jigdo-lite &>/dev/null
			if [ ${?} -eq 0 ]; then
				echo "Okay"
			else
				echo "Failed: Default mirror incorrect."
				SKIP_REMAINING=1
			fi
			# Check jigdo filesPerFetch setting
			echo -n "	Checking jigdo filesPerFetch [~/.jigdo-lite]: "
			jigdo_conf_fpf=`grep -E "filesPerFetch='[0-9]*'" ~/.jigdo-lite`
			echo "${jigdo_conf_fpf:15:-1}"

			if [ ${SKIP_REMAINING} -eq 0 ]; then
				echo "	Downloading additional ISOs using jigdo:"
				for tmp_arch in ${LST_ARCH}; do
					# Clear jigdo cache directory
					rm -rf "${jigdo_cachedir}"/* &>/dev/null

					download_path="${DIR_TMP}${PATH_DLOAD_JIGDO}/${tmp_arch}"
					download_url=`echo "${ISOSRC_DEBIAN_URLBASE}" | sed -e "s|###VERSION###|${ISOSRC_DEBIAN_VER}|" -e "s|###ARCHITECTURE###|${tmp_arch}|" -e "s|###TYPE###|${ISOSRC_DEBIAN_TYPE_JIGDO}|"`
					echo "		Architecture: ${tmp_arch}"
					# Delete existing directory (and files)
					rm -rf "${download_path}" &>/dev/null
					echo -n "			Creating .${download_path#${DIR_PWD}}: "
					mkdir -p "${download_path}" &>/dev/null
					if [ ${?} -eq 0 ]; then
						echo "Okay"
					else
						echo "Failed"
						SKIP_REMAINING=1
						break;
					fi
					echo -n "			Downloading ${download_url}: "
					err_msg=`isosrc_download_files "${download_url}" "${download_path}"`
					if [ ${?} -eq 0 ]; then
						echo "Okay"
					else
						echo "Failed: ${err_msg}"
						SKIP_REMAINING=1
						break;
					fi
					echo -n "			Validating downloads: "
					# Throw error
					ls monkeybutt &>/dev/null
					if [ ${?} -eq 0 ]; then
						echo "Okay"
					else
						echo "Failed: ${err_msg}"
						SKIP_REMAINING=1
						break;
					fi

					echo "			Scanning for packages: "
					for tmp_pkg in ${LST_PKG}; do
						echo "				${tmp_pkg}:"
						# Scan jigdo files for package name
						for tmp_jigdo in `zgrep -l "/${tmp_pkg}_" "${download_path}"/*.jigdo`; do
							tmp_jigdo_stripped=`basename "${tmp_jigdo}" ".jigdo"`
							echo -n "					${tmp_jigdo_stripped} - "
							# Check if already downloaded
							if [ -f "${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}/${tmp_jigdo_stripped}.iso" ]; then
								echo "Exists"
							elif [ -f "${download_path}/${tmp_jigdo_stripped}.iso" ]; then
								echo "Exists"
							else
								cd "${download_path}" &>/dev/null
								if [ ${?} -ne 0 ]; then
									echo "Failed to change directory"
									SKIP_REMAINING=1
									break 3
								fi
								echo -n "Downloading - "
								jigdo-lite --scan "${jigdo_cachedir}" --noask "${tmp_jigdo}" &>/dev/null
								retval=${?}
								cd - &>/dev/null
								if [ ${?} -ne 0 ]; then
									echo "Failed to change directory"
									SKIP_REMAINING=1
									break 3
								fi
								if [ ${retval} -eq 0 ]; then
									echo "Okay"
								else
									echo "Failed"
									SKIP_REMAINING=1
									break 3
								fi
							fi
						done
					done
				done
			fi
		fi

		# Set flag to mark download complete
		if [ ${SKIP_REMAINING} -eq 0 ]; then DLOAD_DONE=1; fi
	else
		echo "	Failed to download files, no architectures given"
		SKIP_REMAINING=1
	fi
	echo
fi

# Skip USB key creation if just downloading files
##########################################################
if [ ${DLOAD_ONLY} -eq 0 ] && [ ${SKIP_REMAINING} -eq 0 ]; then
	# User confirmation
	#############################
	echo "The device ${DEV_PATH} will be completely wiped."
	read -r -p "ARE YOU SURE YOU WISH TO CONTINUE? (y/N): " DOCONTINUE
	if [[ $DOCONTINUE = [Yy] ]]; then
		echo -n
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

	# Process downloaded files
	#############################
	if [ ${DLOAD_DONE} -eq 1 ]; then
		echo -e "${TXT_UNDERLINE}Processing downloaded files:${TXT_NORMAL}"

		echo "	Checking for base files:"
		for tmp_arch in ${LST_ARCH}; do
			download_path="${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}"

			echo -n "		${tmp_arch}: "
			# Check that the directory exists
			if [ -d "${download_path}" ]; then
				echo "Found"
				#echo -n "			Verifying hashes - "
				echo "			Verifying images:"
				verify_iso_images "${download_path}" 4
				if [ ${?} -ne 0 ]; then
					SKIP_REMAINING=1
					break;
				fi
				echo -n "			Copying signatures & hashes - "
				err_msg=`verify_files_copy "${download_path}" "${PATH_EFI_MNT}${PATH_EFI_HASHES}/${tmp_arch}"`
				if [ ${?} -eq 0 ]; then
					echo "Okay"
				else
					echo "Error: ${err_msg}"
					SKIP_REMAINING=1
					break;
				fi
				echo "			Searching for ISOs:"
				# Search for ISO images
				for tmp_iso_img in `find "${download_path}" -iname *.iso`; do
					iso_filename=`basename "${tmp_iso_img}"`
					echo "				${iso_filename} - Added"
					LST_ISO+=( "${tmp_iso_img}" )
				done
			else
				echo "Not found"
				SKIP_REMAINING=1
				break;
			fi
		done

#		# Check if any packages listed
#		if [ -n "${LST_PKG}" ] && [ ${SKIP_REMAINING} -eq 0 ]; then
#			# Directory to cache downloaded packages
#			jigdo_cachedir="${DIR_TMP}${PATH_JIGDO_CACHE}"
#
#			# Check jigdo default mirror
#			echo -n "	Checking jigdo default mirror [~/.jigdo-lite]: "
#			grep "debianMirror='http://ftp.uk.debian.org/debian/'" ~/.jigdo-lite &>/dev/null
#			if [ ${?} -eq 0 ]; then
#				echo "Okay"
#			else
#				echo "Failed: Default mirror incorrect."
#				SKIP_REMAINING=1
#			fi
#			# Check jigdo filesPerFetch setting
#			echo -n "	Checking jigdo filesPerFetch [~/.jigdo-lite]: "
#			jigdo_conf_fpf=`grep -E "filesPerFetch='[0-9]*'" ~/.jigdo-lite`
#			echo "${jigdo_conf_fpf:15:-1}"
#
#			if [ ${SKIP_REMAINING} -eq 0 ]; then
#				echo "	Downloading additional ISOs using jigdo:"
#				for tmp_arch in ${LST_ARCH}; do
#					# Clear jigdo cache directory
#					rm -rf "${jigdo_cachedir}"/* &>/dev/null
#
#					download_path="${DIR_TMP}${PATH_DLOAD_JIGDO}/${tmp_arch}"
#					download_url=`echo "${ISOSRC_DEBIAN_URLBASE}" | sed -e "s|###VERSION###|${ISOSRC_DEBIAN_VER}|" -e "s|###ARCHITECTURE###|${tmp_arch}|" -e "s|###TYPE###|${ISOSRC_DEBIAN_TYPE_JIGDO}|"`
#					echo "		Architecture: ${tmp_arch}"
#					# Delete existing directory (and files)
#					rm -rf "${download_path}" &>/dev/null
#					echo -n "			Creating .${download_path#${DIR_PWD}}: "
#					mkdir -p "${download_path}" &>/dev/null
#					if [ ${?} -eq 0 ]; then
#						echo "Okay"
#					else
#						echo "Failed"
#						SKIP_REMAINING=1
#						break;
#					fi
#					echo -n "			Downloading ${download_url}: "
#					err_msg=`isosrc_download_files "${download_url}" "${download_path}"`
#					if [ ${?} -eq 0 ]; then
#						echo "Okay"
#					else
#						echo "Failed: ${err_msg}"
#						SKIP_REMAINING=1
#						break;
#					fi
#					echo -n "			Validating downloads: "
#					# Throw error
#					ls monkeybutt &>/dev/null
#					if [ ${?} -eq 0 ]; then
#						echo "Okay"
#					else
#						echo "Failed: ${err_msg}"
#						SKIP_REMAINING=1
#						break;
#					fi
#
#					echo "			Scanning for packages: "
#					for tmp_pkg in ${LST_PKG}; do
#						echo "				${tmp_pkg}:"
#						# Scan jigdo files for package name
#						for tmp_jigdo in `zgrep -l "/${tmp_pkg}_" "${download_path}"/*.jigdo`; do
#							tmp_jigdo_stripped=`basename "${tmp_jigdo}" ".jigdo"`
#							echo -n "					${tmp_jigdo_stripped} - "
#							# Check if already downloaded
#							if [ -f "${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}/${tmp_jigdo_stripped}.iso" ]; then
#								echo "Exists"
#							elif [ -f "${download_path}/${tmp_jigdo_stripped}.iso" ]; then
#								echo "Exists"
#							else
#								cd "${download_path}" &>/dev/null
#								if [ ${?} -ne 0 ]; then
#									echo "Failed to change directory"
#									SKIP_REMAINING=1
#									break 3
#								fi
#								echo -n "Downloading - "
#								jigdo-lite --scan "${jigdo_cachedir}" --noask "${tmp_jigdo}" &>/dev/null
#								retval=${?}
#								cd - &>/dev/null
#								if [ ${?} -ne 0 ]; then
#									echo "Failed to change directory"
#									SKIP_REMAINING=1
#									break 3
#								fi
#								if [ ${retval} -eq 0 ]; then
#									echo "Okay"
#								else
#									echo "Failed"
#									SKIP_REMAINING=1
#									break 3
#								fi
#							fi
#						done
#					done
#				done
#			fi
#		fi

		echo
		# Skip everything else for testing
		SKIP_REMAINING=1
	fi

	# Add specified ISO images
	#############################
	if [ -n "${LST_ISO}" ] && [ ${SKIP_REMAINING} -eq 0 ]; then
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
				SKIP_REMAINING=1
				break;
			fi
			echo -n "		Mounting ISO image: "
			err_msg=`sudo mount "/dev/disk/by-partlabel/${tmp_iso_filename}" "${PATH_ISO_MNT}" 2>&1`
			if [ ${?} -eq 0 ]; then
				echo "Okay"
			else
				echo "Failed: ${err_msg}"
				SKIP_REMAINING=1
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
					SKIP_REMAINING=1
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
				SKIP_REMAINING=1
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
fi

if [ ${SKIP_REMAINING} -eq 1 ]; then
	echo "!!! Failed to create USB key !!!"
fi
