#!/usr/bin/env bash

set -euo pipefail

function usage() {
  echo
  echo "NAME"
  echo "    $(basename "${0}") - Apply GPD Pocket modifications to an Ubuntu .iso image without sudo."
  echo
  echo "SYNOPSIS"
  echo "    $(basename "${0}") -d gpd-pocket [ ubuntu iso image ]"
  echo
  echo "OPTIONS"
  echo "    -d"
  echo "        device modifications to apply. This rootless builder currently supports 'gpd-pocket'."
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

function require_command() {
  command -v "${1}" >/dev/null 2>&1 || die "Unable to find required command: ${1}"
}

function extract_from_iso() {
  local ISO_PATH="${1}"
  local ISO_FILE="${2}"
  local OUT_FILE="${3}"

  mkdir -p "$(dirname "${OUT_FILE}")"
  xorriso -osirrox on:auto_chmod_on -indev "${ISO_PATH}" -extract "${ISO_FILE}" "${OUT_FILE}" >/dev/null
  chmod u+w "${OUT_FILE}"
}

function find_squashfs_image() {
  local ISO_PATH="${1}"
  local CANDIDATE=""

  if isoinfo -R -i "${ISO_PATH}" -f | grep -Fx "/casper/filesystem.squashfs" >/dev/null; then
    echo "casper/filesystem.squashfs"
    return 0
  fi

  for CANDIDATE in minimal.squashfs ubuntu-server-minimal.squashfs; do
    if isoinfo -R -i "${ISO_PATH}" -f | grep -Fx "/casper/${CANDIDATE}" >/dev/null; then
      echo "casper/${CANDIDATE}"
      return 0
    fi
  done

  isoinfo -R -i "${ISO_PATH}" -f |
    awk '
      /^\/casper\/.*\.squashfs$/ &&
      $0 !~ /\.live\.squashfs$/ &&
      $0 !~ /installer/ &&
      $0 !~ /\/[^/]*\.[^/]*\.squashfs$/ {
        sub(/^\//, "", $0)
        print
        exit
      }'
}

# Copy file from /data to its intended location.
function inject_data() {
  local TARGET_FILE="${1}"
  local TARGET_DIR
  local SOURCE_FILE

  TARGET_DIR=$(dirname "${TARGET_FILE}")
  if [ -n "${2:-}" ] && [ -f "${2}" ]; then
    SOURCE_FILE="${2}"
  else
    SOURCE_FILE="data/$(basename "${TARGET_FILE}")"
  fi

  if [ -f "${SOURCE_FILE}" ]; then
    echo " - Injecting ${TARGET_FILE#${SQUASH_OUT}/}"
    mkdir -p "${TARGET_DIR}"
    cp "${SOURCE_FILE}" "${TARGET_FILE}"

    if [[ "${TARGET_FILE}" == *"monitors.xml"* ]]; then
      mv -v "${TARGET_FILE}" "${TARGET_DIR}/monitors.xml"
    fi
  fi
}

function update_md5sum() {
  local MD5_FILE="${1}"
  local ISO_PATH="${2}"
  local DISK_PATH="${3}"
  local SUM
  local TMP_FILE

  SUM=$(md5sum "${DISK_PATH}" | awk '{print $1}')
  TMP_FILE="${MD5_FILE}.tmp"
  awk -v path="./${ISO_PATH}" -v sum="${SUM}" '
    $2 == path { print sum "  " path; next }
    { print }
  ' "${MD5_FILE}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${MD5_FILE}"
}

function write_dev_pseudo_file() {
  local PSEUDO_FILE="${1}"

  cat > "${PSEUDO_FILE}" <<'EOF'
dev/console c 666 0 0 5 1
dev/full c 666 0 0 1 7
dev/null c 666 0 0 1 3
dev/ptmx c 666 0 0 5 2
dev/random c 666 0 0 1 8
dev/tty c 666 0 0 5 0
dev/urandom c 666 0 0 1 9
dev/zero c 666 0 0 1 5
var/lib/apt/lists/auxfiles m 755 42 0
var/lib/apt/lists/partial m 700 42 0
EOF
}

function add_live_boot_args() {
  local FILE="${1}"
  local ARGS="${2}"

  [ -f "${FILE}" ] || return 0
  sed -i "s/quiet splash/${ARGS}/g" "${FILE}"
}

function clean_up() {
  if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR}" ]; then
    echo "Cleaning up ${WORKDIR}"
    rm -rf "${WORKDIR}"
  fi
}

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
ISO_IN="${1:-}"

[ -n "${UMPC}" ] || die "You must supply a device with -d."
[ "${UMPC}" = "gpd-pocket" ] || die "Rootless respin currently supports gpd-pocket only."
[ -n "${ISO_IN}" ] || die "You must provide the filename of an Ubuntu iso image."
[ -f "${ISO_IN}" ] || die "Can not access ${ISO_IN}."

for CMD in awk chmod cp du grep isoinfo md5sum mksquashfs mv rm sed sort unsquashfs xorriso; do
  require_command "${CMD}"
done

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}"

