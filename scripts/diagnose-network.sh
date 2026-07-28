#!/usr/bin/env bash
set -Eeuo pipefail

PROGRAM="diagnose-network.sh"
LANGUAGE=zh

usage() {
  if [[ "$LANGUAGE" == en ]]; then
    cat <<'EOF'
Usage: bash diagnose-network.sh [--help]

Collects read-only Debian network, DNS, APT, and SSH evidence.
It does not change configuration.
EOF
  else
    cat <<'EOF'
用法：bash diagnose-network.sh [--lang zh|en] [--help]

只读收集 Debian 的网卡、地址、路由、DNS、APT、SSH 和近期日志证据。
本脚本不会修改任何系统配置。
EOF
  fi
}

section() {
  if [[ "$LANGUAGE" == en ]]; then
    printf '\n=== %s ===\n' "$2"
  else
    printf '\n=== %s ===\n' "$1"
  fi
}

redact_sensitive() {
  sed -E \
    -e 's#(https?://)[^/@[:space:]]+@#\1[REDACTED]@#gI' \
    -e 's#(authorization[[:space:]]*[:=][[:space:]]*).*#\1[REDACTED]#I' \
    -e 's#\<(password|passwd|api[-_]?key|private[-_]?key|[A-Za-z0-9_-]*(token|secret|psk|_private_key|-private-key))\>([[:space:]]*[:=][[:space:]]*)[^[:space:],;]+#\1\3[REDACTED]#gI' \
    -e 's#\<(Bearer)[[:space:]]+[^[:space:],;]+#\1 [REDACTED]#gI'
}

run_optional() {
  local command="$1"
  shift

  if command -v "$command" >/dev/null 2>&1; then
    "$command" "$@" 2>&1 | redact_sensitive || true
  else
    if [[ "$LANGUAGE" == en ]]; then
      printf '%s: not installed\n' "$command"
    else
      printf '%s：未安装\n' "$command"
    fi
  fi
}

show_carriers() {
  local path interface carrier

  for path in /sys/class/net/*; do
    [[ -e "$path" ]] || continue
    interface="${path##*/}"
    if [[ -r "$path/carrier" ]]; then
      IFS= read -r carrier <"$path/carrier" || carrier="unavailable"
    else
      carrier="unavailable"
    fi
    printf '%s: carrier=%s\n' "$interface" "$carrier"
  done
}

show_resolver() {
  if [[ -L /etc/resolv.conf ]]; then
    printf 'symlink: '
    readlink /etc/resolv.conf 2>&1 || true
    printf 'resolved path: '
    readlink -f /etc/resolv.conf 2>&1 || true
  else
    printf 'symlink: no\n'
  fi

  if [[ -r /etc/resolv.conf ]]; then
    printf '%s\n' 'content:'
    cat /etc/resolv.conf 2>&1 | redact_sensitive || true
  else
    printf '%s\n' '/etc/resolv.conf: unreadable or absent'
  fi

  printf '%s\n' 'getent ahosts deb.debian.org:'
  run_optional getent ahosts deb.debian.org
}

show_apt_sources() {
  printf '%s\n' 'Configured source entries:'
  grep -RhsE '^[[:space:]]*(deb |Types:|URIs:|Suites:|Components:|Signed-By:)' \
    /etc/apt/sources.list /etc/apt/sources.list.d 2>&1 | redact_sensitive || true
  printf '%s\n' 'openssh-server policy:'
  run_optional apt-cache policy openssh-server
}

show_recent_logs() {
  if command -v journalctl >/dev/null 2>&1; then
    journalctl -b --no-pager -n 120 2>&1 |
      grep -Ei 'link|carrier|dhcp|dns|network|firmware|acpi' |
      tail -n 80 |
      redact_sensitive || true
  else
    printf '%s\n' 'journalctl: not installed'
  fi
}

main() {
  while (($#)); do
    case "$1" in
      --lang)
        (($# >= 2)) || { printf '%s: --lang requires zh or en\n' "$PROGRAM" >&2; return 2; }
        [[ "$2" == zh || "$2" == en ]] ||
          { printf '%s: --lang must be zh or en\n' "$PROGRAM" >&2; return 2; }
        LANGUAGE="$2"
        shift 2
        ;;
      --help)
        usage
        return 0
        ;;
      *)
        printf '%s: unknown option: %s\n' "$PROGRAM" "$1" >&2
        return 2
        ;;
    esac
  done

  section '系统' 'SYSTEM'
  if [[ -r /etc/os-release ]]; then
    grep -E '^(PRETTY_NAME|VERSION_ID|VERSION_CODENAME)=' /etc/os-release 2>&1 |
      redact_sensitive || true
  else
    printf '%s\n' '/etc/os-release: unreadable or absent'
  fi
  uname -a 2>&1 || true

  section '链路' 'LINKS'
  run_optional ip -br link
  show_carriers

  section '地址' 'ADDRESSES'
  run_optional ip -br address

  section '路由' 'ROUTES'
  run_optional ip route show

  section '域名解析' 'DNS'
  show_resolver

  section '网络管理器' 'NETWORK MANAGERS'
  run_optional systemctl is-active NetworkManager
  run_optional systemctl is-active systemd-networkd
  run_optional systemctl is-active networking
  run_optional nmcli device status
  run_optional networkctl list

  section '软件源' 'APT'
  show_apt_sources

  section 'SSH 服务' 'SSH'
  run_optional systemctl status ssh --no-pager
  run_optional ss -lntp

  section '近期日志' 'RECENT LOGS'
  show_recent_logs
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
