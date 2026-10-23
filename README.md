# MiniMax Agent for Linux: FIX for the community port

Unofficial Linux installer for **MiniMax Agent** (the MiniMax coding/agent desktop app).
MiniMax ships Windows and macOS only. There is no official Linux build.

**This is a FIX for the community port.** The community package
[`unn-Known1/minimax-agent-linux`](https://github.com/unn-Known1/minimax-agent-linux)
does not work on Ubuntu, and its latest release (v3.1.4, published 3 days
before this installer) still does not. See
[Why the community package fails](#why-the-community-package-fails-on-ubuntu)
below for the exact error and the root cause.

This repo is **not** a fork of the app source. It is a self-contained installer that:

1. downloads the community package (`unn-Known1/minimax-agent-linux` `.deb`),
2. downloads the matching Electron runtime,
3. unpacks the app **outside** the `.asar` container,
4. wires the native SQLite module for the Electron ABI,
5. installs the daemon runtime dependencies the community package forgets,
6. installs a launcher, a desktop entry and a `systemd --user` service.

Everything lands in the user home directory. **No `sudo`, no `dpkg -i`, no `/opt`.**

---

## Why the community package fails on Ubuntu

Tested on Ubuntu 26.04.1 LTS with the latest community release, **v3.1.4**,
published 3 days before this installer. The install goes through, the window
opens, and then the app reports:

```
Service start failed
The local service failed to start. Failure reason: utility runtime initialization handshake failed
```

Everything downstream breaks with it:

- `local_runtime_unavailable`
- the model list never loads
- `Plugin catalog is temporarily unavailable.`
- `Sites failed to load. Try again later.`

This is not a stale package. v3.1.4 is the current release and it ships the
app still packed inside `resources/app.asar`. The upstream `build.sh` re-packs
the archive instead of unpacking it, so the root cause below is still present
in the newest build.

### Root cause 1: the app is packed inside the `.asar`

The app boots a Node utility process with `utilityProcess.fork()` pointing at
an **ESM** entry point inside `resources/app.asar`.

Node's ESM loader cannot read files inside an `.asar` archive. The forked child
dies during boot, the `postMessage` handshake throws, and the GUI shows the
error above.

The fix is to extract the archive and expose it as `resources/app` (a real
directory on disk), which gives `utilityProcess.fork()` a real path. The
original archive is kept as `resources/app.asar.original`.

### Root cause 2: the native SQLite module cannot be rebuilt

The LocalRuntime rebuilds `better-sqlite3` for the Electron ABI on first use,
but the packaged `.asar` ships no `node_modules/.bin/prebuild-install`, so the
rebuild fails. `MAVIS_SQLITE3_MODULE_PATH` points the app at the Linux binary
that is already present in the unpacked tree.

### Root cause 3: the daemon ships with no dependencies

The daemon's `package.json` inside the `.deb` declares **no** dependencies, so
the upstream `setup.sh` runs `npm install --omit=dev` and installs nothing. The
daemon then dies with `MODULE_NOT_FOUND` for `better-sqlite3` and
`fs-native-extensions`. This installer installs both explicitly.

### Root cause 4: the upstream `setup.sh` does not work on Ubuntu

Beyond the missing dependencies, the upstream `setup.sh` downloads the wrong
script, targets `/opt` (so it needs `sudo`), and assumes a daemon
`package.json` that has dependencies. The `.deb` itself ships no
`daemon/node_modules` directory at all. This installer skips `setup.sh`
entirely and extracts the payload with `dpkg-deb -x`, which needs no root.

## What this installer does differently

| | community package | this installer |
|---|---|---|
| install path | `/opt`, needs `sudo dpkg -i` | `$HOME/MiniMax Agent`, no root |
| app payload | packed in `resources/app.asar` | extracted, `resources/app` is a real directory |
| `better-sqlite3` for Electron | rebuilt at runtime, fails | prebuilt Linux binary, wired via `MAVIS_SQLITE3_MODULE_PATH` |
| daemon deps | not declared, not installed | `better-sqlite3` and `fs-native-extensions` installed explicitly |
| Electron runtime | downloaded by a separate `setup.sh` | downloaded and verified by `install.sh` |
| service | system-wide `dpkg` install | `systemd --user` unit in `$HOME/.config/systemd/user` |
| verification | none | `check-install.sh` validates the layout and the native modules |

---

## Install

```bash
git clone https://github.com/andersonnarciso/minimax-agent-linux-installer.git
cd minimax-agent-linux-installer
bash install.sh
```

Requirements: `curl`, `unzip`, `dpkg-deb`, `node >= 20`, `npm`, `npx`.

Verify an existing installation:

```bash
bash check-install.sh "$HOME/MiniMax Agent"
```

Start it:

```bash
~/.local/bin/minimax-agent
```

Daemon log:

```bash
journalctl --user -u mavis.service -f
```

## Uninstall

```bash
systemctl --user disable --now mavis.service
rm -f ~/.config/systemd/user/mavis.service
rm -f ~/.local/bin/minimax-agent
rm -f ~/.local/share/applications/minimax-agent.desktop
rm -rf ~/.local/share/icons/hicolor/*/apps/minimax-agent-hd.png
rm -rf "$HOME/MiniMax Agent"
```

User data lives in `~/.minimax` (with `~/.mavis` symlinked to it) and
`~/.config/MiniMax Agent/`.

---

## Known issues (upstream, not fixable here)

- `mcode-tools development resource preparation failed`: dev-only resources that
  are not part of the port.
- `Cannot resolve @mavis/opencode-plugin` / `@mavis/opencode-skill-tool`: private
  MiniMax packages, absent from npm and from the `.asar`. Affects the `mavis`
  agent only, not the daemon itself.
- The daemon writes `~/.minimax/permission.json` in a schema the daemon then
  refuses to read (`Permission config "allow" must be an array of strings`),
  which puts `mavis.service` into a restart loop. Delete or fix that file to
  recover.

## Credits

- App and community package: [unn-Known1/minimax-agent-linux](https://github.com/unn-Known1/minimax-agent-linux).
  The `.deb` is downloaded from its releases, it is not redistributed here.
- Electron runtime: [electron/electron](https://github.com/electron/electron) v35.7.0
- MiniMax Agent: <https://agent.minimax.io/>

This project is unofficial and is not affiliated with MiniMax. The original
application belongs to MiniMax.
