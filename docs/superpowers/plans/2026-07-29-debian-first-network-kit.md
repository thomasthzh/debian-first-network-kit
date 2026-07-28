# Debian First Network Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build and publish a USB-portable Debian 12/13 first-network recovery kit that restores wired DHCP, DNS, official APT sources, and OpenSSH, with a read-only diagnostic tool and a complete Chinese installation guide.

**Architecture:** Two standalone Bash entrypoints keep diagnosis separate from mutation. `bootstrap-network.sh` exposes pure render/discovery functions behind a `main` guard so a dependency-free smoke test can validate interface selection and generated configuration without touching the host; all real writes are root-only, backed up, and idempotent. Documentation and the full project are copied to the verified Kingston data partition, then the same Git history is published to a new public GitHub repository.

**Tech Stack:** Bash 5, iproute2, systemd-networkd, NetworkManager when present, APT, OpenSSH, Git, GitHub CLI, PowerShell for Windows-to-USB copy verification.

---

## File map

- `.gitattributes`: keep shell scripts LF-only when edited or copied from Windows.
- `.gitignore`: exclude local logs, test scratch files, and editor artifacts.
- `README.md`: project overview, quick start, safety boundary, documentation index.
- `README.en.md`: equivalent English quick start, options, and safety boundary.
- `LICENSE`: MIT license.
- `CHANGELOG.md`: initial release notes.
- `scripts/bootstrap-network.sh`: state-changing recovery workflow.
- `scripts/diagnose-network.sh`: read-only evidence collection.
- `tests/smoke-test.sh`: dependency-free Bash syntax and pure-function tests.
- `docs/installation-guide.md`: ISO verification, boot-media choices, installer choices, and first boot.
- `docs/troubleshooting.md`: symptom-to-layer diagnosis and manual recovery commands.
- `docs/superpowers/specs/2026-07-29-debian-first-network-kit-design.md`: approved design.
- `docs/superpowers/plans/2026-07-29-debian-first-network-kit.md`: this execution plan.

### Task 1: Add repository metadata and line-ending policy

**Files:**
- Create: `.gitattributes`
- Create: `.gitignore`
- Create: `LICENSE`
- Create: `CHANGELOG.md`

- [ ] **Step 1: Add LF and ignore rules**

Create `.gitattributes`:

```gitattributes
*.sh text eol=lf
*.md text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
```

Create `.gitignore`:

```gitignore
*.log
*.tmp
*.bak
.DS_Store
Thumbs.db
tests/.scratch/
```

- [ ] **Step 2: Add MIT license and changelog**

Create `LICENSE` with the standard MIT text, copyright:

```text
Copyright (c) 2026 THZH
```

Create `CHANGELOG.md`:

```markdown
# Changelog

## 1.0.0 - 2026-07-29

- Add Debian 12/13 wired-network bootstrap script.
- Add read-only network diagnostic script.
- Add ISO, Ventoy, installer, partitioning, and troubleshooting guides.
```

- [ ] **Step 3: Validate and commit**

Run:

```powershell
git diff --check
git add .gitattributes .gitignore LICENSE CHANGELOG.md
git commit -m "Add repository metadata"
```

Expected: `git diff --check` has no output; commit succeeds.

### Task 2: Build the pure-function smoke-test harness

**Files:**
- Create: `tests/smoke-test.sh`
- Test: `tests/smoke-test.sh`

- [ ] **Step 1: Write tests that initially fail because the bootstrap script is absent**

Create `tests/smoke-test.sh`:

```bash
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
source "$bootstrap"

assert_eq "bookworm" "$(validate_debian_release debian 12 bookworm)" \
  "Debian 12 validation"
assert_eq "trixie" "$(validate_debian_release debian 13 trixie)" \
  "Debian 13 validation"

if validate_debian_release ubuntu 24 noble >/dev/null 2>&1; then
  fail "Ubuntu must be rejected"
fi

expected_networkd=$'[Match]\nName=enp2s0\n\n[Network]\nDHCP=yes'
assert_eq "$expected_networkd" "$(render_networkd_config enp2s0)" \
  "networkd render"

sources="$(render_debian_sources trixie /usr/share/keyrings/debian-archive-keyring.gpg)"
grep -q '^Suites: trixie trixie-updates$' <<<"$sources" ||
  fail "missing trixie suites"
grep -q '^Suites: trixie-security$' <<<"$sources" ||
  fail "missing security suite"
grep -q '^Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg$' <<<"$sources" ||
  fail "missing keyring"

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir -p "$scratch"/{lo,enp1s0,enp2s0,wlp3s0,docker0}
mkdir -p "$scratch/enp1s0/device" "$scratch/enp2s0/device" "$scratch/wlp3s0/wireless"
printf '0\n' >"$scratch/enp1s0/carrier"
printf '1\n' >"$scratch/enp2s0/carrier"
printf '1\n' >"$scratch/wlp3s0/carrier"

mapfile -t interfaces < <(DFNK_SYS_CLASS_NET="$scratch" list_wired_interfaces)
assert_eq "2" "${#interfaces[@]}" "wired interface count"
assert_eq "enp1s0" "${interfaces[0]}" "first wired interface"
assert_eq "enp2s0" "${interfaces[1]}" "second wired interface"
assert_eq "enp2s0" "$(DFNK_SYS_CLASS_NET="$scratch" choose_unique_carrier "${interfaces[@]}")" \
  "carrier selection"

"$bootstrap" --help >/dev/null
[[ -f "$diagnose" ]] || fail "missing $diagnose"
bash -n "$diagnose"
"$diagnose" --help >/dev/null

printf 'All smoke tests passed.\n'
```

