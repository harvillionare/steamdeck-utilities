#!/usr/bin/env bash
#
# steamdeck-utilities / zerotier / install.sh
#
# Installs ZeroTier on SteamOS in a way that survives SteamOS updates,
# without disabling the read-only root filesystem.
#
# How it works:
#   * Downloads the official zerotier-one package (plus any libraries the OS
#     image lacks) from Valve's own SteamOS package mirror, using the repos
#     listed in /etc/pacman.conf, so binaries match the running OS version.
#   * Installs it as a systemd system extension in /var/lib/extensions
#     (/var is preserved across SteamOS updates), overlaid onto /usr at boot.
#   * Keeps ZeroTier's identity in /var/lib/zerotier-one, so the Deck stays
#     authorized on your network after updates.
#   * Adds a boot-time "heal" service that rebuilds the extension from the
#     new OS version's repos whenever SteamOS has been updated.
#   * Optionally enables sshd and installs SSH public keys.
#
# Usage (run as the normal 'deck' user in Desktop Mode -> Konsole):
#   curl -fsSL https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh \
#     | bash -s -- --network <NETWORK_ID> [--ssh-key "<public key>"] [--github-keys <github user>]
#
# Other modes:
#   install.sh --status        Show what is installed and ZeroTier status
#   install.sh --heal          Rebuild if SteamOS changed (run automatically at boot)
#   install.sh --refresh       Force a rebuild of the extension
#   install.sh --uninstall     Remove everything (keeps ZeroTier identity unless --purge)
#   install.sh --download-only DIR   Resolve + download + extract only (for testing)
#
set -euo pipefail

SELF_URL="${SELF_URL:-https://raw.githubusercontent.com/harvillionare/steamdeck-utilities/main/zerotier/install.sh}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
PACMAN_CONF="${PACMAN_CONF:-/etc/pacman.conf}"
ARCH="x86_64"
PKG_NAME="zerotier-one"

EXT_NAME="zerotier-one"
EXT_ROOT="/var/lib/extensions"
EXT_DIR="${EXT_ROOT}/${EXT_NAME}"
STATE_DIR="/var/lib/steamdeck-utilities"
INSTALLED_SCRIPT="${STATE_DIR}/zerotier-install.sh"
BUILD_STAMP="${STATE_DIR}/zerotier.build"
ZT_HOME="/var/lib/zerotier-one"
UNIT_DIR="/etc/systemd/system"
ZT_UNIT="zerotier-one.service"
HEAL_UNIT="steamdeck-zerotier-heal.service"
KEEP_CONF="/etc/atomic-update.conf.d/steamdeck-utilities.conf"

MODE="install"
NETWORK_ID=""
SSH_KEYS=()
GITHUB_KEYS_USER=""
ENABLE_SSH=1
PURGE=0
DOWNLOAD_DIR=""
ORIG_ARGS=("$@")

# ---------------------------------------------------------------- helpers --

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,/^set -euo/p' "$0" 2>/dev/null | sed -e 's/^# \{0,1\}//' -e '/^set -euo/d'; exit "${1:-0}"; }

fetch() { # url dest
  curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 15 -o "$2" "$1"
}

os_field() { # KEY -> value from os-release
  ( set +u; . "$OS_RELEASE"; eval "printf '%s' \"\${$1:-}\"" )
}

current_build() { printf '%s-%s' "$(os_field VERSION_ID)" "$(os_field BUILD_ID)"; }

sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

extract() { # archive dest
  if command -v bsdtar >/dev/null 2>&1; then bsdtar -xpf "$1" -C "$2"
  else tar --zstd -xpf "$1" -C "$2"; fi
}

