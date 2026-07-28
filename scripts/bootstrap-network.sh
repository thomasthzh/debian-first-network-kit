#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="debian-first-network-kit"
VERSION="1.0.0"

DFNK_SYS_CLASS_NET="${DFNK_SYS_CLASS_NET:-/sys/class/net}"
ASSUME_YES=0
DO_APT=1
DO_SSH=1
REQUESTED_INTERFACE=""
FALLBACK_DNS=(1.1.1.1 9.9.9.9)
SHOW_HELP=0

usage() {
  cat <<EOF
Usage: $PROGRAM [OPTIONS]

Options:
  --interface IFACE  Use IFACE instead of automatic wired-interface selection.
  --dns ADDRESS      Append a fallback DNS server (may be repeated).
  --no-apt           Do not configure APT.
  --no-ssh           Do not configure SSH.
  --yes              Do not ask for confirmation.
  --help             Show this help text.
EOF
}

die() {
  printf '%s: %s\n' "$PROGRAM" "$*" >&2
  return 2
}

parse_args() {
  while (($#)); do
    case "$1" in
      --interface)
        (($# >= 2)) || die "--interface requires an interface name" || return $?
        [[ -n "$2" && "$2" != --* ]] || die "--interface requires an interface name" || return $?
        REQUESTED_INTERFACE="$2"
        shift 2
        ;;
      --dns)
        (($# >= 2)) || die "--dns requires an address" || return $?
        [[ -n "$2" && "$2" != --* ]] || die "--dns requires an address" || return $?
        FALLBACK_DNS+=("$2")
        shift 2
        ;;
      --no-apt)
        DO_APT=0
        shift
        ;;
      --no-ssh)
        DO_SSH=0
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --help)
        SHOW_HELP=1
        shift
        ;;
      *)
        die "unknown option: $1" || return $?
        ;;
    esac
  done
}

validate_debian_release() {
  local distro="$1" version="$2" codename="$3"

  [[ "$distro" == "debian" ]] || {
    printf 'Unsupported distribution: %s\n' "$distro" >&2
    return 1
  }

  case "$version:$codename" in
    12:bookworm | 13:trixie)
      printf '%s\n' "$codename"
      ;;
    *)
      printf 'Unsupported Debian release: %s (%s)\n' "$version" "$codename" >&2
      return 1
      ;;
  esac
}

render_networkd_config() {
  local interface="$1"
  printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "$interface"
}

render_debian_sources() {
  local codename="$1" signed_by="${2:-}"

  printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: %s %s-updates\nComponents: main contrib non-free non-free-firmware\n' \
    "$codename" "$codename"
  [[ -z "$signed_by" ]] || printf 'Signed-By: %s\n' "$signed_by"
  printf '\nTypes: deb\nURIs: https://security.debian.org/debian-security\nSuites: %s-security\nComponents: main contrib non-free non-free-firmware\n' \
    "$codename"
  [[ -z "$signed_by" ]] || printf 'Signed-By: %s\n' "$signed_by"
}

is_virtual_interface_name() {
  case "$1" in
    lo | docker* | veth* | br-* | bond* | dummy* | tun* | tap* | wg* | zt* | ifb* | virbr* | wl*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

list_wired_interfaces() {
  local path interface
  for path in "$DFNK_SYS_CLASS_NET"/*; do
    [[ -d "$path" ]] || continue
    interface="${path##*/}"
    is_virtual_interface_name "$interface" && continue
    [[ -d "$path/device" ]] || continue
    [[ ! -d "$path/wireless" ]] || continue
    printf '%s\n' "$interface"
  done | LC_ALL=C sort
}

carrier_of() {
  local carrier_file="$DFNK_SYS_CLASS_NET/$1/carrier"
  [[ -r "$carrier_file" ]] || return 1
  local carrier
  IFS= read -r carrier <"$carrier_file" || true
  [[ "$carrier" == "0" || "$carrier" == "1" ]] || return 1
  printf '%s\n' "$carrier"
}

choose_unique_carrier() {
  local interface active_interface="" active_count=0 carrier

  for interface in "$@"; do
    carrier=$(carrier_of "$interface") || continue
    [[ "$carrier" == "1" ]] || continue
    active_interface="$interface"
    ((active_count += 1))
  done

  ((active_count == 1)) || return 1
  printf '%s\n' "$active_interface"
}

main() {
  parse_args "$@"
  if ((SHOW_HELP)); then
    usage
    return 0
  fi
  printf '%s %s\n' "$PROGRAM" "$VERSION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" && "${DFNK_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
