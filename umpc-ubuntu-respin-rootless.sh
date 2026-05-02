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
  echo "    --slim-online"
  echo "        remove offline/full-install payloads and install Epiphany online after setup."
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

function enter_fakeroot() {
  if [ "$(id -u)" -eq 0 ] || [ -n "${FAKEROOTKEY:-}" ]; then
    return
  fi

  require_command fakeroot
  exec fakeroot -- "${0}" "${@}"
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
    $2 == path { print sum "  " path; found = 1; next }
    { print }
    END {
      if (!found) {
        print sum "  " path
      }
    }
  ' "${MD5_FILE}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${MD5_FILE}"
}

function filter_md5sum_for_slim_online() {
  local MD5_FILE="${1}"
  local TMP_FILE="${MD5_FILE}.tmp"

  awk '
    {
      path = $2
      if (path ~ /^\.\/dists\//) {
        next
      }
      if (path ~ /^\.\/pool\//) {
        next
      }
      if (path ~ /^\.\/casper\/minimal\.standard/ &&
          path !~ /^\.\/casper\/minimal\.standard\.live/) {
        next
      }
      if (path ~ /^\.\/casper\/minimal\./ &&
          path !~ /^\.\/casper\/minimal\.(squashfs|size|manifest|manifest\.full)$/ &&
          path !~ /^\.\/casper\/minimal\.standard\.live\./) {
        next
      }
      print
    }
  ' "${MD5_FILE}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${MD5_FILE}"
}

function prune_slim_online_manifest() {
  local MANIFEST="${1}"
  local TMP_FILE="${MANIFEST}.tmp"

  [ -f "${MANIFEST}" ] || return 0
  awk '
    {
      name = $1
      sub(/^[+-]/, "", name)

      if (name ~ /^snap:/) {
        snap = name
        sub(/^snap:/, "", snap)
        if (snap == "firefox" || snap == "thunderbird") {
          next
        }
      }

      pkg = name
      sub(/:.*/, "", pkg)
      if (pkg == "firefox" ||
          pkg == "thunderbird" || pkg ~ /^thunderbird-/ ||
          pkg == "transmission" || pkg ~ /^transmission-/ ||
          pkg == "libreoffice" || pkg ~ /^libreoffice-/ ||
          pkg == "remmina" || pkg ~ /^remmina-/ ||
          pkg == "rhythmbox" || pkg ~ /^rhythmbox-/ ||
          pkg == "shotwell" || pkg ~ /^shotwell-/ ||
          pkg == "nvidia-prime" || pkg == "nvidia-settings" ||
          pkg == "libnvidia-egl-wayland1" || pkg == "libxnvctrl0" ||
          pkg == "linux-firmware-nvidia-graphics") {
        next
      }

      print
    }
  ' "${MANIFEST}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${MANIFEST}"
}

function keep_minimal_install_source() {
  local INSTALL_SOURCES="${1}"
  local TMP_FILE="${INSTALL_SOURCES}.tmp"

  [ -f "${INSTALL_SOURCES}" ] || return 0
  awk '
    /^- default: false$/ {
      skip = 1
      next
    }
    skip && /^version:/ {
      skip = 0
    }
    skip {
      next
    }
    /^  preinstalled_langs:/ {
      skip_langs = 1
      next
    }
    skip_langs {
      if ($0 ~ /^  [^[:space:]-]/ || $0 ~ /^version:/) {
        skip_langs = 0
      } else {
        next
      }
    }
    /^    minimal-enhanced-secureboot:/ {
      skip_secureboot = 1
      next
    }
    skip_secureboot {
      if ($0 ~ /^    [^[:space:]]/ || $0 ~ /^version:/) {
        skip_secureboot = 0
      } else {
        next
      }
    }
    { print }
  ' "${INSTALL_SOURCES}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${INSTALL_SOURCES}"
}