- [ ] **Step 2: Run and verify the expected failure**

Run:

```powershell
wsl.exe -e bash -lc 'cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && bash tests/smoke-test.sh'
```

Expected: exits non-zero with `missing .../scripts/bootstrap-network.sh`.

- [ ] **Step 3: Commit the test harness**

Run:

```powershell
git add tests/smoke-test.sh
git commit -m "Add network kit smoke tests"
```

### Task 3: Implement bootstrap argument parsing and pure render/discovery functions

**Files:**
- Create: `scripts/bootstrap-network.sh`
- Test: `tests/smoke-test.sh`

- [ ] **Step 1: Add the script header, CLI, OS validation, and pure functions**

Create `scripts/bootstrap-network.sh` with:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="debian-first-network-kit"
VERSION="1.0.0"
DFNK_SYS_CLASS_NET="${DFNK_SYS_CLASS_NET:-/sys/class/net}"

ASSUME_YES=0
DO_APT=1
DO_SSH=1
REQUESTED_INTERFACE=""
FALLBACK_DNS=("1.1.1.1" "9.9.9.9")

usage() {
  cat <<'EOF'
Usage: sudo bash bootstrap-network.sh [options]

Options:
  --interface IFACE  Use this wired interface.
  --dns ADDRESS      Append a fallback DNS server; repeatable.
  --no-apt           Do not configure APT or run apt update.
  --no-ssh           Do not install or start OpenSSH.
  --yes              Accept planned file and service changes.
  --help              Show this help.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  return 1
}

validate_debian_release() {
  local id="$1" version_id="$2" codename="$3"
  [[ "$id" == "debian" ]] || die "Only Debian is supported."
  case "$version_id" in
    12) [[ "$codename" == "bookworm" ]] || die "Debian 12 must use bookworm." ;;
    13) [[ "$codename" == "trixie" ]] || die "Debian 13 must use trixie." ;;
    *) die "Only Debian 12 and Debian 13 are supported." ;;
  esac
  printf '%s\n' "$codename"
}

render_networkd_config() {
  local interface="$1"
  printf '[Match]\nName=%s\n\n[Network]\nDHCP=yes\n' "$interface"
}

render_debian_sources() {
  local codename="$1" keyring="${2:-}"
  cat <<EOF
Types: deb
URIs: https://deb.debian.org/debian
Suites: ${codename} ${codename}-updates
Components: main contrib non-free non-free-firmware
EOF
  [[ -n "$keyring" ]] && printf 'Signed-By: %s\n' "$keyring"
  cat <<EOF

Types: deb
URIs: https://security.debian.org/debian-security
Suites: ${codename}-security
Components: main contrib non-free non-free-firmware
EOF
  [[ -n "$keyring" ]] && printf 'Signed-By: %s\n' "$keyring"
}

is_virtual_interface_name() {
  case "$1" in
    lo|docker*|veth*|virbr*|br-*|bond*|dummy*|tun*|tap*|wg*|zt*|ifb*) return 0 ;;
    *) return 1 ;;
  esac
}

list_wired_interfaces() {
  local root="${DFNK_SYS_CLASS_NET}" entry name
  for entry in "$root"/*; do
    [[ -e "$entry" ]] || continue
    name="${entry##*/}"
    is_virtual_interface_name "$name" && continue
    [[ -d "$entry/wireless" ]] && continue
    [[ "$name" == wl* ]] && continue
    [[ -e "$entry/device" ]] || continue
    printf '%s\n' "$name"
  done | sort
}

carrier_of() {
  local interface="$1" file="${DFNK_SYS_CLASS_NET}/${interface}/carrier"
  [[ -r "$file" ]] && tr -d '\r\n' <"$file" || printf '0'
}

choose_unique_carrier() {
  local found="" interface count=0
  for interface in "$@"; do
    if [[ "$(carrier_of "$interface")" == "1" ]]; then
      found="$interface"
      ((count += 1))
    fi
  done
  [[ "$count" -eq 1 ]] || return 1
  printf '%s\n' "$found"
}

