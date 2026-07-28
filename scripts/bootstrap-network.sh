#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="debian-first-network-kit"
VERSION="1.0.0"
LOG_FILE=/var/log/debian-first-network-kit.log
[[ -z "${DFNK_LOG_FILE:-}" ]] || LOG_FILE="$DFNK_LOG_FILE"

DFNK_SYS_CLASS_NET="${DFNK_SYS_CLASS_NET:-/sys/class/net}"
DFNK_OS_RELEASE_FILE="${DFNK_OS_RELEASE_FILE:-/etc/os-release}"
DFNK_IFUPDOWN_ROOT="${DFNK_IFUPDOWN_ROOT:-/etc/network}"
if [[ -n "${DFNK_NETWORKD_DIR:-}" ]]; then
  DFNK_NETWORKD_DIR="$DFNK_NETWORKD_DIR"
  DFNK_NETWORKD_SEARCH_DIRS="${DFNK_NETWORKD_SEARCH_DIRS:-$DFNK_NETWORKD_DIR}"
else
  DFNK_NETWORKD_DIR=/etc/systemd/network
  DFNK_NETWORKD_SEARCH_DIRS="${DFNK_NETWORKD_SEARCH_DIRS:-/etc/systemd/network /run/systemd/network /usr/lib/systemd/network}"
fi
DFNK_RUN_DIR="${DFNK_RUN_DIR:-/run}"
DFNK_LOCK_FILE="${DFNK_LOCK_FILE:-$DFNK_RUN_DIR/debian-first-network-kit.lock}"
ASSUME_YES=0
DO_APT=1
DO_SSH=1
REQUESTED_INTERFACE=""
FALLBACK_DNS=(1.1.1.1 9.9.9.9)
SHOW_HELP=0
NETWORKD_FALLBACK_APPROVED=0

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
        (($# >= 2)) || { die "--interface requires an interface name"; return $?; }
        [[ -n "$2" && "$2" != --* ]] || { die "--interface requires an interface name"; return $?; }
        REQUESTED_INTERFACE="$2"
        shift 2
        ;;
      --dns)
        (($# >= 2)) || { die "--dns requires an address"; return $?; }
        [[ -n "$2" && "$2" != --* ]] || { die "--dns requires an address"; return $?; }
        FALLBACK_DNS+=("$2")
        shift 2
        ;;
      --no-apt) DO_APT=0; shift ;;
      --no-ssh) DO_SSH=0; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --help) SHOW_HELP=1; shift ;;
      *) die "unknown option: $1"; return $? ;;
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
    12:bookworm | 13:trixie) printf '%s\n' "$codename" ;;
    *)
      printf 'Unsupported Debian release: %s (%s)\n' "$version" "$codename" >&2
      return 1
      ;;
  esac
}

validate_interface_name() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,14}$ ]]
}

backup_stamp() {
  date -u +%Y%m%dT%H%M%SZ
}

backup_path() {
  local target="$1" candidate sequence=0
  while :; do
    candidate="$target.debian-first-network-kit.$(backup_stamp).$$.$RANDOM.$sequence.bak"
    [[ ! -e "$candidate" && ! -L "$candidate" ]] && break
    ((sequence += 1))
  done
  printf '%s\n' "$candidate"
}

create_private_log() {
  touch -- "$LOG_FILE"
  chown root:root -- "$LOG_FILE"
  chmod 0600 -- "$LOG_FILE"
}

log_message() {
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE"
}

backup_file() {
  local target="$1" backup
  [[ -e "$target" || -L "$target" ]] || return 0
  backup="$(backup_path "$target")"
  cp -a --update=none -- "$target" "$backup"
  log_message "Backed up $target to $backup"
}

acquire_mutation_lock() {
  command -v flock >/dev/null 2>&1 || {
    printf 'flock is required to safely apply network changes.\n' >&2
    return 1
  }
  mkdir -p -- "$DFNK_RUN_DIR" || return 1
  exec {DFNK_LOCK_FD}>"$DFNK_LOCK_FILE"
  flock -n "$DFNK_LOCK_FD" || {
    printf 'Another %s run is already applying network changes.\n' "$PROGRAM" >&2
    return 1
  }
}

confirm_execution() {
  ((ASSUME_YES)) && return 0
  local answer
  printf 'This may reconfigure network services. Continue? [y/N] ' >&2
  read -r answer || return 1
  [[ "$answer" == "y" || "$answer" == "Y" || "$answer" == "yes" || "$answer" == "YES" ]]
}

