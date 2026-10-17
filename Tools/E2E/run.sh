#!/usr/bin/env bash
# Host をこのシェルから直接起動して、ターミナルの画面収録・アクセシビリティ権限を引き継がせる
set -eu
cd "$(dirname "$0")/../.."

host="build/DerivedData/Build/Products/Debug/PadBridge Host.app/Contents/MacOS/PadBridge Host"
code=$(LC_ALL=C tr -dc 'ABCDEFGHJKMNPQRSTUVWXYZ23456789' </dev/urandom | head -c 10 || true)
# 普段使いの Host が動いていても Bonjour 名がぶつからないよう、テスト専用の名前で広告する
name="PadBridge-E2E-$code"
"$host" -PadBridgeTestPairingCode "$code" -PadBridgeTestServiceName "$name" &
host_pid=$!
trap 'kill "$host_pid" 2>/dev/null || true' EXIT
sleep 2
port=$(lsof -nP -a -p "$host_pid" -iTCP -sTCP:LISTEN | awk 'NR == 2 { sub(/.*:/, "", $9); print $9 }')
build/e2e "$code" "$name" "$port"
