#!/usr/bin/env bash
# Android エミュレータのセットアップ（macOS / Linux）
#  - Android SDK が無ければ command-line tools を取得
#  - emulator / platform-tools / platform / build-tools / システムイメージをインストール
#  - AVD（仮想端末）を作成
#  - アプリの APK をビルド
set -euo pipefail

API_LEVEL="${API_LEVEL:-34}"
AVD_NAME="${AVD_NAME:-photobridge_api${API_LEVEL}}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

case "$(uname -s)" in
  Darwin) OS=mac;   DEFAULT_SDK="$HOME/Library/Android/sdk" ;;
  Linux)  OS=linux; DEFAULT_SDK="$HOME/Android/Sdk" ;;
  *) echo "未対応の OS です。Windows では Android Studio の Device Manager を使ってください。" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64|aarch64) ABI=arm64-v8a ;;
  *)             ABI=x86_64 ;;
esac

export ANDROID_HOME="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$DEFAULT_SDK}}"
SDKMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager"
AVDMANAGER="$ANDROID_HOME/cmdline-tools/latest/bin/avdmanager"

command -v java >/dev/null || { echo "Java 17 以上が必要です（例: brew install openjdk@17 / apt install openjdk-17-jdk）" >&2; exit 1; }

if [[ ! -x "$SDKMANAGER" ]]; then
  echo "==> Android command-line tools を $ANDROID_HOME にインストール"
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  tmp="$(mktemp -d)"
  curl -fSL -o "$tmp/ct.zip" "https://dl.google.com/android/repository/commandlinetools-${OS}-11076708_latest.zip"
  unzip -q "$tmp/ct.zip" -d "$tmp"
  rm -rf "$ANDROID_HOME/cmdline-tools/latest"
  mv "$tmp/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -rf "$tmp"
fi

IMAGE="system-images;android-${API_LEVEL};google_apis;${ABI}"
echo "==> SDK パッケージをインストール（初回は数GBダウンロードします）"
yes | "$SDKMANAGER" --licenses >/dev/null || true
"$SDKMANAGER" "platform-tools" "emulator" "platforms;android-${API_LEVEL}" "build-tools;34.0.0" "$IMAGE"

if "$ANDROID_HOME/emulator/emulator" -list-avds | grep -qx "$AVD_NAME"; then
  echo "==> AVD '$AVD_NAME' は作成済み"
else
  echo "==> AVD '$AVD_NAME' を作成"
  echo no | "$AVDMANAGER" create avd -n "$AVD_NAME" -k "$IMAGE" -d pixel_6
fi

echo "sdk.dir=$ANDROID_HOME" > "$ROOT_DIR/local.properties"

echo "==> APK をビルド"
(cd "$ROOT_DIR" && ./gradlew assembleDebug)

if [[ "$OS" == linux && ! -e /dev/kvm ]]; then
  echo "警告: /dev/kvm がありません。CPU の仮想化支援（VT-x / AMD-V）を BIOS で有効にし、KVM を導入してください。" >&2
fi

cat <<MSG

セットアップ完了。
  起動:          scripts/run-emulator.sh
  位置を変える:  scripts/geo.sh 35.681236 139.767125
MSG
