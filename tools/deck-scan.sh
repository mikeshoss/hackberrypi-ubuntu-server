#!/bin/bash
# =============================================================================
# HackberryPi CM5 - deck inventory scan
# =============================================================================
# Read-only. Run it ON THE DECK to record what security/wifi tooling is
# installed, what is running, and how the radios and the wardrive service are
# set up. It writes a JSON file that install-security-tools.sh can replay onto
# a fresh Ubuntu deck (--from-inventory), and prints a readable report.
#
# It changes nothing: no installs, no service starts, no radio mode changes.
# Works on the deck's current Kali/Debian and on Ubuntu after the move — both
# have dpkg, systemctl, ss and iw.
#
# Usage:
#   ./deck-scan.sh                 # report + write ./deck-inventory-<host>-<date>.json
#   ./deck-scan.sh -o out.json     # choose the output path
#   sudo ./deck-scan.sh            # a bit more detail (iw phy info, some ss rows)
#
# Nothing sensitive is collected: package names, service names, interface
# names and driver names only — no keys, no captures, no wordlist contents.
# Read it before you paste it anywhere.
# =============================================================================
set -uo pipefail

OUT=""
for ((i = 1; i <= $#; i++)); do
  case ${!i} in
    -o|--out) j=$((i + 1)); OUT=${!j:-} ;;
    -h|--help) sed -n '2,/^# ===/{/^# ===/d;s/^# \{0,1\}//;p}' "$0"; exit 0 ;;
  esac
done

host=$(hostname 2>/dev/null || echo deck)
OUT=${OUT:-deck-inventory-$host-$(date +%Y%m%d-%H%M%S).json}

GREEN='\033[0;32m'; BLUE='\033[1;34m'; DIM='\033[2m'; NC='\033[0m'
have() { command -v "$1" >/dev/null 2>&1; }
say()  { printf "\n${BLUE}== %s${NC}\n" "$*"; }
row()  { printf "  %-16s %s\n" "$1" "$2"; }

# ---- JSON emit (no jq dependency; values are simple package/interface names) -
json_escape() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '%s' "$s"; }
jstr() { printf '"%s"' "$(json_escape "$1")"; }
jarr() { # jarr item item item...  -> ["a","b",...]  (empty items skipped)
  local out="[" first=1 x
  for x in "$@"; do
    [[ -z $x ]] && continue
    [[ $first == 1 ]] && first=0 || out+=","
    out+=$(jstr "$x")
  done
  printf '%s]' "$out"
}

# ---- curated security / wifi tool catalogue --------------------------------
# Package names we recognise and report by category. Anything installed that
# is not here still lands in packages_all, so nothing is missed.
WIFI_PKGS="aircrack-ng kismet kismet-core hcxtools hcxdumptool reaver bully wifite mdk3 mdk4 pixiewps cowpatty hostapd hostapd-wpe eaphammer wifipumpkin3 airgeddon fluxion wireless-tools iw rfkill macchanger"
CRACK_PKGS="hashcat john john-data hydra medusa crunch"
RECON_PKGS="nmap masscan bettercap tshark tcpdump wireshark ettercap-text-only dsniff netdiscover arp-scan responder"
NET_PKGS="tailscale wireguard-tools openvpn proxychains4 tor"
CORE_PKGS="docker.io docker-ce docker-compose-v2 docker-compose git python3 python3-flask python3-pip"

pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
pkg_ver() { dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true; }

# =============================================================================
say "System"
model=$(tr -d '\0' 2>/dev/null </proc/device-tree/model || echo unknown)
arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
osname=$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}" )
osid=$( . /etc/os-release 2>/dev/null; echo "${ID:-unknown}" )
kernel=$(uname -r)
row model "$model"; row arch "$arch"; row os "$osname"; row kernel "$kernel"

