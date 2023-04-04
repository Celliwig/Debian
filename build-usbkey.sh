#!/bin/bash

#################################################################################################
#												#
# Script to build a USB key containing Debian ISO images copied to individual paritions.	#
# The main install disc (DVD 1) is downloaded according to specified architecture.		#
# Will also download additional ISO images according to the packages specified. 		#
#												#
#################################################################################################

# Defines
#############################
# Hybrid MBR/GPT layout types
declare -r HYBRID_LAYOUT_GRUB=1					# Use host's GRUB as a bootloader for the hybrid MBR/GPT layout
declare -r HYBRID_LAYOUT_ISOLINUX=2				# Use patch ISOLINUX's MBR from an ISO image as bootloader
# ISO source (Debian)
declare -r ISOSRC_DEBIAN_URLBASE="https://cdimage.debian.org/debian-cd/###VERSION###/###ARCHITECTURE###/###TYPE###/"
declare -r ISOSRC_DEBIAN_VER="current"
declare -r ISOSRC_DEBIAN_TYPE_HTTPS="iso-dvd"
declare -r ISOSRC_DEBIAN_TYPE_JIGDO="jigdo-dvd"
declare -r ISOSRC_DEBIAN_REJECT=( "debian-update-" )
# Paths
declare -r PATH_DLOAD_HTTPS="/https"				# Path to store downloaded files (https)
declare -r PATH_DLOAD_JIGDO="/jigdo"				# Path to store downloaded files (jigdo)
declare -r PATH_EFI_EFIBOOT="/EFI/boot"				# Path to EFI GRUB binaries
declare -r PATH_EFI_BOOTGRUB="/boot/grub"			# Path to GRUB resources
declare -r PATH_EFI_HASHES="/hashes"				# Base directory of store for hashes/signatures
declare -r PATH_JIGDO_CACHE="/jigdo-cache"			# Temporary directory for jigdo files
declare -r PATH_MBR_IMG="/mbr.img"				# Path to copy of ISOLINUX MBR
# Pretty print
declare -r TXT_UNDERLINE="\033[1m\033[4m"			# Used to pretty print output
declare -r TXT_NORMAL="\033[0m"

# Associative arrays
#############################
declare -A LST_ARCH_CHK						# Architecture check array
declare -A LST_ISO_ADDITIONAL					# Additional ISO image path array
declare -A LST_ISO_CHK						# ISO image path check array
declare -A LST_PKG						# Packages array
# Index arrays
#############################
declare -a LST_ARCH						# Architecture array
declare -a LST_ISO						# ISO image path array

# Variables
#############################
DEV_PATH=							# USB device path
DEV_LAYOUT_HYBRID=0						# Flag whether to create hybrid MBR/GPT layout or not
DEV_LAYOUT_HYBRID_ARCH=						# If set contains the architecture of the ISO to use as source for isolinux boot
DIR_PWD=`pwd`							# Current directory
DIR_MNT="${DIR_PWD}/mnt"					# Directory to use for mount points
DIR_MNT_EXISTS=0						# Flag whether mount directory was created or not
DIR_TMP="${DIR_PWD}/tmp"					# Directory to use for temporary storage
DIR_TMP_EXISTS=0						# Flag whether tmp directory was created or not
DLOAD_ONLY=0							# When set, only download selected files
DLOAD_DONE=0							# When set, skip downloading files
PARTITION_NUM=1							# Partition counter
PATH_EFI_DEV=							# USB key EFI partition path
PATH_EFI_MNT="${DIR_MNT}/efi"					# USB key EFI partition mount path
PATH_GPG_KEYRNG=""						# Path to GPG keyring
PATH_INITRD=							# Path to additional initrd image to include on ESP
PATH_ISO_DEV=							# ISO image partition path
PATH_ISO_MNT="${DIR_MNT}/iso"					# ISO image partition mount path
SKIP_REMAINING=0						# If set, skip any remaining items

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
	echo "	-G <GPG keyring path>	Path to GPG keyring to use"
	echo "	-i <initrd path>	Path to additional initrd image to copy to ESP"
	echo "	-I <ISO image path>	Path to ISO image to add"
	echo "	-M			Create hybrid MBR/GPT partition layout and install BIOS bootloader"
	echo "	-m <architecture>	Create hybrid MBR/GPT partition layout and install/patch isolinux from <arch> ISO"
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

