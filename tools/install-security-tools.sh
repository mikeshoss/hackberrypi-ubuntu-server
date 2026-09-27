#!/bin/bash
# =============================================================================
# HackberryPi CM5 - security / wifi tooling installer for Ubuntu (arm64)
# =============================================================================
# Reinstalls the deck's Kali-style wifi-audit stack on Ubuntu 26.04. Most of it
# is in Ubuntu's own arm64 archive; Kismet and Tailscale come from their own
# apt repos; a few Kali-only tools come from a *pinned* Kali repo you opt into.
#
# Only use this deck against networks you own or are authorized to test.
#
# Usage:
#   ./install-security-tools.sh                 # --plan: show where each tool comes from, change nothing
#   ./install-security-tools.sh install         # install the default wardrive-deck set
#   ./install-security-tools.sh install --with-kali    # + the Kali-only extras (pinned repo)
#   ./install-security-tools.sh install --from-inventory deck-inventory-*.json   # install what the scan found
#   ./install-security-tools.sh verify          # check the expected tools are on PATH and a radio can go monitor
#   ./install-security-tools.sh wardrive        # set up the wardrive-ui checkout (does not auto-start it)
#
# Flags: --with-kali (Kali-only tools), --docker-ce (Docker's repo not Ubuntu's),
#        --yes (no prompts), --group wifi,crack,recon,host (limit the default set).
# =============================================================================
set -uo pipefail

ACTION=plan
WITH_KALI=0; DOCKER_CE=0
INVENTORY=""; WANT_GROUPS="host,wifi,crack,recon"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case ${args[i]} in
    plan|install|verify|wardrive) ACTION=${args[i]} ;;
    --with-kali) WITH_KALI=1 ;;
    --docker-ce) DOCKER_CE=1 ;;
    --from-inventory) INVENTORY=${args[i+1]:-}; ((i++)) ;;
    --from-inventory=*) INVENTORY=${args[i]#*=} ;;
    --group) WANT_GROUPS=${args[i+1]:-}; ((i++)) ;;
    --group=*) WANT_GROUPS=${args[i]#*=} ;;
    -h|--help) sed -n '2,/^# ===/{/^# ===/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
    *) echo "unknown argument: ${args[i]} (see --help)" >&2; exit 2 ;;
  esac
done

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; DIM='\033[2m'; NC='\033[0m'
say()  { printf "\n${BLUE}==> %s${NC}\n" "$*"; }
ok()   { printf "  ${GREEN}OK${NC}   %s\n" "$*"; }
miss() { printf "  ${RED}MISS${NC} %s\n" "$*"; }
warn() { printf "  ${YELLOW}!${NC}  %s\n" "$*" >&2; }
info() { printf "  ${DIM}%s${NC}\n" "$*"; }
die()  { printf "${RED}Error: %s${NC}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

WARDRIVE_URL=https://github.com/mikeshoss/wardrive.git
WARDRIVE_DIR=${WARDRIVE_DIR:-$HOME/code/wardrive-ui}
KEYRINGS=/etc/apt/keyrings

# ---- tool groups (what a wardrive deck needs) -------------------------------
# The wardrive-ui container ships its own attack tools; the HOST only needs
# Kismet (wardriving), Tailscale (remote access) and Docker. The rest is the
# broader wifi-audit set you can run outside the container.
declare -A GROUP
GROUP[host]="kismet tailscale docker.io docker-compose-v2 git python3 python3-flask"
GROUP[wifi]="aircrack-ng hcxtools hcxdumptool iw rfkill macchanger reaver bully wifite mdk4 pixiewps cowpatty hostapd"
GROUP[crack]="hashcat john hydra crunch"
GROUP[recon]="nmap masscan bettercap tshark tcpdump netdiscover arp-scan"
# Kali-only (need --with-kali). Every one of these is confirmed present in the Kali arm64 repo.
KALI_ONLY="hostapd-wpe eaphammer wifipumpkin3 airgeddon fluxion"

is_kali_only() { [[ " $KALI_ONLY " == *" $1 "* ]]; }

# ---- pick an apt codename the vendor repos actually publish -----------------
# Ubuntu 26.04 is "resolute"; Kismet/Tailscale may not list it yet, so fall
# back through the newest release they do publish (their debs work across these).
release_codename() { ( . /etc/os-release 2>/dev/null; echo "${VERSION_CODENAME:-}" ); }
vendor_codename() { # vendor_codename BASE_URL_TEMPLATE (with @@ where the codename goes)
  local tmpl=$1 c
  for c in "$(release_codename)" resolute plucky oracular noble; do
    [[ -z $c ]] && continue
    if curl -fsI --max-time 12 "${tmpl//@@/$c}" >/dev/null 2>&1; then echo "$c"; return 0; fi
  done
  return 1
}

# ---- source resolver --------------------------------------------------------
# Print where a package would come from, without adding any repo.
resolve() { # resolve PKG -> echoes: apt | kismet | tailscale | docker | kali | unknown
  local p=$1
  case $p in
    kismet|kismet-*) echo kismet; return ;;
    tailscale) echo tailscale; return ;;
    docker.io|docker-ce|docker-compose-v2|docker-compose-plugin|containerd*) echo docker; return ;;
  esac
  # Capture apt-cache's output whole, then read it — never pipe into grep -q under
  # pipefail (grep -q exits early, apt-cache dies of SIGPIPE, pipefail calls it failure).
  local pol cand
  pol=$(apt-cache policy "$p" 2>/dev/null)
  cand=$(awk '/Candidate:/{print $2; exit}' <<<"$pol")
  if [[ -n $cand && $cand != "(none)" ]]; then echo apt; return; fi
  is_kali_only "$p" && { echo kali; return; }
  echo unknown
}