parse_args() {
  while (($#)); do
    case "$1" in
      --interface)
        (($# >= 2)) || die "--interface requires a value."
        REQUESTED_INTERFACE="$2"
        shift 2
        ;;
      --dns)
        (($# >= 2)) || die "--dns requires a value."
        FALLBACK_DNS+=("$2")
        shift 2
        ;;
      --no-apt) DO_APT=0; shift ;;
      --no-ssh) DO_SSH=0; shift ;;
      --yes) ASSUME_YES=1; shift ;;
      --help) usage; exit 0 ;;
      *) die "Unknown option: $1" ;;
    esac
  done
}

main() {
  parse_args "$@"
  printf '%s %s\n' "$PROGRAM" "$VERSION"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 2: Run the smoke test and inspect the remaining expected failure**

Run:

```powershell
wsl.exe -e bash -lc 'cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && bash tests/smoke-test.sh'
```

Expected: bootstrap pure-function assertions pass; test then stops because `diagnose-network.sh` is absent.

- [ ] **Step 3: Commit the pure bootstrap core**

Run:

```powershell
git add scripts/bootstrap-network.sh
git commit -m "Add bootstrap discovery and render core"
```

### Task 4: Implement the read-only diagnostic script

**Files:**
- Create: `scripts/diagnose-network.sh`
- Test: `tests/smoke-test.sh`

- [ ] **Step 1: Implement read-only collection**

Create `scripts/diagnose-network.sh`:

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
Usage: bash diagnose-network.sh [--help]

Collects read-only Debian network, DNS, APT, and SSH evidence.
It does not change configuration.
EOF
}

section() {
  printf '\n=== %s ===\n' "$1"
}

run_optional() {
  local command="$1"
  shift
  if command -v "$command" >/dev/null 2>&1; then
    "$command" "$@" 2>&1 || true
  else
    printf '%s: not installed\n' "$command"
  fi
}

main() {
  case "${1:-}" in
    "") ;;
    --help) usage; return 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
  esac

  section "SYSTEM"
  if [[ -r /etc/os-release ]]; then
    grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release || true
  fi
  uname -a

  section "LINKS"
  ip -br link 2>&1 || true
  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    name="${path##*/}"
    printf '%s carrier=' "$name"
    [[ -r "$path/carrier" ]] && cat "$path/carrier" || printf 'n/a\n'
  done

  section "ADDRESSES"
  ip -br address 2>&1 || true

  section "ROUTES"
  ip route 2>&1 || true

  section "DNS"
  ls -l /etc/resolv.conf 2>&1 || true
  sed -n '1,40p' /etc/resolv.conf 2>&1 || true
  getent ahosts deb.debian.org 2>&1 || true

  section "NETWORK MANAGERS"
  for service in NetworkManager systemd-networkd networking; do
    printf '%s: ' "$service"
    systemctl is-active "$service" 2>/dev/null || true
  done
  run_optional nmcli device status
  run_optional networkctl list

  section "APT"
  grep -RhsE '^[[:space:]]*(deb |Types:|URIs:|Suites:|Components:|Signed-By:)' \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null || true
  apt-cache policy openssh-server 2>&1 || true

  section "SSH"
  systemctl status ssh --no-pager 2>&1 || true
  run_optional ss -lntp

  section "RECENT LOGS"
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager -n 120 2>/dev/null |
      grep -Ei 'link|carrier|dhcp|dns|network|firmware|acpi' |
      tail -n 80 || true
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
```

- [ ] **Step 2: Run tests**

Run:

```powershell
wsl.exe -e bash -lc 'cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && bash tests/smoke-test.sh'
```

Expected: `All smoke tests passed.`

- [ ] **Step 3: Commit**

Run:

```powershell
git add scripts/diagnose-network.sh
git commit -m "Add read-only network diagnostics"
```

### Task 5: Implement safe host mutation, DHCP, and logging

**Files:**
- Modify: `scripts/bootstrap-network.sh`
- Modify: `tests/smoke-test.sh`

- [ ] **Step 1: Extend tests for idempotent backup naming and interface validation**

Append before the final success message in `tests/smoke-test.sh`:

```bash
assert_eq "enp2s0" \
  "$(DFNK_SYS_CLASS_NET="$scratch" validate_interface_name enp2s0)" \
  "valid interface"
if DFNK_SYS_CLASS_NET="$scratch" validate_interface_name '../bad' >/dev/null 2>&1; then
  fail "unsafe interface name must be rejected"
fi