# ------------------------------------------------------------ arguments ----

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network|-n)     NETWORK_ID="${2:?}"; shift 2 ;;
    --ssh-key)        SSH_KEYS+=("${2:?}"); shift 2 ;;
    --github-keys)    GITHUB_KEYS_USER="${2:?}"; shift 2 ;;
    --no-ssh)         ENABLE_SSH=0; shift ;;
    --status)         MODE="status"; shift ;;
    --heal)           MODE="heal"; shift ;;
    --refresh)        MODE="refresh"; shift ;;
    --uninstall)      MODE="uninstall"; shift ;;
    --purge)          PURGE=1; shift ;;
    --download-only)  MODE="download-only"; DOWNLOAD_DIR="${2:?}"; shift 2 ;;
    -h|--help)        usage 0 ;;
    *)                die "unknown argument: $1 (see --help)" ;;
  esac
done

if [[ -n "$NETWORK_ID" && ! "$NETWORK_ID" =~ ^[0-9a-fA-F]{16}$ ]]; then
  die "network id must be 16 hex characters, got '$NETWORK_ID'"
fi

# ------------------------------------------------------ self-bootstrapping --
# When piped from curl there is no script file to persist for the boot-time
# heal service, so download ourselves to a real file and re-exec from it.

SELF="${BASH_SOURCE[0]:-}"
if [[ "$MODE" != "download-only" && ( -z "$SELF" || ! -f "$SELF" ) ]]; then
  tmp_self="$(mktemp /tmp/steamdeck-zerotier.XXXXXX.sh)"
  log "Downloading installer to $tmp_self"
  fetch "$SELF_URL" "$tmp_self" || die "could not download $SELF_URL"
  exec bash "$tmp_self" "${ORIG_ARGS[@]}"
fi
SELF="$(cd "$(dirname "$SELF")" && pwd)/$(basename "$SELF")"

# ----------------------------------------------- package resolution (repo) --

WORK=""
declare -A SEEN=()
declare -a PLAN=()       # entries: "repo|desc_path"
declare -a REPO_ORDER=()
declare -A REPO_URL=()   # repo -> url template
declare -A REPO_READY=() # repo -> 1 once db extracted

cleanup() { [[ -n "$WORK" && -d "$WORK" ]] && rm -rf "$WORK"; return 0; }
trap cleanup EXIT

