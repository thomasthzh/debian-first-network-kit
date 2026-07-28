#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bootstrap="$repo_root/scripts/bootstrap-network.sh"
diagnose="$repo_root/scripts/diagnose-network.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$actual" == "$expected" ]] ||
    fail "$label: expected [$expected], got [$actual]"
}

[[ -f "$bootstrap" ]] || fail "missing $bootstrap"
bash -n "$bootstrap"

# shellcheck disable=SC1090
export DFNK_SOURCE_ONLY=1
source "$bootstrap"
unset DFNK_SOURCE_ONLY

if ! validate_interface_name enp2s0; then
  fail "ordinary Ethernet interface name must be accepted"
fi
if validate_interface_name ../bad >/dev/null 2>&1; then
  fail "unsafe interface name must be rejected"
fi
stamp="$(backup_stamp)"
[[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
  fail "backup stamp must be UTC in YYYYMMDDTHHMMSSZ format: $stamp"

parse_args --dns 8.8.8.8 --dns 208.67.222.222
assert_eq "1.1.1.1 9.9.9.9 8.8.8.8 208.67.222.222" "${FALLBACK_DNS[*]}" \
  "DNS options append to fallbacks"

assert_eq "bookworm" "$(validate_debian_release debian 12 bookworm)" \
  "Debian 12 validation"
assert_eq "trixie" "$(validate_debian_release debian 13 trixie)" \
  "Debian 13 validation"

if validate_debian_release ubuntu 24 noble >/dev/null 2>&1; then
  fail "Ubuntu must be rejected"
fi
if validate_debian_release debian 11 bullseye >/dev/null 2>&1; then
  fail "Unsupported Debian version must be rejected"
fi
if validate_debian_release debian 12 trixie >/dev/null 2>&1; then
  fail "Debian codename mismatch must be rejected"
fi

expected_networkd=$'[Match]\nName=enp2s0\n\n[Network]\nDHCP=yes'
assert_eq "$expected_networkd" "$(render_networkd_config enp2s0)" \
  "networkd render"

expected_bookworm_sources=$'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: bookworm bookworm-updates\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: https://security.debian.org/debian-security\nSuites: bookworm-security\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg'
assert_eq "$expected_bookworm_sources" \
  "$(render_debian_sources bookworm /usr/share/keyrings/debian-archive-keyring.gpg)" \
  "bookworm sources render"

expected_trixie_sources=$'Types: deb\nURIs: https://deb.debian.org/debian\nSuites: trixie trixie-updates\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg\n\nTypes: deb\nURIs: https://security.debian.org/debian-security\nSuites: trixie-security\nComponents: main contrib non-free non-free-firmware\nSigned-By: /usr/share/keyrings/debian-archive-keyring.gpg'
assert_eq "$expected_trixie_sources" \
  "$(render_debian_sources trixie /usr/share/keyrings/debian-archive-keyring.gpg)" \
  "trixie sources render"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch"/{lo,br-test,brcm0,bridge-test,docker0,enp1s0,enp2s0,virbr0,wlfake0,wlp3s0}
mkdir -p "$scratch/br-test/device" "$scratch/brcm0/device" "$scratch/bridge-test/device" \
  "$scratch/enp1s0/device" "$scratch/enp2s0/device" "$scratch/wlp3s0/wireless" \
  "$scratch/wlfake0/device" "$scratch/virbr0/device"
printf '0\n' >"$scratch/enp1s0/carrier"
printf '1\n' >"$scratch/enp2s0/carrier"
printf '1\n' >"$scratch/wlp3s0/carrier"

mapfile -t interfaces < <(DFNK_SYS_CLASS_NET="$scratch" list_wired_interfaces)
assert_eq "4" "${#interfaces[@]}" "wired interface count"
assert_eq "brcm0" "${interfaces[0]}" "physical brcm interface retained"
assert_eq "bridge-test" "${interfaces[1]}" "physical bridge interface retained"
assert_eq "enp1s0" "${interfaces[2]}" "third wired interface"
assert_eq "enp2s0" "${interfaces[3]}" "fourth wired interface"
assert_eq "enp2s0" "$(DFNK_SYS_CLASS_NET="$scratch" choose_unique_carrier "${interfaces[@]}")" \
  "carrier selection"

printf '1\n' >"$scratch/enp1s0/carrier"
if DFNK_SYS_CLASS_NET="$scratch" choose_unique_carrier "${interfaces[@]}" >/dev/null; then
  fail "ambiguous active carriers must be rejected"
fi

printf '0\n' >"$scratch/enp1s0/carrier"
printf '0\n' >"$scratch/enp2s0/carrier"
if DFNK_SYS_CLASS_NET="$scratch" choose_unique_carrier "${interfaces[@]}" >/dev/null; then
  fail "no active carrier must be rejected"
fi

mkdir -p "$scratch/network/interfaces.d"
printf 'iface enp2s0 inet dhcp\n' >"$scratch/network/interfaces"
if ! DFNK_IFUPDOWN_ROOT="$scratch/network" ifupdown_is_configured enp2s0; then
  fail "ifupdown DHCP stanza must be detected"
fi
printf 'iface enp2s0 inet static\n  address 192.0.2.10/24\n' >"$scratch/network/interfaces.d/10-static"
assert_eq "static" "$(DFNK_IFUPDOWN_ROOT="$scratch/network" ifupdown_method enp2s0)" \
  "non-DHCP stanza in sourced interfaces.d takes ownership"
rm -f -- "$scratch/network/interfaces.d/10-static"
printf 'iface enp2s0 inet static\n  address 192.0.2.10/24\n' >"$scratch/network/interfaces"
if ! DFNK_IFUPDOWN_ROOT="$scratch/network" ifupdown_is_configured enp2s0; then
  fail "ifupdown static stanza must retain ownership"
fi
assert_eq "static" "$(DFNK_IFUPDOWN_ROOT="$scratch/network" ifupdown_method enp2s0)" \
  "ifupdown static ownership method"

LOG_FILE="$scratch/bootstrap.log"
has_ipv4_and_default_route() { return 1; }
ensure_no_manager_conflict() { return 0; }
if DFNK_IFUPDOWN_ROOT="$scratch/network" recover_dhcp enp2s0 >/dev/null 2>&1; then
  fail "non-DHCP ifupdown ownership must refuse recovery"
fi
unset -f has_ipv4_and_default_route ensure_no_manager_conflict

ASSUME_YES=1
if DFNK_SYS_CLASS_NET="$scratch" select_wired_interface >/dev/null 2>&1; then
  fail "ambiguous wired NICs must require --interface under --yes"
fi
ASSUME_YES=0

printf 'iface enp2s0 inet manual\n' >"$scratch/network/interfaces"
assert_eq "manual" "$(DFNK_IFUPDOWN_ROOT="$scratch/network" ifupdown_method enp2s0)" \
  "ifupdown ownership method"

fake_bin="$scratch/fake-bin"
mkdir -p "$fake_bin"
printf '%s\n' '#!/usr/bin/env bash' 'case "$1" in' '  status) printf "%s\n" "${FAKE_NETWORKCTL_STATUS:-}" ;;' '  reload | reconfigure) exit 0 ;;' '  *) exit 1 ;;' 'esac' >"$fake_bin/networkctl"
printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >>"$FAKE_SYSTEMCTL_LOG"' 'exit 0' >"$fake_bin/systemctl"
chmod +x "$fake_bin/networkctl" "$fake_bin/systemctl"
saved_path="$PATH"
PATH="$fake_bin:$PATH"
export PATH
export FAKE_NETWORKCTL_STATUS=$'Setup State: failed\nNetwork File: /etc/systemd/network/10-foreign.network'
networkmanager_manages_interface() { return 0; }
if ensure_no_manager_conflict enp2s0 >/dev/null 2>&1; then
  fail "NetworkManager and failed-state networkd ownership must conflict"
fi
unset -f networkmanager_manages_interface

first_backup_path="$(backup_path "$scratch/source")"
second_backup_path="$(backup_path "$scratch/source")"
[[ "$first_backup_path" != "$second_backup_path" ]] || fail "backup paths must be unique"
printf 'original\n' >"$scratch/source"
backup_file "$scratch/source"
backup_file "$scratch/source"
mapfile -t created_backups < <(compgen -G "$scratch/source.debian-first-network-kit.*.bak" || true)
[[ "${#created_backups[@]}" == 2 ]] || fail "backup must be created without clobbering"

DFNK_NETWORKD_DIR="$scratch/networkd"
DFNK_NETWORKD_SEARCH_DIRS="$DFNK_NETWORKD_DIR"
mkdir -p "$DFNK_NETWORKD_DIR"
write_networkd_config enp2s0
networkd_project_config="$(networkd_config_path enp2s0)"
first_networkd_config="$(<"$networkd_project_config")"
write_networkd_config enp2s0
assert_eq "$first_networkd_config" "$(<"$networkd_project_config")" "project networkd config idempotency"
rm -f -- "$networkd_project_config"
printf '[Match]\nName=enp2s0\n\n[Network]\nDHCP=no\n' >"$DFNK_NETWORKD_DIR/10-foreign.network"
if write_networkd_config enp2s0 >/dev/null 2>&1; then
  fail "foreign matching networkd configuration must be refused"
fi
rm -f -- "$DFNK_NETWORKD_DIR/10-foreign.network"

fake_systemctl_log="$scratch/systemctl.log"
export FAKE_SYSTEMCTL_LOG="$fake_systemctl_log"
export FAKE_NETWORKCTL_STATUS="$(printf 'Setup State: configured\nNetwork File: %s' "$(networkd_config_path enp2s0)")"
configure_networkd_dhcp enp2s0
if grep -Fq 'restart systemd-networkd' "$fake_systemctl_log"; then
  fail "normal networkd reconfigure must not restart all links"
fi
PATH="$saved_path"
export PATH
unset FAKE_NETWORKCTL_STATUS FAKE_SYSTEMCTL_LOG

"$bootstrap" --help >/dev/null
[[ -f "$diagnose" ]] || fail "missing $diagnose"
bash -n "$diagnose"
# shellcheck disable=SC1090
source "$diagnose"

redacted="$(printf '%s\n' \
  'URIs: https://user:topsecret@example.invalid/debian' \
  'Mirror: https://token-only-secret@example.invalid/debian' \
  'password=hunter2 token: abc123 Authorization: token ghp_authsecret api-key=key-secret' \
  'access_token=access-secret refresh_token: refresh-secret client_secret=client-secret github_token: github-secret' \
  'psk=wifi-psk-material wifi_psk: wifi-profile-material private_key=private-key-material' \
  'proxy credentials: Bearer bearer-secret' \
  'safe setting: keep-this-value' \
  'password authentication disabled' | redact_sensitive)"
grep -Fq 'topsecret' <<<"$redacted" && fail "URI credentials must be redacted"
grep -Fq 'token-only-secret' <<<"$redacted" && fail "token-only URI credentials must be redacted"
grep -Fq 'hunter2' <<<"$redacted" && fail "password values must be redacted"
grep -Fq 'abc123' <<<"$redacted" && fail "token values must be redacted"
grep -Fq 'ghp_authsecret' <<<"$redacted" && fail "authorization values must be redacted"
grep -Fq 'bearer-secret' <<<"$redacted" && fail "Bearer tokens must be redacted"
grep -Fq 'key-secret' <<<"$redacted" && fail "API key values must be redacted"
grep -Fq 'access-secret' <<<"$redacted" && fail "access_token values must be redacted"
grep -Fq 'refresh-secret' <<<"$redacted" && fail "refresh_token values must be redacted"
grep -Fq 'client-secret' <<<"$redacted" && fail "client_secret values must be redacted"
grep -Fq 'github-secret' <<<"$redacted" && fail "github_token values must be redacted"
grep -Fq 'wifi-psk-material' <<<"$redacted" && fail "psk values must be redacted"
grep -Fq 'wifi-profile-material' <<<"$redacted" && fail "wifi_psk values must be redacted"
grep -Fq 'private-key-material' <<<"$redacted" && fail "private_key values must be redacted"
grep -Fq 'https://[REDACTED]@example.invalid/debian' <<<"$redacted" ||
  fail "URI redaction must retain the host and path"
grep -Fq 'Mirror: https://[REDACTED]@example.invalid/debian' <<<"$redacted" ||
  fail "token-only URI redaction must retain the host and path"
grep -Fq 'safe setting: keep-this-value' <<<"$redacted" ||
  fail "safe text must be retained"
grep -Fq 'password authentication disabled' <<<"$redacted" ||
  fail "safe prose must remain readable"
"$diagnose" --help >/dev/null
if "$diagnose" --unknown >/dev/null 2>&1; then
  fail "unknown diagnose option must fail"
else
  assert_eq "2" "$?" "unknown diagnose option exit status"
fi

printf 'All smoke tests passed.\n'