stamp="$(backup_stamp)"
[[ "$stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] ||
  fail "backup stamp has unexpected format: $stamp"
```

- [ ] **Step 2: Run the test and verify failure**

Run the smoke test.

Expected: failure mentioning `validate_interface_name: command not found`.

- [ ] **Step 3: Add logging, confirmation, selection, backup, and DHCP functions**

Add to `scripts/bootstrap-network.sh` before `main`:

```bash
LOG_FILE="/var/log/debian-first-network-kit.log"

log() {
  printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" | tee -a "$LOG_FILE"
}

backup_stamp() {
  date -u +%Y%m%dT%H%M%SZ
}

validate_interface_name() {
  local interface="$1"
  [[ "$interface" =~ ^[a-zA-Z0-9_.:-]+$ ]] ||
    die "Unsafe interface name: $interface"
  [[ -e "${DFNK_SYS_CLASS_NET}/${interface}" ]] ||
    die "Interface does not exist: $interface"
  printf '%s\n' "$interface"
}

backup_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  cp -a -- "$path" "${path}.${PROGRAM}.$(backup_stamp).bak"
}

confirm_plan() {
  ((ASSUME_YES)) && return 0
  printf 'This will configure wired DHCP and may update DNS/APT/SSH. Continue? [y/N] '
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]] || die "Cancelled."
}

