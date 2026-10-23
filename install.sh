#!/usr/bin/env bash
# MiniMax Agent for Linux — rootless install of the community port WITH the
# upstream fixes (asar unpacked + native sqlite shim + daemon deps + user service).
#
# Usage:  bash install.sh
# Env overrides (for testing): APP_DIR, BIN_DIR, APPS_DIR, ICON_DIR, CACHE, NO_SERVICE
set -euo pipefail

APP_VER="3.1.4"
ELECTRON_VER="35.7.0"
PORT_REPO="unn-Known1/minimax-agent-linux"

DEB_URL="https://github.com/${PORT_REPO}/releases/download/v${APP_VER}/minimax-agent_${APP_VER}_amd64.deb"
DEB_SHA256="adc02ea23973758d0c09d57465d445f61eba7a650d4feba25847d7a0a9edb68a"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VER}/electron-v${ELECTRON_VER}-linux-x64.zip"
ELECTRON_SHA256="8c667169cf7e85463677b44d96ec795ab05974a1f3224ad020542580d65c66a5"

APP_DIR="${APP_DIR:-$HOME/MiniMax Agent}"
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
APPS_DIR="${APPS_DIR:-$HOME/.local/share/applications}"
ICON_ROOT="${ICON_ROOT:-$HOME/.local/share/icons/hicolor}"
CACHE="${CACHE:-$HOME/.cache/minimax-agent-linux}"
NO_SERVICE="${NO_SERVICE:-0}"

DAEMON_PORT="5321"

