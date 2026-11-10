#!/usr/bin/env bash
# エミュレータを起動し、アプリをインストール・権限設定して起動する
set -euo pipefail

API_LEVEL="${API_LEVEL:-34}"
AVD_NAME="${AVD_NAME:-photobridge_api${API_LEVEL}}"
PKG="com.example.photobridge"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APK="$ROOT_DIR/app/build/outputs/apk/debug/app-debug.apk"

case "$(uname -s)" in
  Darwin) DEFAULT_SDK="$HOME/Library/Android/sdk" ;;
  *)      DEFAULT_SDK="$HOME/Android/Sdk" ;;
esac
export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK}}"
ADB="$ANDROID_HOME/platform-tools/adb"
EMULATOR="$ANDROID_HOME/emulator/emulator"

[[ -f "$APK" ]] || { echo "APK がありません。先に scripts/setup-emulator.sh を実行してください。" >&2; exit 1; }

if ! "$ADB" devices | grep -q '^emulator-'; then
  echo "==> エミュレータ '$AVD_NAME' を起動"
  # 画面なしで動かしたい場合は EMULATOR_OPTS="-no-window" を指定
  nohup "$EMULATOR" -avd "$AVD_NAME" -no-snapshot-save ${EMULATOR_OPTS:-} >/tmp/photobridge-emulator.log 2>&1 &
fi

echo "==> 起動待ち"
"$ADB" wait-for-device
until [[ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do sleep 2; done

echo "==> アプリをインストール"
"$ADB" install -r -g "$APK"

# 開発者オプションの「仮の現在地情報アプリ」に設定するのと同じ操作
"$ADB" shell appops set "$PKG" android:mock_location allow
"$ADB" shell pm grant "$PKG" android.permission.POST_NOTIFICATIONS 2>/dev/null || true

"$ADB" shell am start -n "$PKG/.MainActivity"
echo "完了。エミュレータで photobridge が起動しています。"