render_networkd_config() {
  local interface="$1"
  validate_interface_name "$interface" || return 1
  printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "$interface"
}

render_debian_sources() {
  local codename="$1" signed_by="${2:-}"
  printf 'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: %s %s-updates\nComponents: main contrib non-free non-free-firmware\n' "$codename" "$codename"
  [[ -z "$signed_by" ]] || printf 'Signed-By: %s\n' "$signed_by"
  printf '\nTypes: deb\nURIs: https://security.debian.org/debian-security\nSuites: %s-security\nComponents: main contrib non-free non-free-firmware\n' "$codename"
  [[ -z "$signed_by" ]] || printf 'Signed-By: %s\n' "$signed_by"
}

is_virtual_interface_name() {
  case "$1" in
    lo | docker* | veth* | br-* | bond* | dummy* | tun* | tap* | wg* | zt* | ifb* | virbr* | wl*) return 0 ;;
    *) return 1 ;;
  esac
}

is_wired_candidate() {
  local interface="$1" path resolved
  validate_interface_name "$interface" || return 1
  is_virtual_interface_name "$interface" && return 1
  path="$DFNK_SYS_CLASS_NET/$interface"
  [[ -d "$path" && -d "$path/device" && ! -d "$path/wireless" ]] || return 1
  resolved="$(readlink -f -- "$path" 2>/dev/null || printf '%s' "$path")"
  [[ "$resolved" != */virtual/net/* ]]
}

list_wired_interfaces() {
  local path interface
  for path in "$DFNK_SYS_CLASS_NET"/*; do
    [[ -d "$path" ]] || continue
    interface="${path##*/}"
    is_wired_candidate "$interface" || continue
    printf '%s\n' "$interface"
  done | LC_ALL=C sort
}

carrier_of() {
  local interface="$1" carrier_file carrier
  validate_interface_name "$interface" || return 1
  carrier_file="$DFNK_SYS_CLASS_NET/$interface/carrier"
  [[ -r "$carrier_file" ]] || return 1
  IFS= read -r carrier <"$carrier_file" || true
  [[ "$carrier" == "0" || "$carrier" == "1" ]] || return 1
  printf '%s\n' "$carrier"
}

choose_unique_carrier() {
  local interface active_interface="" active_count=0 carrier
  for interface in "$@"; do
    carrier="$(carrier_of "$interface")" || continue
    [[ "$carrier" == "1" ]] || continue
    active_interface="$interface"
    ((active_count += 1))
  done
  ((active_count == 1)) || return 1
  printf '%s\n' "$active_interface"
}

select_wired_interface() {
  local -a candidates=()
  local selected choice index
  mapfile -t candidates < <(list_wired_interfaces)
  if [[ -n "$REQUESTED_INTERFACE" ]]; then
    is_wired_candidate "$REQUESTED_INTERFACE" || {
      printf 'Requested interface is not an available wired NIC: %s\n' "$REQUESTED_INTERFACE" >&2
      return 1
    }
    printf '%s\n' "$REQUESTED_INTERFACE"
    return 0
  fi
  case "${#candidates[@]}" in
    0) printf 'No physical wired network interfaces were found.\n' >&2; return 1 ;;
    1) printf '%s\n' "${candidates[0]}"; return 0 ;;
  esac
  selected="$(choose_unique_carrier "${candidates[@]}")" && { printf '%s\n' "$selected"; return 0; }
  if ((ASSUME_YES)); then
    printf 'Multiple wired NICs are ambiguous; rerun with --interface IFACE.\n' >&2
    return 1
  fi
  printf 'Select a wired interface:\n' >&2
  for index in "${!candidates[@]}"; do
    printf '  %d) %s\n' "$((index + 1))" "${candidates[index]}" >&2
  done
  printf '> ' >&2
  read -r choice || return 1
  [[ "$choice" =~ ^[0-9]+$ ]] || return 1
  ((choice >= 1 && choice <= ${#candidates[@]})) || return 1
  printf '%s\n' "${candidates[choice - 1]}"
}

wait_for_carrier() {
  local interface="$1" attempt carrier
  for ((attempt = 0; attempt < 10; attempt += 1)); do
    carrier="$(carrier_of "$interface")" || carrier=0
    [[ "$carrier" == 1 ]] && return 0
    sleep 1
  done
  printf 'No physical carrier detected on %s. Check the cable and switch port.\n' "$interface" >&2
  return 1
}

bring_link_up() {
  local interface="$1"
  validate_interface_name "$interface" || return 1
  ip link set dev "$interface" up
  wait_for_carrier "$interface"
}

has_ipv4_address() {
  local interface="$1"
  validate_interface_name "$interface" || return 1
  ip -4 -o addr show dev "$interface" scope global | grep -q ' inet '
}

has_default_route() {
  local interface="$1"
  validate_interface_name "$interface" || return 1
  ip -4 route show default dev "$interface" | grep -q .
}

has_ipv4_and_default_route() {
  has_ipv4_address "$1" && has_default_route "$1"
}

wait_for_ipv4_and_default_route() {
  local interface="$1" attempt
  for ((attempt = 0; attempt < 30; attempt += 1)); do
    has_ipv4_and_default_route "$interface" && return 0
    sleep 1
  done
  printf 'DHCP did not obtain an IPv4 address and default route on %s within 30 seconds.\n' "$interface" >&2
  return 1
}

service_is_active() {
  systemctl is-active --quiet "$1"
}

networkmanager_manages_interface() {
  validate_interface_name "$1" || return 1
  command -v nmcli >/dev/null 2>&1 || return 1
  [[ "$(nmcli -g GENERAL.MANAGED device show "$1" 2>/dev/null)" == yes ]]
}

networkd_effective_network_file() {
  local interface="$1" status network_file
  validate_interface_name "$interface" || return 1
  command -v networkctl >/dev/null 2>&1 || return 1
  status="$(networkctl status "$interface" --no-pager 2>&1 || true)"
  network_file="$(awk -F: '/^[[:space:]]*Network File:/ { sub(/^[[:space:]]*/, "", $2); print $2; exit }' <<<"$status")"
  [[ -n "$network_file" && "$network_file" != n/a ]] || return 1
  printf '%s\n' "$network_file"
}

networkd_manages_interface() {
  networkd_effective_network_file "$1" >/dev/null
}

ensure_no_manager_conflict() {
  local interface="$1" ifup_method
  networkmanager_manages_interface "$interface" && networkd_manages_interface "$interface" && {
    printf 'Refusing to change %s: NetworkManager and systemd-networkd both manage it.\n' "$1" >&2
    return 1
  }
  ifup_method="$(ifupdown_method "$interface" 2>/dev/null || true)"
  [[ -z "$ifup_method" ]] || ! networkd_manages_interface "$interface" || {
    printf 'Refusing to change %s: ifupdown (%s) and systemd-networkd both manage it.\n' "$interface" "$ifup_method" >&2
    return 1
  }
  return 0
}

ifupdown_method() {
  local interface="$1" config method found_dhcp=0
  validate_interface_name "$interface" || return 1
  for config in "$DFNK_IFUPDOWN_ROOT/interfaces" "$DFNK_IFUPDOWN_ROOT/interfaces.d"/*; do
    [[ -r "$config" ]] || continue
    while IFS= read -r method; do
      [[ -n "$method" ]] || continue
      if [[ "$method" != dhcp ]]; then
        printf '%s\n' "$method"
        return 0
      fi
      found_dhcp=1
    done < <(awk -v target="$interface" '
      $1 == "iface" && $2 == target && $3 == "inet" && $4 != "" { print $4 }
    ' "$config")
  done
  ((found_dhcp)) && { printf 'dhcp\n'; return 0; }
  return 1
}

ifupdown_is_configured() {
  ifupdown_method "$1" >/dev/null
}

networkd_config_path() {
  local interface="$1"
  validate_interface_name "$interface" || return 1
  printf '%s/20-debian-first-network-%s.network\n' "$DFNK_NETWORKD_DIR" "$interface"
}

network_file_could_match_interface() {
  local file="$1" interface="$2" line section="" name pattern saw_match=0 saw_name=0
  validate_interface_name "$interface" || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      \[*\]) section="$line"; continue ;;
    esac
    [[ "$section" == "[Match]" ]] || continue
    saw_match=1
    [[ "$line" == Name=* ]] || continue
    saw_name=1
    name="${line#Name=}"
    for pattern in $name; do
      [[ "$pattern" == "!"* ]] && continue
      [[ "$interface" == $pattern ]] && return 0
    done
  done <"$file"
  ((!saw_match || !saw_name)) && return 0
  return 1
}

foreign_networkd_match_exists() {
  local interface="$1" project directory file
  project="$(networkd_config_path "$interface")" || return 1
  for directory in $DFNK_NETWORKD_SEARCH_DIRS; do
    for file in "$directory"/*.network; do
      [[ -f "$file" || -L "$file" ]] || continue
      [[ "$file" == "$project" ]] && continue
      network_file_could_match_interface "$file" "$interface" && {
        printf 'Refusing to write project networkd config: foreign matching file exists: %s\n' "$file" >&2
        return 0
      }
    done
  done
  return 1
}

write_networkd_config() (
  local interface="$1" target temporary
  target="$(networkd_config_path "$interface")" || return 1
  mkdir -p -- "$DFNK_NETWORKD_DIR" || return 1
  foreign_networkd_match_exists "$interface" && return 1
  temporary="$(mktemp "$DFNK_NETWORKD_DIR/.debian-first-network.XXXXXX")" || return 1
  cleanup_networkd_temporary() { rm -f -- "$temporary"; }
  trap cleanup_networkd_temporary EXIT INT TERM
  if ! render_networkd_config "$interface" >"$temporary"; then
    return 1
  fi
  if [[ -f "$target" ]] && cmp -s -- "$temporary" "$target"; then
    return 0
  fi
  if ! backup_file "$target" || ! install -m 0644 -- "$temporary" "$target"; then
    return 1
  fi
  log_message "Wrote systemd-networkd DHCP configuration: $target"
)

verify_project_networkd_effective_file() {
  local interface="$1" target actual
  command -v networkctl >/dev/null 2>&1 || return 0
  target="$(networkd_config_path "$interface")" || return 1
  actual="$(networkd_effective_network_file "$interface" 2>/dev/null || true)"
  [[ -z "$actual" || "$actual" == "$target" ]] || {
    printf 'systemd-networkd selected %s for %s instead of project config %s.\n' "$actual" "$interface" "$target" >&2
    return 1
  }
}

configure_networkd_dhcp() {
  local interface="$1"
  write_networkd_config "$interface" || return 1
  if ! service_is_active systemd-networkd; then
    systemctl enable --now systemd-networkd || return 1
  fi
  command -v networkctl >/dev/null 2>&1 || {
    printf 'networkctl is required to reload and reconfigure systemd-networkd safely.\n' >&2
    return 1
  }
  networkctl reload || {
    printf 'systemd-networkd reload failed; no daemon-wide restart was attempted.\n' >&2
    return 1
  }
  networkctl reconfigure "$interface" || {
    printf 'systemd-networkd could not reconfigure %s; no daemon-wide restart was attempted.\n' "$interface" >&2
    return 1
  }
  verify_project_networkd_effective_file "$interface"
}

determine_recovery_backend() {
  local interface="$1" method
  if has_ipv4_and_default_route "$interface"; then
    printf 'existing IPv4/default route (no DHCP change)\n'
  elif service_is_active NetworkManager && command -v nmcli >/dev/null 2>&1; then
    printf 'NetworkManager\n'
  elif service_is_active systemd-networkd; then
    printf 'systemd-networkd\n'
  elif method="$(ifupdown_method "$interface" 2>/dev/null || true)"; [[ -n "$method" ]]; then
    printf 'ifupdown (%s)\n' "$method"
  else
    printf 'systemd-networkd fallback\n'
  fi
}

print_recovery_plan() {
  local interface="$1" backend="$2" method target fallback='none'
  target="$(networkd_config_path "$interface")" || return 1
  method="$(ifupdown_method "$interface" 2>/dev/null || true)"
  [[ "$backend" == "ifupdown (dhcp)" && "$method" == dhcp ]] &&
    fallback='if ifup fails, use the project systemd-networkd DHCP configuration'
  printf 'Network recovery plan:\n'
  printf '  NIC: %s\n' "$interface"
  printf '  Backend: %s\n' "$backend"
  printf '  Project networkd file: %s\n' "$target"
  printf '  Services: NetworkManager is used only when active; systemd-networkd is enabled/started only when needed, then reloaded and reconfigured for this NIC.\n'
  printf '  Potential fallback: %s\n' "$fallback"
}

recover_dhcp() {
  local interface="$1" ifup_method
  has_ipv4_and_default_route "$interface" && {
    log_message "IPv4 address and default route already present on $interface; no DHCP change needed"
    return 0
  }
  ensure_no_manager_conflict "$interface" || return 1
  ifup_method="$(ifupdown_method "$interface" 2>/dev/null || true)"
  [[ -z "$ifup_method" || "$ifup_method" == dhcp ]] || {
    printf 'Refusing to replace intentional ifupdown %s configuration on %s.\n' "$ifup_method" "$interface" >&2
    return 1
  }
  if service_is_active NetworkManager && command -v nmcli >/dev/null 2>&1; then
    log_message "Requesting DHCP through NetworkManager on $interface"
    if ! nmcli device set "$interface" managed yes; then
      log_message "NetworkManager failed to manage $interface"
      printf 'NetworkManager could not mark %s as managed.\n' "$interface" >&2
      return 1
    fi
    if ! nmcli device connect "$interface"; then
      log_message "NetworkManager failed to connect $interface"
      printf 'NetworkManager could not activate %s.\n' "$interface" >&2
      return 1
    fi
  elif service_is_active systemd-networkd; then
    log_message "Configuring active systemd-networkd DHCP on $interface"
    configure_networkd_dhcp "$interface" || return 1
  elif [[ "$ifup_method" == dhcp ]]; then
    log_message "Requesting DHCP through ifupdown on $interface"
    if ! command -v ifup >/dev/null 2>&1 || ! ifup "$interface"; then
      ((NETWORKD_FALLBACK_APPROVED)) || {
        printf 'ifupdown could not configure %s; systemd-networkd fallback was not approved in the plan.\n' "$interface" >&2
        return 1
      }
      log_message "Approved ifupdown fallback to systemd-networkd for $interface"
      printf 'ifupdown could not configure %s; applying the approved systemd-networkd fallback.\n' "$interface" >&2
      configure_networkd_dhcp "$interface" || return 1
    fi
  else
    log_message "Configuring fallback systemd-networkd DHCP on $interface"
    configure_networkd_dhcp "$interface" || return 1
  fi
  wait_for_ipv4_and_default_route "$interface"
}

read_os_release_value() {
  local key="$1" line value
  [[ -r "$DFNK_OS_RELEASE_FILE" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "$key="* ]] || continue
    value="${line#*=}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s\n' "$value"
    return 0
  done <"$DFNK_OS_RELEASE_FILE"
  return 1
}

main() {
  parse_args "$@" || return $?
  if ((SHOW_HELP)); then
    usage
    return 0
  fi
  ((EUID == 0)) || die "must be run as root (use sudo)"
  create_private_log
  local distro version codename interface backend ifup_method
  distro="$(read_os_release_value ID)" || die "cannot read ID from $DFNK_OS_RELEASE_FILE"
  version="$(read_os_release_value VERSION_ID)" || die "cannot read VERSION_ID from $DFNK_OS_RELEASE_FILE"
  codename="$(read_os_release_value VERSION_CODENAME)" || die "cannot read VERSION_CODENAME from $DFNK_OS_RELEASE_FILE"
  validate_debian_release "$distro" "$version" "$codename" >/dev/null || return 1
  interface="$(select_wired_interface)" || return 1
  ensure_no_manager_conflict "$interface" || return 1
  backend="$(determine_recovery_backend "$interface")" || return 1
  print_recovery_plan "$interface" "$backend" || return 1
  ifup_method="$(ifupdown_method "$interface" 2>/dev/null || true)"
  [[ -z "$ifup_method" || "$ifup_method" == dhcp ]] || {
    printf 'Refusing to replace intentional ifupdown %s configuration on %s.\n' "$ifup_method" "$interface" >&2
    return 1
  }
  confirm_execution || die "cancelled"
  [[ "$backend" != "ifupdown (dhcp)" ]] || NETWORKD_FALLBACK_APPROVED=1
  acquire_mutation_lock || return 1
  log_message "Selected wired interface: $interface"
  log_message "Approved network recovery plan: backend=$backend interface=$interface"
  bring_link_up "$interface" || return 1
  recover_dhcp "$interface" || return 1
  log_message "DHCP recovery completed on $interface"
  printf 'Network recovery completed on %s.\n' "$interface"
}

if [[ "${BASH_SOURCE[0]}" == "$0" && "${DFNK_SOURCE_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