function create_empty_layer() {
  local LAYER_FILE="${1}"
  local SIZE_FILE="${2}"
  local MANIFEST_FILE="${3}"
  local MANIFEST_FULL_FILE="${4}"
  local EMPTY_DIR="${WORKDIR}/empty-layer"

  rm -rf "${EMPTY_DIR}"
  mkdir -p "${EMPTY_DIR}"
  du -sx --block-size=1 "${EMPTY_DIR}" | cut -f1 > "${SIZE_FILE}"
  : > "${MANIFEST_FILE}"
  : > "${MANIFEST_FULL_FILE}"

  rm -f "${LAYER_FILE}"
  mksquashfs "${EMPTY_DIR}" "${LAYER_FILE}" -noappend -processors "${MKSQUASHFS_PROCESSORS:-2}" -comp xz >/dev/null
}

function remove_snap_from_seed_yaml() {
  local SEED_YAML="${1}"
  local SNAP_NAME="${2}"
  local TMP_FILE="${SEED_YAML}.tmp"

  [ -f "${SEED_YAML}" ] || return 0
  awk -v snap="${SNAP_NAME}" '
    /^  -$/ {
      if (in_block && !skip_block) {
        printf "%s", block
      }
      block = $0 ORS
      in_block = 1
      skip_block = 0
      next
    }
    {
      if (in_block) {
        block = block $0 ORS
        if ($0 ~ "^[[:space:]]+name:[[:space:]]*" snap "$") {
          skip_block = 1
        }
        next
      }
      print
    }
    END {
      if (in_block && !skip_block) {
        printf "%s", block
      }
    }
  ' "${SEED_YAML}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${SEED_YAML}"
}

function remove_snap_from_state() {
  local ROOT="${1}"
  local SNAP_NAME="${2}"
  local STATE_JSON="${ROOT}/var/lib/snapd/state.json"
  local TMP_FILE="${STATE_JSON}.tmp"

  [ -f "${STATE_JSON}" ] || return 0
  jq --arg snap "${SNAP_NAME}" '
    del(.data.snaps[$snap])
    | .data.conns |= with_entries(
        select(((.key | startswith($snap + ":")) or (.key | contains(" " + $snap + ":"))) | not)
      )
    | .data["snap-cookies"] |= with_entries(select(.value != $snap))
  ' "${STATE_JSON}" > "${TMP_FILE}"
  mv "${TMP_FILE}" "${STATE_JSON}"
}

function remove_seeded_snap() {
  local ROOT="${1}"
  local SNAP_NAME="${2}"

  echo " - Removing seeded snap ${SNAP_NAME}"
  rm -rf "${ROOT}/snap/${SNAP_NAME}"
  rm -f "${ROOT}/snap/bin/${SNAP_NAME}" "${ROOT}/snap/bin/${SNAP_NAME}."*
  if [ "${SNAP_NAME}" = "firefox" ]; then
    rm -f "${ROOT}/snap/bin/geckodriver"
  fi

  rm -f "${ROOT}/etc/systemd/system/snap-${SNAP_NAME}-"*.mount
  rm -f "${ROOT}/etc/systemd/system/multi-user.target.wants/snap-${SNAP_NAME}-"*.mount
  rm -f "${ROOT}/etc/systemd/system/snapd.mounts.target.wants/snap-${SNAP_NAME}-"*.mount
  rm -f "${ROOT}/etc/udev/rules.d/"*snap.${SNAP_NAME}.rules
  rm -f "${ROOT}/var/cache/apparmor/"*/snap.${SNAP_NAME}.*
  rm -f "${ROOT}/var/cache/apparmor/"*/snap-update-ns.${SNAP_NAME}
  rm -rf "${ROOT}/var/snap/${SNAP_NAME}"

  rm -f "${ROOT}/var/lib/snapd/seed/snaps/${SNAP_NAME}_"*.snap
  rm -f "${ROOT}/var/lib/snapd/snaps/${SNAP_NAME}_"*.snap
  rm -f "${ROOT}/var/lib/snapd/seed/assertions/${SNAP_NAME}_"*.assert
  rm -f "${ROOT}/var/lib/snapd/apparmor/profiles/snap.${SNAP_NAME}"*
  rm -f "${ROOT}/var/lib/snapd/apparmor/profiles/snap-update-ns.${SNAP_NAME}"
  rm -f "${ROOT}/var/lib/snapd/cgroup/snap.${SNAP_NAME}."*
  rm -f "${ROOT}/var/lib/snapd/cookie/snap.${SNAP_NAME}"
  rm -f "${ROOT}/var/lib/snapd/desktop/applications/${SNAP_NAME}_"*.desktop
  rm -f "${ROOT}/var/lib/snapd/inhibit/${SNAP_NAME}.lock"
  rm -f "${ROOT}/var/lib/snapd/mount/snap.${SNAP_NAME}."*
  rm -f "${ROOT}/var/lib/snapd/seccomp/bpf/snap.${SNAP_NAME}."*
  rm -f "${ROOT}/var/lib/snapd/sequence/${SNAP_NAME}.json"

  remove_snap_from_seed_yaml "${ROOT}/var/lib/snapd/seed/seed.yaml" "${SNAP_NAME}"
  remove_snap_from_state "${ROOT}" "${SNAP_NAME}"
}