# Add architecture to list if not already present
arch_add () {
	arch="${1}"
	if [ ! -v LST_ARCH_CHK[${arch}] ]; then
		LST_ARCH_CHK[${arch}]=
		LST_ARCH+=( "${arch}" )
	fi
}

# Check architecture is valid
arch_check () {
	arch="${1}"
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

# Add ISO image to list if not already present
iso_list_add () {
	iso_image_path="${1}"
	if [ ! -v LST_ISO_CHK[${iso_image_path}] ]; then
		LST_ISO_CHK[${iso_image_path}]=
		LST_ISO+=( "${iso_image_path}" )
	fi
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

	# Rescan device
	sudo partprobe "${device_path}" &>/dev/null

	device_found=0
	device_sleep=1
	for (( i=0; i<5; i++ )); do
		if [ -b "${device_path}p${partition_num}" ]; then
			partition_path="${device_path}p${partition_num}"
			device_found=1
			break
		elif [ -b "${device_path}${partition_num}" ]; then
			partition_path="${device_path}${partition_num}"
			device_found=1
			break
		fi
		sleep ${device_sleep}
		device_sleep=$((${device_sleep}*2))
	done
	if [ ${device_found} -eq 0 ]; then
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

# Verify hash files using signatures
verify_hash_files () {
	source_path="${1}"
	gpg_keyring="${2}"
	padding="${3}"
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
		case "${tmp_hashfile}" in
		SHA256SUMS| \
		SHA512SUMS)
			echo -n "${padding_txt}${tmp_hashfile}.sign: "
			if [ -f "${tmp_hashfile}.sign" ]; then
				if [ -n "${gpg_keyring}" ]; then
					gpg --no-default-keyring --keyring "${gpg_keyring}" --verify "${tmp_hashfile}.sign" "${tmp_hashfile}" &>/dev/null
				else
					gpg --verify "${tmp_hashfile}.sign" "${tmp_hashfile}" &>/dev/null
				fi
				if [ ${?} -eq 0 ]; then
					echo "Valid"
					retval=0
				else
					echo "Invalid"
					retval=1
					break
				fi
			else
				echo "Failed to find signature file"
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

# Verify ISO images using hash files
verify_iso_images () {
	source_path="${1}"
	padding="${2}"
	sudo_update=${3}
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
		if [ ${sudo_update} -eq 1 ]; then sudo_priv_check fi

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

# Copy hash files and signatures to EFI partition
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

# Initialise GPG keyring (if needed)
# Returns path to temporary GPG keyring (if created)
gpg_keyring_init () {
	keyring_path="${1}"
	have_keys=0
	retval_txt=""

	# If keyring path not defined, use temp
	if [ -z "${keyring_path}" ]; then
		keyring_path="${DIR_TMP}/keyring.gpg"
		# If using temp key, delete it
		rm -f "${keyring_path}"
	fi

	## Check distribution name, as keys
	## should already be available in Debian
	#distro_name=`lsb_release -is`
	#if [[ "${distro_name}" == "Debian" ]]; then return 0; fi

	# Check if keys are already available
	gpg_key_chk=( "DF9B9C49EAA9298432589D76DA87E80D6294BE9B" )
	for tmp_gpgkey in "${gpg_key_chk[@]}"; do
		gpg --list-public-keys "${tmp_gpgkey}" &>/dev/null
		if [ ${?} -eq 0 ]; then
			have_keys=1
		else
			have_keys=0
			break
		fi
	done

	# Create temporary keyring, if keys aren't available
	if [ ${have_keys} -eq 0 ]; then
		retval_txt="${keyring_path}"
		# Check if keyring exists already
		if [ ! -f "${keyring_path}" ]; then
			# Create it if it doesn't
			err_msg=`gpg --no-default-keyring --keyring "${keyring_path}" -k 2>&1`
			if [ ${?} -ne 0 ]; then
				echo "${err_msg}"
				return 1
			fi
		fi
		# Check if keys are already available
		for tmp_gpgkey in "${gpg_key_chk[@]}"; do
			# Check if this keyring has the key
			gpg --no-default-keyring --keyring "${keyring_path}" --list-public-keys "${tmp_gpgkey}" &>/dev/null
			if [ ${?} -ne 0 ]; then
				err_msg=`gpg --no-default-keyring --keyring ${keyring_path} --keyserver keyring.debian.org --recv-keys "0x${tmp_gpgkey}" 2>&1`
				if [ ${?} -ne 0 ]; then
					echo "${err_msg}"
					return 1
				fi
			fi
		done
	fi

	echo "${retval_txt}"
	return 0
}

# Parse arguments
while getopts ":hMa:d:D:G:i:I:m:p:t:" arg; do
	case ${arg} in
	a)
		arch_check "${OPTARG}"
		if [ ${?} -ne 0 ]; then
			echo "Invalid architecture: ${OPTARG}"
			exit
		fi
		arch_add "${OPTARG}"
		;;
	d)
		DEV_PATH=`realpath "${OPTARG}"`
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
	G)
		PATH_GPG_KEYRNG=`realpath "${OPTARG}"`
		;;
	h)
		usage
		exit 0
		;;
	i)
		PATH_INITRD=`realpath "${OPTARG}"`
		;;
	I)
		LST_ISO_ADDITIONAL["${OPTARG}"]=
		;;
	m)
		arch_check "${OPTARG}"
		if [ ${?} -eq 0 ]; then
			DEV_LAYOUT_HYBRID_ARCH="${OPTARG}"
			DEV_LAYOUT_HYBRID=${HYBRID_LAYOUT_ISOLINUX}
		else
			echo "Error: invalid argument for -m"
			exit 1
		fi
		;;
	M)
		DEV_LAYOUT_HYBRID=${HYBRID_LAYOUT_GRUB}
		;;
	p)
		LST_PKG["${OPTARG}"]=
		;;
	t)
		DIR_TMP=`realpath "${OPTARG}"`
		;;
	*)
		echo "$0: Unknown argument"
		exit 1
		;;
	esac
