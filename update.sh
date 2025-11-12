#!/bin/bash
# Color setup (only if STDOUT is a TTY). Prefer tput, fallback to ANSI; otherwise disable colors
if [ -t 1 ]; then
  if command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    RED="$(tput setaf 1)"
    BLUE="$(tput setaf 4)"
    YELLOW="$(tput setaf 3)"
    GREEN="$(tput setaf 2)"
    RESET="$(tput sgr0)"
  else
    RED=$'\033[0;31m'
    BLUE=$'\033[0;34m'
    YELLOW=$'\033[0;33m'
    GREEN=$'\033[0;32m'
    RESET=$'\033[0m'
  fi
else
  RED=""; BLUE=""; YELLOW=""; RESET=""
fi

set -euo pipefail

# Output mode: minimal by default; set VERBOSE=1 for more
VERBOSE=${VERBOSE:-0}
QUIET=$(( VERBOSE ? 0 : 1 ))

# Short icons
OK_ICON="${GREEN}✓${RESET}"; WARN_ICON="${YELLOW}!${RESET}"; ERR_ICON="${RED}✗${RESET}"; DOT_ICON="${BLUE}•${RESET}"

info() { echo "${DOT_ICON} $*"; }
ok()   { echo "${OK_ICON} $*"; }
warn() { echo "${WARN_ICON} $*"; }
fail() { echo "${ERR_ICON} $*"; }

# Optional tracing: run with TRACE=1 ./update.sh
[[ "${TRACE:-0}" == "1" ]] && set -x

# Better error context on failure
trap 'rc=$?; echo "[!] Script berhenti di baris ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2; exit $rc' ERR

info "apt update"

# Helper: disable a repository by matching pattern in sources files
disable_repo_by_pattern() {
  local pattern="$1"
  info "disable repo pattern: $pattern"
  # .list files (legacy format)
  while IFS= read -r -d '' f; do
    if grep -q "$pattern" "$f" 2>/dev/null; then
      sudo cp -n "$f" "$f.bak" 2>/dev/null || true
      # Comment only lines containing the pattern
      sudo sed -i -E "/$pattern/ s/^([[:space:]]*deb)/# \\1/; /$pattern/ s/^([[:space:]]*deb-src)/# \\1/" "$f"
      echo "    - Disabled entries in $f"
    fi
  done < <(sudo find /etc/apt/sources.list /etc/apt/sources.list.d -maxdepth 1 -type f -name "*.list" -print0 2>/dev/null)

  # .sources files (Deb822 format)
  while IFS= read -r -d '' f; do
    if grep -q "$pattern" "$f" 2>/dev/null; then
      sudo cp -n "$f" "$f.bak" 2>/dev/null || true
      if grep -qi '^Enabled:' "$f"; then
        sudo sed -i -E 's/^Enabled:.*/Enabled: no/i' "$f"
      else
        echo "Enabled: no" | sudo tee -a "$f" >/dev/null
      fi
      echo "    - Marked Enabled: no in $f"
    fi
  done < <(sudo find /etc/apt/sources.list.d -type f -name "*.sources" -print0 2>/dev/null)
}

# Run apt update; on failure, optionally auto-disable patterns from env and retry (generic, no vendor-specific text)
if ! { (( QUIET )) && sudo apt-get -qq update || sudo apt update; }; then
  warn "apt update gagal"
  if [ -n "${AUTO_DISABLE_PATTERNS:-}" ]; then
  info "AUTO_DISABLE_PATTERNS: ${AUTO_DISABLE_PATTERNS}"
    # Split by comma menjadi spasi
    for pattern in ${AUTO_DISABLE_PATTERNS//,/ } ; do
      [ -n "$pattern" ] && disable_repo_by_pattern "$pattern"
    done
    { (( QUIET )) && sudo apt-get -qq update || sudo apt update; } || { fail "apt update masih gagal"; exit 1; }
  else
    warn "set AUTO_DISABLE_PATTERNS='pattern1,pattern2' lalu jalankan ulang"
    exit 1
  fi
fi
ok "apt update"

info "upgrade sudo+glibc"
if ! { (( QUIET )) && sudo apt-get -yqq install --only-upgrade sudo libc6 || sudo apt-get -y install --only-upgrade sudo libc6; }; then
  fail "upgrade sudo/libc6 gagal"
  exit 1
fi
ok "upgrade selesai"

info "versi paket"
dpkg -l sudo libc6 | awk '/^ii/ {print}'

info "cek aturan sudoers -R (opsional)"
RULE=/etc/sudoers.d/no_chroot_option
if ! sudo test -f "$RULE"; then
  # Catatan: Tidak ada opsi Defaults yang valid untuk menonaktifkan argumen -R (chroot) secara langsung.
  # Kita validasi contoh aturan terlebih dahulu; jika tidak valid, kita lewati agar tidak merusak konfigurasi sudoers.
  TMP_RULE=$(mktemp)
  echo 'Defaults!/usr/bin/sudo !chroot' > "$TMP_RULE"
  if sudo visudo -cf "$TMP_RULE"; then
    sudo install -m 0440 "$TMP_RULE" "$RULE"
    ok "aturan sudoers ditambahkan"
  else
    warn "aturan sudoers -R tidak valid, lewati"
  fi
  rm -f "$TMP_RULE"
fi

info "AppArmor harden sudo (opsional)"
if systemctl is-active --quiet apparmor; then
  AA_LOCAL=/etc/apparmor.d/local/usr.bin.sudo
  if ! grep -q '/tmp/' "$AA_LOCAL" 2>/dev/null; then
    sudo mkdir -p "$(dirname "$AA_LOCAL")"
    sudo bash -c "cat >> '$AA_LOCAL' <<'EOF'
# Hardening cepat: blok sudo membaca libnss_ dari direktori tulis-user
deny /tmp/** mr,
deny /var/tmp/** mr,
deny /dev/shm/** mr,
EOF"
    sudo apparmor_parser -r /etc/apparmor.d/usr.bin.sudo || warn "update AppArmor gagal"
  fi
fi
info "saran: mount /tmp nosuid,nodev (opsional)"
ok "selesai"