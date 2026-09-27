#!/bin/bash
# Step 15 — architecture-aware replacement for the omarchy-ubuntu kit's 15-chrome.sh.
# Copied over the kit's own step by install-omarchy.sh (HackberryPi CM5 repo). The only change is the
# repository line: the kit pins arch=amd64, and Google now publishes google-chrome-stable for arm64 too.
# Ubuntu's Chromium is a confined snap that breaks Omarchy's --app web apps and native messaging.
# Option: --skip
. "$(dirname "$0")/lib.sh"
[[ " $* " == *" --skip "* ]] && { skip "Google Chrome (--skip)"; exit 0; }
if command -v google-chrome-stable >/dev/null; then ok "Google Chrome already installed: $(google-chrome-stable --version 2>/dev/null)"; exit 0; fi
ask_choice KIT_BROWSER "Install a browser for Omarchy's web apps and hotkeys?" google-chrome google-chrome none
[[ $KIT_BROWSER == none ]] && { skip "browser install (answer: none); Omarchy menu → Install → Browser offers others"; exit 0; }
need sudo curl
arch=$(dpkg --print-architecture)
case $arch in amd64|arm64) ;; *) die "Google publishes no Chrome build for $arch" ;; esac
say "Google Chrome repository ($arch)"
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | sudo gpg --dearmor -o /etc/apt/keyrings/google-chrome.gpg --yes
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/google-chrome.gpg] https://dl.google.com/linux/chrome/deb/ stable main\n' "$arch" | sudo tee /etc/apt/sources.list.d/google-chrome.list >/dev/null
sudo apt-get update
apt_install google-chrome-stable
ok "$(google-chrome-stable --version)"