# =============================================================================
say "WiFi radios (monitor mode is what capture needs)"
declare -a WIFI_IFACES=()
declare -a WIFI_JSON=()
if have iw; then
  for dev in /sys/class/net/*/wireless; do
    [[ -e $dev ]] || continue
    ifn=$(basename "$(dirname "$dev")")
    WIFI_IFACES+=("$ifn")
    drv=$(basename "$(readlink -f "/sys/class/net/$ifn/device/driver" 2>/dev/null)" 2>/dev/null || echo "?")
    phy=$(cat "/sys/class/net/$ifn/phy80211/name" 2>/dev/null || echo "")
    modes=""
    if [[ -n $phy ]]; then
      modes=$(iw phy "$phy" info 2>/dev/null | awk '/Supported interface modes/{f=1;next} /^\t[A-Za-z]/{f=0} f{gsub(/[* \t]/,"");print}' | paste -sd, -)
    fi
    mon="no"; [[ $modes == *monitor* ]] && mon="yes"
    printf "  %-8s driver=%-14s monitor=%s  modes=%s\n" "$ifn" "$drv" "$mon" "${modes:-unknown}"
    WIFI_JSON+=("{\"name\":$(jstr "$ifn"),\"driver\":$(jstr "$drv"),\"phy\":$(jstr "$phy"),\"monitor\":$(jstr "$mon"),\"modes\":$(jstr "${modes:-}")}")
  done
  (( ${#WIFI_IFACES[@]} )) || row "(none)" "no wireless interfaces found"
else
  row iw "not installed — cannot enumerate radios (install: iw)"
fi

# =============================================================================
say "Security / wifi packages installed"
declare -a INSTALLED=()
print_group() { # print_group LABEL "pkg pkg pkg"
  local label=$1 list=$2 p found=()
  for p in $list; do pkg_installed "$p" && found+=("$p"); done
  if (( ${#found[@]} )); then
    printf "  ${GREEN}%-8s${NC} %s\n" "$label" "${found[*]}"
    INSTALLED+=("${found[@]}")
  fi
}
print_group wifi   "$WIFI_PKGS"
print_group crack  "$CRACK_PKGS"
print_group recon  "$RECON_PKGS"
print_group net    "$NET_PKGS"
print_group core   "$CORE_PKGS"
(( ${#INSTALLED[@]} )) || row "(none)" "none of the known tools are installed"

# Kali metapackages tell us which tool groups were pulled in wholesale.
declare -a METAS=()
for m in $(dpkg-query -Wf '${Package}\n' 2>/dev/null | grep -E '^kali-(linux|tools)-' || true); do METAS+=("$m"); done
(( ${#METAS[@]} )) && row "kali metas" "${METAS[*]}"

# =============================================================================
say "Services and listening ports"
declare -a SERVICES=()
if have systemctl; then
  while read -r unit; do
    [[ -n $unit ]] && SERVICES+=("$unit")
  done < <(systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null \
            | awk '{print $1}' | grep -iE 'kismet|tailscale|docker|wardrive|bettercap|ssh' || true)
  (( ${#SERVICES[@]} )) && printf "  running: %s\n" "${SERVICES[*]}" || row running "(none of interest)"
fi
if have ss; then
  ports=$(ss -tulnH 2>/dev/null | awk '{print $5}' | grep -oE '[0-9]+$' | sort -un | paste -sd, - || true)
  row "listen ports" "${ports:-(none)}"
fi

# =============================================================================
say "Docker"
declare -a CONTAINERS=()
has_docker=no
if have docker && docker info >/dev/null 2>&1; then
  has_docker=yes
  while read -r c; do [[ -n $c ]] && CONTAINERS+=("$c"); done < <(docker ps -a --format '{{.Names}} ({{.Image}}) {{.Status}}' 2>/dev/null)
  if (( ${#CONTAINERS[@]} )); then printf "  %s\n" "${CONTAINERS[@]}"; else row containers "(none)"; fi
elif have docker; then
  row docker "installed but daemon not reachable (try: sudo systemctl start docker, or add yourself to the docker group)"
else
  row docker "not installed"
fi

# =============================================================================
say "Tailscale"
has_tailscale=no; ts_state=""
if have tailscale; then
  has_tailscale=yes
  ts_state=$(tailscale status --self=true --peers=false 2>/dev/null | head -1 || echo "installed, not logged in")
  row status "${ts_state:-installed}"
else
  row tailscale "not installed"
fi

# =============================================================================
say "wardrive service"
wardrive_dir=""
for d in "$HOME/code/wardrive-ui" "$HOME/wardrive" "$HOME/code/wardrive" ./wardrive /opt/wardrive; do
  if [[ -f $d/docker-compose.yml ]] && grep -qs wardrive "$d/docker-compose.yml"; then wardrive_dir=$(cd "$d" && pwd); break; fi
done
if [[ -n $wardrive_dir ]]; then
  row checkout "$wardrive_dir"
  [[ -f $wardrive_dir/config.json ]] && row config "config.json present" || row config "config.json MISSING (copy config.example.json)"
  iface=$(grep -oE '"interface"[[:space:]]*:[[:space:]]*"[^"]+"' "$wardrive_dir/config.json" 2>/dev/null | grep -oE '"[^"]+"$' | tr -d '"' || echo "")
  [[ -n $iface ]] && row interface "$iface (the radio the UI drives)"
  wl=$(ls -1 "$wardrive_dir"/data/wordlists/ 2>/dev/null | paste -sd, - || echo "")
  [[ -n $wl ]] && row wordlists "$wl" || row wordlists "(none in data/wordlists)"
else
  row checkout "not found in the usual places — note where you keep it"
fi

# kismet host config (the wardrive UI stops host kismet to free the radio)
km=""
for f in /etc/kismet/kismet_site.conf "$HOME/.kismet/kismet_site.conf"; do [[ -f $f ]] && km=$f; done
[[ -n $km ]] && row kismet-conf "$km" || row kismet-conf "(no kismet_site.conf — default config)"

# =============================================================================
# Write the JSON inventory
mapfile -t INSTALLED_SORTED < <(printf '%s\n' "${INSTALLED[@]:-}" | sed '/^$/d' | sort -u)
mapfile -t ALLPKGS < <(dpkg-query -Wf '${Package}\n' 2>/dev/null | sort -u)

{
  printf '{\n'
  printf '  "generated": %s,\n' "$(jstr "$(date -u +%Y-%m-%dT%H:%M:%SZ)")"
  printf '  "host": %s,\n' "$(jstr "$host")"
  printf '  "system": {"model": %s, "arch": %s, "os": %s, "os_id": %s, "kernel": %s},\n' \
    "$(jstr "$model")" "$(jstr "$arch")" "$(jstr "$osname")" "$(jstr "$osid")" "$(jstr "$kernel")"
  printf '  "wifi": [%s],\n' "$(IFS=,; echo "${WIFI_JSON[*]:-}")"
  printf '  "security_packages": %s,\n' "$(jarr "${INSTALLED_SORTED[@]:-}")"
  printf '  "kali_metapackages": %s,\n' "$(jarr "${METAS[@]:-}")"
  printf '  "services_running": %s,\n' "$(jarr "${SERVICES[@]:-}")"
  printf '  "has_docker": %s,\n' "$([[ $has_docker == yes ]] && echo true || echo false)"
  printf '  "containers": %s,\n' "$(jarr "${CONTAINERS[@]:-}")"
  printf '  "has_tailscale": %s,\n' "$([[ $has_tailscale == yes ]] && echo true || echo false)"
  printf '  "wardrive_dir": %s,\n' "$(jstr "$wardrive_dir")"
  printf '  "package_count": %s\n' "${#ALLPKGS[@]}"
  printf '}\n'
} >"$OUT"

echo
printf "${GREEN}Inventory written:${NC} %s\n" "$OUT"
printf "${DIM}Next: on the Ubuntu deck, ./install-security-tools.sh --from-inventory %s --plan${NC}\n" "$OUT"
