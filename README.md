# MiniMax Agent for Linux (rootless installer + runtime fixes)

Unofficial Linux installer for **MiniMax Agent** (the MiniMax coding/agent desktop app).
MiniMax ships Windows and macOS only — there is no official Linux build.

This repo is **not** a fork of the app source. It is a self-contained installer that:

1. downloads the community package (`unn-Known1/minimax-agent-linux` `.deb`),
2. downloads the matching Electron runtime,
3. unpacks the app **outside** the `.asar` container,
4. wires the native SQLite module for the Electron ABI,
5. installs the daemon runtime dependencies the community package forgets,
6. installs a launcher, a desktop entry and a `systemd --user` service.

Everything lands in the user home directory. **No `sudo`, no `dpkg -i`, no `/opt`.**

---

## Why the unpack step matters

The community `.deb` ships the app as `resources/app.asar`. The app boots a Node
utility process with `utilityProcess.fork()` pointing at an **ESM** entry point
inside that `.asar`.

Node's ESM loader cannot read files inside an `.asar` archive. The forked child
dies during boot, the `postMessage` handshake throws, and the GUI shows:

```
Service start failed
The local service failed to start. Failure reason: utility runtime initialization handshake failed
```

which cascades into `local_runtime_unavailable`, an empty model list and an
unavailable plugin catalog.

Extracting the archive and exposing it as `resources/app` (a real directory on
disk) gives `utilityProcess.fork()` a real path. The original archive is kept as
`resources/app.asar.original`.

## Why the native-sqlite shim matters

The LocalRuntime rebuilds `better-sqlite3` for the Electron ABI on first use,
but the packaged `.asar` ships no `node_modules/.bin/prebuild-install`, so the
rebuild fails. `MAVIS_SQLITE3_MODULE_PATH` points the app at the Linux binary
that is already present in the unpacked tree.

## Why the daemon dependency step matters

The daemon's `package.json` inside the `.deb` declares **no** dependencies, so
the upstream `setup.sh` runs `npm install --omit=dev` and installs nothing. The
daemon then dies with `MODULE_NOT_FOUND` for `better-sqlite3` and
`fs-native-extensions`. This installer installs both explicitly.

---

## Install

```bash
git clone https://github.com/andersonnarciso/minimax-agent-linux-fix.git
cd minimax-agent-linux-fix
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

- `mcode-tools development resource preparation failed` — dev-only resources that
  are not part of the port.
- `Cannot resolve @mavis/opencode-plugin` / `@mavis/opencode-skill-tool` — private
  MiniMax packages, absent from npm and from the `.asar`. Affects the `mavis`
  agent only, not the daemon itself.
- The daemon writes `~/.minimax/permission.json` in a schema the daemon then
  refuses to read (`Permission config "allow" must be an array of strings`),
  which puts `mavis.service` into a restart loop. Delete or fix that file to
  recover.

## Credits

- App and community package: [unn-Known1/minimax-agent-linux](https://github.com/unn-Known1/minimax-agent-linux)
- Electron runtime: [electron/electron](https://github.com/electron/electron) v35.7.0
- MiniMax Agent: <https://agent.minimax.io/>

This project is unofficial and is not affiliated with MiniMax. The original
application belongs to MiniMax.