done

# Check for used commands
#############################
command_check blockdev						# Check for 'blockdev' command
command_check dd						# Check for 'dd' command
command_check gpg						# Check for 'gpg' command
command_check grub-install					# Check for 'grub-install' command
command_check isoinfo						# Check for 'isoinfo' command
command_check jigdo-lite					# Check for 'jigdo-lite' command
command_check lsb_release					# Check for 'lsb_release' command
command_check lsblk						# Check for 'lsblk' command
command_check mkfs.vfat						# Check for 'mkfs.vfat' command
command_check partprobe						# Check for 'partprobe' command
command_check sed						# Check for 'sed' command
command_check sgdisk						# Check for 'sgdisk' command
command_check sudo						# Check for 'sudo' command
command_check wget						# Check for 'wget' command
command_check zgrep						# Check for 'zgrep' command

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

# Check GPG keyring, initialise if necessary
##########################################################
echo -e "${TXT_UNDERLINE}GPG keyring:${TXT_NORMAL}"
echo -n "	Initialising: "
PATH_GPG_KEYRNG=`gpg_keyring_init "${PATH_GPG_KEYRNG}"`
if [ ${?} -eq 0 ]; then
	if [ -n "${PATH_GPG_KEYRNG}" ]; then
		echo "Using .${PATH_GPG_KEYRNG#${DIR_PWD}}"
	else
		echo "Default used"
	fi
else
	echo "Failed: ${PATH_GPG_KEYRNG}"
	exit
fi
echo

