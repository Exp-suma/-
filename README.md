# photobridge（Fake GPS / Mock Location）

端末の **実際の現在地** に位置を固定する Android アプリです。
Android 標準の **疑似ロケーション（モックロケーション）** 機能を使っており、root化は不要です。

**任意の座標には飛ばせません。** 配信される位置は必ず端末の本当の現在地なので、
別の場所にいるように見せかける用途（勤怠の偽装、位置情報ゲームの不正など）には使えません。
固定した位置も OS からは mock として扱われ、`Location.isMock()` は `true` のままです。
この挙動を打ち消す手段（パスワード等の隠し経路を含む）は用意していません。

もともと任意座標を配信する機能や歩行シミュレーションがありましたが、不正利用の余地を
なくすため「現在地への固定のみ」に変更しました。ルート再生などで任意座標を扱いたい
開発テストは、`isMock()` が付かないエミュレータ（`scripts/geo-route.sh`）で行ってください。

## 機能

- ボタン一つで、端末の実測の現在地を取得してそこに位置を固定
- GPS / Network / Fused（Android 12+）の各プロバイダを同時に差し替え
- フォアグラウンドサービスで常駐し、通知から停止可能
- 受け取った位置が mock か判定する「位置受信テスト」画面（開発用）

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
5. 「現在地に固定する」を押す（端末の実測の現在地に固定されます）

> 固定した位置も mock として扱われ、`isMock()` で検出するアプリには効きません。
> これは仕様です。検出を回避する機能はありません。

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
- Windows では Android Studio を使います（下記）。

## Android エミュレータで使う（Windows）

Windows ではシェルスクリプトは使えないので、Android Studio を使うのが確実です。

1. **Android Studio をインストール**（<https://developer.android.com/studio>）。
   初回起動時のウィザードで Android SDK・エミュレータ・システムイメージが入ります。
2. **仮想端末を作る**：Android Studio → 右上の **Device Manager** → **Create Device**
   → 端末（例: Pixel 6）を選び、システムイメージ（例: API 34）をダウンロードして **Finish**。
3. **このプロジェクトを開く**：**Open** でこのフォルダを選び、Gradle 同期を待ちます。
4. **エミュレータで実行**：ツールバーで実行対象を作った仮想端末にして **Run ▶**。
   photobridge がビルドされ、エミュレータにインストール・起動します。
5. **「仮の現在地情報アプリ」に設定**（photobridge を試す場合）：
   エミュレータ内の 設定 → システム → 開発者向けオプション → 「仮の現在地情報アプリを選択」
   で photobridge を選びます。
6. **エミュレータの GPS 座標を設定**：次のどちらか。
   - エミュレータ右側の **…（Extended controls）→ Location** で緯度・経度を入れて **Send**。
     GPX/KML でルート再生もできます。
   - コマンドで設定（開発者向け）：

     ```bat
     scripts\windows\geo.bat 35.681236 139.767125
     ```

     `geo.bat` は `adb emu geo fix` を呼ぶだけの薄いラッパーです。`ANDROID_HOME` が未設定なら
     `%LOCALAPPDATA%\Android\Sdk` を使います。

> エミュレータの GPS（`geo fix` / Extended controls）から届く位置は、エミュレータの
> ハードウェア GPS 扱いなので `isMock()` は `false` になります。自分のアプリの位置まわりの
> 開発・テストはこの方法で行えます。

## 使い方（実機）

1. APK をインストール
2. **設定 → 端末情報 → ビルド番号** を7回タップして開発者オプションを有効化
3. **設定 → システム → 開発者向けオプション → 仮の現在地情報アプリを選択** で「photobridge」を選ぶ
4. アプリを開き、「現在地に固定する」を押す
5. 位置情報の権限と通知の権限を許可
6. 端末の実測の現在地を取得し、その地点に固定します（任意の座標は指定できません）
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
1秒ごとに `setTestProviderLocation()` でその現在地を送り続けます（固定）。座標は動かしません。
OS は実際の GPS の代わりにこの値を位置情報として各アプリへ返しますが、mock フラグは
そのまま付くので `isMock()` は `true` です。

## 注意事項

- このアプリは端末の実際の現在地にしか固定できず、別の場所の座標は指定できません。
  そのため、別の場所にいるように見せかける不正（勤怠偽装・位置ゲーム不正など）には使えません。
- 固定した位置も `Location.isMock()` で検出され、検出するアプリには効きません。
  検出を回避する機能（root 利用、隠しコマンド等）は提供しません。
- 想定用途は、GPS が揺れる環境で現在地を安定させる、位置情報を使うアプリの開発・テスト、などです。
