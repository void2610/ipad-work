#!/bin/bash
# Host を新しいビルドに更新する。音声入力中に終了させるとその音声入力が無駄になり、iPad が接続中なら操作が途切れるので、その間は更新しない
set -euo pipefail
app="$1"
here=$(cd "$(dirname "$0")" && pwd)
swift "$here/TypelessIdle.swift" || { echo "更新を中止しました" >&2; exit 1; }
if "$here/pad-connected.sh"; then
    echo "iPad が接続中のため、更新を中止しました" >&2
    exit 1
fi
pkill -x "PadBridge Host" || true
while pgrep -x "PadBridge Host" >/dev/null; do sleep 0.1; done
# 終了直後に開くと LaunchServices が起動に失敗する (-600) ことがあるので、起動を確認できるまで開き直す
for _ in 1 2 3 4 5 6 7 8 9 10; do
    open "$app" || true
    sleep 1.5
    if pgrep -x "PadBridge Host" >/dev/null; then
        echo "PadBridge Host を起動しました"
        exit 0
    fi
done
echo "PadBridge Host を起動できません" >&2
exit 1