ISO_IN=$(realpath "${ISO_IN}")
ISO_OUT=$(basename "${ISO_IN}" | sed "s/\.iso/-${UMPC}\.iso/")
WORKDIR=$(mktemp -d -t umpc-ubuntu-rootless.XXXXXX)
trap clean_up EXIT

SQUASH_REL=$(find_squashfs_image "${ISO_IN}")
[ -n "${SQUASH_REL}" ] || die "Could not find a supported casper squashfs image."
SQUASH_SIZE_REL="${SQUASH_REL%.squashfs}.size"

INFO_FILE="${WORKDIR}/info"
MD5_FILE="${WORKDIR}/md5sum.txt"
GRUB_BOOT_CONF="${WORKDIR}/grub.cfg"
GRUB_LOOPBACK_CONF="${WORKDIR}/loopback.cfg"
SQUASH_IN="${WORKDIR}/$(basename "${SQUASH_REL}")"
SQUASH_OUT="${WORKDIR}/squashfs-root"
SQUASH_NEW="${WORKDIR}/$(basename "${SQUASH_REL%.squashfs}")-new.squashfs"
SQUASH_SIZE="${WORKDIR}/$(basename "${SQUASH_SIZE_REL}")"
PSEUDO_FILE="${WORKDIR}/rootfs.pseudo"

extract_from_iso "${ISO_IN}" "/.disk/info" "${INFO_FILE}"
extract_from_iso "${ISO_IN}" "/md5sum.txt" "${MD5_FILE}"
extract_from_iso "${ISO_IN}" "/boot/grub/grub.cfg" "${GRUB_BOOT_CONF}"
extract_from_iso "${ISO_IN}" "/boot/grub/loopback.cfg" "${GRUB_LOOPBACK_CONF}"
extract_from_iso "${ISO_IN}" "/${SQUASH_REL}" "${SQUASH_IN}"