function install_epiphany_online_hook() {
  local ROOT="${1}"
  local SCRIPT="${ROOT}/usr/local/sbin/umpc-install-epiphany-browser"
  local SERVICE="${ROOT}/etc/systemd/system/umpc-install-epiphany-browser.service"
  local WANTS="${ROOT}/etc/systemd/system/multi-user.target.wants"

  echo " - Adding online Epiphany install hook"
  mkdir -p "$(dirname "${SCRIPT}")" "$(dirname "${SERVICE}")" "${WANTS}"
  cat > "${SCRIPT}" <<'EOF'
#!/bin/sh
set -eu

MARKER=/var/lib/umpc-online-slim/epiphany-browser-installed
[ -e "${MARKER}" ] && exit 0

export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=300 purge -y firefox || true
apt-get -o DPkg::Lock::Timeout=300 update
apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends epiphany-browser

mkdir -p "$(dirname "${MARKER}")"
touch "${MARKER}"
EOF
  chmod 755 "${SCRIPT}"

  cat > "${SERVICE}" <<'EOF'
[Unit]
Description=Install Epiphany browser for the UMPC online-slim image
Wants=network-online.target
After=network-online.target apt-daily.service apt-daily-upgrade.service snapd.seeded.service
ConditionPathExists=!/cdrom/casper
ConditionPathExists=!/var/lib/umpc-online-slim/epiphany-browser-installed

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/umpc-install-epiphany-browser

[Install]
WantedBy=multi-user.target
EOF
  ln -sf ../umpc-install-epiphany-browser.service "${WANTS}/umpc-install-epiphany-browser.service"
}

function apply_slim_online_rootfs() {
  local ROOT="${1}"

  echo "Applying online-slim root filesystem changes"
  remove_seeded_snap "${ROOT}" firefox
  remove_seeded_snap "${ROOT}" thunderbird
  rm -rf "${ROOT}/usr/lib/firmware/nvidia"
  install_epiphany_online_hook "${ROOT}"
}

function apply_slim_online_live_rootfs() {
  local ROOT="${1}"

  echo "Applying online-slim live layer changes"
  remove_seeded_snap "${ROOT}" firefox
  remove_seeded_snap "${ROOT}" thunderbird
  rm -f "${ROOT}/var/lib/snapd/seed/snaps/"*nvidia*.comp
}

function iso_path_exists() {
  local ISO_PATH="${1}"
  local ISO_FILE="${2}"

  isoinfo -R -i "${ISO_PATH}" -f | grep -Fx "${ISO_FILE}" >/dev/null
}

