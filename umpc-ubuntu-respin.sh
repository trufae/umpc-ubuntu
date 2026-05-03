#!/usr/bin/env bash

function usage() {
    echo
    echo "NAME"
    echo "    $(basename "${0}") - Apply GPD/TopJoy device modifications to an Ubuntu .iso image."
    echo
    echo "SYNOPSIS"
    echo "    $(basename "${0}") [ options ] [ ubuntu iso image ]"
    echo
    echo "OPTIONS"
    echo "    -d"
    echo "        device modifications to apply to the iso image, can be 'gpd-pocket', 'gpd-pocket2', 'gpd-pocket3', 'gpd-micropc', 'gpd-p2-max', 'gpd-win2', 'gpd-win3', 'gpd-win-max' or 'topjoy-falcon'"
    echo
    echo "    -h"
    echo "        display this help and exit"
    echo
    exit
}

function die() {
  echo "ERROR! ${*}" >&2
  exit 1
}

APT_UPDATED=0
function install_package() {
  local PACKAGE="${1}"

  if [ "${APT_UPDATED}" -eq 0 ]; then
    apt-get update
    APT_UPDATED=1
  fi
  DEBIAN_FRONTEND=noninteractive apt-get -y install "${PACKAGE}"
}

function require_command() {
  local COMMAND="${1}"
  local PACKAGE="${2}"

  if ! command -v "${COMMAND}" >/dev/null 2>&1; then
    echo "ERROR! Unable to find ${COMMAND}. Installing ${PACKAGE} now..."
    install_package "${PACKAGE}"
  fi
}

function require_file() {
  local FILE="${1}"
  local PACKAGE="${2}"

  if [ ! -f "${FILE}" ]; then
    echo "ERROR! Unable to find ${FILE}. Installing ${PACKAGE} now..."
    install_package "${PACKAGE}"
  fi
}

# Return the root filesystem squashfs path relative to the ISO root.
function find_squashfs_image() {
  local CASPER_DIR="${1}"
  local CANDIDATE=""

  if [ -f "${CASPER_DIR}/filesystem.squashfs" ]; then
    echo "casper/filesystem.squashfs"
    return 0
  fi

  # Ubuntu 24.04 and newer desktop images use layered squashfs files. The
  # shortest base image is inherited by the live session and install sources.
  for CANDIDATE in minimal.squashfs ubuntu-server-minimal.squashfs; do
    if [ -f "${CASPER_DIR}/${CANDIDATE}" ]; then
      echo "casper/${CANDIDATE}"
      return 0
    fi
  done

  CANDIDATE=$(find "${CASPER_DIR}" -maxdepth 1 -type f -name "*.squashfs" \
    ! -name "*.live.squashfs" \
    ! -name "*installer*.squashfs" \
    ! -name "*.*.squashfs" \
    -printf "%f\n" | sort | head -n 1)
  if [ -n "${CANDIDATE}" ]; then
    echo "casper/${CANDIDATE}"
    return 0
  fi

  return 1
}

function add_live_boot_args() {
  local FILE="${1}"
  local ARGS="${2}"

  [ -f "${FILE}" ] || return 0
  if [[ " ${ARGS} " != *" nopersistent "* ]]; then
    ARGS="${ARGS} nopersistent"
  fi
  sed -i "s/quiet splash/${ARGS}/g" "${FILE}"
}

function disable_persistent_partition_creation() {
  local CASPER_HELPERS="${1}"

  [ -f "${CASPER_HELPERS}" ] || die "Could not find casper-helpers in initrd."

  cat >> "${CASPER_HELPERS}" <<'EOF'

# UMPC Ubuntu images are meant to boot without modifying the USB stick.
find_or_create_persistent_partition () {
    return 0
}
EOF
}

function patch_casper_bottom_scripts() {
  local CASPER_BOTTOM="${1}"

  [ -d "${CASPER_BOTTOM}" ] || die "Could not find casper-bottom scripts in initrd."

  cat > "${CASPER_BOTTOM}/22sslcert" <<'EOF'
#! /bin/sh

PREREQ=""
DESCRIPTION="Skipping SSL certificate regeneration for offline live boot..."

prereqs()
{
       echo "$PREREQ"
}

case $1 in
prereqs)
       prereqs
       exit 0
       ;;
