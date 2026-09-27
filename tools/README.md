# Deck tools: scan + security-stack installer

The deck runs a Kali-style wifi-audit stack (Kismet, aircrack-ng, hashcat, the
[wardrive-ui](https://github.com/mikeshoss/wardrive) capture service…). When the
deck moves from Kali to Ubuntu/Omarchy, these two scripts carry that stack over.

> Only use this deck against networks you own or are authorized to test.

## The two scripts

| Script | Runs on | Does |
|---|---|---|
| `deck-scan.sh` | the deck (Kali now, or Ubuntu later) | Read-only inventory: radios + monitor-mode capability, installed security tools, services, Docker, Tailscale, the wardrive checkout. Writes a JSON. |
| `install-security-tools.sh` | the Ubuntu deck | Reinstalls that stack from the right sources. Reads the scan's JSON to install exactly what you had. |

## Workflow

**1. Scan the deck as it is now** (before you reflash), so nothing is forgotten:

```bash
./deck-scan.sh                 # prints a report, writes deck-inventory-<host>-<date>.json
```

Keep that JSON. It changes nothing on the deck and holds only tool/interface
names — no keys, no captures.

**2. On the fresh Ubuntu deck, see the plan** (nothing is installed yet):

```bash
./install-security-tools.sh plan --from-inventory deck-inventory-warlord-*.json
```

It groups every tool by where it comes from: Ubuntu's archive, the Kismet repo,
the Tailscale repo, Docker, or the (opt-in, pinned) Kali repo.

**3. Install:**

```bash
./install-security-tools.sh install --from-inventory deck-inventory-warlord-*.json
# add --with-kali for the Kali-only extras (hostapd-wpe, eaphammer, …)
```

**4. Verify** the binaries are on PATH and a radio can enter monitor mode:

```bash
./install-security-tools.sh verify
```

**5. Bring the wardrive service back:**

```bash
./install-security-tools.sh wardrive     # clones to ~/code/wardrive-ui, writes a starter config.json
# edit ~/code/wardrive-ui/config.json (interface, crack host), then:
cd ~/code/wardrive-ui && docker compose up -d
```

Without an inventory, `install`/`plan` use a sensible default set
(`--group host,wifi,crack,recon`); pick groups with `--group wifi,crack`.

## Where each tool comes from on Ubuntu 26.04 arm64

Almost the whole stack is in **Ubuntu's own arm64 archive** — `apt install` and
done: aircrack-ng, hcxtools, hcxdumptool, hashcat, iw, reaver, bully, wifite,
mdk4, pixiewps, cowpatty, bettercap, tshark, tcpdump, nmap, masscan, hydra,
john, macchanger, docker, flask.

Two need their **own apt repos** (both publish arm64; the installer adds them):

- **Kismet** — `kismetwireless.net` repo. Ubuntu 26.04 ("resolute") isn't listed
  yet, so the installer falls back to the newest release it does publish
  (`plucky`); Kismet's debs work across recent Ubuntu releases.
- **Tailscale** — `pkgs.tailscale.com`, which does carry `resolute` for arm64.

A handful are **Kali-only** (hostapd-wpe, eaphammer, wifipumpkin3, airgeddon,
fluxion). `--with-kali` adds the Kali repo **pinned to priority 100**, so it can
never upgrade or replace an Ubuntu base package — Kali is used *only* for a
package Ubuntu doesn't have. It's off by default.

The **wardrive-ui** needs nothing special on the host beyond Kismet + Tailscale +
Docker: it's a privileged, host-network container that carries its own attack
tools (aircrack-ng, hcxtools, iw…) in its Dockerfile, and those all build for
arm64.

## Gotchas

- **A monitor-mode radio is hardware, not a package.** Capture needs a USB
  adapter that does monitor mode + injection (the deck's `wlan1`). `verify`
  checks whether any radio advertises monitor mode and says so if none does.
- **The Kali repo is a loaded gun if unpinned.** Never add it without the
  priority pin this script writes (`/etc/apt/preferences.d/99-kali-pin`);
  unpinned, `apt upgrade` would start pulling Kali's libc and break the system.
  If a Kali-only tool won't install because a dependency is held back by the
  pin, build that one tool from source rather than loosening the pin.
- **Group memberships need a re-login.** The installer adds you to the `kismet`
  and `docker` groups; log out and back in before running Kismet unprivileged or
  `docker` without sudo.
- **The wardrive container is privileged and host-network** (it drives the
  radio). The installer clones and configures it but does **not** auto-start it —
  edit `config.json` first, then `docker compose up -d` yourself.
- `deck-scan.sh` runs on the current Kali too — Kali is Debian-based, so dpkg,
  systemctl, ss and iw are all there. Run it before reflashing.

## Tested

`deck-scan.sh` was run in a container and produces valid JSON that the installer
reads back. `install-security-tools.sh plan` and `--from-inventory` resolution
are checked against the real Ubuntu 26.04 arm64 archive and the live
Kismet/Tailscale repos — every tool routes to a real source. A representative
`install` + `verify` (Kismet + Tailscale repos, the wifi group, monitor-mode
check) is being validated in an arm64 Ubuntu 26.04 container. Nothing has run on
the deck itself yet — `plan` and `deck-scan.sh` change nothing, so start there.