function extract_optional_from_iso() {
  local ISO_PATH="${1}"
  local ISO_FILE="${2}"
  local OUT_FILE="${3}"

  if iso_path_exists "${ISO_PATH}" "${ISO_FILE}"; then
    extract_from_iso "${ISO_PATH}" "${ISO_FILE}" "${OUT_FILE}"
    return 0
  fi
  return 1
}

function find_live_squashfs_image() {
  local ISO_PATH="${1}"

  isoinfo -R -i "${ISO_PATH}" -f |
    awk '
      /^\/casper\/.*\.live\.squashfs$/ {
        sub(/^\//, "", $0)
        print
        exit
      }'
}

function collect_slim_iso_remove_paths() {
  local ISO_PATH="${1}"

  isoinfo -R -i "${ISO_PATH}" -f |
    awk '
      /^\/casper\/minimal\./ &&
      $0 !~ /^\/casper\/minimal\.(squashfs|size|manifest|manifest\.full)$/ &&
      $0 !~ /^\/casper\/minimal\.standard\.live\./ {
        print
      }'
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

function clean_up() {
  if [ -n "${WORKDIR:-}" ] && [ -d "${WORKDIR}" ]; then
    echo "Cleaning up ${WORKDIR}"
    rm -rf "${WORKDIR}"
  fi
}

ORIGINAL_ARGS=("$@")
UMPC=""
SLIM_ONLINE=0
while [ "${#}" -gt 0 ]; do
  case "${1}" in
    -d)
      [ "${#}" -ge 2 ] || usage
      UMPC="${2}"
      shift 2
      ;;
    --slim-online)
      SLIM_ONLINE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    --)
      shift
      break
      ;;
    -*)
      usage
      ;;
    *)
      break
      ;;
  esac
done

enter_fakeroot "${ORIGINAL_ARGS[@]}"

ISO_IN="${1:-}"

[ -n "${UMPC}" ] || die "You must supply a device with -d."
[ "${UMPC}" = "gpd-pocket" ] || die "Rootless respin currently supports gpd-pocket only."
[ -n "${ISO_IN}" ] || die "You must provide the filename of an Ubuntu iso image."
[ -f "${ISO_IN}" ] || die "Can not access ${ISO_IN}."

for CMD in awk chmod cp cpio du find grep isoinfo md5sum mksquashfs mv rm sed sort unmkinitramfs unsquashfs xorriso zstd; do
  require_command "${CMD}"
done
if [ "${SLIM_ONLINE}" -eq 1 ]; then
  require_command jq
fi

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
INITRD_REL="casper/initrd"
INITRD_IN="${WORKDIR}/initrd"
INITRD_NEW="${WORKDIR}/initrd-new"
INITRD_ROOT="${WORKDIR}/initrd-root"
SQUASH_IN="${WORKDIR}/$(basename "${SQUASH_REL}")"
SQUASH_OUT="${WORKDIR}/squashfs-root"
SQUASH_NEW="${WORKDIR}/$(basename "${SQUASH_REL%.squashfs}")-new.squashfs"
SQUASH_SIZE="${WORKDIR}/$(basename "${SQUASH_SIZE_REL}")"
INSTALL_SOURCES_REL="casper/install-sources.yaml"
INSTALL_SOURCES="${WORKDIR}/install-sources.yaml"
LIVE_SQUASH_REL=""
LIVE_SQUASH_IN=""
LIVE_SQUASH_OUT=""
LIVE_SQUASH_NEW=""
LIVE_SQUASH_SIZE_REL=""
LIVE_SQUASH_SIZE=""
STANDARD_LAYER_REL="casper/minimal.standard.squashfs"
STANDARD_LAYER="${WORKDIR}/minimal.standard-empty.squashfs"
STANDARD_SIZE_REL="casper/minimal.standard.size"
STANDARD_SIZE="${WORKDIR}/minimal.standard.size"
STANDARD_MANIFEST_REL="casper/minimal.standard.manifest"
STANDARD_MANIFEST="${WORKDIR}/minimal.standard.manifest"
STANDARD_MANIFEST_FULL_REL="casper/minimal.standard.manifest.full"
STANDARD_MANIFEST_FULL="${WORKDIR}/minimal.standard.manifest.full"
MANIFEST_RELS=()
MANIFEST_FILES=()

