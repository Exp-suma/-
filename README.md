# photobridge（Fake GPS / Mock Location）

指定した緯度・経度を端末の「現在地」として他のアプリに取得させる Android アプリです。
Android 標準の **疑似ロケーション（モックロケーション）** 機能を使っており、root化は不要です。

## 機能

- 緯度・経度・精度を入力して偽の位置情報を配信
- プリセット（東京駅・大阪駅・札幌駅・那覇空港・NY・パリ）
- 歩行シミュレーション（約1.4m/sでランダムに移動）
- GPS / Network / Fused（Android 12+）の各プロバイダを同時に差し替え
- フォアグラウンドサービスで常駐し、通知から停止可能
- 配信中に座標を変えて「配信開始」を押すと即座に移動

## 動作環境

- Android 8.0（API 26）以上

## ビルド

```bash
./gradlew assembleDebug
# 出力: app/build/outputs/apk/debug/app-debug.apk
```

Android Studio でこのフォルダを開いて実行することもできます。

## Android エミュレータで使う（macOS / Linux）

```bash
scripts/setup-emulator.sh   # SDK・エミュレータ・システムイメージ導入、AVD 作成、APK ビルド
scripts/run-emulator.sh     # エミュレータ起動 → アプリをインストール・権限付与・起動
scripts/geo.sh 35.681236 139.767125   # エミュレータの仮想 GPS の位置を直接設定
```

- `ANDROID_HOME` が未設定なら `~/Library/Android/sdk`（mac）/ `~/Android/Sdk`（Linux）を使います。
- Apple Silicon では arm64、それ以外では x86_64 のイメージ（API 34, Google APIs）を使います。
- エミュレータには CPU の仮想化支援が必要です（Linux は KVM、mac は標準で対応）。
- `run-emulator.sh` は `appops set ... android:mock_location allow` で、開発者オプションの
  「仮の現在地情報アプリ」設定も自動で済ませます。
- `geo.sh` はエミュレータ自体の GPS を動かすので、アプリを使わずに位置を変えられます。
- Windows では Android Studio の Device Manager で仮想端末を作成してください。

## 使い方（実機）

1. APK をインストール
2. **設定 → 端末情報 → ビルド番号** を7回タップして開発者オプションを有効化
3. **設定 → システム → 開発者向けオプション → 仮の現在地情報アプリを選択** で「photobridge」を選ぶ
4. アプリを開き、座標を入力（またはプリセットを選択）して「偽の位置を配信開始」
5. 位置情報の権限と通知の権限を許可
6. 地図アプリなどで現在地が変わっていることを確認
7. 終了するときはアプリまたは通知の「停止」を押す

## 仕組み

`MockLocationService` が `LocationManager.addTestProvider()` でテスト用プロバイダを登録し、
1秒ごとに `setTestProviderLocation()` で指定座標を送り続けます。
OS は実際の GPS の代わりにこの値を位置情報として各アプリへ返します。

## 注意事項

- 一部のアプリは `Location.isMock()` などで疑似ロケーションを検出できます。
  Google Play 開発者サービスの Fused Location は、端末や GMS のバージョンによっては反映されない場合があります。
- 位置情報を使うアプリの開発・テストや、プライバシー保護を目的としています。
  位置情報ゲームの不正、勤怠・本人確認システムの偽装など、利用規約や法律に反する用途には使わないでください。