esac

. /scripts/casper-functions

log_begin_msg "$DESCRIPTION"
log_end_msg
EOF
  chmod 755 "${CASPER_BOTTOM}/22sslcert"

  cat > "${CASPER_BOTTOM}/41apt_build_cache_cdrom" <<'EOF'
#! /bin/sh

PREREQ=""
DESCRIPTION="Skipping APT cache generation for offline live boot..."

prereqs()
{
       echo "$PREREQ"
}

case $1 in
prereqs)
       prereqs
       exit 0
       ;;
esac

. /scripts/casper-functions

log_begin_msg "$DESCRIPTION"
log_end_msg
EOF
  chmod 755 "${CASPER_BOTTOM}/41apt_build_cache_cdrom"
}

function append_cpio_archive() {
  local SOURCE_DIR="${1}"
  local OUT_FILE="${2}"

  [ -d "${SOURCE_DIR}" ] || return 0
  (
    cd "${SOURCE_DIR}"
    find . -print0 |
      sort -z |
      cpio --null --quiet --reproducible --owner=0:0 -o -H newc
  ) >> "${OUT_FILE}"
}

function append_compressed_cpio_archive() {
  local SOURCE_DIR="${1}"
  local OUT_FILE="${2}"

  (
    cd "${SOURCE_DIR}"
    find . -print0 |
      sort -z |
      cpio --null --quiet --reproducible --owner=0:0 -o -H newc |
      zstd -q -19 -T0
  ) >> "${OUT_FILE}"
}

function patch_live_initrd() {
  local INITRD_IN="${1}"
  local INITRD_OUT="${2}"
  local INITRD_ROOT="${3}"
  local MAIN_DIR
  local EARLY_DIR

  rm -rf "${INITRD_ROOT}"
  mkdir -p "${INITRD_ROOT}"
  TMPDIR="${WORKDIR}" unmkinitramfs "${INITRD_IN}" "${INITRD_ROOT}" >/dev/null

  if [ -d "${INITRD_ROOT}/main/scripts/casper-bottom" ]; then
    MAIN_DIR="${INITRD_ROOT}/main"
  else
    MAIN_DIR="${INITRD_ROOT}"
  fi

  patch_casper_bottom_scripts "${MAIN_DIR}/scripts/casper-bottom"
  disable_persistent_partition_creation "${MAIN_DIR}/scripts/casper-helpers"

  : > "${INITRD_OUT}"
  if [ "${MAIN_DIR}" != "${INITRD_ROOT}" ]; then
    for EARLY_DIR in "${INITRD_ROOT}"/early*; do
      append_cpio_archive "${EARLY_DIR}" "${INITRD_OUT}"
    done
  fi
  append_compressed_cpio_archive "${MAIN_DIR}" "${INITRD_OUT}"
}

# Copy file from /data to it's intended location
function inject_data() {
  local TARGET_FILE="${1}"
  local TARGET_DIR=$(dirname "${TARGET_FILE}")
  if [ -n "${2}" ] && [ -f "${2}" ]; then
    local SOURCE_FILE="${2}"
  else
    local SOURCE_FILE="data/$(basename ${TARGET_FILE})"
  fi

  if [ -f "${SOURCE_FILE}" ]; then
    echo " - Injecting ${TARGET_FILE}"
    if [ ! -d "${TARGET_DIR}" ]; then
      mkdir -p "${TARGET_DIR}"
    fi
    cp "${SOURCE_FILE}" "${TARGET_FILE}"

    # Rename the GDM3 monitors configuration
    if [[ "${TARGET_FILE}" == *"monitors.xml"* ]]; then
      mv -v "${TARGET_FILE}" "${TARGET_DIR}/monitors.xml"
    fi
  fi
}