select_interface() {
  local -a interfaces=()
  local interface selected=""
  mapfile -t interfaces < <(list_wired_interfaces)
  ((${#interfaces[@]})) || die "No wired Ethernet interface was found."

  if [[ -n "$REQUESTED_INTERFACE" ]]; then
    validate_interface_name "$REQUESTED_INTERFACE"
    printf '%s\n' "$REQUESTED_INTERFACE"
    return
  fi

  if ((${#interfaces[@]} == 1)); then
    printf '%s\n' "${interfaces[0]}"
    return
  fi

  if selected="$(choose_unique_carrier "${interfaces[@]}")"; then
    printf '%s\n' "$selected"
    return
  fi

  ((ASSUME_YES)) && die "Multiple wired interfaces are ambiguous; use --interface."
  printf 'Select a wired interface:\n' >&2
  select interface in "${interfaces[@]}"; do
    [[ -n "$interface" ]] && printf '%s\n' "$interface" && return
  done
}

bring_link_up() {
  local interface="$1" attempt
  ip link set dev "$interface" up
  for attempt in {1..10}; do
    [[ "$(carrier_of "$interface")" == "1" ]] && return 0
    sleep 1
  done
  die "$interface is UP but has no physical carrier (LOWER_UP)."
}

has_ipv4() {
  ip -4 -o address show dev "$1" scope global | grep -q .
}

has_default_route() {
  ip -4 route show default dev "$1" | grep -q '^default '
}

render_and_write_networkd() {
  local interface="$1"
  local target="/etc/systemd/network/20-debian-first-network-${interface}.network"
  mkdir -p /etc/systemd/network
  if [[ -f "$target" ]] &&
     cmp -s <(render_networkd_config "$interface") "$target"; then
    log "networkd configuration is already current: $target"
  else
    backup_path "$target"
    render_networkd_config "$interface" >"$target"
    chmod 0644 "$target"
  fi
  systemctl enable --now systemd-networkd
  networkctl reconfigure "$interface" 2>/dev/null ||
    systemctl restart systemd-networkd
}

configure_dhcp() {
  local interface="$1"
  if has_ipv4 "$interface" && has_default_route "$interface"; then
    log "$interface already has IPv4 and a default route."
    return 0
  fi

  guard_manager_conflicts "$interface"

  if systemctl is-active --quiet NetworkManager &&
     command -v nmcli >/dev/null 2>&1; then
    nmcli device set "$interface" managed yes
    nmcli device connect "$interface"
  elif systemctl is-active --quiet systemd-networkd; then
    render_and_write_networkd "$interface"
  elif grep -RqsE "^[[:space:]]*(auto|allow-hotplug)[[:space:]]+${interface}([[:space:]]|$)" \
       /etc/network/interfaces /etc/network/interfaces.d 2>/dev/null; then
    ifup "$interface" || render_and_write_networkd "$interface"
  else
    render_and_write_networkd "$interface"
  fi

  for _ in {1..30}; do
    has_ipv4 "$interface" && has_default_route "$interface" && return 0
    sleep 1
  done
  die "DHCP timed out on $interface."
}

guard_manager_conflicts() {
  local interface="$1" nm_managed=0 networkd_managed=0
  if systemctl is-active --quiet NetworkManager &&
     command -v nmcli >/dev/null 2>&1 &&
     ! nmcli -g GENERAL.STATE device show "$interface" 2>/dev/null |
       grep -qi 'unmanaged'; then
    nm_managed=1
  fi
  if systemctl is-active --quiet systemd-networkd &&
     networkctl status "$interface" 2>/dev/null |
       grep -q 'Network File:'; then
    networkd_managed=1
  fi
  if ((nm_managed && networkd_managed)); then
    die "$interface appears managed by both NetworkManager and systemd-networkd."
  fi
}
```

Replace `main` with:

```bash
main() {
  parse_args "$@"
  [[ "$(id -u)" -eq 0 ]] || die "Run with sudo: sudo bash $0"
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"

  # shellcheck disable=SC1091
  source /etc/os-release
  CODENAME="$(validate_debian_release "${ID:-}" "${VERSION_ID:-}" "${VERSION_CODENAME:-}")"

  confirm_plan
  INTERFACE="$(select_interface)"
  log "Selected interface: $INTERFACE"
  bring_link_up "$INTERFACE"
  configure_dhcp "$INTERFACE"
}
```

- [ ] **Step 4: Run tests and commit**

Run:

```powershell
wsl.exe -e bash -lc 'cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && bash tests/smoke-test.sh'
git diff --check
git add scripts/bootstrap-network.sh tests/smoke-test.sh
git commit -m "Add safe wired DHCP recovery"
```

Expected: smoke tests pass; diff check is clean.

### Task 6: Implement DNS, official APT sources, and OpenSSH

**Files:**
- Modify: `scripts/bootstrap-network.sh`
- Modify: `tests/smoke-test.sh`

- [ ] **Step 1: Add resolver rendering test**

Append before the final success message in `tests/smoke-test.sh`:

```bash
expected_resolver=$'# Generated by debian-first-network-kit\nnameserver 192.0.2.1\nnameserver 1.1.1.1'
assert_eq "$expected_resolver" \
  "$(render_resolv_conf 192.0.2.1 1.1.1.1)" \
  "resolver render"
```

- [ ] **Step 2: Run and verify failure**

Expected: `render_resolv_conf: command not found`.

- [ ] **Step 3: Add DNS, APT, SSH, and final summary functions**

Add before `main`:

```bash
default_gateway() {
  ip -4 route show default dev "$1" |
    awk 'NR == 1 { for (i=1; i<=NF; i++) if ($i=="via") print $(i+1) }'
}

render_resolv_conf() {
  printf '# Generated by %s\n' "$PROGRAM"
  for server in "$@"; do
    [[ -n "$server" ]] && printf 'nameserver %s\n' "$server"
  done
}

dns_works() {
  getent ahosts deb.debian.org >/dev/null 2>&1
}

repair_dns() {
  local interface="$1" gateway
  dns_works && { log "DNS resolution already works."; return 0; }
  gateway="$(default_gateway "$interface")"
  [[ -n "$gateway" ]] || die "Cannot repair DNS without a default gateway."
  backup_path /etc/resolv.conf
  rm -f /etc/resolv.conf
  render_resolv_conf "$gateway" "${FALLBACK_DNS[@]}" >/etc/resolv.conf
  chmod 0644 /etc/resolv.conf
  dns_works || die "DNS still fails after resolver recovery."
}

configure_apt_sources() {
  local codename="$1"
  local target="/etc/apt/sources.list.d/debian-first-network-kit.sources"
  local keyring="" content
  [[ -f /usr/share/keyrings/debian-archive-keyring.gpg ]] &&
    keyring="/usr/share/keyrings/debian-archive-keyring.gpg"
  mkdir -p /etc/apt/sources.list.d
  content="$(render_debian_sources "$codename" "$keyring")"
  if [[ -f "$target" ]] &&
     cmp -s <(printf '%s\n' "$content") "$target"; then
    log "APT source configuration is already current: $target"
  else
    backup_path "$target"
    printf '%s\n' "$content" >"$target"
    chmod 0644 "$target"
  fi
  apt-get update
}

install_ssh() {
  DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server
  systemctl enable --now ssh
  systemctl is-active --quiet ssh || die "SSH did not become active."
}

print_summary() {
  local interface="$1" address
  address="$(ip -4 -o address show dev "$interface" scope global |
    awk 'NR == 1 { split($4,a,"/"); print a[1] }')"
  printf '\nRecovery complete.\n'
  printf 'Interface: %s\n' "$interface"
  printf 'IPv4: %s\n' "${address:-unavailable}"
  if ((DO_SSH)); then
    printf 'SSH: active on port 22\n'
    printf 'Connect: ssh <user>@%s\n' "${address:-<server-ip>}"
  fi
  printf 'Log: %s\n' "$LOG_FILE"
}
```

Extend `main` after `configure_dhcp "$INTERFACE"`:

```bash
  repair_dns "$INTERFACE"
  if ((DO_APT)); then
    configure_apt_sources "$CODENAME"
  fi
  if ((DO_SSH)); then
    ((DO_APT)) || die "--no-apt cannot be combined with automatic SSH installation."
    install_ssh
  fi
  print_summary "$INTERFACE"
```

- [ ] **Step 4: Run tests and commit**

Run smoke tests and `git diff --check`.

Commit:

```powershell
git add scripts/bootstrap-network.sh tests/smoke-test.sh
git commit -m "Add DNS APT and SSH recovery"
```

### Task 7: Add default-Chinese and optional-English output

**Files:**
- Modify: `scripts/bootstrap-network.sh`
- Modify: `scripts/diagnose-network.sh`
- Modify: `tests/smoke-test.sh`

- [ ] **Step 1: Add failing bilingual CLI tests**

Append before the final success message in `tests/smoke-test.sh`:

```bash
zh_help="$("$bootstrap" --help)"
en_help="$("$bootstrap" --lang en --help)"
grep -q '用法：' <<<"$zh_help" || fail "default help must be Chinese"
grep -q '^Usage:' <<<"$en_help" || fail "English help is missing"

zh_diagnose="$("$diagnose" --help)"
en_diagnose="$("$diagnose" --lang en --help)"
grep -q '只读' <<<"$zh_diagnose" || fail "diagnostic default help must be Chinese"
grep -q 'read-only' <<<"$en_diagnose" || fail "diagnostic English help is missing"

if "$bootstrap" --lang fr --help >/dev/null 2>&1; then
  fail "unsupported language must be rejected"
fi
```

- [ ] **Step 2: Run and verify failure**

Expected: the default-help Chinese assertion fails because both scripts still emit English.

- [ ] **Step 3: Add stable message keys and language parsing**

In `scripts/bootstrap-network.sh`, add:

```bash
LANG_CODE="zh"

msg() {
  local key="$1"
  case "${LANG_CODE}:${key}" in
    zh:usage) printf '用法：sudo bash bootstrap-network.sh [选项]\n' ;;
    en:usage) printf 'Usage: sudo bash bootstrap-network.sh [options]\n' ;;
    zh:confirm) printf '将配置有线 DHCP，并可能更新 DNS、APT 和 SSH。继续吗？[y/N] ' ;;
    en:confirm) printf 'Configure wired DHCP and possibly update DNS, APT and SSH? [y/N] ' ;;
    zh:only_debian) printf '仅支持 Debian 12/13。' ;;
    en:only_debian) printf 'Only Debian 12/13 is supported.' ;;
    zh:complete) printf '网络恢复完成。' ;;
    en:complete) printf 'Network recovery complete.' ;;
    *) printf '[%s]' "$key" ;;
  esac
}
```

Update argument parsing:

```bash
      --lang)
        (($# >= 2)) || die "--lang requires zh or en."
        case "$2" in
          zh|en) LANG_CODE="$2" ;;
          *) die "Unsupported language: $2" ;;
        esac
        shift 2
        ;;
