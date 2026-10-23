#!/bin/bash
# self-check for install.sh: validates the layout the script produces
set -euo pipefail
APP_DIR="${1:-/home/anderson/MiniMax Agent}"
DAEMON_DIR="$APP_DIR/resources/resources/daemon"

fail=0
check() { if eval "$2" >/dev/null 2>&1; then echo "OK   $1"; else echo "FAIL $1"; fail=1; fi; }

check "resources/app -> ../app-unpacked" '[ "$(readlink "$APP_DIR/resources/app")" = "../app-unpacked" ]'
check "app.asar.original kept"           '[ -f "$APP_DIR/resources/app.asar.original" ]'
check "native-sqlite shim"               '[ -f "$APP_DIR/native-sqlite/index.cjs" ]'
check "daemon better-sqlite3"            '[ -d "$DAEMON_DIR/node_modules/better-sqlite3" ]'
check "daemon fs-native-extensions"      '[ -d "$DAEMON_DIR/node_modules/fs-native-extensions" ]'
check "electron runtime"                 '[ -x "$APP_DIR/electron" ]'

ELECTRON_RUN_AS_NODE=1 NODE_PATH="$APP_DIR/app-unpacked/node_modules" \
  "$APP_DIR/electron" -e "
    const {createRequire}=require('module');
    const r=createRequire('$APP_DIR/app-unpacked/dist/main/modules/local-runtime/utility/utility-process-manager.js');
    for (const m of ['better-sqlite3','node-pty']) {
      try { r.resolve(m); console.log('OK   resolve '+m); }
      catch(e) { console.log('FAIL resolve '+m); process.exit(1); }
    }
  " || fail=1

( cd "$DAEMON_DIR" && node -e "require('better-sqlite3');require('fs-native-extensions');console.log('OK   daemon native deps load')" ) || fail=1

[ "$fail" = 0 ] && echo "ALL CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit "$fail"