extract_from_iso "${ISO_IN}" "/.disk/info" "${INFO_FILE}"
extract_from_iso "${ISO_IN}" "/md5sum.txt" "${MD5_FILE}"
extract_from_iso "${ISO_IN}" "/boot/grub/grub.cfg" "${GRUB_BOOT_CONF}"
extract_from_iso "${ISO_IN}" "/boot/grub/loopback.cfg" "${GRUB_LOOPBACK_CONF}"
extract_from_iso "${ISO_IN}" "/${INITRD_REL}" "${INITRD_IN}"
extract_from_iso "${ISO_IN}" "/${SQUASH_REL}" "${SQUASH_IN}"
if [ "${SLIM_ONLINE}" -eq 1 ]; then
  extract_from_iso "${ISO_IN}" "/${INSTALL_SOURCES_REL}" "${INSTALL_SOURCES}"
  for MANIFEST_REL in "${SQUASH_REL%.squashfs}.manifest" "${SQUASH_REL%.squashfs}.manifest.full"; do
    MANIFEST_FILE="${WORKDIR}/$(basename "${MANIFEST_REL}")"
    if extract_optional_from_iso "${ISO_IN}" "/${MANIFEST_REL}" "${MANIFEST_FILE}"; then
      MANIFEST_RELS+=("${MANIFEST_REL}")
      MANIFEST_FILES+=("${MANIFEST_FILE}")
    fi
  done
  LIVE_SQUASH_REL=$(find_live_squashfs_image "${ISO_IN}")
  if [ -n "${LIVE_SQUASH_REL}" ]; then
    LIVE_SQUASH_SIZE_REL="${LIVE_SQUASH_REL%.squashfs}.size"
    LIVE_SQUASH_IN="${WORKDIR}/$(basename "${LIVE_SQUASH_REL}")"
    LIVE_SQUASH_OUT="${WORKDIR}/live-squashfs-root"
    LIVE_SQUASH_NEW="${WORKDIR}/$(basename "${LIVE_SQUASH_REL%.squashfs}")-new.squashfs"
    LIVE_SQUASH_SIZE="${WORKDIR}/$(basename "${LIVE_SQUASH_SIZE_REL}")"
    extract_from_iso "${ISO_IN}" "/${LIVE_SQUASH_REL}" "${LIVE_SQUASH_IN}"
    for MANIFEST_REL in "${LIVE_SQUASH_REL%.squashfs}.manifest" "${LIVE_SQUASH_REL%.squashfs}.manifest.full"; do
      MANIFEST_FILE="${WORKDIR}/$(basename "${MANIFEST_REL}")"
      if extract_optional_from_iso "${ISO_IN}" "/${MANIFEST_REL}" "${MANIFEST_FILE}"; then
        MANIFEST_RELS+=("${MANIFEST_REL}")
        MANIFEST_FILES+=("${MANIFEST_FILE}")
      fi
    done
  fi
fi

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

unsquashfs -no-exit-code -f -d "${SQUASH_OUT}" "${SQUASH_IN}"
if [ "${SLIM_ONLINE}" -eq 1 ]; then
  apply_slim_online_rootfs "${SQUASH_OUT}"
fi

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

patch_live_initrd "${INITRD_IN}" "${INITRD_NEW}" "${INITRD_ROOT}"

inject_data "${SQUASH_OUT}/usr/bin/umpc-display-scaler"
inject_data "${SQUASH_OUT}/etc/xdg/autostart/umpc-display-scaler.desktop"
inject_data "${SQUASH_OUT}/usr/share/applications/umpc-display-scaler.desktop"