CLEANED_UP=0
function clean_up() {
  if [ "${CLEANED_UP}" -eq 1 ]; then
    return
  fi
  CLEANED_UP=1

  echo "Cleaning up..."
  if [ -n "${MNT_IN}" ] && mountpoint -q "${MNT_IN}" 2>/dev/null; then
    echo "  - Unmounting ${MNT_IN}"
    umount -l "${MNT_IN}"
  fi
  if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
    echo "  - ${WORKDIR}"
    rm -rf "${WORKDIR}"
  fi
}

# Make sure we are root.
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR! You must be root to run $(basename "${0}")"
  exit 1
fi

require_command xorriso xorriso
require_command unsquashfs squashfs-tools
require_command mksquashfs squashfs-tools
require_command rsync rsync
require_command gcc gcc
require_command cpio cpio
require_command unmkinitramfs initramfs-tools-core
require_command zstd zstd


UMPC=""
OPTSTRING=d:h
while getopts ${OPTSTRING} OPT; do
    case ${OPT} in
        d) UMPC="${OPTARG}";;
        h) usage;;
        *) usage;;
    esac
done
shift "$((OPTIND - 1))"
ISO_IN="${1}"

if [ -z "${UMPC}" ]; then
  echo "ERROR! You must supply the name of the device you want to apply modifications for."
  usage
fi

case "${UMPC}" in
  gpd-pocket|gpd-pocket2|gpd-pocket3|gpd-micropc|gpd-p2-max|gpd-win2|gpd-win3|gpd-win-max|topjoy-falcon) true;;
  *) echo "ERROR! Unknown device name given."
     usage;;
esac

if [ -z "${ISO_IN}" ]; then
  echo "ERROR! You must provide the filename of an Ubuntu iso image."
  usage
fi

if [ ! -f "${ISO_IN}" ]; then
  die "Can not access ${ISO_IN}."
fi

ISO_OUT=$(basename "${ISO_IN}" | sed "s/\.iso/-${UMPC}\.iso/")
if [ -f "${ISO_OUT}" ]; then
  rm -f "${ISO_OUT}"
fi

WORKDIR=$(mktemp -d -t umpc-ubuntu-respin.XXXXXX)
MNT_IN="${WORKDIR}/iso_in"
MNT_OUT="${WORKDIR}/iso_out"
SQUASH_OUT="${WORKDIR}/squashfs-root"
XORG_CONF_PATH="${SQUASH_OUT}/usr/share/X11/xorg.conf.d"
INTEL_CONF="${XORG_CONF_PATH}/20-${UMPC}-intel.conf"
MODPROBE_CONF="${SQUASH_OUT}/etc/modprobe.d/alsa-${UMPC}.conf"
MONITOR_CONF="${XORG_CONF_PATH}/40-${UMPC}-monitor.conf"
MONITORS_XML="${SQUASH_OUT}/var/lib/gdm3/.config/${UMPC}-monitors.xml"
TRACKPOINT_CONF="${XORG_CONF_PATH}/80-${UMPC}-trackpoint.conf"
TOUCH_RULES="${SQUASH_OUT}/etc/udev/rules.d/99-${UMPC}-touch.rules"
GRUB_DEFAULT_CONF="${SQUASH_OUT}/etc/default/grub"
GRUB_D_CONF="${SQUASH_OUT}/etc/default/grub.d/${UMPC}.cfg"
GRUB_BOOT_CONF="${MNT_OUT}/boot/grub/grub.cfg"
GRUB_LOOPBACK_CONF="${MNT_OUT}/boot/grub/loopback.cfg"
INITRD_TARGET="${MNT_OUT}/casper/initrd"
INITRD_NEW="${WORKDIR}/initrd-new"
INITRD_ROOT="${WORKDIR}/initrd-root"
CONSOLE_CONF="${SQUASH_OUT}/etc/default/console-setup"
GSCHEMA_OVERRIDE="${SQUASH_OUT}/usr/share/glib-2.0/schemas/90-${UMPC}.gschema.override"
HWDB_CONF="${SQUASH_OUT}/etc/udev/hwdb.d/61-${UMPC}-sensor-local.hwdb"
trap clean_up EXIT

