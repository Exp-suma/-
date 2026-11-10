#!/usr/bin/env bash
# エミュレータの仮想 GPS に座標を送り続ける（1点保持 / 複数地点をつないで移動）
#
# 使い方:
#   scripts/geo-route.sh 35.681236,139.767125
#       → 1点を保持（HOLD 秒ごとに再送。既定で動き続ける）
#   scripts/geo-route.sh 35.681,139.767 35.690,139.700 35.700,139.690
#       → 地点を順に歩行速度でつないで移動（waypoint 間を補間）
#   scripts/geo-route.sh -f route.txt
#       → 1行 "lat,lng" のファイルを読む（# 始まりはコメント）
#
# 環境変数:
#   SPEED_MPS   移動速度 m/s（既定 1.4 = 徒歩）
#   INTERVAL    送信間隔 秒（既定 1）
#   LOOP        1 なら最後まで行ったら先頭に戻って繰り返す
#   HOLD        1地点のときの保持秒数（既定 0 = 無限）
#   DRY_RUN     1 なら adb に送らず送信内容を表示（ロジック確認用）
set -euo pipefail

case "$(uname -s)" in
  Darwin) DEFAULT_SDK="$HOME/Library/Android/sdk" ;;
  *)      DEFAULT_SDK="$HOME/Android/Sdk" ;;
esac
ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK}}/platform-tools/adb"

SPEED_MPS="${SPEED_MPS:-1.4}"
INTERVAL="${INTERVAL:-1}"
LOOP="${LOOP:-0}"
HOLD="${HOLD:-0}"
DRY_RUN="${DRY_RUN:-0}"

# ---- 引数 → waypoint 配列 ----
pts=()
if [[ "${1:-}" == "-f" ]]; then
  [[ -n "${2:-}" && -f "$2" ]] || { echo "ファイルがありません: ${2:-}" >&2; exit 1; }
  while IFS= read -r line; do
    line="${line%%#*}"; line="$(echo "$line" | tr -d ' \t\r')"
    [[ -n "$line" ]] && pts+=("$line")
  done < "$2"
else
  [[ $# -ge 1 ]] || { echo "使い方: $0 <lat,lng> [<lat,lng> ...] | -f route.txt" >&2; exit 1; }
  pts=("$@")
fi
[[ ${#pts[@]} -ge 1 ]] || { echo "座標がありません" >&2; exit 1; }

send() { # lat lng
  if [[ "$DRY_RUN" == 1 ]]; then
    printf 'geo fix %s %s\n' "$2" "$1"   # geo fix は「経度 緯度」の順
  else
    "$ADB" emu geo fix "$2" "$1" 10 >/dev/null
  fi
}

# ---- 1地点: 保持 ----
if [[ ${#pts[@]} -eq 1 ]]; then
  IFS=, read -r lat lng <<< "${pts[0]}"
  echo "保持: 緯度 $lat, 経度 $lng（Ctrl+C で停止）"
  end=0; [[ "$HOLD" != 0 ]] && end=$(( $(date +%s) + HOLD ))
  while :; do
    send "$lat" "$lng"
    [[ "$HOLD" != 0 && $(date +%s) -ge $end ]] && break
    sleep "$INTERVAL"
  done
  exit 0
fi

# ---- 複数地点: 補間して移動 ----
play_once() {
  for ((i=0; i<${#pts[@]}-1; i++)); do
    IFS=, read -r lat1 lng1 <<< "${pts[i]}"
    IFS=, read -r lat2 lng2 <<< "${pts[i+1]}"
    # 区間距離（簡易 equirectangular, m）と所要ステップ数
    read -r steps < <(awk -v a1="$lat1" -v o1="$lng1" -v a2="$lat2" -v o2="$lng2" \
      -v sp="$SPEED_MPS" -v itv="$INTERVAL" 'BEGIN{
        R=6371000; d2r=3.14159265358979/180;
        x=(o2-o1)*d2r*cos((a1+a2)/2*d2r); y=(a2-a1)*d2r;
        dist=R*sqrt(x*x+y*y); n=int(dist/(sp*itv)+0.5); if(n<1)n=1; print n }')
    for ((s=1; s<=steps; s++)); do
      read -r lat lng < <(awk -v a1="$lat1" -v o1="$lng1" -v a2="$lat2" -v o2="$lng2" \
        -v s="$s" -v n="$steps" 'BEGIN{ f=s/n; printf "%.6f %.6f\n", a1+(a2-a1)*f, o1+(o2-o1)*f }')
      send "$lat" "$lng"
      sleep "$INTERVAL"
    done
  done
}

echo "移動開始: ${#pts[@]} 地点, ${SPEED_MPS} m/s（Ctrl+C で停止）"
if [[ "$LOOP" == 1 ]]; then while :; do play_once; done; else play_once; fi
echo "到着しました"