du -sx --block-size=1 "${SQUASH_OUT}" | cut -f1 > "${SQUASH_SIZE}"

MKSQUASHFS_ARGS=("${SQUASH_OUT}" "${SQUASH_NEW}" -noappend -processors "${MKSQUASHFS_PROCESSORS:-2}")
case "${SQUASH_COMP}" in
  gzip|lzma|lzo|lz4|xz|zstd)
    MKSQUASHFS_ARGS+=(-comp "${SQUASH_COMP}")
    ;;
esac
mksquashfs "${MKSQUASHFS_ARGS[@]}"

if [ "${SLIM_ONLINE}" -eq 1 ] && [ -n "${LIVE_SQUASH_REL}" ]; then
  LIVE_SQUASH_COMP=$(unsquashfs -s "${LIVE_SQUASH_IN}" | awk '
    /^Compression/ {
      if ($0 ~ /:/) {
        sub(/^[^:]*:[ \t]*/, "", $0)
        print tolower($0)
      } else {
        print tolower($2)
      }
      exit
    }')
  unsquashfs -no-exit-code -f -d "${LIVE_SQUASH_OUT}" "${LIVE_SQUASH_IN}"
  apply_slim_online_live_rootfs "${LIVE_SQUASH_OUT}"
  du -sx --block-size=1 "${LIVE_SQUASH_OUT}" | cut -f1 > "${LIVE_SQUASH_SIZE}"

  LIVE_MKSQUASHFS_ARGS=("${LIVE_SQUASH_OUT}" "${LIVE_SQUASH_NEW}" -noappend -processors "${MKSQUASHFS_PROCESSORS:-2}")
  case "${LIVE_SQUASH_COMP}" in
    gzip|lzma|lzo|lz4|xz|zstd)
      LIVE_MKSQUASHFS_ARGS+=(-comp "${LIVE_SQUASH_COMP}")
      ;;
  esac
  mksquashfs "${LIVE_MKSQUASHFS_ARGS[@]}"
fi

if [ "${SLIM_ONLINE}" -eq 1 ]; then
  keep_minimal_install_source "${INSTALL_SOURCES}"
  for MANIFEST_FILE in "${MANIFEST_FILES[@]}"; do
    prune_slim_online_manifest "${MANIFEST_FILE}"
  done
  create_empty_layer "${STANDARD_LAYER}" "${STANDARD_SIZE}" "${STANDARD_MANIFEST}" "${STANDARD_MANIFEST_FULL}"
  filter_md5sum_for_slim_online "${MD5_FILE}"
fi

update_md5sum "${MD5_FILE}" "boot/grub/grub.cfg" "${GRUB_BOOT_CONF}"
update_md5sum "${MD5_FILE}" "boot/grub/loopback.cfg" "${GRUB_LOOPBACK_CONF}"
update_md5sum "${MD5_FILE}" "${INITRD_REL}" "${INITRD_NEW}"
update_md5sum "${MD5_FILE}" "${SQUASH_SIZE_REL}" "${SQUASH_SIZE}"
update_md5sum "${MD5_FILE}" "${SQUASH_REL}" "${SQUASH_NEW}"
if [ "${SLIM_ONLINE}" -eq 1 ]; then
  update_md5sum "${MD5_FILE}" "${INSTALL_SOURCES_REL}" "${INSTALL_SOURCES}"
  update_md5sum "${MD5_FILE}" "${STANDARD_LAYER_REL}" "${STANDARD_LAYER}"
  update_md5sum "${MD5_FILE}" "${STANDARD_SIZE_REL}" "${STANDARD_SIZE}"
  update_md5sum "${MD5_FILE}" "${STANDARD_MANIFEST_REL}" "${STANDARD_MANIFEST}"
  update_md5sum "${MD5_FILE}" "${STANDARD_MANIFEST_FULL_REL}" "${STANDARD_MANIFEST_FULL}"
  for MANIFEST_INDEX in "${!MANIFEST_FILES[@]}"; do
    update_md5sum "${MD5_FILE}" "${MANIFEST_RELS[${MANIFEST_INDEX}]}" "${MANIFEST_FILES[${MANIFEST_INDEX}]}"
  done
  if [ -n "${LIVE_SQUASH_REL}" ]; then
    update_md5sum "${MD5_FILE}" "${LIVE_SQUASH_SIZE_REL}" "${LIVE_SQUASH_SIZE}"
    update_md5sum "${MD5_FILE}" "${LIVE_SQUASH_REL}" "${LIVE_SQUASH_NEW}"
  fi
