#!/usr/bin/env bash
# Host をこのシェルから直接起動して、ターミナルの画面収録・アクセシビリティ権限を引き継がせる
set -eu
cd "$(dirname "$0")/../.."

host="build/DerivedData/Build/Products/Debug/PadBridge Host.app/Contents/MacOS/PadBridge Host"
if pgrep -f "PadBridge Host.app/Contents/MacOS" >/dev/null; then
  echo "PadBridge Host が起動中です。Bonjour の名前がぶつかるので、終了してから実行してください。" >&2
  exit 1
fi

code=$(LC_ALL=C tr -dc 'ABCDEFGHJKMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 10 || true)
"$host" -PadBridgeTestPairingCode "$code" &
host_pid=$!
trap 'kill "$host_pid" 2>/dev/null || true' EXIT
sleep 2
port=$(lsof -nP -a -p "$host_pid" -iTCP -sTCP:LISTEN | awk 'NR == 2 { sub(/.*:/, "", $9); print $9 }')
build/e2e "$code" "$port"
