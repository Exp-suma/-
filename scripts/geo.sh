#!/usr/bin/env bash
# エミュレータの仮想 GPS の位置を設定する
# 使い方: scripts/geo.sh <緯度> <経度> [高度m]
set -euo pipefail
[[ $# -ge 2 ]] || { echo "使い方: $0 <緯度> <経度> [高度m]" >&2; exit 1; }
case "$(uname -s)" in
  Darwin) DEFAULT_SDK="$HOME/Library/Android/sdk" ;;
  *)      DEFAULT_SDK="$HOME/Android/Sdk" ;;
esac
ADB="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK}}/platform-tools/adb"
# geo fix は「経度 緯度」の順
"$ADB" emu geo fix "$2" "$1" "${3:-10}"
echo "位置を 緯度 $1, 経度 $2 に設定しました"