wanted_packages() {
  local out=() g
  if [[ -n $INVENTORY ]]; then
    [[ -f $INVENTORY ]] || die "inventory file not found: $INVENTORY"
    # pull security_packages[] out of the scan JSON without needing jq
    mapfile -t out < <(grep -ozP '"security_packages"\s*:\s*\[[^]]*\]' "$INVENTORY" 2>/dev/null \
      | tr -d '\0' | grep -oE '"[^"]+"' | tr -d '"' | grep -v security_packages)
    # host essentials the deck always needs, even if the scan predates them
    out+=(kismet tailscale docker.io docker-compose-v2)
  else
    for g in ${WANT_GROUPS//,/ }; do
      [[ -n ${GROUP[$g]:-} ]] || die "unknown group '$g' (host,wifi,crack,recon)"
      read -ra g_items <<<"${GROUP[$g]}"; out+=("${g_items[@]}")
    done
  fi
  if (( WITH_KALI )); then read -ra k_items <<<"$KALI_ONLY"; out+=("${k_items[@]}"); fi
  printf '%s\n' "${out[@]}" | sed '/^$/d' | sort -u
}

# =============================================================================
# plan
# =============================================================================
declare -a NEED_APT NEED_KISMET NEED_TS NEED_DOCKER NEED_KALI NEED_UNKNOWN
build_plan() {
  NEED_APT=(); NEED_KISMET=(); NEED_TS=(); NEED_DOCKER=(); NEED_KALI=(); NEED_UNKNOWN=()
  local p src
  while read -r p; do
    [[ -z $p ]] && continue
    src=$(resolve "$p")
    case $src in
      apt) NEED_APT+=("$p") ;;
      kismet) NEED_KISMET+=("$p") ;;
      tailscale) NEED_TS+=("$p") ;;
      docker) NEED_DOCKER+=("$p") ;;
      kali) NEED_KALI+=("$p") ;;
      *) NEED_UNKNOWN+=("$p") ;;
    esac
  done < <(wanted_packages)
}

phase_plan() {
  say "Install plan${INVENTORY:+ (from $INVENTORY)}"
  build_plan
  [[ -n ${NEED_KISMET[*]:-} ]] && printf "  ${GREEN}Kismet repo${NC}   %s\n" "${NEED_KISMET[*]}"
  [[ -n ${NEED_TS[*]:-} ]]     && printf "  ${GREEN}Tailscale repo${NC} %s\n" "${NEED_TS[*]}"
  [[ -n ${NEED_DOCKER[*]:-} ]] && printf "  ${GREEN}Docker${NC}        %s\n" "${NEED_DOCKER[*]}"
  [[ -n ${NEED_APT[*]:-} ]]    && printf "  ${GREEN}apt (Ubuntu)${NC}  %s\n" "${NEED_APT[*]}"
  if [[ -n ${NEED_KALI[*]:-} ]]; then
    if (( WITH_KALI )); then printf "  ${GREEN}Kali repo${NC}     %s\n" "${NEED_KALI[*]}"
    else printf "  ${YELLOW}Kali-only${NC}     %s  ${DIM}(add --with-kali)${NC}\n" "${NEED_KALI[*]}"; fi
  fi
  if [[ -n ${NEED_UNKNOWN[*]:-} ]]; then
    printf "  ${YELLOW}unresolved${NC}    %s\n" "${NEED_UNKNOWN[*]}"
    info "not in Ubuntu, not a known vendor/Kali tool — install by hand or from source."
  fi
  echo
  info "This was a dry run. To do it: ./install-security-tools.sh install${WITH_KALI:+ --with-kali}${INVENTORY:+ --from-inventory $INVENTORY}"
}