# Copy the contents of the ISO
mkdir -p "${MNT_IN}"
mkdir -p "${MNT_OUT}"
if ! mount -o loop "${ISO_IN}" "${MNT_IN}"; then
  die "Unable to mount ${ISO_IN}"
fi

if [ -d "${MNT_IN}/isolinux" ]; then
  ISO_BUILD="old"
  require_file /usr/lib/ISOLINUX/isohdpfx.bin isolinux
else
  ISO_BUILD="new"
  require_file /usr/share/cd-boot-images-amd64/images/boot/grub/efi.img cd-boot-images-amd64
fi

SQUASH_REL=$(find_squashfs_image "${MNT_IN}/casper") || die "Could not find a supported casper squashfs image."
SQUASH_IN="${MNT_IN}/${SQUASH_REL}"
SQUASH_TARGET="${MNT_OUT}/${SQUASH_REL}"
SQUASH_SIZE="${MNT_OUT}/${SQUASH_REL%.squashfs}.size"
SQUASH_COMP=$(unsquashfs -s "${SQUASH_IN}" | awk -F: '/Compression/ {gsub(/^[ \t]+/, "", $2); print tolower($2); exit}')

if [ -f "${MNT_IN}/.disk/info" ] && [ -f "${SQUASH_IN}" ]; then
  FLAVOUR=$(cut -d' ' -f1 < "${MNT_IN}/.disk/info")
  VERSION=$(cut -d' ' -f2 < "${MNT_IN}/.disk/info")
  CODENAME=$(cut -d'"' -f2 < "${MNT_IN}/.disk/info")
  echo "Modifying ${FLAVOUR} ${VERSION} (${CODENAME}) for the ${UMPC}"
  echo "Using ${SQUASH_REL} as the root filesystem image"
  echo "Preserving ${SQUASH_COMP:-default} squashfs compression"

  rsync -aHAXx --delete --quiet \
    --exclude="/${SQUASH_REL}" \
    --exclude="/${SQUASH_REL}.gpg" \
    --exclude=/md5sum.txt \
    "${MNT_IN}/" "${MNT_OUT}/" >/dev/null

  # Extract the contents of the squashfs
  unsquashfs -f -d "${SQUASH_OUT}" "${SQUASH_IN}"
  umount -l "${MNT_IN}"
else
  echo "ERROR! This doesn't look like an Ubuntu iso image."
  exit 1
fi

# Check versions
case ${VERSION} in
  14*|16*|18*)
    echo "ERROR! Only Ubuntu 20.04 or newer is supported."
    exit 1
    ;;
esac

# Some device have require specific Ubuntu releases.
case "${UMPC}" in
  gpd-pocket3)
    case ${VERSION} in
      20*|21.04)
        echo "ERROR! GPD Pocket 3 is only supported by Ubuntu 21.10 and newer."
        exit 1
        ;;
    esac
    ;;
  gpd-win-max)
    case ${VERSION} in
      22.04*)
        GRUB_D_CONF="${SQUASH_OUT}/etc/default/grub.d/${UMPC}-new.cfg"
        echo "ERROR! GPD Win Max is only supported by Ubuntu 20.04 to 21.10."
        exit 1
        ;;
    esac
    ;;
esac

# NOTE! Do not inject this configuration anymore. The defaults are sane.
# Enable Intel SNA, DRI1/3 and TearFree.
# inject_data "${INTEL_CONF}"

# Rotate the monitor.
inject_data "${MONITOR_CONF}"
inject_data "${MONITORS_XML}"

# Scroll while holding down the right track point button
inject_data "${TRACKPOINT_CONF}"

# Rotate the touchscreen.
inject_data "${TOUCH_RULES}"

# Configure kernel modules
inject_data "${MODPROBE_CONF}"

# Apply device specific gschema overrides
inject_data "${GSCHEMA_OVERRIDE}"

# Add device specific /etc/grub.d configuration
inject_data "${GRUB_D_CONF}"

