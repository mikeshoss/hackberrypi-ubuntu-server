#!/bin/bash
# Step 20 — architecture-aware replacement for the omarchy-ubuntu kit's 20-prebuilt.sh.
# Copied over the kit's own step by install-omarchy.sh (HackberryPi CM5 repo). Same software and the
# same versions as the kit at the pinned commit; only the release asset names change per architecture.
# Obsidian publishes no arm64 .deb, so on arm64 its AppImage is unpacked into /opt/Obsidian — the path
# Ubuntu's AppArmor profile for Obsidian allows user namespaces for, which keeps Electron's sandbox on.
# Options: --with-pinta (flatpak).  SKIP_DEB=1 downloads the .deb files without installing them (no sudo).
. "$(dirname "$0")/lib.sh"
need curl tar

DEB_ARCH=$(dpkg --print-architecture)
case $DEB_ARCH in
  amd64) UNAME_ARCH=x86_64;  GO_ARCH=amd64; LOCALSEND_ARCH=x86-64 ;;
  arm64) UNAME_ARCH=aarch64; GO_ARCH=arm64; LOCALSEND_ARCH=arm-64 ;;
  *) die "no prebuilt Omarchy tools for architecture $DEB_ARCH" ;;
esac

AETHER_VER=4.29.8      # theme builder GUI       (official deb, amd64 + arm64)
LOCALSEND_VER=1.18.2   # file sharing            (official deb, x86-64 + arm-64)
OBSIDIAN_VER=1.13.7    # notes                   (deb on amd64, AppImage on arm64)
TENSAKU_VER=0.29.0     # screenshot annotation   (tar.gz, x86_64 + aarch64)
HERDR_VER=0.9.0        # terminal workspace mgr  (binary, x86_64 + aarch64)
CLIAMP_VER=2.2.0       # TUI music player        (binary, amd64 + arm64)
TRY_VER=1.8.1          # tobi/try                (ruby script)
NERD_VER=3.5.1         # JetBrainsMono Nerd Font

say ".deb packages (aether, localsend$([[ $DEB_ARCH == amd64 ]] && echo ', obsidian'))"
fetch "https://github.com/omacom/aether/releases/download/v$AETHER_VER/aether_${AETHER_VER}_${DEB_ARCH}.deb" "$DL/aether-$DEB_ARCH.deb"
fetch "https://github.com/localsend/localsend/releases/download/v$LOCALSEND_VER/LocalSend-$LOCALSEND_VER-linux-$LOCALSEND_ARCH.deb" "$DL/localsend-$DEB_ARCH.deb"
debs=("$DL/aether-$DEB_ARCH.deb" "$DL/localsend-$DEB_ARCH.deb")
if [[ $DEB_ARCH == amd64 ]]; then
  fetch "https://github.com/obsidianmd/obsidian-releases/releases/download/v$OBSIDIAN_VER/obsidian_${OBSIDIAN_VER}_amd64.deb" "$DL/obsidian-amd64.deb"
  debs+=("$DL/obsidian-amd64.deb")
fi
if [[ ${SKIP_DEB:-0} == 1 ]]; then
  warn "SKIP_DEB=1: the .deb files are in $DL; install them with: sudo apt-get install -y ${debs[*]}"