# Download files using HTTPS & jigdo if necessary
##########################################################
if [ ${DLOAD_DONE} -eq 0 ]; then
	echo -e "${TXT_UNDERLINE}Downloading files:${TXT_NORMAL}"
	if [ ${#LST_ARCH[@]} -gt 0 ]; then
		echo "	Downloading base ISOs using HTTPS:"
		for tmp_arch in ${LST_ARCH[@]}; do
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
		if [ ${#LST_PKG[@]} -gt 0 ] && [ ${SKIP_REMAINING} -eq 0 ]; then
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
				for tmp_arch in ${LST_ARCH[@]}; do
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
					echo "                  Verifying hashes:"
					verify_hash_files "${download_path}" "${PATH_GPG_KEYRNG}" 4
					if [ ${?} -ne 0 ]; then
						SKIP_REMAINING=1
						break;
					fi
					echo "                  Verifying jigdo files:"
					verify_iso_images "${download_path}" 4 0
					if [ ${?} -ne 0 ]; then
						SKIP_REMAINING=1
						break;
					fi
					echo "			Scanning for packages: "
					for tmp_pkg in ${!LST_PKG[@]}; do
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
	DEV_SIZE_GIG=$((${DEV_SIZE_BYTES}/1073741824))
	if [ ${DEV_SIZE_GIG} -gt 4 ]; then
		echo "	Detected: ${DEV_PATH} (${DEV_SIZE_GIG} GB)"
	else
		echo "	Error: The device ${DEV_PATH}, is too small." >&2
		exit 1
	fi
	echo


	# Is this hybrid layout
	#############################
	if [ ${DEV_LAYOUT_HYBRID} -gt 0 ]; then
		# Create hybrid layout
		#############################
		echo -e "${TXT_UNDERLINE}Creating hybrid MBR/GPT layout: ${DEV_PATH}${TXT_NORMAL}"
		echo -n "	Wiping partition table: "
		sudo sgdisk --zap-all "${DEV_PATH}" &>/dev/null
		okay_failedexit $?
		echo -n "	Create BIOS boot partition (1MB): "
		sudo sgdisk --set-alignment=1 --new=1:34:2047 --typecode=1:ef02 --change-name=1:BIOSBOOT "${DEV_PATH}" &>/dev/null
		okay_failedexit $?
		PARTITION_NUM=$((${PARTITION_NUM}+1))
		echo -n "	Create EFI System partition (256MB): "
		sudo sgdisk --new=2:0:+256M --typecode=2:ef00 --change-name=2:DI-EFI "${DEV_PATH}" &>/dev/null
		okay_failedexit $?
		PARTITION_NUM=$((${PARTITION_NUM}+1))
		PATH_EFI_DEV=`device_part_check "${DEV_PATH}" 2`
		if [ ${?} -ne 0 ]; then
			echo "	Error: ${PATH_EFI_DEV}" >&2
			exit 1
		fi
	else
		# Create GPT layout
		#############################
		echo -e "${TXT_UNDERLINE}Creating GPT layout: ${DEV_PATH}${TXT_NORMAL}"
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
	fi
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
	if [ -n "${PATH_INITRD}" ]; then
		echo -n "	Copying additional initrd image (${PATH_INITRD#${DIR_PWD}}): "
		sudo cp "${PATH_INITRD}" "${PATH_EFI_MNT}" &>/dev/null
		okay_failedexit $?
	fi
	echo

	# Process downloaded files
	#############################
	if [ ${DLOAD_DONE} -eq 1 ]; then
		echo -e "${TXT_UNDERLINE}Processing downloaded files:${TXT_NORMAL}"

		echo "	Checking for base files:"
		for tmp_arch in ${LST_ARCH[@]}; do
			download_path="${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}"

			echo -n "		${tmp_arch}: "
			# Check that the directory exists
			if [ -d "${download_path}" ]; then
				echo "Found"
				echo "			Verifying hashes:"
				verify_hash_files "${download_path}" "${PATH_GPG_KEYRNG}" 4
				if [ ${?} -ne 0 ]; then
					SKIP_REMAINING=1
					break;
				fi
				echo "			Verifying images:"
				verify_iso_images "${download_path}" 4 1
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
					iso_list_add "${tmp_iso_img}"
				done
			else
				echo "Not found"
				SKIP_REMAINING=1
				break;
			fi
		done

		# Check if any packages listed
		if [ ${#LST_PKG[@]} -gt 0 ] && [ ${SKIP_REMAINING} -eq 0 ]; then
			echo "	Checking for additional ISOs:"
			for tmp_arch in ${LST_ARCH[@]}; do
				download_path="${DIR_TMP}${PATH_DLOAD_JIGDO}/${tmp_arch}"

				echo -n "		${tmp_arch}: "
				# Check that the directory exists
				if [ -d "${download_path}" ]; then
					echo "Found"
					echo "			Verifying hashes:"
					verify_hash_files "${download_path}" "${PATH_GPG_KEYRNG}" 4
					if [ ${?} -ne 0 ]; then
						SKIP_REMAINING=1
						break;
					fi
					echo "			Verifying images:"
					verify_iso_images "${download_path}" 4 1
					if [ ${?} -ne 0 ]; then
						SKIP_REMAINING=1
						break;
					fi
					echo "			Scanning for packages: "
					for tmp_pkg in ${!LST_PKG[@]}; do
						echo "				${tmp_pkg}:"
						# Scan jigdo files for package name
						for tmp_jigdo in `zgrep -l "/${tmp_pkg}_" "${download_path}"/*.jigdo`; do
							tmp_jigdo_stripped=`basename "${tmp_jigdo}" ".jigdo"`
							echo -n "					${tmp_jigdo_stripped} - "
							# Check whether to ignore ISO image
							for tmp_reject in ${ISOSRC_DEBIAN_REJECT}; do
								if [[ "${tmp_jigdo_stripped}" == ${tmp_reject}* ]]; then
									echo "Rejected"
									continue 2;
								fi
							done
							# Check if already downloaded
							if [ -f "${DIR_TMP}${PATH_DLOAD_HTTPS}/${tmp_arch}/${tmp_jigdo_stripped}.iso" ]; then
								echo "Ignored (Base ISO)"
							elif [ -f "${download_path}/${tmp_jigdo_stripped}.iso" ]; then
								echo "Added"
								iso_list_add "${download_path}/${tmp_jigdo_stripped}.iso"
							else
								echo "ISO image not found"
								SKIP_REMAINING=1
								break 3
							fi
						done
					done
				else
					echo "Not found"
					SKIP_REMAINING=1
					break;
				fi
			done
		fi

		# Add additional ISO images
		if [ ${#LST_ISO_ADDITIONAL[@]} -gt 0 ] && [ ${SKIP_REMAINING} -eq 0 ]; then
			echo "	Adding additional ISO images:"
			for tmp_iso_img in ${!LST_ISO_ADDITIONAL[@]}; do
				tmp_iso_filename=`basename "${tmp_iso_img}"`
				echo -n "		${tmp_iso_filename}: "
				if [ -f "${tmp_iso_img}" ]; then
					echo "Added"
					iso_list_add "${tmp_iso_img}"
				else
					echo "Not found"
					SKIP_REMAINING=1
					break;
				fi
			done
		fi

		echo
	fi

	# Add specified ISO images
	#############################
	if [ ${#LST_ISO[@]} -gt 0 ] && [ ${SKIP_REMAINING} -eq 0 ]; then
		echo -e "${TXT_UNDERLINE}Add specified ISO images:${TXT_NORMAL}"
		for (( iso_idx=0; iso_idx<${#LST_ISO[@]}; iso_idx++ )); do
			tmp_iso_img="${LST_ISO[${iso_idx}]}"

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
			# If it's the 1st ISO image
			if [ ${iso_idx} -eq 0 ]; then
				# Check whether to use ISOLINUX MBR
				if [ ${DEV_LAYOUT_HYBRID} -eq ${HYBRID_LAYOUT_ISOLINUX} ]; then
					echo -n "		Configuring ISOLINUX: "
					if [ -d "${PATH_ISO_MNT}/dists/" ]; then
						release_filepath=`find "${PATH_ISO_MNT}/dists/" -maxdepth 2 -mindepth 2 -type f -name Release`
						if [ -n "${release_filepath}" ]; then
							grep "Architectures: ${DEV_LAYOUT_HYBRID_ARCH}" "${release_filepath}" &>/dev/null
							if [ ${?} -eq 0 ]; then
								if [ -f "${PATH_ISO_MNT}/isolinux/isolinux.bin" ]; then
									echo

									#
									# ISOLINUX hybrid MBR support patching
									#
									# First check that MBR supports hybrid booting by checking for '0x7078c0fb'
									# signature in MBR image, if it does it needs patching to support the ISO
									# partition.
									#
									# Registers EBX/ECX are used initially to represent the LBA offset of the
									# partition containing the ISO image (EBX offset high/ECX offset low).
									# Originally the registers are cleared using 2 XOR instructions which compile
									# to "0x66,0x31,0xdb,0x66,0x31,0xc9". So convert the MBR image to hex stream
									# using hexdump to be able to grep for the byte offset position of those
									# instructions. Then those instructions are replaced using 'dd' with the
									# instruction 'mov ecx, #<partition LBA offset>', which is also 6 bytes.
									#
									# EBX/ECX still need to be initialised (or at least EBX does) so find empty space
									# before that to insert the XOR instructions into.
									#
									# Finally sanity check that the offset found earlier for 'isolinux.bin' matches
									# the one found at offset 0x1b0 in the file.
									#

									isolinux_bin_offset_2048=0
									isolinux_bin_offset_512=0
									partition_offset_512=0
									mbr_xor_offset=0
									mbr_freesp_offset=0
									mbr_freesp_size=0
									mbr_freesp_need_bytes=6

									echo -n "			Copying ISOLINUX MBR: "
									err_msg=`sudo dd "if=/dev/disk/by-partlabel/${tmp_iso_filename}" "of=${DIR_TMP}${PATH_MBR_IMG}" bs=1 count=446 status=none 2>&1`
									if [ ${?} -eq 0 ]; then
										echo "Okay"
									else
										echo "${err_msg}"
										SKIP_REMAINING=1
									fi
									echo -n "			Checking for ISOLINUX hybrid MBR: "
									cat "${DIR_TMP}${PATH_MBR_IMG}" | hexdump -v -e '1/1 "/x%02x"' | grep --byte-offset --only-matching '/xfb/xc0/x78/x70' &>/dev/null
									if [ ${?} -eq 0 ]; then
										echo "Hybrid"
									else
										echo "Non-Hybrid"
										SKIP_REMAINING=1
									fi
									if [ ${SKIP_REMAINING} -eq 0 ]; then
										echo -n "			Getting isolinux.bin offset: "
										isolinux_bin_offset_txt=`isoinfo  -i "${tmp_iso_img}" -l | grep -E '^[-]*\s*[0-9]*\s*[0-9]*\s*[0-9]*\s*[0-9]*\s*[A-Za-z]*\s*[0-9]*\s[0-9]*\s*\[\s*[0-9]*\s*[0-9]*\]\s*ISOLINUX\.BIN;1\s*$'`
										if [ ${?} -eq 0 ]; then
											isolinux_bin_offset_2048=`echo "${isolinux_bin_offset_txt}" | sed 's|^[-]*\s*[0-9]*\s*[0-9]*\s*[0-9]*\s*[0-9]*\s*[A-Za-z]*\s*[0-9]*\s[0-9]*\s*\[\s*\([0-9]*\)\s*[0-9]*\]\s*ISOLINUX\.BIN;1\s*$|\1|'`
											isolinux_bin_offset_512=$((${isolinux_bin_offset_2048}*2048))
											isolinux_bin_offset_512=$((${isolinux_bin_offset_512}/512))
											printf "0x%x (2048 sectors)/0x%x (512 sectors)\\n" ${isolinux_bin_offset_2048} ${isolinux_bin_offset_512}
										else
											echo "Failed to extract from ISO image"
											SKIP_REMAINING=1
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Checking isolinux.bin pointer in MBR: "
											isolinux_bin_offset_512_hex=`printf "%08x" ${isolinux_bin_offset_512}`
											hex_match_str="^/x${isolinux_bin_offset_512_hex:6:2}/x${isolinux_bin_offset_512_hex:4:2}/x${isolinux_bin_offset_512_hex:2:2}/x${isolinux_bin_offset_512_hex:0:2}$"
											dd "if=${DIR_TMP}${PATH_MBR_IMG}" bs=1 count=4 skip=432 status=none | hexdump -v -e '1/1 "/x%02x"' | grep -E "${hex_match_str}" &>/dev/null
											if [ ${?} -eq 0 ]; then
												echo "Valid"
											else
												echo "Invalid"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Getting partition offset: "
											partition_offset_txt=`sudo sgdisk -i=3 "${DEV_PATH}" | grep -E '^First sector:\s*[0-9]*\s*\(at\s[0-9.]*\s*[A-Za-z]*\)$'`
											if [ ${?} -eq 0 ]; then
												partition_offset_512=`echo "${partition_offset_txt}" | sed 's|^First sector:\s*\([0-9]*\)\s*(at\s*[0-9.]*\s[A-Za-z]*)$|\1|'`
												printf "0x%x (512 sectors)\\n" ${partition_offset_512}
											else
												echo "Failed"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Getting MBR XOR (ebx/ecx) offset: "
											mbr_xor_offset_txt=`cat "${DIR_TMP}${PATH_MBR_IMG}" | hexdump -v -e '1/1 "/x%02x"' |grep --byte-offset --only-matching '/x66/x31/xdb/x66/x31/xc9'`
											if [ ${?} -eq 0 ]; then
												mbr_xor_offset=`echo "${mbr_xor_offset_txt}" | sed 's|^\([0-9]*\):\(/x[0-9a-f]*\)*$|\1|'`
												# Divide by four (4 chars to 1 byte)
												mbr_xor_offset=$((${mbr_xor_offset}/4))
												printf "%i = 0x%x bytes\\n" ${mbr_xor_offset} ${mbr_xor_offset}
											else
												echo "Failed"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Looking for free space: "
											# Scan for blocks of free space (0x00) before MBR XOR offset
											for mbr_freesp_offset_txt in `head -c ${mbr_xor_offset} "${DIR_TMP}${PATH_MBR_IMG}" | hexdump -v -e '1/1 "/x%02x"' |grep -E --byte-offset --only-matching  '(/x00)*'|sort -nr`; do
												mbr_freesp_offset=`echo ${mbr_freesp_offset_txt} | sed -E 's|^([0-9]*):([/x00]*)|\1|'`
												mbr_freesp_size=`echo ${mbr_freesp_offset_txt} | sed -E 's|^([0-9]*):([/x00]*)|\2|'| tr -d "\n"| wc -c`
												# Divide by four (4 chars to 1 byte)
												mbr_freesp_offset=$((${mbr_freesp_offset}/4))
												mbr_freesp_size=$((${mbr_freesp_size}/4))
												# Looking for 6 or more bytes of free space
												if [ ${mbr_freesp_size} -ge ${mbr_freesp_need_bytes} ]; then
													break;
												fi
											done
											if [ ${mbr_freesp_size} -ge ${mbr_freesp_need_bytes} ]; then
												printf "%i bytes at offset 0x%x\\n" ${mbr_freesp_size} ${mbr_freesp_offset}
												if [ ${mbr_freesp_size} -gt ${mbr_freesp_need_bytes} ]; then
													echo -n "				Recalculating offset: "
													mbr_freesp_offset=$((${mbr_freesp_offset}+${mbr_freesp_size}-${mbr_freesp_need_bytes}))
													printf "0x%x\\n" ${mbr_freesp_offset}
												fi
											else
												echo "Failed"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Patching MBR - Setting partition address: "
											# Check partition LBA offset look sensible (<0x100000000 we're only setting ECX)
											if [ ${partition_offset_512} -gt 0 ] || [ ${partition_offset_512} -lt 4294967296 ]; then
												# Check MBR XOR offset look sensible(ish), numbers are arbitary
												if [ ${mbr_xor_offset} -gt 0 ] || [ ${mbr_xor_offset} -lt 100 ]; then
													partition_offset_512_hex=`printf "%08x" ${partition_offset_512}`
													hex_instruct_str="\x66\xb9\x${partition_offset_512_hex:0:2}\x${partition_offset_512_hex:2:2}\x${partition_offset_512_hex:4:2}\x${partition_offset_512_hex:6:2}"
													printf "${hex_instruct_str}" | sudo dd "of=${DIR_TMP}${PATH_MBR_IMG}" bs=1 count=6 seek=${mbr_xor_offset} conv=notrunc status=none &>/dev/null
													if [ ${?} -eq 0 ]; then
														echo "Done"
													else
														echo "Failed"
														SKIP_REMAINING=1
													fi
												else
													echo "Invalid MBR offset"
													SKIP_REMAINING=1
												fi
											else
												echo "Invalid partition LBA offset"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Patching MBR - Adding XOR instructions: "
											# Check MBR free space offset look sensible(ish), numbers are arbitary
											if [ ${mbr_freesp_offset} -gt 0 ] || [ ${mbr_freesp_offset} -lt 100 ]; then
												printf '\x66\x31\xdb\x66\x31\xc9' | sudo dd "of=${DIR_TMP}${PATH_MBR_IMG}" bs=1 count=6 seek=${mbr_freesp_offset} conv=notrunc status=none &>/dev/null
												if [ ${?} -eq 0 ]; then
													echo "Done"
												else
													echo "Failed"
													SKIP_REMAINING=1
												fi
											else
												echo "Invalid MBR offset"
												SKIP_REMAINING=1
											fi
										fi
										if [ ${SKIP_REMAINING} -eq 0 ]; then
											echo -n "			Writing MBR to ${DEV_PATH}: "
											sudo dd "if=${DIR_TMP}${PATH_MBR_IMG}" "of=${DEV_PATH}" status=none &>/dev/null
											if [ ${?} -eq 0 ]; then
												echo "Done"
											else
												echo "Failed"
												SKIP_REMAINING=1
											fi
											sudo sync
										fi
									fi
								else
									echo "No ISOLINUX installation"
									SKIP_REMAINING=1
								fi
							else
								echo "Wrong architecture"
								SKIP_REMAINING=1
							fi
						else
							echo "Couldn't find Release file"
							SKIP_REMAINING=1
						fi
					else
						echo "Not Debian installation ISO"
						SKIP_REMAINING=1
					fi
				fi
			fi
			echo -n "		Unmounting ISO image: "
			# Bug fix, the mount is being held open by other programs, GNOME???
			# Retry implemented to get around this with increasing sleep time
			umount_sleep=1
			retval=1
			for (( i=0; i<5; i++ )); do
				err_msg=`sudo umount "${PATH_ISO_MNT}" 2>&1`
				if [ ${?} -eq 0 ]; then
					retval=0
					break
				fi
				sleep ${umount_sleep}
				umount_sleep=$((${umount_sleep}*2))
			done
			if [ ${retval} -eq 0 ]; then
				echo "Okay"
			else
				echo "Failed: ${err_msg}"
				SKIP_REMAINING=1
				break;
			fi
			PARTITION_NUM=$((${PARTITION_NUM}+1))
		done
		echo
	fi

	# Clean up
	##########################################################
	echo -e "${TXT_UNDERLINE}Clean Up:${TXT_NORMAL}"
	# Is this hybrid layout
	#############################
	if [ ${DEV_LAYOUT_HYBRID} -gt 0 ]; then
		if [ ${DEV_LAYOUT_HYBRID} -eq ${HYBRID_LAYOUT_GRUB} ]; then
			echo -n "	Creating hybrid layout: "
			sudo sgdisk --hybrid=1:2 "${DEV_PATH}" &>/dev/null
			okay_failedexit $?
			echo -n "	Installing GRUB (BIOS) from host: "
			sudo grub-install --target i386-pc --boot-directory="${PATH_EFI_MNT}/boot" "${DEV_PATH}" &>/dev/null
			okay_failedexit $?
		fi
		if [ ${DEV_LAYOUT_HYBRID} -eq ${HYBRID_LAYOUT_ISOLINUX} ]; then
			echo -n "	Creating hybrid layout: "
			sudo sgdisk --hybrid=1:2:3 "${DEV_PATH}" &>/dev/null
			okay_failedexit $?
		fi
	fi
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