# =============================================================================
# repo setup
# =============================================================================
need_root_apt() { (( EUID == 0 )) && SUDO="" || SUDO="sudo"; have apt-get || die "apt-get not found — this installer is for Ubuntu/Debian"; }

add_kismet_repo() {
  grep -rqs kismetwireless /etc/apt/sources.list.d/ && { ok "Kismet repo already added"; return; }
  local c; c=$(vendor_codename "https://www.kismetwireless.net/repos/apt/release/@@/dists/@@/Release") ||
    die "no Kismet apt repo for this release — see kismetwireless.net/packages"
  say "Adding the Kismet apt repo ($c)"
  $SUDO install -d -m0755 "$KEYRINGS"
  curl -fsSL https://www.kismetwireless.net/repos/kismet-release.gpg.key | $SUDO gpg --dearmor -o "$KEYRINGS/kismet.gpg"
  echo "deb [signed-by=$KEYRINGS/kismet.gpg] https://www.kismetwireless.net/repos/apt/release/$c $c main" |
    $SUDO tee /etc/apt/sources.list.d/kismet.list >/dev/null
  APT_DIRTY=1
}

add_tailscale_repo() {
  grep -rqs pkgs.tailscale.com /etc/apt/sources.list.d/ && { ok "Tailscale repo already added"; return; }
  local c; c=$(vendor_codename "https://pkgs.tailscale.com/stable/ubuntu/@@.tailscale-keyring.list") ||
    die "no Tailscale apt repo for this release — see tailscale.com/download/linux"
  say "Adding the Tailscale apt repo ($c)"
  $SUDO install -d -m0755 /usr/share/keyrings
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$c.noarmor.gpg" | $SUDO tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
  curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/$c.tailscale-keyring.list" | $SUDO tee /etc/apt/sources.list.d/tailscale.list >/dev/null
  APT_DIRTY=1
}

add_kali_repo() {
  grep -rqs 'kali.org' /etc/apt/sources.list.d/ && { ok "Kali repo already added"; return; }
  say "Adding the Kali repo — PINNED so it can never upgrade your Ubuntu base"
  warn "Kali packages are only pulled when Ubuntu has no equivalent. Base packages stay Ubuntu's."
  $SUDO install -d -m0755 /usr/share/keyrings
  curl -fsSL https://archive.kali.org/archive-keyring.gpg | $SUDO tee /usr/share/keyrings/kali-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/kali-archive-keyring.gpg] http://http.kali.org/kali kali-rolling main contrib non-free non-free-firmware" |
    $SUDO tee /etc/apt/sources.list.d/kali.list >/dev/null
  # Pin-Priority 100: below Ubuntu's 500, so Kali never wins for a package Ubuntu also has,
  # and installed packages are never upgraded to Kali. Kali is used only where Ubuntu has nothing.
  printf 'Package: *\nPin: release o=Kali\nPin-Priority: 100\n' | $SUDO tee /etc/apt/preferences.d/99-kali-pin >/dev/null
  APT_DIRTY=1
}

