#!/usr/bin/env bash
# Download, verify, and start the Debian security bootstrap from a fixed release.
set -Eeuo pipefail
IFS=$'\n\t'

readonly INSTALLER_VERSION='v1.3.3'
readonly REPOSITORY='elonjack/vps-security-bootstrap'

RELEASE_VERSION=$INSTALLER_VERSION
KEEP_FILES=0
declare -a BOOTSTRAP_ARGS=()

usage() {
  cat <<'EOF'
Usage:
  install.sh [--version vX.Y.Z] [--keep] [--firewall] [-- bootstrap.sh arguments]

Downloads bootstrap.sh and its SHA-256 file from a fixed GitHub Release,
verifies the checksum, then starts the Debian bootstrap.
EOF
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --version)
      if [ "$#" -lt 2 ] || [ -z "$2" ]; then
        die '--version requires a value.'
      fi
      RELEASE_VERSION=$2
      shift 2
      ;;
    --keep)
      KEEP_FILES=1
      shift
      ;;
    --firewall)
      BOOTSTRAP_ARGS+=("$1")
      shift
      ;;
    --)
      shift
      BOOTSTRAP_ARGS+=("$@")
      break
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown installer option: $1 (use --help)"
      ;;
  esac
done

[[ "$RELEASE_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
  die '--version must look like vX.Y.Z.'
[ "$(uname -s)" = 'Linux' ] || die 'This installer is for Debian Linux. Use install.ps1 on Windows.'
[ -r /etc/os-release ] || die 'Cannot identify the Linux distribution.'
# shellcheck disable=SC1091
. /etc/os-release
[ "${ID:-}" = 'debian' ] || die 'This installer supports Debian only.'
case "${VERSION_ID%%.*}" in
  12|13) ;;
  *) die 'This installer supports Debian 12 or 13 only.' ;;
esac
command -v curl >/dev/null 2>&1 || die 'curl is required to download the release.'
command -v sha256sum >/dev/null 2>&1 || die 'sha256sum is required to verify the release.'

WORK_DIR=$(mktemp -d -t vps-security.XXXXXXXX) || die 'Cannot create a temporary directory.'
cleanup() {
  [ "$KEEP_FILES" -eq 1 ] || rm -rf -- "$WORK_DIR"
}
trap cleanup EXIT

BASE_URL="https://github.com/$REPOSITORY/releases/download/$RELEASE_VERSION"
SCRIPT_PATH="$WORK_DIR/bootstrap.sh"
CHECKSUM_PATH="$WORK_DIR/bootstrap.sh.sha256"

printf 'Downloading %s...\n' "$RELEASE_VERSION"
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
  --connect-timeout 10 --max-time 60 \
  "$BASE_URL/bootstrap.sh" --output "$SCRIPT_PATH"
curl --fail --show-error --silent --location --proto '=https' --tlsv1.2 \
  --connect-timeout 10 --max-time 60 \
  "$BASE_URL/bootstrap.sh.sha256" --output "$CHECKSUM_PATH"

(
  cd "$WORK_DIR"
  sha256sum --check --status bootstrap.sh.sha256
) || die 'SHA-256 verification failed. The script will not run.'

chmod 0700 "$SCRIPT_PATH"
printf 'SHA-256 verified. Starting the Debian security bootstrap.\n'
if [ "$KEEP_FILES" -eq 1 ]; then
  printf 'Downloaded files are kept in: %s\n' "$WORK_DIR"
fi

# A curl pipeline makes stdin a pipe.  Interactive modes must read from the
# controlling terminal, while unattended argument-based runs keep their stdin.
NEEDS_TTY=0
if [ "${#BOOTSTRAP_ARGS[@]}" -eq 0 ]; then
  NEEDS_TTY=1
else
  for bootstrap_arg in "${BOOTSTRAP_ARGS[@]}"; do
    case "$bootstrap_arg" in
      --interactive|--firewall|--rotate-telegram-token)
        NEEDS_TTY=1
        break
        ;;
    esac
  done
fi

if [ "$NEEDS_TTY" -eq 1 ]; then
  [ -r /dev/tty ] || die 'Interactive mode requires a terminal. Run the downloaded installer from a terminal, or use unattended bootstrap arguments.'
  bash "$SCRIPT_PATH" "${BOOTSTRAP_ARGS[@]}" </dev/tty
else
  bash "$SCRIPT_PATH" "${BOOTSTRAP_ARGS[@]}"
fi
