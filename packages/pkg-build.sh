#!/bin/bash

delete_tempfiles() {
	dir_pkg="${1}"

	# Check that a directory has been passed
	if [ ! -d "${dir_pkg}" ]; then
		echo "Error: delete_tempfiles: No such directory."
		exit -1
	fi

	# Delete python caches (__pycache__)
	for pycache_dir in `find "${dir_pkg}" -type d -name __pycache__`; do
		echo "Deleting Python cache directory: ${pycache_dir}"
		rm -rf "${pycache_dir}" &>/dev/null
		if [ ${?} -ne 0 ]; then
			echo "Error: delete_tempfiles: Failed to delete directory."
			exit -1
		fi
	done
}

PKG_NAME="${1}"
PKG_VERSION="${2}"
if [ -z "${PKG_NAME}" ]; then
	echo "Error: Package name must be given."
	exit -1
fi

DIR_PWD=`pwd`
DIR_PKG="${DIR_PWD}/${PKG_NAME}"
if [ ! -d "${DIR_PKG}" ]; then
	echo "Error: No such package directory."
	exit -1
fi
if [ ! -d "${DIR_PKG}/DEBIAN" ]; then
	echo "Error: No DEBIAN directory."
	exit -1
fi

FILE_CTRL="${DIR_PKG}/DEBIAN/control"
FILE_CTRL_PREV="${DIR_PKG}/DEBIAN/control.prev"
FILE_MD5S="DEBIAN/md5sums"
FILE_CONFFILES="DEBIAN/conffiles"

delete_tempfiles "${DIR_PKG}"

# Calculate install size
INSTALL_SIZE=`tmp=$(du -c -s -B 1K "${DIR_PKG}" | tail -n 1); echo ${tmp%*total}`

# Update control file
mv "${FILE_CTRL}" "${FILE_CTRL_PREV}" &>/dev/null
if [ ${?} -ne 0 ]; then
	echo "Error: Failed to move control file"
	exit -1
fi
SED_SCRIPT1=""
if [ -n "${PKG_VERSION}" ]; then
	echo $(basename -s .sh ${0})": Setting version to ${PKG_VERSION}"
	SED_SCRIPT1="s|^Version: [0-9.]+$|Version: ${PKG_VERSION}|"
fi
SED_SCRIPT2="s|^Installed-Size: [0-9]+$|Installed-Size: ${INSTALL_SIZE}|"
sed -E -e "${SED_SCRIPT1}" -e "${SED_SCRIPT2}" "${FILE_CTRL_PREV}" > "${FILE_CTRL}"
if [ -f "${FILE_CTRL}" ]; then
	rm "${FILE_CTRL_PREV}"
fi

# Build md5sums
cd "${DIR_PKG}" >/dev/null
rm -f "${FILE_MD5S}" >/dev/null
find . ! -path \*/DEBIAN/\* -type f,l -exec md5sum '{}' \; >> "${FILE_MD5S}"
cd - >/dev/null

# Build conffiles
cd "${DIR_PKG}" >/dev/null
if [ -d 'etc/' ]; then
	rm -f "${FILE_CONFFILES}" >/dev/null
	find etc/ -type f,l -printf "/%p\n" >> "${FILE_CONFFILES}"
fi
cd - >/dev/null

# Get filename attributesfrom control file
PKG_NAME=`tmp=$(grep Package ${FILE_CTRL}); echo ${tmp#Package: *}`
PKG_VER=`tmp=$(grep Version ${FILE_CTRL}); echo ${tmp#Version: *}`
PKG_ARCH=`tmp=$(grep Architecture ${FILE_CTRL}); echo ${tmp#Architecture: *}`

# Build package
dpkg-deb --root-owner-group --build "${DIR_PKG}" "build/${PKG_NAME}_${PKG_VER}_${PKG_ARCH}.deb"
