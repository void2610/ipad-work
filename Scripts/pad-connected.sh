#!/bin/bash
# 動いている Host に iPad がつながっていれば 0 で終わる。引数で Host のプロセスを渡すと、そのプロセスだけを見る
set -uo pipefail
pids=("$@")
[ ${#pids[@]} -eq 0 ] && pids=($(pgrep -x "PadBridge Host"))
for pid in "${pids[@]}"; do
    # Network.framework が受けた接続は lsof に TCP として出ないことがあり、22:05 からつながっていた iPad を見落として入れ替えた。Host が残す接続と切断の記録で決める
    last=$(/usr/bin/log show --last 24h --style compact --predicate "processIdentifier == $pid AND subsystem == \"dev.void2610.padbridge.host\" AND category == \"server\"" 2>/dev/null | grep -E "\] (接続: |切断$)" | tail -1)
    case "$last" in *"] 接続: "*) exit 0 ;; esac
    # 補助アプリとの接続はループバックなので、それ以外の接続を iPad とみなす
    if lsof -nP -a -p "$pid" -iTCP -sTCP:ESTABLISHED 2>/dev/null | grep TCP | grep -v -e "127.0.0.1" -e "\[::1\]" >/dev/null; then
        exit 0
    fi
done
exit 1