apt_update_once() {
  [[ ${APT_DIRTY:-0} == 1 ]] || return 0
  say "apt-get update"
  $SUDO apt-get update -qq || die "apt-get update failed — a repo was not added cleanly (check the messages above)"
  APT_DIRTY=0
}
apt_install() { $SUDO DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

# =============================================================================
# install
# =============================================================================
phase_install() {
  need_root_apt
  build_plan
  (( ${#NEED_KISMET[@]} )) && add_kismet_repo
  (( ${#NEED_TS[@]} ))     && add_tailscale_repo
  if (( ${#NEED_KALI[@]} )); then
    (( WITH_KALI )) && add_kali_repo || warn "skipping Kali-only tools (${NEED_KALI[*]}); pass --with-kali to include them"
  fi
  apt_update_once

  if (( ${#NEED_KISMET[@]} )); then
    say "Kismet"
    # kismet + the linux wifi datasource; the wardrive user must be in the kismet group
    apt_install "${NEED_KISMET[@]}" kismet-capture-linux-wifi 2>/dev/null || apt_install "${NEED_KISMET[@]}" || die "Kismet failed to install"
    getent group kismet >/dev/null && $SUDO usermod -aG kismet "$(id -un)" && ok "added $(id -un) to the kismet group (re-login to take effect)"
  fi
  (( ${#NEED_TS[@]} )) && { say "Tailscale"; apt_install tailscale || die "Tailscale failed to install"; $SUDO systemctl enable --now tailscaled 2>/dev/null || true; info "connect with: sudo tailscale up"; }
  if (( ${#NEED_DOCKER[@]} )); then
    say "Docker"
    { (( DOCKER_CE )) && setup_docker_ce || apt_install docker.io docker-compose-v2; } || die "Docker failed to install"
    $SUDO systemctl enable --now docker 2>/dev/null || true
    getent group docker >/dev/null && $SUDO usermod -aG docker "$(id -un)" && ok "added $(id -un) to the docker group (re-login to take effect)"
  fi
  (( ${#NEED_APT[@]} ))  && { say "Ubuntu archive tools"; apt_install "${NEED_APT[@]}" || die "some Ubuntu-archive tools failed to install (see apt's message above)"; }
  if (( ${#NEED_KALI[@]} && WITH_KALI )); then
    say "Kali-only tools (pinned repo)"
    local p
    for p in "${NEED_KALI[@]}"; do apt_install "$p" || warn "$p could not be installed from Kali (dependency held back by the pin) — build it by hand if you need it"; done
  fi
  (( ${#NEED_UNKNOWN[@]} )) && warn "not installed (no source found): ${NEED_UNKNOWN[*]}"

  echo
  ok "install done — run ./install-security-tools.sh verify to check the radios and binaries"
}

setup_docker_ce() {
  grep -rqs download.docker.com /etc/apt/sources.list.d/ || {
    local c; c=$(release_codename)
    $SUDO install -d -m0755 "$KEYRINGS"
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | $SUDO gpg --dearmor -o "$KEYRINGS/docker.gpg"
    echo "deb [arch=arm64 signed-by=$KEYRINGS/docker.gpg] https://download.docker.com/linux/ubuntu $c stable" | $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
    $SUDO apt-get update -qq
  }
  apt_install docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

# =============================================================================
# verify
# =============================================================================
phase_verify() {
  say "Binaries on PATH"
  local b bins=(kismet iw aircrack-ng airodump-ng aireplay-ng hcxpcapngtool hashcat nmap tailscale docker)
  for b in "${bins[@]}"; do have "$b" && ok "$b ($(command -v "$b"))" || miss "$b — not installed"; done

  say "Docker Compose v2"
  docker compose version >/dev/null 2>&1 && ok "docker compose works" || miss "docker compose — install docker-compose-v2 (or --docker-ce)"

  say "A radio that can enter monitor mode (capture needs one)"
  if have iw; then
    local found=0 phy modes
    for phy in $(iw dev 2>/dev/null | awk '/phy#/{gsub("#","");print "phy"$1}' | sort -u); do :; done
    for p in /sys/class/ieee80211/*; do
      [[ -e $p ]] || continue
      phy=$(basename "$p")
      modes=$(iw phy "$phy" info 2>/dev/null | awk '/Supported interface modes/{f=1;next}/^\t[A-Za-z]/{f=0}f' | tr -d ' \t*')
      if grep -qi monitor <<<"$modes"; then ok "$phy supports monitor mode"; found=1; else info "$phy: no monitor mode"; fi
    done
    (( found )) || miss "no radio advertises monitor mode — the wardrive capture needs a monitor+injection USB adapter (e.g. the deck's wlan1)"
  else
    miss "iw not installed — cannot check the radios"
  fi

  say "Tailscale"
  have tailscale && { tailscale status >/dev/null 2>&1 && ok "connected" || info "installed, not up — sudo tailscale up"; } || miss "tailscale not installed"
}

# =============================================================================
# wardrive-ui checkout (does not auto-start the privileged container)
# =============================================================================
phase_wardrive() {
  have git || die "git required — ./install-security-tools.sh install first"
  if [[ -d $WARDRIVE_DIR/.git ]]; then
    say "wardrive-ui already at $WARDRIVE_DIR"; git -C "$WARDRIVE_DIR" pull --ff-only 2>/dev/null || true
  else
    say "Cloning wardrive-ui → $WARDRIVE_DIR"
    mkdir -p "$(dirname "$WARDRIVE_DIR")"; git clone "$WARDRIVE_URL" "$WARDRIVE_DIR"
  fi
  if [[ ! -f $WARDRIVE_DIR/config.json ]]; then
    cp "$WARDRIVE_DIR/config.example.json" "$WARDRIVE_DIR/config.json"
    warn "wrote a starter config.json — EDIT IT (interface name, crack host) before starting the container"
  fi
  mkdir -p "$WARDRIVE_DIR/data/wordlists"
  echo
  info "The wardrive-ui is a privileged, host-network container; it is not auto-started."
  info "When config.json is right:  cd $WARDRIVE_DIR && docker compose up -d"
  info "Reach it over Tailscale at http://<deck-tailscale-ip>:8088 (firewall 8088 to tailscale0 only)."
}

# =============================================================================
(( EUID != 0 )) || [[ $ACTION == plan || $ACTION == verify ]] || die "run as your normal user (sudo is used where needed), not root"
case $ACTION in
  plan)     phase_plan ;;
  install)  phase_install ;;
  verify)   phase_verify ;;
  wardrive) phase_wardrive ;;
esac