```

Make `usage`, confirmation, supported-release errors, progress labels, and summary call `msg` keys. Keep generated configuration comments in English.

In `scripts/diagnose-network.sh`, parse `--lang zh|en` before `--help`, default `LANG_CODE=zh`, and route section titles through:

```bash
title() {
  local key="$1"
  case "${LANG_CODE}:${key}" in
    zh:system) printf '系统' ;; en:system) printf 'SYSTEM' ;;
    zh:links) printf '链路' ;; en:links) printf 'LINKS' ;;
    zh:addresses) printf '地址' ;; en:addresses) printf 'ADDRESSES' ;;
    zh:routes) printf '路由' ;; en:routes) printf 'ROUTES' ;;
    zh:dns) printf 'DNS' ;; en:dns) printf 'DNS' ;;
    zh:managers) printf '网络管理器' ;; en:managers) printf 'NETWORK MANAGERS' ;;
    zh:apt) printf 'APT 软件源' ;; en:apt) printf 'APT' ;;
    zh:ssh) printf 'SSH 服务' ;; en:ssh) printf 'SSH' ;;
    zh:logs) printf '最近日志' ;; en:logs) printf 'RECENT LOGS' ;;
  esac
}
```

- [ ] **Step 4: Run tests and commit**

Run smoke tests and `git diff --check`.

Commit:

```powershell
git add scripts/bootstrap-network.sh scripts/diagnose-network.sh tests/smoke-test.sh
git commit -m "Add Chinese and English CLI output"
```

### Task 8: Write the installation and boot-media guide

**Files:**
- Create: `docs/installation-guide.md`

- [ ] **Step 1: Document image selection and integrity**

The guide must link directly to:

```text
https://www.debian.org/CD/
https://www.debian.org/CD/verify
https://www.debian.org/releases/trixie/installmanual
```

Include Windows and Linux verification examples:

```powershell
Get-FileHash .\debian-13.x.x-amd64-netinst.iso -Algorithm SHA512
```

```bash
sha512sum debian-13.x.x-amd64-netinst.iso
```

State that the result must match Debian’s signed `SHA512SUMS`.

- [ ] **Step 2: Document Ventoy, Rufus, and direct-write choices**

Include this decision table:

| Method | Best for | Erases USB | Multiple ISOs |
|---|---|---:|---:|
| Ventoy | Reusable multi-boot service USB | On first install | Yes |
| Rufus | Simple single-image Windows workflow | Yes | No |
| `dd` | Minimal Linux tooling | Yes | No |

For Ventoy, cite:

```text
https://www.ventoy.net/en/doc_start.html
https://www.ventoy.net/en/doc_secondary_boot_menu.html
https://www.ventoy.net/en/doc_checksum.html
```

Specify Normal first, GRUB2 only after a Normal failure, Memdisk not recommended for Debian netinst, and File checksum after copying.

- [ ] **Step 3: Document firmware and installer choices**

Include:

- UEFI first; use one-time boot menu;
- Secure Boot may stay enabled for official Debian, while Ventoy may require first-boot key enrollment;
- `Graphical install` changes only installer UI;
- five Debian partition recipes and their exact mount points;
- recommend “all files in one partition” for a simple single-disk home server;
- recommend server recipe only when `/srv` and `/var` isolation is intentional;
- tasksel: deselect desktops, select SSH server and Standard system utilities.

- [ ] **Step 4: Document first-boot USB execution**

Use device-safe commands:

```bash
lsblk -o NAME,MODEL,SERIAL,SIZE,FSTYPE,LABEL,MOUNTPOINTS
sudo mkdir -p /mnt/first-network-kit
sudo mount /dev/disk/by-label/THZH_MULTI /mnt/first-network-kit
cd /mnt/first-network-kit/debian-first-network-kit
bash scripts/diagnose-network.sh
sudo bash scripts/bootstrap-network.sh
```

Explain that users with another volume label must select the correct partition from `lsblk`, not copy the example blindly.

- [ ] **Step 5: Commit**

Run Markdown link/text checks, then:

```powershell
git add docs/installation-guide.md
git commit -m "Document Debian installation workflow"
```

### Task 9: Write troubleshooting and bilingual README

**Files:**
- Create: `docs/troubleshooting.md`
- Create: `README.md`
- Create: `README.en.md`

- [ ] **Step 1: Write symptom-driven troubleshooting**

Include exact evidence commands:

```bash
ip -br link
ip -4 -br address
ip route
cat /sys/class/net/INTERFACE/carrier
getent ahosts deb.debian.org
grep -RhsE '^[[:space:]]*(deb |Types:|URIs:|Suites:|Components:|Signed-By:)' \
  /etc/apt/sources.list /etc/apt/sources.list.d
