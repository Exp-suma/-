@echo off
REM エミュレータの仮想GPSに座標を設定する（開発テスト用）
REM 使い方: geo.bat <緯度> <経度> [高度m]
setlocal
if "%~2"=="" (
  echo 使い方: %~nx0 ^<緯度^> ^<経度^> [高度m]
  exit /b 1
)
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ADB=%ANDROID_HOME%\platform-tools\adb.exe"
if not exist "%ADB%" (
  echo adb が見つかりません: "%ADB%"
  echo ANDROID_HOME を設定するか、Android Studio の SDK を確認してください。
  exit /b 1
)
set "ALT=%~3"
if "%ALT%"=="" set "ALT=10"
REM geo fix は「経度 緯度」の順
"%ADB%" emu geo fix %2 %1 %ALT%
echo 位置を 緯度 %1, 経度 %2 に設定しました
endlocal