FLAVOUR=$(cut -d' ' -f1 < "${INFO_FILE}")
VERSION=$(cut -d' ' -f2 < "${INFO_FILE}")
CODENAME=$(cut -d'"' -f2 < "${INFO_FILE}")
SQUASH_COMP=$(unsquashfs -s "${SQUASH_IN}" | awk '
  /^Compression/ {
    if ($0 ~ /:/) {
      sub(/^[^:]*:[ \t]*/, "", $0)
      print tolower($0)
    } else {
      print tolower($2)
    }
    exit
  }')

echo "Modifying ${FLAVOUR} ${VERSION} (${CODENAME}) for the ${UMPC}"
echo "Using ${SQUASH_REL} as the root filesystem image"
echo "Preserving ${SQUASH_COMP:-default} squashfs compression"

unsquashfs -no-xattrs -no-exit-code -f -d "${SQUASH_OUT}" "${SQUASH_IN}"
chmod -R u+rwX "${SQUASH_OUT}"
write_dev_pseudo_file "${PSEUDO_FILE}"

XORG_CONF_PATH="${SQUASH_OUT}/usr/share/X11/xorg.conf.d"
MODPROBE_CONF="${SQUASH_OUT}/etc/modprobe.d/alsa-${UMPC}.conf"
MONITOR_CONF="${XORG_CONF_PATH}/40-${UMPC}-monitor.conf"
MONITORS_XML="${SQUASH_OUT}/var/lib/gdm3/.config/${UMPC}-monitors.xml"
TRACKPOINT_CONF="${XORG_CONF_PATH}/80-${UMPC}-trackpoint.conf"
TOUCH_RULES="${SQUASH_OUT}/etc/udev/rules.d/99-${UMPC}-touch.rules"
GRUB_DEFAULT_CONF="${SQUASH_OUT}/etc/default/grub"
GRUB_D_CONF="${SQUASH_OUT}/etc/default/grub.d/${UMPC}.cfg"
CONSOLE_CONF="${SQUASH_OUT}/etc/default/console-setup"
GSCHEMA_OVERRIDE="${SQUASH_OUT}/usr/share/glib-2.0/schemas/90-${UMPC}.gschema.override"
BRCM4356_CONF="${SQUASH_OUT}/lib/firmware/brcm/brcmfmac4356-pcie.txt"

inject_data "${MONITOR_CONF}"
inject_data "${MONITORS_XML}"
inject_data "${TRACKPOINT_CONF}"
inject_data "${TOUCH_RULES}"
inject_data "${MODPROBE_CONF}"
inject_data "${GSCHEMA_OVERRIDE}"
inject_data "${GRUB_D_CONF}"
inject_data "${BRCM4356_CONF}"

sed -i 's/GRUB_CMDLINE_LINUX="/GRUB_CMDLINE_LINUX="fbcon=rotate:1/' "${GRUB_DEFAULT_CONF}"
add_live_boot_args "${GRUB_BOOT_CONF}" "fbcon=rotate:1 fsck.mode=skip"
add_live_boot_args "${GRUB_LOOPBACK_CONF}" "fbcon=rotate:1 fsck.mode=skip"
sed -i 's/FONTSIZE="8x16"/FONTSIZE="16x32"/' "${CONSOLE_CONF}"

inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"

du -sx --block-size=1 "${SQUASH_OUT}" | cut -f1 > "${SQUASH_SIZE}"

MKSQUASHFS_ARGS=("${SQUASH_OUT}" "${SQUASH_NEW}" -noappend -processors "${MKSQUASHFS_PROCESSORS:-2}" -all-root -pf "${PSEUDO_FILE}" -pseudo-override)
case "${SQUASH_COMP}" in
  gzip|lzma|lzo|lz4|xz|zstd)
    MKSQUASHFS_ARGS+=(-comp "${SQUASH_COMP}")
    ;;
esac
mksquashfs "${MKSQUASHFS_ARGS[@]}"

update_md5sum "${MD5_FILE}" "boot/grub/grub.cfg" "${GRUB_BOOT_CONF}"
update_md5sum "${MD5_FILE}" "boot/grub/loopback.cfg" "${GRUB_LOOPBACK_CONF}"
update_md5sum "${MD5_FILE}" "${SQUASH_SIZE_REL}" "${SQUASH_SIZE}"
update_md5sum "${MD5_FILE}" "${SQUASH_REL}" "${SQUASH_NEW}"

rm -f "${ISO_OUT}"
VOL_ID=$(echo "${FLAVOUR}-${VERSION}-${UMPC}" | cut -c1-31)
xorriso \
  -indev "${ISO_IN}" \
  -outdev "${ISO_OUT}" \
  -boot_image any replay \
  -volid "${VOL_ID}" \
  -overwrite on \
  -map "${GRUB_BOOT_CONF}" /boot/grub/grub.cfg \
  -map "${GRUB_LOOPBACK_CONF}" /boot/grub/loopback.cfg \
  -map "${SQUASH_SIZE}" "/${SQUASH_SIZE_REL}" \
  -map "${SQUASH_NEW}" "/${SQUASH_REL}" \
  -map "${MD5_FILE}" /md5sum.txt \
  -commit

echo
echo "Built ${ISO_OUT}"