# Device specific tweaks
case ${UMPC} in
  gpd-pocket)
    # Add BRCM4356 firmware configuration
    inject_data "${SQUASH_OUT}/lib/firmware/brcm/brcmfmac4356-pcie.txt"

    # Frame buffer rotation
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 fsck.mode=skip"

    # Increase console font size
    sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"

    # Display scaler
    inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
    inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"
    ;;
  gpd-pocket2)
    # Frame buffer rotation
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 fsck.mode=skip"

    # Increase console font size
    sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"

    # Display scaler
    inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
    inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"
    ;;
  gpd-pocket3)
    # Frame buffer rotation and s2idle by default.
    # s2idle is a temporary workaround
    #  - Otherwise the screen will not turn back on after blanking if the system is busy.
    #  - This issue also affects suspend feature.
    #  - Patches are being worked on, more info here:
    #    https://ubuntu-mate.community/t/gpd-pocket-3-s3-sleep-waiting-for-kernel-fix/25053/
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"

    # Increase console font size
    sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"

    # Add automatic screen rotation
    gcc -O2 "data/umpc-display-rotate.c" -o "${SQUASH_OUT}/usr/bin/umpc-display-rotate" -lm
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-rotate.desktop"
    inject_data "${HWDB_CONF}"

    # Display scaler
    inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
    inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"
    ;;
  gpd-p2-max)
    # Increase console font size
    sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"
    ;;
  gpd-micropc)
    # Frame buffer rotation
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 fsck.mode=skip"
    ;;
  gpd-win2)
    # Frame buffer rotation
    # s2idle is required to wake from suspend.
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1 video=eDP-1:panel_orientation=right_side_up mem_sleep_default=s2idle/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=eDP-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=eDP-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"
    ;;
  gpd-win3)
    # Frame buffer rotation and s2idle by default.
    # s2idle is a temporary workaround
    #  - Otherwise the screen will not turn back on after blanking if the system is busy.
    #  - This issue also affects suspend feature.
    #  - Patches are being worked on, more info here:
    #    https://ubuntu-mate.community/t/gpd-pocket-3-s3-sleep-waiting-for-kernel-fix/25053/
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle/' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up mem_sleep_default=s2idle fsck.mode=skip"

    # Might need a workaround for the touch screen.
    # > "My touch screen does work if I "modprobe -r goodix && modprobe goodix"
    # > after login, as opposed to adding it under /etc/modules-load.d."
    # See also: https://aur.archlinux.org/packages/goodix-gpdwin3-dkms/
    ;;
  gpd-win-max)
    # Add device specific EDID on Ubuntu 21.10 are earlier
    # https://patchwork.kernel.org/project/intel-gfx/cover/20210817204329.5457-1-anisse@astier.eu/#24416791
    case "${VERSION}" in
      22*)
        sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"fbcon=rotate:1 video=eDP-1:800x1280/" "${GRUB_DEFAULT_CONF}"
        add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=eDP-1:800x1280 fsck.mode=skip"
        add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=eDP-1:800x1280 fsck.mode=skip"
        ;;
      *)
        inject_data "${SQUASH_OUT}/usr/lib/firmware/edid/${UMPC}-edid.bin"
        sed -i "s/GRUB_CMDLINE_LINUX=\"/GRUB_CMDLINE_LINUX=\"fbcon=rotate:1 video=eDP-1:800x1280 drm.edid_firmware=eDP-1:edid\/${UMPC}-edid.bin/" "${GRUB_DEFAULT_CONF}"
        add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=eDP-1:800x1280 drm.edid_firmware=eDP-1:edid\/${UMPC}-edid.bin fsck.mode=skip"
        add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=eDP-1:800x1280 drm.edid_firmware=eDP-1:edid\/${UMPC}-edid.bin fsck.mode=skip"
        ;;
    esac
    ;;
  topjoy-falcon)
    # Frame buffer rotation
    sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up /' "${GRUB_DEFAULT_CONF}"
    add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up fsck.mode=skip"
    add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 video=DSI-1:panel_orientation=right_side_up fsck.mode=skip"

    # Increase console font size
    sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"

    # Add automatic screen rotation
    gcc -O2 "data/umpc-display-rotate.c" -o "${SQUASH_OUT}/usr/bin/umpc-display-rotate" -lm
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-rotate.desktop"
    inject_data "${HWDB_CONF}"

    # Display scaler
    inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
    inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
    inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"
    ;;
  *)
    echo "ERROR! No device configuration for ${UMPC}!"
    exit 1
    ;;