load_repos() {
  local repo url
  while read -r repo url; do
    [[ -z "$repo" || "$repo" == *debug* ]] && continue
    REPO_ORDER+=("$repo"); REPO_URL[$repo]="$url"
  done < <(awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[.*\][[:space:]]*$/ { s=$0; gsub(/[][[:space:]]/, "", s); sec=s; next }
    sec == "" || sec == "options" { next }
    /^[[:space:]]*Server[[:space:]]*=/ {
      if (!(sec in seen)) { v=$0; sub(/^[^=]*=[[:space:]]*/, "", v); print sec, v; seen[sec]=1 }
      next
    }
    /^[[:space:]]*Include[[:space:]]*=/ {
      if (!(sec in seen)) {
        f=$0; sub(/^[^=]*=[[:space:]]*/, "", f)
        while ((getline l < f) > 0) {
          if (l ~ /^[[:space:]]*Server[[:space:]]*=/) { sub(/^[^=]*=[[:space:]]*/, "", l); print sec, l; seen[sec]=1; break }
        }
        close(f)
      }
    }
  ' "$PACMAN_CONF")

  if [[ ${#REPO_ORDER[@]} -eq 0 ]]; then
    # Fallback: construct Valve's mirror layout from the OS version (e.g. 3.7).
    local ver; ver="$(os_field VERSION_ID | cut -d. -f1,2)"
    [[ -n "$ver" ]] || die "no repos in $PACMAN_CONF and no VERSION_ID in $OS_RELEASE"
    warn "no repos found in $PACMAN_CONF; falling back to Valve mirror for SteamOS $ver"
    for repo in "core-$ver" "extra-$ver" "community-$ver" "multilib-$ver"; do
      REPO_ORDER+=("$repo")
      REPO_URL[$repo]='https://steamdeck-packages.steamos.cloud/archlinux-mirror/$repo/os/$arch'
    done
  fi
}

repo_base() { # repo -> base url
  local t="${REPO_URL[$1]}"
  t="${t//\$repo/$1}"; t="${t//\$arch/$ARCH}"
  printf '%s' "$t"
}

ensure_repo_db() { # repo
  local repo="$1"
  [[ -n "${REPO_READY[$repo]:-}" ]] && return 0
  mkdir -p "$WORK/db/$repo"
  if fetch "$(repo_base "$repo")/$repo.db" "$WORK/db/$repo.db" 2>/dev/null \
     && extract "$WORK/db/$repo.db" "$WORK/db/$repo" 2>/dev/null; then
    REPO_READY[$repo]=1
  else
    warn "could not load package database for repo '$repo' (skipping)"
    REPO_READY[$repo]=skip
  fi
}

desc_field() { # desc_file FIELD -> values, one per line
  awk -v f="%$2%" '$0 == f { while ((getline line) > 0 && line != "") print line; exit }' "$1"
}

find_desc() { # dep_name -> "repo|desc" matching NAME, else PROVIDES
  local want="$1" repo hit
  for pass in NAME PROVIDES; do
    for repo in "${REPO_ORDER[@]}"; do
      ensure_repo_db "$repo"
      [[ "${REPO_READY[$repo]}" == 1 ]] || continue
      hit="$(find "$WORK/db/$repo" -mindepth 2 -maxdepth 2 -name desc -print0 \
        | xargs -0 awk -v want="$want" -v field="%$pass%" '
            FNR == 1 { infield = 0 }
            $0 == field { infield = 1; next }
            infield && $0 == "" { infield = 0; next }
            infield {
              v = $0; sub(/[<>=].*$/, "", v)
              if (v == want) { print FILENAME; exit }
            }
          ' 2>/dev/null | head -n1 || true)"
      if [[ -n "$hit" ]]; then printf '%s|%s' "$repo" "$hit"; return 0; fi
    done
  done
  return 1
}

dep_satisfied() { # dep_string -> 0 if the running OS already provides it
  [[ "$MODE" == "download-only" && "${ASSUME_EMPTY:-0}" == 1 ]] && return 1
  command -v pacman >/dev/null 2>&1 || return 1
  pacman -T "$1" >/dev/null 2>&1
}

resolve() { # dep_string
  local dep="$1" name entry desc d
  name="${dep%%[<>=]*}"
  [[ -n "${SEEN[$name]:-}" ]] && return 0
  SEEN[$name]=1
  entry="$(find_desc "$name")" || die "package '$name' not found in any repo from $PACMAN_CONF"
  local p; for p in "${PLAN[@]}"; do [[ "$p" == "$entry" ]] && return 0; done
  PLAN+=("$entry")
  desc="${entry#*|}"
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    dep_satisfied "$d" && continue
    resolve "$d"
  done < <(desc_field "$desc" DEPENDS)
}

build_root() { # dest_root -> downloads + extracts PLAN into dest_root
  local dest="$1" entry repo desc file sum
  mkdir -p "$dest" "$WORK/pkgs"
  for entry in "${PLAN[@]}"; do
    repo="${entry%%|*}"; desc="${entry#*|}"
    file="$(desc_field "$desc" FILENAME)"
    sum="$(desc_field "$desc" SHA256SUM)"
    log "Fetching $file (from $repo)"
    fetch "$(repo_base "$repo")/$file" "$WORK/pkgs/$file" || die "download failed: $file"
    if [[ -n "$sum" && "$(sha256 "$WORK/pkgs/$file")" != "$sum" ]]; then
      die "checksum mismatch for $file"
    fi
    extract "$WORK/pkgs/$file" "$dest"
  done
  rm -f "$dest"/.PKGINFO "$dest"/.MTREE "$dest"/.BUILDINFO "$dest"/.INSTALL
}

prepare_packages() { # -> builds the package tree in $WORK/root
  WORK="$(mktemp -d /tmp/steamdeck-zerotier.XXXXXX)"
  load_repos
  log "Resolving $PKG_NAME from: ${REPO_ORDER[*]}"
  resolve "$PKG_NAME"
  local names=() e; for e in "${PLAN[@]}"; do names+=("$(basename "$(dirname "${e#*|}")")"); done
  log "Packages to install: ${names[*]}"
  build_root "$WORK/root"
}

cleanup_stray_root() {
  # v1 bug: packages were extracted into /root instead of a temp dir.
  # /root/usr never exists on SteamOS otherwise, so remove what it left.
  if [[ -x /root/usr/bin/zerotier-one ]]; then
    log "Cleaning up files left in /root by an earlier failed run"
    rm -rf /root/usr
    rmdir /root/var/lib/zerotier-one /root/var/lib /root/var 2>/dev/null || true
  fi
}

# ------------------------------------------------------------ system bits --

require_root() {
  if [[ $EUID -ne 0 ]]; then
    if ! sudo -n true 2>/dev/null; then
      # Fresh Steam Decks have no password, so sudo cannot work yet.
      local st ans; st="$(passwd -S "$USER" 2>/dev/null | awk '{print $2}' || true)"
      if [[ -z "$st" ]]; then
        printf 'Have you already set a password for "%s" on this Deck? [y/N] ' "$USER" > /dev/tty
        read -r ans < /dev/tty || ans=""
        [[ "$ans" =~ ^[Yy] ]] && st="P" || st="NP"
      fi
      if [[ "$st" == "NP" || "$st" == "L" ]]; then
        log "Your Deck needs a password for admin (sudo) access. Choose one now."
        log "(You will type it twice, then once more for sudo. Nothing shows while typing.)"
        passwd < /dev/tty > /dev/tty 2>&1 || die "setting the password failed; run 'passwd' manually and re-run"
      fi
    fi
    log "Re-running with sudo (enter the password for '$USER' if asked)"
    local rc=0
    sudo bash "$SELF" "${ORIG_ARGS[@]}" || rc=$?
    if [[ $rc -ne 0 ]]; then
      die "install failed (exit $rc); see the error above."
    fi
    exit 0
  fi
}

target_user() { printf '%s' "${SUDO_USER:-deck}"; }

write_units() {
  cat > "$UNIT_DIR/$ZT_UNIT" <<'EOF'
# Installed by steamdeck-utilities (zerotier/install.sh)
[Unit]
Description=ZeroTier One
After=network-online.target systemd-sysext.service
Wants=network-online.target systemd-sysext.service

[Service]
ExecStart=/usr/bin/zerotier-one
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=multi-user.target
EOF

  cat > "$UNIT_DIR/$HEAL_UNIT" <<EOF
# Installed by steamdeck-utilities (zerotier/install.sh)
[Unit]
Description=Rebuild ZeroTier extension after SteamOS updates
After=network-online.target systemd-sysext.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash $INSTALLED_SCRIPT --heal
TimeoutStartSec=15min

[Install]
WantedBy=multi-user.target
EOF
}

write_keep_list() {
  # SteamOS 3.6+ only carries /etc changes across updates if they are on a
  # keep list; record every file/symlink we created or rely on.
  mkdir -p "$(dirname "$KEEP_CONF")"
  {
    echo "# Managed by steamdeck-utilities (zerotier/install.sh)"
    echo "$KEEP_CONF"
    echo "$UNIT_DIR/$ZT_UNIT"
    echo "$UNIT_DIR/$HEAL_UNIT"
    find "$UNIT_DIR" -mindepth 2 -maxdepth 2 -type l \
      \( -name "$ZT_UNIT" -o -name "$HEAL_UNIT" -o -name sshd.service -o -name systemd-sysext.service \) \
      2>/dev/null | sort
    echo "/etc/ssh/ssh_host_*"
  } > "$KEEP_CONF"
}

install_extension() {
  local stage="${EXT_DIR}.new"
  rm -rf "$stage"; mkdir -p "$stage"
  prepare_packages

  [[ -x "$WORK/root/usr/bin/zerotier-one" ]] || die "package did not contain /usr/bin/zerotier-one"
  cp -a "$WORK/root/usr" "$stage/"
  [[ -d "$WORK/root/opt" ]] && cp -a "$WORK/root/opt" "$stage/"

  mkdir -p "$stage/usr/lib/extension-release.d"
  printf 'ID=%s\n' "$(os_field ID)" > "$stage/usr/lib/extension-release.d/extension-release.${EXT_NAME}"

  mkdir -p "$EXT_ROOT"
  systemctl stop "$ZT_UNIT" >/dev/null 2>&1 || true
  systemd-sysext unmerge >/dev/null 2>&1 || true
  rm -rf "$EXT_DIR"; mv "$stage" "$EXT_DIR"
  systemd-sysext merge
  systemctl daemon-reload
  # The package ships a sysusers.d entry for a 'zerotier-one' user; create it.
  systemd-sysusers >/dev/null 2>&1 || true

  if ! /usr/bin/zerotier-one -v >/dev/null 2>&1; then
    die "zerotier-one does not run after merge: $(/usr/bin/zerotier-one -v 2>&1 | head -1)"
  fi
  log "ZeroTier $(/usr/bin/zerotier-one -v) installed as a system extension"

  mkdir -p "$STATE_DIR" "$ZT_HOME"
  current_build > "$BUILD_STAMP"
}

persist_self() {
  mkdir -p "$STATE_DIR"
  if [[ "$SELF" != "$INSTALLED_SCRIPT" ]]; then
    install -m 0755 "$SELF" "$INSTALLED_SCRIPT"
  fi
}

setup_ssh() {
  local user home keyfile k
  user="$(target_user)"; home="$(getent passwd "$user" | cut -d: -f6)"
  [[ -n "$home" ]] || { warn "user '$user' not found; skipping SSH setup"; return; }

  if [[ -n "$GITHUB_KEYS_USER" ]]; then
    log "Fetching SSH keys for GitHub user '$GITHUB_KEYS_USER'"
    while IFS= read -r k; do [[ -n "$k" ]] && SSH_KEYS+=("$k"); done \
      < <(curl -fsSL "https://github.com/${GITHUB_KEYS_USER}.keys" || true)
  fi

  if [[ ${#SSH_KEYS[@]} -gt 0 ]]; then
    keyfile="$home/.ssh/authorized_keys"
    install -d -m 0700 -o "$user" -g "$(id -gn "$user")" "$home/.ssh"
    touch "$keyfile"
    for k in "${SSH_KEYS[@]}"; do
      if ! grep -qxF "$k" "$keyfile"; then echo "$k" >> "$keyfile"; log "Added SSH key: ${k:0:40}..."; fi
    done
    chown "$user":"$(id -gn "$user")" "$keyfile"; chmod 0600 "$keyfile"
  fi

  log "Enabling sshd"
  systemctl enable --now sshd.service >/dev/null
}

join_network() {
  local i
  for i in $(seq 1 30); do
    zerotier-cli info >/dev/null 2>&1 && break
    sleep 1
  done
  zerotier-cli info >/dev/null 2>&1 || die "zerotier-one service did not come up (see: journalctl -u $ZT_UNIT)"
  if [[ -n "$NETWORK_ID" ]]; then
    log "Joining network $NETWORK_ID"
    zerotier-cli join "$NETWORK_ID" >/dev/null
  fi
}

show_status() {
  echo "SteamOS build:      $(current_build)"
  echo "Installed for:      $(cat "$BUILD_STAMP" 2>/dev/null || echo '-')"
  echo "Extension dir:      $([[ -d $EXT_DIR ]] && echo "$EXT_DIR" || echo 'not installed')"
  echo "zerotier-one:       $(/usr/bin/zerotier-one -v 2>/dev/null || echo 'not available')"
  echo "Service:            $(systemctl is-active "$ZT_UNIT" 2>/dev/null || true) / $(systemctl is-enabled "$ZT_UNIT" 2>/dev/null || true)"
  echo "Heal service:       $(systemctl is-enabled "$HEAL_UNIT" 2>/dev/null || true)"
  echo "sshd:               $(systemctl is-active sshd 2>/dev/null || true) / $(systemctl is-enabled sshd 2>/dev/null || true)"
  if [[ $EUID -eq 0 ]] && command -v zerotier-cli >/dev/null 2>&1; then
    zerotier-cli info 2>/dev/null || true
    zerotier-cli listnetworks 2>/dev/null || true
  else
    echo "(run with sudo to see ZeroTier node/network info)"
  fi
}

wait_for_repo() {
  load_repos
  local base i; base="$(repo_base "${REPO_ORDER[0]}")"
  for i in $(seq 1 60); do
    curl -fsI --connect-timeout 5 "$base/${REPO_ORDER[0]}.db" >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}

# ------------------------------------------------------------------ modes --

case "$MODE" in
  download-only)
    WORK="$(mktemp -d /tmp/steamdeck-zerotier.XXXXXX)"
    load_repos
    log "Resolving $PKG_NAME from: ${REPO_ORDER[*]}"
    resolve "$PKG_NAME"
    build_root "$DOWNLOAD_DIR"
    log "Extracted into $DOWNLOAD_DIR"
    ;;

  status)
    show_status
    ;;

  install|refresh)
    require_root
    [[ "$(os_field ID)" == "steamos" ]] || warn "this does not look like SteamOS (ID=$(os_field ID)); continuing anyway"
    command -v systemd-sysext >/dev/null || die "systemd-sysext not found"
    cleanup_stray_root
    persist_self
    install_extension
    write_units
    systemctl daemon-reload
    systemctl enable systemd-sysext.service >/dev/null 2>&1 || true
    systemctl enable "$HEAL_UNIT" >/dev/null
    systemctl enable "$ZT_UNIT" >/dev/null
    systemctl restart "$ZT_UNIT"
    [[ "$MODE" == "install" && $ENABLE_SSH -eq 1 ]] && setup_ssh
    write_keep_list
    join_network
    echo
    log "Done. ZeroTier node id: $(zerotier-cli info | awk '{print $3}')"
    [[ -n "$NETWORK_ID" ]] && log "Authorize this node at https://my.zerotier.com/ (network $NETWORK_ID)"
    ;;

  heal)
    [[ $EUID -eq 0 ]] || die "--heal must run as root"
    if [[ "$(cat "$BUILD_STAMP" 2>/dev/null)" == "$(current_build)" ]] && /usr/bin/zerotier-one -v >/dev/null 2>&1; then
      exit 0
    fi
    log "SteamOS changed ($(cat "$BUILD_STAMP" 2>/dev/null || echo none) -> $(current_build)); rebuilding ZeroTier extension"
    wait_for_repo || die "package mirror unreachable; will retry next boot"
    REPO_ORDER=(); REPO_URL=()
    install_extension
    write_units
    write_keep_list
    systemctl daemon-reload
    systemctl restart "$ZT_UNIT"
    ;;

  uninstall)
    require_root
    systemctl disable --now "$ZT_UNIT" "$HEAL_UNIT" >/dev/null 2>&1 || true
    rm -f "$UNIT_DIR/$ZT_UNIT" "$UNIT_DIR/$HEAL_UNIT" "$KEEP_CONF"
    systemd-sysext unmerge >/dev/null 2>&1 || true
    rm -rf "$EXT_DIR" "$STATE_DIR"
    systemd-sysext merge >/dev/null 2>&1 || true
    systemctl daemon-reload
    if [[ $PURGE -eq 1 ]]; then rm -rf "$ZT_HOME"; log "Removed ZeroTier identity"; fi
    log "Uninstalled. (sshd and authorized_keys were left as-is.)"
    ;;
esac