say() { printf '\n== %s ==\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

say "pre-flight"
for c in curl unzip dpkg-deb node npm; do
  command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"
done
command -v npx >/dev/null 2>&1 || die "missing dependency: npx (needed for @electron/asar)"
node -e 'process.exit(Number(process.versions.node.split(".")[0]) >= 20 ? 0 : 1)' \
  || die "Node.js >= 20 required (found $(node -v))"
echo "node $(node -v), npm $(npm -v)"

mkdir -p "$CACHE" "$APP_DIR" "$BIN_DIR" "$APPS_DIR"

say "1/8 downloading community package"
cd "$CACHE"
[ -f minimax-agent_${APP_VER}_amd64.deb ] || curl -fL --retry 3 -o "minimax-agent_${APP_VER}_amd64.deb" "$DEB_URL"
echo "${DEB_SHA256}  minimax-agent_${APP_VER}_amd64.deb" | sha256sum -c -

say "2/8 downloading Electron runtime ${ELECTRON_VER}"
[ -f electron-v${ELECTRON_VER}-linux-x64.zip ] \
  || curl -fL --retry 3 -o "electron-v${ELECTRON_VER}-linux-x64.zip" "$ELECTRON_URL"
echo "${ELECTRON_SHA256}  electron-v${ELECTRON_VER}-linux-x64.zip" | sha256sum -c -

say "3/8 laying out ${APP_DIR}"
# Electron runtime at the app root
unzip -q -o "electron-v${ELECTRON_VER}-linux-x64.zip" -d "$APP_DIR"
# App payload (asar + daemon + icons) from the community .deb, extracted
# without root: dpkg-deb -x only needs read access to the .deb.
rm -rf "$CACHE/deb-root"
dpkg-deb -x "minimax-agent_${APP_VER}_amd64.deb" "$CACHE/deb-root"
cp -a "$CACHE/deb-root/opt/minimax-agent/resources/." "$APP_DIR/resources/"
rm -rf "$CACHE/deb-root"

say "4/8 unpacking app.asar (fixes the utility-runtime handshake)"
# WHY: the app boots a Node utility process with utilityProcess.fork() pointing
# at an ESM entry inside resources/app.asar. Node's ESM loader cannot read
# inside an .asar, the child dies before the handshake and the GUI shows
# "utility runtime initialization handshake failed" -> local_runtime_unavailable,
# no models, no plugin catalog.
# Electron loads resources/app.asar FIRST, so the original is renamed and the
# extracted tree is exposed as resources/app.
cd "$APP_DIR"
[ -d app-unpacked ] || npx --yes @electron/asar extract resources/app.asar app-unpacked
[ -f resources/app.asar.original ] || mv resources/app.asar resources/app.asar.original
rm -rf resources/app
ln -s ../app-unpacked resources/app
echo "resources/app -> $(readlink resources/app)"

say "5/8 native-sqlite shim (prebuilt better-sqlite3 for Electron ABI)"
# WHY: the LocalRuntime tries to rebuild better-sqlite3 for the Electron ABI at
# runtime, but the packaged asar ships no node_modules/.bin/prebuild-install, so
# the rebuild fails. MAVIS_SQLITE3_MODULE_PATH points the app at the Linux
# binary that is already inside the unpacked tree.
rm -rf native-sqlite
mkdir -p native-sqlite/node_modules/better-sqlite3
cat > native-sqlite/package.json <<'JSON'
{"name":"better-sqlite3","version":"12.11.1","main":"index.cjs"}
JSON
cat > native-sqlite/index.cjs <<'JS'
module.exports = require("../app-unpacked/node_modules/better-sqlite3");
JS
cat > native-sqlite/node_modules/better-sqlite3/package.json <<'JSON'
{"name":"better-sqlite3","version":"12.11.1","main":"index.cjs"}
JSON
cat > native-sqlite/node_modules/better-sqlite3/index.cjs <<'JS'
module.exports = require("../../index.cjs");
JS

say "6/8 daemon runtime dependencies"
# WHY: the daemon package.json shipped in the .deb declares no dependencies, so
# the upstream setup.sh runs `npm install --omit=dev` and installs nothing.
# The daemon then dies with MODULE_NOT_FOUND for better-sqlite3 /
# fs-native-extensions.
DAEMON_DIR="$APP_DIR/resources/resources/daemon"
( cd "$DAEMON_DIR" && npm install --no-save --no-audit --no-fund \
    better-sqlite3@13.0.3 fs-native-extensions@1.5.1 )

say "7/8 launcher, desktop entry and icons"
cat > "$BIN_DIR/minimax-agent" <<EOF
#!/bin/bash
# MiniMax Agent (community Linux port + fixes) — rootless launcher
APP_DIR="\${APP_DIR:-$APP_DIR}"
export LD_LIBRARY_PATH="\${APP_DIR}:\${LD_LIBRARY_PATH}"
export ELECTRON_DISABLE_SECURITY_WARNINGS=1
# The generic electron binary must treat this directory as an installed app.
export ELECTRON_FORCE_IS_PACKAGED=1
# Prebuilt native better-sqlite3 for the Electron ABI (no prebuild-install in asar).
export MAVIS_SQLITE3_MODULE_PATH="\$APP_DIR/native-sqlite"

# GNOME sessions inherit the display from gnome-shell; terminals may not.
if [ -z "\$WAYLAND_DISPLAY" ] && [ -n "\$XDG_RUNTIME_DIR" ]; then
  export WAYLAND_DISPLAY="wayland-0"
fi
if [ -z "\$DISPLAY" ]; then
  for d in /tmp/.X11-unix/X*; do
    export DISPLAY=":\${d##*X}"
    break
  done
fi
if [ -z "\$XAUTHORITY" ] && [ -n "\$XDG_RUNTIME_DIR" ]; then
  for f in "\$XDG_RUNTIME_DIR"/.mutter-Xwaylandauth.*; do
    [ -r "\$f" ] && export XAUTHORITY="\$f" && break
  done
fi

exec "\${APP_DIR}/electron" "\${APP_DIR}/app-unpacked" --disable-gpu --no-sandbox "\$@"
EOF
chmod +x "$BIN_DIR/minimax-agent"

cat > "$APPS_DIR/minimax-agent.desktop" <<EOF
[Desktop Entry]
Name=MiniMax Agent
Comment=MiniMax Agent Desktop Application
Exec=$BIN_DIR/minimax-agent %U
Icon=minimax-agent-hd
Type=Application
StartupNotify=true
Categories=Network;Chat;
Keywords=AI;Agent;Assistant;Chat;
MimeType=x-scheme-handler/minimax;x-scheme-handler/minimax-agent;
Terminal=false
StartupWMClass=MiniMax Agent
EOF

# Icon set from the .ico shipped in the package
ICO="$APP_DIR/resources/resources/icon.ico"
if [ -f "$ICO" ]; then
  for s in 16 24 32 48 64 128 256 512; do
    mkdir -p "$ICON_ROOT/${s}x${s}/apps"
    if command -v magick >/dev/null 2>&1; then
      magick "$ICO[0]" -resize "${s}x${s}" "$ICON_ROOT/${s}x${s}/apps/minimax-agent-hd.png"
    elif command -v convert >/dev/null 2>&1; then
      convert "$ICO[0]" -resize "${s}x${s}" "$ICON_ROOT/${s}x${s}/apps/minimax-agent-hd.png"
    else
      cp "$ICO" "$ICON_ROOT/${s}x${s}/apps/minimax-agent-hd.ico"
    fi
  done
  command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APPS_DIR" || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -f "$ICON_ROOT" || true
fi

if [ "$NO_SERVICE" != "1" ]; then
  say "8/8 user service for the Mavis daemon"
  MAVIS_BIN="$HOME/.mavis/bin"
  mkdir -p "$MAVIS_BIN"
  [ -e "$HOME/.minimax" ] && [ ! -e "$HOME/.mavis" ] && ln -s "$HOME/.minimax" "$HOME/.mavis"
  cat > "$MAVIS_BIN/daemon-launcher.sh" <<EOF
#!/bin/bash
# Mavis Daemon Launcher — resolves Node.js dynamically for system services
export NVM_DIR="\${NVM_DIR:-\$HOME/.nvm}"
[ -s "\$NVM_DIR/nvm.sh" ] && . "\$NVM_DIR/nvm.sh" 2>/dev/null
for dir in "\$HOME/.local/bin" /usr/local/bin /usr/bin; do
  case ":\$PATH:" in *":\$dir:"*) ;; *) [ -d "\$dir" ] && PATH="\$dir:\$PATH" ;; esac
