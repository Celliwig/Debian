# debian-installer

## Overview
The Debian text based installer provides quite a simple interface to install a Debian system, however this simplicity belies it's power and the flexability that is available to overcome limitations in the base installer. In a number of situations the in built shell interface provides enough access to correct a number of deficiencies (eg. creating partition layouts not available through partman).

The Debian installer offers preseeding as a way of (semi)automating installations by passing configuration values to the installer. There are a number of different methods supported to pass the preseeding configuration to the installer either using a file or over a network (DHCP/HTTP). However traditionally, for a standalone machine with no network connection, this would require updating the installer initrd for a truely automated install.

In addition, like any software the installer suffers from bugs (such as the inability to handle an encrypted /boot, where GRUB fails to install), and there are use cases which are not handled where providing additional capabilities (partman in particular) would be helpful. Whether fixing bugs or adding capabilities this again would require updating the installer initrd.

As a one off updating the initrd is not particularly taxing, however performing this operation on a number of different target architecture ISOs whenever you're updating your installation media (or indeed adding a new host configuration) quickly becomes tiresome and a better way of handling this was wanted. This became available when support was added to both the kernel and GRUB for multiple initrds. In this scenario the installer initrd remains the same, and a new initrd containing both preseed configuration and any new installer resources is created. Then at boot time both these initrds are passed to the kernel and are combined at runtime. 

## Preseeding
The existing facility of loading the preseed config from the file '/preseed.cfg' is used, however this capability has been augmented to allow the use of the current hostname to select the correct configuration (more on this later). The preseed files for a particular Debian version are stored in a directory '/preseed.\<version name\>', there is then a symlink '/preseed' which points to the relevant version. 

## build-initrd.sh
This script is used to build an initrd image. If run without arguments it will build a basic initrd with preseed files & basic helper functions. If run with the '-p' flag additional d-i packages will be built and included in the initrd.

## initrd.base
This provides the basic helpers:
* S19set_hostname
  - Sets the hostname from the kernel command line early, so '/preseed.cfg' can use it. Normally, it's set after the attempted load of '/preseed.cfg' but before the network preseed file is tried.
* S28debian_iso
  - The initrd is expected to be used where there are multiple installation ISOs saved to individual (named) partitions on a USB key. This selects the correct image by architecture (and also by kernel command line arguments if present). Also fixes a problem associated with mounting manually (it'll do a base install, but won't install anything else).
* S29log_environ
  - This just logs some information (hashes) of the install media/preseed files.
* S34preseed_arch
  - Selects the correct kernel image based on architecture.

## initrd.extras
These are required to support additional packages:
* S98extra_modules
  - This will unpack the full kernel package, and copy particular kernel modules into the current kernel '/lib/modules' directory. This currently copies brd and overlay modules, brd for the ramdisk-target package and overlay FS is needed to merge the new package directories with the existing repository.
* S99merge_packages
  - This merges the existing repository from the ISO with the one containing the new packages.

## initrd.pkgs
This directory contains the source for the additional packages:
* partman-crypto-boot
  - This package fixes the bug which causes the install to fail when GRUB tries to install with '/boot' on an encrypted partition.
* ramdisk-target
  - This package creates a ramdisk backed installation target, useful for testing other d-i components (especially partman).
* remove-celliwig-packages
  - This removes the changes that were made by 'S99merge_packages'.