apt-cache policy openssh-server
systemctl status ssh --no-pager
```

Map:

- `DOWN` → administrative state;
- `UP` without `LOWER_UP` → physical carrier;
- carrier but no address → DHCP manager;
- address but no default route → route;
- IP works but hostname fails → DNS;
- no package candidate → sources/index;
- missing `ssh.service` → package not installed;
- ACPI BIOS warnings that do not halt boot → firmware warning, not proof of network failure.

- [ ] **Step 2: Write README quick start and safety**

README must contain:

```bash
bash scripts/diagnose-network.sh
sudo bash scripts/bootstrap-network.sh
```

Also include:

- Debian 12/13 support matrix;
- default changes and backup policy;
- CLI options;
- documentation links;
- clear non-goals;
- MIT license;
- no `curl | sh` installation.

Create `README.en.md` with the same support matrix, quick-start commands, CLI options, backup policy, non-goals, and license. Link the two README files at the top:

```markdown
[English](README.en.md)
```

```markdown
[中文](README.md)
```

Document that scripts default to Chinese and accept:

```bash
sudo bash scripts/bootstrap-network.sh --lang en
bash scripts/diagnose-network.sh --lang en
```

- [ ] **Step 3: Commit**

```powershell
git add README.md README.en.md docs/troubleshooting.md
git commit -m "Add usage and troubleshooting guides"
```

### Task 10: Run local validation and privacy review

**Files:**
- Modify only if validation identifies defects.

- [ ] **Step 1: Run syntax and smoke tests**

Run:

```powershell
wsl.exe -e bash -lc 'cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && bash -n scripts/bootstrap-network.sh && bash -n scripts/diagnose-network.sh && bash tests/smoke-test.sh'
```

Expected: `All smoke tests passed.`

- [ ] **Step 2: Run optional ShellCheck**

Run:

```powershell
wsl.exe -e bash -lc 'if command -v shellcheck >/dev/null; then cd "/mnt/c/Users/thoma/Desktop/服务器硬件选购/debian-first-network-kit" && shellcheck scripts/*.sh tests/*.sh; else echo "ShellCheck not installed; skipped"; fi'
```

Expected: no ShellCheck findings, or the explicit skip message.

- [ ] **Step 3: Scan for private session data and formatting defects**

Run:

```powershell
rg -n -i --glob '!docs/superpowers/plans/2026-07-29-debian-first-network-kit.md' 'gh[oprsu]_[A-Za-z0-9_]+|GITHUB_TOKEN|password[[:space:]]*[:=][[:space:]]*[^<[:space:]]+|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3}|([0-9a-f]{2}:){5}[0-9a-f]{2}' .
git diff --check
git status -sb
```

Expected: privacy scan returns no matches; diff check is silent; working tree is clean after any fixes are committed.

- [ ] **Step 4: Tag the release**

Run:

```powershell
git tag -a v1.0.0 -m "Debian First Network Kit 1.0.0"
```

### Task 11: Copy to the verified Kingston data partition

**Files:**
- Copy project tree to: `G:\debian-first-network-kit`
- Do not modify: `H:\`
- Do not modify: `G:\ISO\`

- [ ] **Step 1: Reconfirm the exact USB device**

Run:

```powershell
Get-CimInstance Win32_DiskDrive |
  Where-Object { $_.Model -match 'Kingston DataTraveler' } |
  Select-Object Index,Model,Size,SerialNumber