else
  sudo apt-get install -y "${debs[@]}"
  ok "$(printf '%s ' "${debs[@]##*/}")"
fi

if [[ $DEB_ARCH == arm64 ]]; then
  say "Obsidian (arm64 AppImage → /opt/Obsidian)"
  fetch "https://github.com/obsidianmd/obsidian-releases/releases/download/v$OBSIDIAN_VER/Obsidian-$OBSIDIAN_VER-arm64.AppImage" "$DL/Obsidian-arm64.AppImage"
  chmod +x "$DL/Obsidian-arm64.AppImage"
  # --appimage-extract needs no FUSE: it unpacks the embedded squashfs into ./squashfs-root.
  rm -rf "$BUILD/obsidian"; mkdir -p "$BUILD/obsidian"
  ( cd "$BUILD/obsidian" && "$DL/Obsidian-arm64.AppImage" --appimage-extract >/dev/null )
  sudo rm -rf /opt/Obsidian
  sudo cp -a "$BUILD/obsidian/squashfs-root" /opt/Obsidian
  sudo chmod -R a+rX /opt/Obsidian
  sudo ln -sfn /opt/Obsidian/obsidian /usr/local/bin/obsidian
  icon=$(find /opt/Obsidian -maxdepth 1 -name 'obsidian.png' -print -quit)
  [[ -n $icon ]] && install -Dm644 "$icon" "$HOME/.local/share/icons/hicolor/512x512/apps/obsidian.png"
  cat >"$HOME/.local/share/applications/obsidian.desktop" <<'DESKTOP'
[Desktop Entry]
Name=Obsidian
Comment=Knowledge base
Exec=/opt/Obsidian/obsidian %U
Terminal=false
Type=Application
Icon=obsidian
StartupWMClass=obsidian
MimeType=x-scheme-handler/obsidian;
Categories=Office;
DESKTOP
  ok "obsidian $OBSIDIAN_VER (/opt/Obsidian, launcher in ~/.local/share/applications)"
fi

say "Tensaku (screenshot editor)"
fetch "https://github.com/jondkinney/tensaku/releases/download/v$TENSAKU_VER/tensaku-v$TENSAKU_VER-$UNAME_ARCH.tar.gz" "$DL/tensaku-$UNAME_ARCH.tgz"
rm -rf "$BUILD/tensaku"; mkdir -p "$BUILD/tensaku"; tar xzf "$DL/tensaku-$UNAME_ARCH.tgz" -C "$BUILD/tensaku"
[[ -d $BUILD/tensaku/bin ]]   && cp -a "$BUILD/tensaku/bin/."   "$HOME/.local/bin/"
[[ -d $BUILD/tensaku/share ]] && cp -a "$BUILD/tensaku/share/." "$HOME/.local/share/"
command -v tensaku >/dev/null && ok "tensaku $(tensaku --version 2>/dev/null | head -1)" || warn "tensaku: binary not found in the archive, check $BUILD/tensaku"

say "Herdr, Cliamp (static binaries)"
fetch "https://github.com/herdrdev/herdr/releases/download/v$HERDR_VER/herdr-linux-$UNAME_ARCH" "$DL/herdr-$UNAME_ARCH"
fetch "https://github.com/bjarneo/cliamp/releases/download/v$CLIAMP_VER/cliamp-linux-$GO_ARCH" "$DL/cliamp-$GO_ARCH"
install -m755 "$DL/herdr-$UNAME_ARCH" "$HOME/.local/bin/herdr"; install -m755 "$DL/cliamp-$GO_ARCH" "$HOME/.local/bin/cliamp"
ok "herdr, cliamp"

say "try (tobi/try, ruby)"
mkdir -p "$HOME/.local/lib/tobi-try/lib"
for f in try.rb lib/tui.rb lib/fuzzy.rb; do
  fetch "https://raw.githubusercontent.com/tobi/try/v$TRY_VER/$f" "$DL/try-$(basename "$f")" || warn "try: $f not found at tag v$TRY_VER"
done
[[ -s $DL/try-try.rb ]] && { sed '1c#!/usr/bin/ruby' "$DL/try-try.rb" > "$HOME/.local/lib/tobi-try/try.rb"; chmod 755 "$HOME/.local/lib/tobi-try/try.rb"; }
for f in tui.rb fuzzy.rb; do [[ -s $DL/try-$f ]] && cp "$DL/try-$f" "$HOME/.local/lib/tobi-try/lib/$f"; done
ln -sfn "$HOME/.local/lib/tobi-try/try.rb" "$HOME/.local/bin/try"; ok "try"

say "mise (dev environments and AI CLI launchers)"
if command -v mise >/dev/null; then ok "already installed: $(mise --version)"; else
  curl -fsSL https://mise.run | MISE_INSTALL_PATH="$HOME/.local/bin/mise" sh; ok "mise"
fi

say "Fonts: JetBrainsMono Nerd Font, iA Writer Mono S"
mkdir -p "$HOME/.local/share/fonts/JetBrainsMonoNerd" "$HOME/.local/share/fonts/iAWriter"
fetch "https://github.com/ryanoasis/nerd-fonts/releases/download/v$NERD_VER/JetBrainsMono.zip" "$DL/JetBrainsMono.zip"
unzip -oq "$DL/JetBrainsMono.zip" -d "$HOME/.local/share/fonts/JetBrainsMonoNerd" -x '*.md' 'LICENSE*' 2>/dev/null || true
for w in Regular Bold Italic BoldItalic; do
  fetch "https://raw.githubusercontent.com/iaolo/iA-Fonts/master/iA%20Writer%20Mono/Static/iAWriterMonoS-$w.ttf" "$HOME/.local/share/fonts/iAWriter/iAWriterMonoS-$w.ttf" || true
done
fc-cache -f >/dev/null; ok "fonts installed ($(fc-list | grep -c 'JetBrainsMono Nerd') JetBrainsMono Nerd files)"

if [[ " $* " == *" --with-pinta "* ]]; then
  say "Pinta (flatpak)"; flatpak install --user -y flathub com.github.PintaProject.Pinta && ok "Pinta"
fi
ok "step 20 done"