esac

# Disable live-boot work that is slow or noisy on an offline USB image.
if [ -f "${INITRD_TARGET}" ]; then
  patch_live_initrd "${INITRD_TARGET}" "${INITRD_NEW}" "${INITRD_ROOT}"
  mv "${INITRD_NEW}" "${INITRD_TARGET}"
fi

#echo
#echo "Modified : ${GRUB_DEFAULT_CONF}"
#cat "${GRUB_DEFAULT_CONF}"
#echo

#echo
#echo "Modified : ${GRUB_BOOT_CONF}"
#cat "${GRUB_BOOT_CONF}"
#echo

#echo
#echo "Modified : ${GRUB_LOOPBACK_CONF}"
#cat "${GRUB_LOOPBACK_CONF}"
#echo

# Update filesystem size
du -sx --block-size=1 "${SQUASH_OUT}" | cut -f1 > "${SQUASH_SIZE}"

# Repack squashfs
rm -f "${SQUASH_TARGET}" 2>/dev/null
case "${SQUASH_COMP}" in
  gzip|lzma|lzo|lz4|xz|zstd)
    mksquashfs "${SQUASH_OUT}" "${SQUASH_TARGET}" -comp "${SQUASH_COMP}"
    ;;
  *)
    mksquashfs "${SQUASH_OUT}" "${SQUASH_TARGET}"
    ;;
esac
echo "Cleaning up..."
echo "  - ${SQUASH_OUT}"
rm -rf "${SQUASH_OUT}"
sync

# Collect md5sums
find "${MNT_OUT}" -type f ! -path "${MNT_OUT}/md5sum.txt" -print0 | xargs -0 md5sum | sed 's|'"${MNT_OUT}"'|\.|g' > "${MNT_OUT}/md5sum.txt"

VOL_ID=$(echo "${FLAVOUR}-${VERSION}-${UMPC}" | cut -c1-31)
rm -f "${ISO_OUT}" 2>/dev/null

# Reference for new iso build:
#  - https://bugs.launchpad.net/ubuntu-cdimage/+bug/1886148
#  - From https://bugs.launchpad.net/ubuntu-cdimage/+bug/1886148/comments/195
case ${ISO_BUILD} in
  old)
  xorriso \
  -as mkisofs \
  -r \
  -checksum_algorithm_iso md5,sha1 \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -J \
  -l \
  -b isolinux/isolinux.bin \
  -c isolinux/boot.cat \
  -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  -eltorito-alt-boot \
  -e boot/grub/efi.img \
  -no-emul-boot \
  -isohybrid-gpt-basdat \
  -isohybrid-apm-hfsplus \
  -volid "${VOL_ID}" \
  -o "${ISO_OUT}" "${MNT_OUT}/";;
  *)
  xorriso \
  -as mkisofs \
  -r \
  -checksum_algorithm_iso md5,sha1 \
  -J -joliet-long \
  -l \
  -b boot/grub/i386-pc/eltorito.img -no-emul-boot \
  -boot-load-size 4 \
  -boot-info-table \
  --grub2-boot-info \
  --grub2-mbr /usr/share/cd-boot-images-amd64/images/boot/grub/i386-pc/boot_hybrid.img \
  -append_partition 2 0xef /usr/share/cd-boot-images-amd64/images/boot/grub/efi.img \
  -appended_part_as_gpt -eltorito-alt-boot -e --interval\:appended_partition_2\:all\:\: -no-emul-boot \
  -partition_offset 16 /usr/share/cd-boot-images-amd64/tree \
  -V "${VOL_ID}" \
  -o "${ISO_OUT}" "${MNT_OUT}/";;
esac
if [ -n "${SUDO_USER:-}" ] && id "${SUDO_USER}" >/dev/null 2>&1; then
  chown -v "${SUDO_USER}":"${SUDO_USER}" "${ISO_OUT}"
fi
