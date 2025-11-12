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

# Optional tracing: run with TRACE=1 ./update.sh
[[ "${TRACE:-0}" == "1" ]] && set -x

# Better error context on failure
trap 'rc=$?; echo "[!] Script berhenti di baris ${LINENO}: ${BASH_COMMAND} (exit ${rc})" >&2; exit $rc' ERR

echo "${BLUE}[*] Update paket sudo & glibc...${RESET}"

# Helper: disable a repository by matching pattern in sources files
disable_repo_by_pattern() {
  local pattern="$1"
  echo "${BLUE}[i] Menonaktifkan repo yang cocok dengan pola: $pattern${RESET}"
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
if ! sudo apt update; then
  echo "${RED}[!] apt update gagal. Kemungkinan ada repo pihak ketiga yang bermasalah (Release file hilang/tidak valid).${RESET}" >&2
  if [ -n "${AUTO_DISABLE_PATTERNS:-}" ]; then
    echo "${YELLOW}[i] AUTO_DISABLE_PATTERNS terisi: ${AUTO_DISABLE_PATTERNS}. Menonaktifkan dan coba ulang.${RESET}"
    # Split by comma menjadi spasi
    for pattern in ${AUTO_DISABLE_PATTERNS//,/ } ; do
      [ -n "$pattern" ] && disable_repo_by_pattern "$pattern"
    done
    sudo apt update || { echo "${RED}[!] apt update tetap gagal setelah menonaktifkan pola yang ditentukan.${RESET}"; exit 1; }
  else
    echo "${YELLOW}[i] Tidak ada pola otomatis untuk dinonaktifkan. Jika Anda tahu repo penyebabnya, jalankan dengan:${RESET}"
    echo "    AUTO_DISABLE_PATTERNS=\"owner/repo atau domain\" ./update.sh"
    echo "${YELLOW}Contoh: AUTO_DISABLE_PATTERNS=\"lutris-team/lutris\" ./update.sh${RESET}"
    exit 1
  fi
fi

if ! sudo apt-get install --only-upgrade -y sudo libc6; then
  echo "${RED}[!] Upgrade paket sudo/libc6 gagal. Kemungkinan penyebab: kunci dpkg terkunci, paket tertahan (held), atau konflik dependensi.${RESET}" >&2
  echo "    Coba selesaikan lalu jalankan ulang skrip. Lihat: sudo dpkg --configure -a; sudo apt -f install" >&2
  exit 1
fi

echo "${BLUE}[*] Tampilkan versi setelah update...${RESET}"
dpkg -l sudo libc6 | awk '/^ii/ {print}'

echo "${BLUE}[*] Tambah aturan sudoers membatasi -R (chroot) jika belum...${RESET}"
RULE=/etc/sudoers.d/no_chroot_option
if ! sudo test -f "$RULE"; then
  # Catatan: Tidak ada opsi Defaults yang valid untuk menonaktifkan argumen -R (chroot) secara langsung.
  # Kita validasi contoh aturan terlebih dahulu; jika tidak valid, kita lewati agar tidak merusak konfigurasi sudoers.
  TMP_RULE=$(mktemp)
  echo 'Defaults!/usr/bin/sudo !chroot' > "$TMP_RULE"
  if sudo visudo -cf "$TMP_RULE"; then
    sudo install -m 0440 "$TMP_RULE" "$RULE"
  else
    echo "${YELLOW}[!] Aturan sudoers untuk memblok -R tidak valid pada sistem ini. Melewati tanpa mengubah sudoers.${RESET}" >&2
  fi
  rm -f "$TMP_RULE"
fi

echo "${BLUE}[*] Opsional: AppArmor deny load NSS dari /tmp (lewati jika tidak pakai AppArmor)...${RESET}"
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
    sudo apparmor_parser -r /etc/apparmor.d/usr.bin.sudo || echo "[!] Update AppArmor gagal"
  fi
fi

echo "${BLUE}[*] (Opsional) Sarankan mount /tmp dengan nosuid,nodev${RESET}"
echo "${BLUE}Tambahkan ke /etc/fstab contoh:${RESET}"
echo "${BLUE}tmpfs /tmp tmpfs rw,nosuid,nodev,relatime 0 0${RESET}"

echo "${GREEN}[*] Selesai. Review manual sudoers untuk aturan khusus lainnya.${RESET}"