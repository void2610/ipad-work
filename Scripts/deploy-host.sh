#!/bin/bash
# Host を新しいビルドに入れ替える。聞き取りの最中に落とすと、その回の聞き取りが無駄になり、iPad がつながっていれば操作が切れるので入れ替えない
set -euo pipefail
app="$1"
here=$(cd "$(dirname "$0")" && pwd)
swift "$here/TypelessIdle.swift" || { echo "入れ替えない" >&2; exit 1; }
for pid in $(pgrep -x "PadBridge Host" || true); do
    # 補助アプリとの接続はループバックなので、それ以外の接続があれば iPad がつながっている
    if lsof -nP -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep TCP | grep -v -e "127.0.0.1" -e "\[::1\]" >/dev/null; then
        echo "iPad がつながっているので入れ替えない" >&2
        exit 1
    fi
done
pkill -x "PadBridge Host" || true
while pgrep -x "PadBridge Host" >/dev/null; do sleep 0.1; done
# 終わった直後に開くと LaunchServices が開けずに終わる (-600) ことがあるので、動いたと確かめるまで開き直す
for _ in 1 2 3 4 5 6 7 8 9 10; do
    open "$app" || true
    sleep 1.5
    if pgrep -x "PadBridge Host" >/dev/null; then
        echo "PadBridge Host を起動した"
        exit 0
    fi
done
echo "PadBridge Host を起動できない" >&2
exit 1
