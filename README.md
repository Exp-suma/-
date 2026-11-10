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

## スマホだけで使う（GitHub Actions でビルド）

PC がなくても、GitHub Actions が自動で APK をビルドします。コードを push すると
ワークフローが走り、スマホのブラウザから最新の APK をダウンロードできます。

1. GitHub のリポジトリ → **Actions** タブ → 最新の **Build APK** を開く
2. 下の **Artifacts** から `photobridge-debug-apk` をダウンロード（zip）
3. 解凍して出てくる `app-debug.apk` をスマホにインストール
4. 開発者オプション →「仮の現在地情報アプリを選択」で photobridge を選ぶ
5. 座標を入れて「配信開始」

> 疑似ロケーションを気にしないアプリ（多くの地図アプリなど）には効きますが、
> `Location.isMock()` などで検出するアプリには効きません。

## Android エミュレータで使う（macOS / Linux）

```bash
scripts/setup-emulator.sh   # SDK・エミュレータ・システムイメージ導入、AVD 作成、APK ビルド
scripts/run-emulator.sh     # エミュレータ起動 → アプリをインストール・権限付与・起動
scripts/geo.sh 35.681236 139.767125   # 1点を送る
scripts/geo-route.sh 35.681236,139.767125              # その座標を保持（再送し続ける）
scripts/geo-route.sh -f scripts/sample-route.txt       # 複数地点を歩行速度でつないで移動
```

- エミュレータから届く位置は実機の GPS と同じ扱いなので、`Location.isMock()` は `false` になります
  （検出するアプリのテストに使えます）。
- `geo-route.sh` は地点間を補間して送り続けます。`SPEED_MPS`（速度）, `INTERVAL`（送信間隔秒）,
  `LOOP=1`（周回）, `HOLD`（1点保持の秒数）で調整できます。`DRY_RUN=1` で送信内容だけ確認できます。

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

## 開発者向け: 偽装検出のテスト（buildType）

このアプリには「位置を受け取る側」のサンプル画面（メイン画面の「位置受信テストを開く」）があり、
受け取った位置が mock かどうかを判定します。その検出を無効化できるかは、ビルド時に固定される
`BuildConfig.ALLOW_MOCK` だけで決まります。実行時に切り替える手段（パスワード等の隠し経路）はありません。

| buildType     | ALLOW_MOCK | 用途                                        | パッケージ |
|---------------|-----------|---------------------------------------------|-----------|
| `debug`       | true      | 開発。mock を受け入れてテスト               | `com.example.photobridge` |
| `release`     | false     | 配布。mock は常に拒否（解除経路なし）       | `com.example.photobridge` |
| `releaseTest` | true      | release に近い状態で mock を検証            | `com.example.photobridge.test` |

```bash
./gradlew assembleRelease      # 配布版（mock 拒否）
./gradlew assembleReleaseTest  # テスト版（mock 可、.test として別アプリでインストール）
```

`releaseTest` は配布する `release` とは別アプリ（`.test`）として入るので、配布版には一切影響しません。
検出まわりを本番に近い状態で確認したいときだけ使い、ユーザーに配るのは `release` です。

## 仕組み

`MockLocationService` が `LocationManager.addTestProvider()` でテスト用プロバイダを登録し、
1秒ごとに `setTestProviderLocation()` で指定座標を送り続けます。
OS は実際の GPS の代わりにこの値を位置情報として各アプリへ返します。

## 注意事項

- 一部のアプリは `Location.isMock()` などで疑似ロケーションを検出できます。
  Google Play 開発者サービスの Fused Location は、端末や GMS のバージョンによっては反映されない場合があります。
- 位置情報を使うアプリの開発・テストや、プライバシー保護を目的としています。
  位置情報ゲームの不正、勤怠・本人確認システムの偽装など、利用規約や法律に反する用途には使わないでください。
