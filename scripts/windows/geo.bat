@echo off
REM PC(Windows)の実際の現在地を取得し、エミュレータの仮想GPSをその地点に固定する。
REM 任意の座標は指定できない（PCの現在地のみ）。
setlocal enabledelayedexpansion
if "%ANDROID_HOME%"=="" set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ADB=%ANDROID_HOME%\platform-tools\adb.exe"
if not exist "%ADB%" (
  echo adb が見つかりません: "%ADB%"
  echo ANDROID_HOME を設定するか、Android Studio の SDK を確認してください。
  exit /b 1
)

set "LAT="
set "LNG="
for /f "usebackq tokens=1,2" %%a in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0geo-current.ps1"`) do (
  set "LAT=%%a"
  set "LNG=%%b"
)
if "%LNG%"=="" (
  echo PCの現在地を取得できませんでした。位置情報を有効にして再試行してください。
  exit /b 1
)

REM geo fix は「経度 緯度」の順
"%ADB%" emu geo fix %LNG% %LAT% 10
echo PCの現在地に固定しました: 緯度 %LAT%, 経度 %LNG%
endlocal
