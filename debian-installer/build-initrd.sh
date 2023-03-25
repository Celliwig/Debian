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
DIR_CWG_DIST="${DIR_BUILD}/celliwig.dist"					# Directory for 'Packages' file
DIR_CWG_PKGS="${DIR_BUILD}/celliwig.packages"					# Contains any additional deb package files
DIR_PKGS="initrd.pkgs"								# Package source directory
DIR_PWD=`pwd`									# Current directory
FILE_INITRD="${DIR_PWD}/initrd.celliwig.img"					# Initrd image to be built
FILE_PACKAGES="${DIR_CWG_DIST}/Packages"					# Path to 'Packages' file
PKG_CLEANUP="remove-celliwig-packages"						# Name of package that cleans up changes made to merge package repos

# Variables
##############
PKG_LST_ARG=									# List of packages to include

# Parse arguments
while getopts ":hp:" arg; do
	case ${arg} in
	h)
		usage
		exit 0
		;;
	p)
		PKG_LST_ARG=${OPTARG}
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
if [ -n "${PKG_LST_ARG}" ]; then
	echo -n "Copying extra files:		"
	cp -r ${DIR_PWD}/initrd.extras/* ${DIR_BUILD} >/dev/null 2>&1
	if [ ${?} -eq 0 ]; then
		echo "[Okay]"
	else
		echo "[Failed]"
		exit 1
	fi

	# Build package list
	PKG_LST=
	# Check whether to include all packages
	if [[ "${PKG_LST_ARG}" == "all" ]]; then
		# Include all packages from the package source directory
		find_cmd="find ${DIR_PKGS} -maxdepth 1 -type d"
		for tmp_pkg in `${find_cmd}`; do
			if [[ "${tmp_pkg}" != "${DIR_PKGS}" ]]; then
				if [ -n "${PKG_LST}" ]; then
					PKG_LST="${PKG_LST} "
				fi
				PKG_LST="${PKG_LST}${tmp_pkg#${DIR_PKGS}/}"
			fi
		done
	else
		# Going to change the Internal Field Seperator so save current config
		IFS_OLD="${IFS}"
		# Change IFS to comma to parse the package list
		IFS=','
		# Parse package list
		for tmp_pkg in ${PKG_LST_ARG}; do
			# Check p[ackage exists
			if [ -d "${DIR_PKGS}/${tmp_pkg}" ]; then
				if [ -n "${PKG_LST}" ]; then
					PKG_LST="${PKG_LST} "
				fi
				# Exclude package that cleans up the changes that are made to merge the package repos
				# This will be added explictly later
				if [[ "${tmp_pkg}" != "${PKG_CLEANUP}" ]]; then
					PKG_LST="${PKG_LST}${tmp_pkg}"
				fi
			else
				echo "Unknown package: ${tmp_pkg}"
				exit 1
			fi
		done
		# Restore IFS
		IFS="${IFS_OLD}"
		# Add package that cleans up previous changes
		if [ -n "${PKG_LST}" ]; then
			PKG_LST="${PKG_LST} "
		fi
		PKG_LST="${PKG_LST}${PKG_CLEANUP}"
	fi

	if [ -z "${PKG_LST}" ]; then
		echo "Error, no packages specfied"
		exit 1
	fi

	# Create repo 'Package' file
	touch ${FILE_PACKAGES} >/dev/null 2>&1
	echo "Building:"
	for pkg in ${PKG_LST}; do
		echo "	${pkg}"

		# Get control info
		pkg_name=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Package`
		pkg_src=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Source`
		pkg_version=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Version`
		pkg_arch=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Architecture`
		pkg_imi=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Installer-Menu-Item`
		pkg_maintainer=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Maintainer`
		pkg_isize=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Installed-Size`
		pkg_depends=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Depends`
		pkg_provides=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Provides`
		pkg_section=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Section`
		pkg_priority=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Priority`
		pkg_desc=`get_value "${DIR_PKGS}/${pkg}/DEBIAN/control" Description`
		pkg_desc_md5=`echo "${pkg_desc}"| md5sum | awk -F '  -' '{print $1}'`
		#echo "Name: ${pkg_name}		Version: ${pkg_version}		Arch: ${pkg_arch}"

		# Package directories are 1 letter
		pkg_dir="${DIR_CWG_PKGS}/${pkg:0:1}/${pkg}"
		# Make package directory
		mkdir -p "${pkg_dir}" >/dev/null 2>&1
		if [ ${?} -ne 0 ]; then
			echo "Failed to create directory: ${pkg_dir}"
			exit 1
		fi

		# Build package
		pkg_filename="${pkg_dir}/${pkg_name}_${pkg_version}_${pkg_arch}.udeb"
		pkg_distpath="pool/main/${pkg_filename#${DIR_CWG_PKGS}/}"
		dpkg-deb --build ${DIR_PKGS}/${pkg}/ ${pkg_filename} >/dev/null 2>&1
		if [ ${?} -ne 0 ]; then
			echo "Failed to build package."
			exit 1
		fi
		pkg_size=`wc -c ${pkg_filename}| awk '{ print $1 }'`
		pkg_md5=`md5sum "${pkg_filename}"| awk -F '  ' '{print $1}'`
		pkg_sha256=`sha256sum "${pkg_filename}"| awk -F '  ' '{print $1}'`

		# Make dist directory
		mkdir -p "${DIR_CWG_DIST}" >/dev/null 2>&1
		if [ ${?} -ne 0 ]; then
			echo "Failed to create directory: ${DIR_CWG_DIST}"
			exit 1
		fi

		# Update 'Packages' file
		echo "Package: ${pkg_name}" >> ${FILE_PACKAGES}
		if [[ ${pkg_src} != "" ]]; then echo "Source: ${pkg_src}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_version} != "" ]]; then echo "Version: ${pkg_version}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_isize} != "" ]]; then echo "Installed-Size: ${pkg_isize}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_maintainer} != "" ]]; then echo "Maintainer: ${pkg_maintainer}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_arch} != "" ]]; then echo "Architecture: ${pkg_arch}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_provides} != "" ]]; then echo "Provides: ${pkg_provides}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_depends} != "" ]]; then echo "Depends: ${pkg_depends}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_desc} != "" ]]; then echo "Description: ${pkg_desc}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_desc_md5} != "" ]]; then echo "Description-md5: ${pkg_desc_md5}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_imi} != "" ]]; then echo "Installer-Menu-Item: ${pkg_imi}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_section} != "" ]]; then echo "Section: ${pkg_section}" >> ${FILE_PACKAGES}; fi
		if [[ ${pkg_priority} != "" ]]; then echo "Priority: ${pkg_priority}" >> ${FILE_PACKAGES}; fi
		echo "Filename: ${pkg_distpath}" >> ${FILE_PACKAGES}
		echo "Size: ${pkg_size}" >> ${FILE_PACKAGES}
		echo "MD5sum: ${pkg_md5}" >> ${FILE_PACKAGES}
		echo "SHA256: ${pkg_sha256}" >> ${FILE_PACKAGES}
		echo >> ${FILE_PACKAGES}
	done

	# Compress Packages file
	gzip ${FILE_PACKAGES}
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