Get-Volume -DriveLetter G,H |
  Select-Object DriveLetter,FileSystemLabel,FileSystem,Size,HealthStatus
```

Expected: Kingston serial `6E07A4414AC9`; `G:` label `THZH_MULTI`; `H:` label `MSI_BIOS`.

- [ ] **Step 2: Copy only tracked project content**

Use a temporary Git archive to exclude `.git` and local artifacts. If the destination already contains a recognizable older copy of this project, move that exact directory to a timestamped backup before extracting; if it is not recognizable, stop:

```powershell
$repo = 'C:\Users\thoma\Desktop\服务器硬件选购\debian-first-network-kit'
$target = 'G:\debian-first-network-kit'
if (Test-Path -LiteralPath $target) {
  $recognized = (Test-Path -LiteralPath (Join-Path $target 'README.md')) -and
    (Test-Path -LiteralPath (Join-Path $target 'scripts\bootstrap-network.sh'))
  if (-not $recognized) { throw "Refusing to replace unrecognized directory: $target" }
  $backup = "G:\debian-first-network-kit.backup-$(Get-Date -Format yyyyMMdd-HHmmss)"
  Move-Item -LiteralPath $target -Destination $backup
}
$archive = Join-Path $env:TEMP 'debian-first-network-kit.zip'
git -C $repo archive --format=zip --output=$archive HEAD
Expand-Archive -LiteralPath $archive -DestinationPath $target
```

The backup is recoverable and remains on the USB until the user removes it.

- [ ] **Step 3: Verify USB file hashes**

For every tracked file:

```powershell
$tracked = git -C $repo ls-files
foreach ($relative in $tracked) {
  $source = Join-Path $repo $relative
  $target = Join-Path 'G:\debian-first-network-kit' $relative
  if (-not (Test-Path -LiteralPath $target)) { throw "Missing USB file: $relative" }
  $a = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
  $b = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
  if ($a -ne $b) { throw "USB hash mismatch: $relative" }
}
'USB hash verification passed.'
```

Expected: all tracked files exist and hashes match.

### Task 12: Publish the completed release to the public GitHub repository

**Files:**
- No project content changes expected.

- [ ] **Step 1: Recheck GitHub authentication and the existing baseline repository**

Run:

```powershell
gh auth status
gh repo view thomasthzh/debian-first-network-kit `
  --json nameWithOwner,visibility,url,defaultBranchRef
```

Expected: authenticated as `thomasthzh`; repository is public and its default branch is `main`.

- [ ] **Step 2: Push the completed main branch and release tag**

Run:

```powershell
git remote get-url origin
git push origin main
git push origin v1.0.0
```

Expected: the existing repository receives the completed `main` branch and tag `v1.0.0`.

- [ ] **Step 3: Verify remote contents**

Run:

```powershell
gh repo view thomasthzh/debian-first-network-kit `
  --json nameWithOwner,visibility,url,defaultBranchRef
gh api repos/thomasthzh/debian-first-network-kit/contents `
  --jq '.[].name'
git status -sb
```

Expected:

- visibility `PUBLIC`;
- default branch `main`;
- root includes README, LICENSE, scripts, tests, and docs;
- local branch tracks `origin/main`;
- working tree is clean.

### Task 13: Final delivery summary

**Files:**
- No changes.

- [ ] **Step 1: Capture final evidence**

Record:

- latest commit and `v1.0.0` tag;
- smoke-test result;
- privacy-scan result;
- USB hash-verification result;
- GitHub repository URL.

- [ ] **Step 2: Report the outcome**

Return concise links to:

- local README;
- USB project directory;
- GitHub repository.

State explicitly that existing ISO files and the `MSI_BIOS` partition were untouched.
