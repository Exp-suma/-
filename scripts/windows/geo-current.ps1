# PC(Windows)の位置情報サービスから現在地を取得し "<緯度> <経度>" を出力する。
# 取得できなければ終了コード1。小数点はロケールに依らず . にする。
Add-Type -AssemblyName System.Device
$w = New-Object System.Device.Location.GeoCoordinateWatcher
$null = $w.TryStart($false, [TimeSpan]::FromSeconds(20))
$n = 0
while ($w.Status -ne [System.Device.Location.GeoPositionStatus]::Ready -and $n -lt 40) {
    Start-Sleep -Milliseconds 500
    $n++
}
$loc = $w.Position.Location
$w.Stop()
if ($loc.IsUnknown) {
    [Console]::Error.WriteLine("現在地を取得できませんでした。設定→プライバシー→位置情報 を有効にしてください。")
    exit 1
}
$inv = [Globalization.CultureInfo]::InvariantCulture
"{0} {1}" -f $loc.Latitude.ToString($inv), $loc.Longitude.ToString($inv)