fi

rm -f "${ISO_OUT}"
VOL_ID=$(echo "${FLAVOUR}-${VERSION}-${UMPC}" | cut -c1-31)
SLIM_XORRISO_ARGS=()
SLIM_MAP_ARGS=()
if [ "${SLIM_ONLINE}" -eq 1 ]; then
  for SLIM_REMOVE_TREE in \
    /dists \
    /pool; do
    if iso_path_exists "${ISO_IN}" "${SLIM_REMOVE_TREE}"; then
      SLIM_XORRISO_ARGS+=(-rm_r "${SLIM_REMOVE_TREE}" --)
    fi
  done
  mapfile -t SLIM_REMOVE_PATHS < <(collect_slim_iso_remove_paths "${ISO_IN}")
  if [ "${#SLIM_REMOVE_PATHS[@]}" -gt 0 ]; then
    SLIM_XORRISO_ARGS+=(-rm "${SLIM_REMOVE_PATHS[@]}" --)
  fi
  SLIM_MAP_ARGS+=(-map "${INSTALL_SOURCES}" "/${INSTALL_SOURCES_REL}")
  SLIM_MAP_ARGS+=(-map "${STANDARD_LAYER}" "/${STANDARD_LAYER_REL}")
  SLIM_MAP_ARGS+=(-map "${STANDARD_SIZE}" "/${STANDARD_SIZE_REL}")
  SLIM_MAP_ARGS+=(-map "${STANDARD_MANIFEST}" "/${STANDARD_MANIFEST_REL}")
  SLIM_MAP_ARGS+=(-map "${STANDARD_MANIFEST_FULL}" "/${STANDARD_MANIFEST_FULL_REL}")
  for MANIFEST_INDEX in "${!MANIFEST_FILES[@]}"; do
    SLIM_MAP_ARGS+=(-map "${MANIFEST_FILES[${MANIFEST_INDEX}]}" "/${MANIFEST_RELS[${MANIFEST_INDEX}]}")
  done
  if [ -n "${LIVE_SQUASH_REL}" ]; then
    SLIM_MAP_ARGS+=(-map "${LIVE_SQUASH_SIZE}" "/${LIVE_SQUASH_SIZE_REL}")
    SLIM_MAP_ARGS+=(-map "${LIVE_SQUASH_NEW}" "/${LIVE_SQUASH_REL}")
  fi
fi
xorriso \
  -indev "${ISO_IN}" \
  -outdev "${ISO_OUT}" \
  -boot_image any replay \
  -volid "${VOL_ID}" \
  -overwrite on \
  "${SLIM_XORRISO_ARGS[@]}" \
  -map "${GRUB_BOOT_CONF}" /boot/grub/grub.cfg \
  -map "${GRUB_LOOPBACK_CONF}" /boot/grub/loopback.cfg \
  -map "${INITRD_NEW}" "/${INITRD_REL}" \
  -map "${SQUASH_SIZE}" "/${SQUASH_SIZE_REL}" \
  -map "${SQUASH_NEW}" "/${SQUASH_REL}" \
  "${SLIM_MAP_ARGS[@]}" \
  -map "${MD5_FILE}" /md5sum.txt \
  -commit

echo
echo "Built ${ISO_OUT}"
