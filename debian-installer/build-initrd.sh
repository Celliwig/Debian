#!/bin/bash

# Functions
##############
get_value () {
	file=${1}
	key=${2}
	value=`grep "^${key}" "${file}"`
	echo "${value#${key}: }"
}

usage () {
	echo "Build additional initrd image for debian-installer."
	echo
	echo "$0 <options>"
	echo "Options:"
	echo "	-p <packages>		Comma separated list of packages to include (or all)"
}

# Defines
##############
DIR_BUILD="initrd.build"							# Build directory
DIR_DIST="${DIR_BUILD}/celliwig.dist"						# Directory for 'Packages' file
DIR_PKGS="${DIR_BUILD}/celliwig.packages"					# Contains any additional deb package files
DIR_PWD=`pwd`									# Current directory
FILE_INITRD="${DIR_PWD}/initrd.celliwig.img"					# Initrd image to be built
FILE_PACKAGES="${DIR_DIST}/Packages"						# Path to 'Packages' file

# Variables
##############
PKG_LST=									# List of packages to include

# Parse arguments
while getopts ":hp:" arg; do
	case ${arg} in
	h)
		usage
		exit 0
		;;
	p)
		PKG_LST=${OPTARG}
		;;
	*)
		echo "$0: Unknown argument"
		exit 1
		;;
	esac
done

# Remove any existing images
rm -f ${FILE_INITRD} ${FILE_INITRD}.gz >/dev/null 2>&1
# Remove previous build
rm -rf ${DIR_BUILD} >/dev/null 2>&1

# Create build directory
echo -n "Creating build directory:	"
mkdir ${DIR_BUILD} >/dev/null 2>&1
if [ ${?} -eq 0 ]; then
	echo "[Okay]"
else
	echo "[Failed]"
	exit 1
fi

# Copying base files
echo -n "Copying preseed files:		"
cp -rL ${DIR_PWD}/preseed.cfg ${DIR_PWD}/preseed ${DIR_BUILD} >/dev/null 2>&1
if [ ${?} -eq 0 ]; then
	echo "[Okay]"
else
	echo "[Failed]"
	exit 1
fi
echo -n "Copying base files:		"
cp -r ${DIR_PWD}/initrd.base/* ${DIR_BUILD} >/dev/null 2>&1
if [ ${?} -eq 0 ]; then
	echo "[Okay]"
else
	echo "[Failed]"
	exit 1
fi

# Check if any packages specified
if [ -n "${PKG_LST}" ]; then
	echo -n "Copying extra files:		"
	cp -r ${DIR_PWD}/initrd.base/* ${DIR_BUILD} >/dev/null 2>&1
	if [ ${?} -eq 0 ]; then
		echo "[Okay]"
	else
		echo "[Failed]"
		exit 1
	fi

#	# Build packages
#	PKG_LST="partman-auto-reuse partman-crypto-boot ramdisk-target remove-fixups"
#	# Create repo 'Package' file
#	touch ${FILE_PACKAGES} >/dev/null 2>&1
#	for pkg in ${PKG_LST}; do
#		echo -n "Building package: ${pkg}"
#
#		# Get control info
#		pkg_name=`get_value "${pkg}/DEBIAN/control" Package`
#		pkg_src=`get_value "${pkg}/DEBIAN/control" Source`
#		pkg_version=`get_value "${pkg}/DEBIAN/control" Version`
#		pkg_arch=`get_value "${pkg}/DEBIAN/control" Architecture`
#		pkg_imi=`get_value "${pkg}/DEBIAN/control" Installer-Menu-Item`
#		pkg_maintainer=`get_value "${pkg}/DEBIAN/control" Maintainer`
#		pkg_isize=`get_value "${pkg}/DEBIAN/control" Installed-Size`
#		pkg_depends=`get_value "${pkg}/DEBIAN/control" Depends`
#		pkg_provides=`get_value "${pkg}/DEBIAN/control" Provides`
#		pkg_section=`get_value "${pkg}/DEBIAN/control" Section`
#		pkg_priority=`get_value "${pkg}/DEBIAN/control" Priority`
#		pkg_desc=`get_value "${pkg}/DEBIAN/control" Description`
#		pkg_desc_md5=`echo "${pkg_desc}"| md5sum | awk -F '  -' '{print $1}'`
#		#echo "Name: ${pkg_name}		Version: ${pkg_version}		Arch: ${pkg_arch}"
#
#		# Package directories are 1 letter
#		pkg_dir="${DIR_PKGS}/${pkg:0:1}/${pkg}"
#		# Make package directory
#		mkdir -p "${pkg_dir}" >/dev/null 2>&1
#
#		# Build package
#		pkg_filename="${pkg_dir}/${pkg_name}_${pkg_version}_${pkg_arch}.udeb"
#		pkg_distpath="pool/main/${pkg_filename#${DIR_PKGS}/}"
#		dpkg-deb --build ${pkg}/ ${pkg_filename} >/dev/null 2>&1
#		if [ ${?} -eq 0 ]; then
#			echo " [Okay]"
#		else
#			echo " [Failed]"
#			exit 1
#		fi
#		pkg_size=`wc -c ${pkg_filename}| awk '{ print $1 }'`
#		pkg_md5=`md5sum "${pkg_filename}"| awk -F '  ' '{print $1}'`
#		pkg_sha256=`sha256sum "${pkg_filename}"| awk -F '  ' '{print $1}'`
#
#		# Update 'Packages' file
#		echo "Package: ${pkg_name}" >> ${FILE_PACKAGES}
#		if [[ ${pkg_src} != "" ]]; then echo "Source: ${pkg_src}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_version} != "" ]]; then echo "Version: ${pkg_version}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_isize} != "" ]]; then echo "Installed-Size: ${pkg_isize}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_maintainer} != "" ]]; then echo "Maintainer: ${pkg_maintainer}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_arch} != "" ]]; then echo "Architecture: ${pkg_arch}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_provides} != "" ]]; then echo "Provides: ${pkg_provides}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_depends} != "" ]]; then echo "Depends: ${pkg_depends}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_desc} != "" ]]; then echo "Description: ${pkg_desc}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_desc_md5} != "" ]]; then echo "Description-md5: ${pkg_desc_md5}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_imi} != "" ]]; then echo "Installer-Menu-Item: ${pkg_imi}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_section} != "" ]]; then echo "Section: ${pkg_section}" >> ${FILE_PACKAGES}; fi
#		if [[ ${pkg_priority} != "" ]]; then echo "Priority: ${pkg_priority}" >> ${FILE_PACKAGES}; fi
#		echo "Filename: ${pkg_distpath}" >> ${FILE_PACKAGES}
#		echo "Size: ${pkg_size}" >> ${FILE_PACKAGES}
#		echo "MD5sum: ${pkg_md5}" >> ${FILE_PACKAGES}
#		echo "SHA256: ${pkg_sha256}" >> ${FILE_PACKAGES}
#		echo >> ${FILE_PACKAGES}
#	done
#
#	# Compress Packages file
#	gzip ${FILE_PACKAGES}
fi

# Build initrd
echo -n "Building initrd image:		"
cd "${DIR_BUILD}"
find . | cpio --create --quiet --format='newc' > "${FILE_INITRD}"
retval=${?}
cd "${DIR_PWD}"
if [ $retval -eq 0 ]; then
	echo "[Okay]"
	# Compress initrd
	gzip -9 "${FILE_INITRD}"
else
	echo "[Failed]"
fi
