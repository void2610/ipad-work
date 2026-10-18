#!/bin/bash
# 動いている Host に iPad がつながっていれば 0 で終わる。補助アプリとの接続はループバックなので、それ以外の接続を iPad とみなす
set -uo pipefail
for pid in $(pgrep -x "PadBridge Host"); do
    if lsof -nP -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep TCP | grep -v -e "127.0.0.1" -e "\[::1\]" >/dev/null; then
        exit 0
    fi
done
exit 1