done
export PATH
exec node "\$@"
EOF
  chmod +x "$MAVIS_BIN/daemon-launcher.sh"

  UNIT_DIR="$HOME/.config/systemd/user"
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_DIR/mavis.service" <<EOF
[Unit]
Description=Mavis Daemon
After=network.target

[Service]
Type=simple
ExecStart=/bin/bash $MAVIS_BIN/daemon-launcher.sh "$DAEMON_DIR/daemon.js" --port $DAEMON_PORT --data-dir $HOME/.mavis --owner service
WorkingDirectory=$DAEMON_DIR
Environment=NODE_ENV=production
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
  systemctl --user daemon-reload
  systemctl --user enable --now mavis.service
  loginctl enable-linger "$USER" 2>/dev/null || true
  systemctl --user --no-pager status mavis.service | head -5 || true
else
  say "8/8 user service skipped (NO_SERVICE=1)"
fi

say "verification"
# ELECTRON_RUN_AS_NODE: do NOT run `electron --version` here, it boots the GUI
# and dies with "Missing X server or $DISPLAY" on a headless box.
ELECTRON_RUN_AS_NODE=1 "$APP_DIR/electron" -e "console.log('electron', process.versions.electron)"
ELECTRON_RUN_AS_NODE=1 NODE_PATH="$APP_DIR/app-unpacked/node_modules" \
  "$APP_DIR/electron" -e "
    const {createRequire}=require('module');
    const r=createRequire('$APP_DIR/app-unpacked/dist/main/modules/local-runtime/utility/utility-process-manager.js');
    for (const m of ['better-sqlite3','node-pty']) console.log(m,'->',r.resolve(m));
  "
( cd "$DAEMON_DIR" && node -e "require('better-sqlite3');require('fs-native-extensions');console.log('daemon deps OK')" )

cat <<EOF

Done. Start it with:  $BIN_DIR/minimax-agent
Daemon log:           journalctl --user -u mavis.service -f
App log:              ~/.config/MiniMax Agent/
EOF
