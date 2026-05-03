#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
cd "${SCRIPT_DIR}"

UBUNTU_RELEASE="${UBUNTU_RELEASE:-26.04}"
UBUNTU_BASE_URL="${UBUNTU_BASE_URL:-https://releases.ubuntu.com/${UBUNTU_RELEASE}}"
UBUNTU_ISO_NAME="${UBUNTU_ISO_NAME:-ubuntu-${UBUNTU_RELEASE}-desktop-amd64.iso}"
DOWNLOAD_DIR="${DOWNLOAD_DIR:-downloads}"
DEVICE="gpd-pocket"
ISO_IN=""
DOWNLOAD_ONLY=0
NO_DOWNLOAD=0

function usage() {
  echo
  echo "Usage"
  echo "  $(basename "${0}") [options]"
  echo
  echo "Options"
  echo "  -d, --device DEVICE     UMPC target, default: ${DEVICE}"
  echo "  -i, --iso ISO           Use an existing Ubuntu ISO instead of downloading"
  echo "      --download-only     Download and verify the base ISO, then stop"
  echo "      --no-download       Require the ISO to already exist"
  echo "  -h, --help              Show this help"
  echo
}

function die() {
  echo "ERROR! ${*}" >&2
  exit 1
}

function validate_device() {
  case "${1}" in
    gpd-pocket|gpd-pocket2|gpd-pocket3|gpd-micropc|gpd-p2-max|gpd-win2|gpd-win3|gpd-win-max|topjoy-falcon) true;;
    *) die "Unknown device: ${1}";;
  esac
}

function download() {
  local URL="${1}"
  local OUT="${2}"

  mkdir -p "$(dirname "${OUT}")"
  curl -L --fail --continue-at - --output "${OUT}" "${URL}"
}

function verify_iso() {
  local ISO_PATH="${1}"
  local SUMS_PATH="${2}"
  local ISO_NAME
  local SUMS_REAL

  ISO_NAME=$(basename "${ISO_PATH}")
  if ! grep -F " *${ISO_NAME}" "${SUMS_PATH}" >/dev/null; then
    die "No checksum entry for ${ISO_NAME} in ${SUMS_PATH}"
  fi

  SUMS_REAL=$(realpath "${SUMS_PATH}")
  (
    cd "$(dirname "${ISO_PATH}")"
    grep -F " *${ISO_NAME}" "${SUMS_REAL}" | sha256sum -c -
  )
}

while [ "${#}" -gt 0 ]; do
  case "${1}" in
    -d|--device)
      [ "${#}" -ge 2 ] || die "${1} requires a device name"
      DEVICE="${2}"
      shift 2
      ;;
    -i|--iso)
      [ "${#}" -ge 2 ] || die "${1} requires an ISO path"
      ISO_IN="${2}"
      NO_DOWNLOAD=1
      shift 2
      ;;
    --download-only)
      DOWNLOAD_ONLY=1
      shift
      ;;
    --no-download)
      NO_DOWNLOAD=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unsupported option: ${1}"
      ;;
  esac
done

validate_device "${DEVICE}"

if [ -z "${ISO_IN}" ]; then
  ISO_IN="${DOWNLOAD_DIR}/${UBUNTU_ISO_NAME}"
fi

if [ ! -f "${ISO_IN}" ]; then
  [ "${NO_DOWNLOAD}" -eq 0 ] || die "ISO not found: ${ISO_IN}"
  download "${UBUNTU_BASE_URL}/${UBUNTU_ISO_NAME}" "${ISO_IN}"
fi

if [ "$(basename "${ISO_IN}")" = "${UBUNTU_ISO_NAME}" ]; then
  SHA256SUMS="${DOWNLOAD_DIR}/SHA256SUMS"
  if [ ! -f "${SHA256SUMS}" ] && [ "${NO_DOWNLOAD}" -eq 0 ]; then
    download "${UBUNTU_BASE_URL}/SHA256SUMS" "${SHA256SUMS}"
  fi
  [ -f "${SHA256SUMS}" ] && verify_iso "${ISO_IN}" "${SHA256SUMS}"
fi

if [ "${DOWNLOAD_ONLY}" -eq 1 ]; then
  echo "Downloaded and verified ${ISO_IN}"
  exit 0
fi

if [ "$(id -u)" -eq 0 ]; then
  ./umpc-ubuntu-respin.sh -d "${DEVICE}" "${ISO_IN}"
elif [ "${DEVICE}" = "gpd-pocket" ] && [ -x ./umpc-ubuntu-respin-rootless.sh ] && ! sudo -n true 2>/dev/null; then
  ./umpc-ubuntu-respin-rootless.sh -d "${DEVICE}" "${ISO_IN}"
else
  sudo ./umpc-ubuntu-respin.sh -d "${DEVICE}" "${ISO_IN}"
fi

ISO_OUT="$(basename "${ISO_IN}" .iso)-${DEVICE}.iso"
echo
echo "Built ${ISO_OUT}"
