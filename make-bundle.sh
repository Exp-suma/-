#!/usr/bin/env bash
# 偽GPS Tier1 一式を生成して zip にまとめる
# 使い方: ./make-bundle.sh [--local /path/to/clone] [--with-apk]
set -euo pipefail

SRC_URL="https://github.com/Exp-suma/-.git"
WORK="${PWD}/fakegps-tier1"
LOCAL=""; WITH_APK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --local) LOCAL="$2"; shift 2 ;;
    --with-apk) WITH_APK=1; shift ;;
    *) echo "unknown: $1"; exit 1 ;;
  esac
done

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== 1/6 ソース取得 =="
if [[ -n "$LOCAL" ]]; then
  rsync -a --exclude .git --exclude build --exclude .gradle "$LOCAL"/ "$WORK"/
else
  git clone --depth 1 "$SRC_URL" "$WORK/src" >/dev/null 2>&1
  shopt -s dotglob
  mv "$WORK"/src/* "$WORK"/ 2>/dev/null || true
  shopt -u dotglob
  rm -rf "$WORK/src"
fi

cd "$WORK"
[[ -f settings.gradle.kts || -f settings.gradle ]] || { echo "Gradle プロジェクトではありません"; exit 1; }
PKG="app/src/main/java/com/example/fakegps"
mkdir -p "$PKG" tools

echo "== 2/6 ソース生成 =="

cat > "$PKG/SpoofEngine.kt" <<'EOF'
package com.example.fakegps

import kotlin.math.cos
import kotlin.math.sin
import kotlin.random.Random

enum class SpoofMode { FIXED, JITTER, WALK, ROUTE, GLIDE }

/**
 * 偽装状態の唯一の真実源。座標は base からの相対ジッタなので drift しない。
 * 位置・Wi-Fi・セルはすべてここから派生させ、互いに矛盾させない。
 */
class SpoofEngine(seed: Long = System.nanoTime()) {

    data class State(
        val lat: Double, val lng: Double, val accuracy: Float, val altitude: Double,
        val bearing: Double, val speed: Float, val mode: SpoofMode
    )

    private val rnd = Random(seed)
    @Volatile private var baseLat = 0.0
    @Volatile private var baseLng = 0.0
    @Volatile private var lat = 0.0
    @Volatile private var lng = 0.0
    @Volatile private var accuracy = 4f
    @Volatile private var altitude = 12.0
    @Volatile private var bearing = 0.0
    @Volatile private var speed = 0f
    @Volatile private var mode = SpoofMode.FIXED
    @Volatile private var route: List<Pair<Double, Double>> = emptyList()
    private var seg = 0
    private var segFrac = 0.0
    private var glideLat0 = 0.0; private var glideLng0 = 0.0
    private var glideLat1 = 0.0; private var glideLng1 = 0.0
    private var glideDurMs = 1L
    private var glideElapsed = 0L

    @Volatile var running = false
        private set

    fun snapshot() = State(lat, lng, accuracy, altitude, bearing, speed, mode)

    @Synchronized
    fun start(lat: Double, lng: Double, acc: Float, m: SpoofMode,
              routeIn: List<Pair<Double, Double>> = emptyList(),
              fromLat: Double? = null, fromLng: Double? = null) {
        baseLat = lat; baseLng = lng
        altitude = 8.0 + rnd.nextDouble() * 40.0
        bearing = rnd.nextDouble(0.0, 360.0)
        route = routeIn
        seg = 0; segFrac = 0.0
        running = true
        if (fromLat != null && fromLng != null) {
            val d = haversine(fromLat, fromLng, lat, lng)
            if (d > 150.0) {
                glideLat0 = fromLat; glideLng0 = fromLng
                glideLat1 = lat; glideLng1 = lng
                glideDurMs = (d / 55.0 * 1000.0).toLong().coerceIn(20_000L, 600_000L)
                glideElapsed = 0L
                mode = SpoofMode.GLIDE
                this.lat = fromLat; this.lng = fromLng
                return
            }
        }
        this.lat = lat; this.lng = lng
        mode = m
    }

    @Synchronized
    fun retarget(lat: Double, lng: Double) {
        baseLat = lat; baseLng = lng
        if (mode == SpoofMode.FIXED || mode == SpoofMode.JITTER) { this.lat = lat; this.lng = lng }
    }

    @Synchronized
    fun stop() { running = false }

    @Synchronized
    fun tick(dtMs: Long) {
        when (mode) {
            SpoofMode.FIXED -> {
                lat = baseLat; lng = baseLng
                jitter(0.7); speed = 0f
                bearing = (bearing + rnd.nextDouble(-3.0, 3.0) + 360.0) % 360.0
            }
            SpoofMode.JITTER -> { lat = baseLat; lng = baseLng; jitter(4.0); speed = 0f }
            SpoofMode.WALK -> advance(1.4, dtMs, 22.0)
            SpoofMode.ROUTE -> followRoute(dtMs)
            SpoofMode.GLIDE -> glide(dtMs)
        }
        accuracy = 2.0f + rnd.nextFloat() * 4.0f
    }

    private fun jitter(radiusM: Double) {
        val r = radiusM * kotlin.math.sqrt(rnd.nextDouble())
        val th = rnd.nextDouble() * 2 * Math.PI
        lat += r * cos(th) / M_PER_DEG
        lng += r * sin(th) / (M_PER_DEG * cos(Math.toRadians(lat)))
    }

    private fun advance(mps: Double, dtMs: Long, turnDeg: Double) {
        bearing = (bearing + rnd.nextDouble(-turnDeg, turnDeg) + 360.0) % 360.0
        val d = mps * dtMs / 1000.0
        val rad = Math.toRadians(bearing)
        lat = (lat + d * cos(rad) / M_PER_DEG).coerceIn(-90.0, 90.0)
        lng = ((lng + d * sin(rad) / (M_PER_DEG * cos(Math.toRadians(lat))) + 540.0) % 360.0) - 180.0
        speed = mps.toFloat()
    }

    private fun followRoute(dtMs: Long) {
        if (route.size < 2) { mode = SpoofMode.FIXED; baseLat = lat; baseLng = lng; return }
        if (seg >= route.size - 1) { mode = SpoofMode.FIXED; baseLat = lat; baseLng = lng; speed = 0f; return }
        val (aLat, aLng) = route[seg]
        val (bLat, bLng) = route[seg + 1]
        val len = haversine(aLat, aLng, bLat, bLng).coerceAtLeast(1.0)
        segFrac += (ROUTE_SPEED * dtMs / 1000.0) / len
        if (segFrac >= 1.0) { seg++; segFrac = 0.0; return }
        lat = aLat + (bLat - aLat) * segFrac
        lng = aLng + (bLng - aLng) * segFrac
        bearing = (Math.toDegrees(Math.atan2(bLng - aLng, bLat - aLat)) + 360.0) % 360.0
        speed = ROUTE_SPEED.toFloat()
    }

    private fun glide(dtMs: Long) {
        glideElapsed += dtMs
        val f = (glideElapsed.toDouble() / glideDurMs).coerceIn(0.0, 1.0)
        val e = if (f < 0.5) 2 * f * f else 1 - Math.pow(-2 * f + 2, 2.0) / 2
        lat = glideLat0 + (glideLat1 - glideLat0) * e
        lng = glideLng0 + (glideLng1 - glideLng0) * e
        bearing = (Math.toDegrees(Math.atan2(glideLng1 - glideLng0, glideLat1 - glideLat0)) + 360.0) % 360.0
        speed = (haversine(glideLat0, glideLng0, glideLat1, glideLng1) / (glideDurMs / 1000.0)).toFloat()
        if (f >= 1.0) { mode = SpoofMode.FIXED; baseLat = glideLat1; baseLng = glideLng1; speed = 0f }
    }

    private fun haversine(la1: Double, lo1: Double, la2: Double, lo2: Double): Double {
        val dLa = Math.toRadians(la2 - la1); val dLo = Math.toRadians(lo2 - lo1)
        val a = sin(dLa / 2).let { it * it } +
            cos(Math.toRadians(la1)) * cos(Math.toRadians(la2)) * sin(dLo / 2).let { it * it }
        return 2 * 6_371_000.0 * Math.asin(kotlin.math.sqrt(a).coerceIn(0.0, 1.0))
    }

    companion object {
        private const val M_PER_DEG = 111_320.0
        private const val ROUTE_SPEED = 8.0
    }
}
EOF

cat > "$PKG/HealthCheck.kt" <<'EOF'
package com.example.fakegps

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.provider.Settings
import androidx.core.content.ContextCompat

object HealthCheck {

    /** severity: 0=OK, 1=要改善, 2=致命的 */
    data class Item(val label: String, val severity: Int, val hint: String, val fix: Intent?)

    fun run(ctx: Context): List<Item> {
        val out = mutableListOf<Item>()
        out += if (isMockApp(ctx)) Item("仮の現在地情報アプリ", 0, "設定済み", null)
        else Item("仮の現在地情報アプリ", 2, "開発者オプションでこのアプリを選択", devIntent())

        val mode = Settings.Secure.getString(ctx.contentResolver, "location_mode")
        out += when (mode) {
            "1" -> Item("位置情報モード", 0, "デバイスのみ(GPSのみ)", null)
            "2" -> Item("位置情報モード", 1, "電池節約(Wi-Fi/セル融合が効く)", locationIntent())
            "3" -> Item("位置情報モード", 2, "高精度 → 実位置に戻される", locationIntent())
            else -> Item("位置情報モード", 1, "確認できません", locationIntent())
        }

        val wifiScan = Settings.Secure.getString(ctx.contentResolver, "wifi_scan_always_enabled")
        out += if (wifiScan == "0") Item("Wi-Fi スキャン", 0, "OFF", null)
        else Item("Wi-Fi スキャン", 2, "ON → 周囲の実APで実位置に吸着", locationIntent())

        val bleScan = Settings.Secure.getString(ctx.contentResolver, "ble_scan_always_enabled")
        out += if (bleScan == "0") Item("Bluetooth スキャン", 0, "OFF", null)
        else Item("Bluetooth スキャン", 1, "ON → BLEビーコンで補正される", locationIntent())

        val pm = ctx.getSystemService(PowerManager::class.java)
        out += if (pm.isIgnoringBatteryOptimizations(ctx.packageName)) Item("電池最適化", 0, "除外済み", null)
        else Item("電池最適化", 1, "Doze で更新が止まる", batteryIntent(ctx))

        val fine = ContextCompat.checkSelfPermission(ctx, Manifest.permission.ACCESS_FINE_LOCATION)
        out += if (fine == PackageManager.PERMISSION_GRANTED) Item("位置情報の権限", 0, "許可済み", null)
        else Item("位置情報の権限", 2, "未許可", null)

        return out
    }

    fun isMockApp(ctx: Context): Boolean {
        val ops = ctx.getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ops.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), ctx.packageName)
        } else {
            @Suppress("DEPRECATION")
            ops.checkOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), ctx.packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun devIntent() =
        Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun locationIntent() =
        Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

    private fun batteryIntent(ctx: Context) =
        Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS)
            .setData(Uri.parse("package:${ctx.packageName}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
}
EOF

cat > "$PKG/NetFaker.kt" <<'EOF'
package com.example.fakegps

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.util.Base64
import kotlin.random.Random

object NetFaker {

    data class Ap(val bssid: String, val ssid: String, val rssi: Int, val known: Boolean)

    fun dummy(lat: Double, lng: Double, n: Int = 6): List<Ap> {
        val r = Random((lat * 1e5).toLong() * 1_000_003L xor (lng * 1e5).toLong())
        return List(n) {
            Ap("02:%02x:%02x:%02x:%02x:%02x".format(
                r.nextInt(256), r.nextInt(256), r.nextInt(256), r.nextInt(256), r.nextInt(256)
            ), "ap-$it", -50 - r.nextInt(30), false)
        }
    }

    fun wigle(lat: Double, lng: Double, token: String): List<Ap> {
        val d = 0.0015
        val url = URL("https://api.wigle.net/api/v2/network/search" +
            "?latrange1=${lat - d}&latrange2=${lat + d}" +
            "&longrange1=${lng - d}&longrange2=${lng + d}&resultsPerPage=25&onlymine=false")
        val c = (url.openConnection() as HttpURLConnection).apply {
            setRequestProperty("Authorization", "Basic " + Base64.getEncoder()
                .encodeToString("$token:".toByteArray()))
            connectTimeout = 8000; readTimeout = 8000
        }
        return try {
            if (c.responseCode != 200) return emptyList()
            val arr = JSONObject(c.inputStream.bufferedReader().readText()).optJSONArray("results")
                ?: return emptyList()
            (0 until arr.length()).mapNotNull { i ->
                val o = arr.getJSONObject(i)
                val b = o.optString("netid").lowercase()
                if (b.length != 17) null else Ap(b, o.optString("ssid", ""), o.optInt("level", -70), true)
            }
        } catch (_: Exception) {
            emptyList()
        } finally {
            c.disconnect()
        }
    }
}
EOF

cat > "$PKG/GeoPresets.kt" <<'EOF'
package com.example.fakegps

import android.content.Context
import android.location.Geocoder
import java.util.Locale

object GeoPresets {
    val presets = listOf(
        "東京駅" to (35.681236 to 139.767125),
        "大阪駅" to (34.702485 to 135.495951),
        "札幌駅" to (43.068661 to 141.350755),
        "名古屋駅" to (35.170915 to 136.881537),
        "那覇空港" to (26.206389 to 127.646389),
        "NY タイムズスクエア" to (40.758000 to -73.985500),
        "パリ エッフェル塔" to (48.858370 to 2.294481),
    )

    fun forward(ctx: Context, name: String, cb: (Double, Double, String) -> Unit) {
        Thread {
            val r = runCatching {
                @Suppress("DEPRECATION")
                Geocoder(ctx, Locale.JAPAN).getFromLocationName(name, 1)?.firstOrNull()
            }.getOrNull()
            if (r != null) cb(r.latitude, r.longitude, r.getAddressLine(0) ?: name)
        }.start()
    }
}
EOF

cat > "$PKG/BootReceiver.kt" <<'EOF'
package com.example.fakegps

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(ctx: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        val p = ctx.getSharedPreferences("fakegps", Context.MODE_PRIVATE)
        if (!p.getBoolean("autoResume", false)) return
        val lat = p.getString("lat", null)?.toDoubleOrNull() ?: return
        val lng = p.getString("lng", null)?.toDoubleOrNull() ?: return
        ContextCompat.startForegroundService(ctx,
            Intent(ctx, MockLocationService::class.java)
                .putExtra(MockLocationService.EXTRA_LAT, lat)
                .putExtra(MockLocationService.EXTRA_LNG, lng)
                .putExtra(MockLocationService.EXTRA_MODE, SpoofMode.FIXED.name))
    }
}
EOF

cat > "$PKG/MockLocationService.kt" <<'EOF'
package com.example.fakegps

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.location.Criteria
import android.location.Location
import android.location.LocationManager
import android.location.LocationProvider
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import kotlin.random.Random

class MockLocationService : Service() {

    private lateinit var lm: LocationManager
    private val h = Handler(Looper.getMainLooper())
    private val providers = mutableListOf<String>()
    private val engine = SpoofEngine()
    private var wake: PowerManager.WakeLock? = null
    private var lastTick = 0L

    private val tick = object : Runnable {
        override fun run() {
            val now = SystemClock.elapsedRealtime()
            val dt = if (lastTick == 0L) TICK_MS else (now - lastTick).coerceAtMost(5_000L)
            lastTick = now
            engine.tick(dt)
            push()
            h.postDelayed(this, TICK_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "fakegps:tick")
            .apply { setReferenceCounted(false) }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> { teardown(); return START_NOT_STICKY }
            ACTION_UPDATE -> {
                intent.getStringExtra(EXTRA_COORDS)?.let(::parseCoords)?.let { (la, ln) -> engine.retarget(la, ln) }
                push()
                return START_STICKY
            }
        }

        val lat = intent?.getDoubleExtra(EXTRA_LAT, Double.NaN) ?: Double.NaN
        val lng = intent?.getDoubleExtra(EXTRA_LNG, Double.NaN) ?: Double.NaN
        val acc = intent?.getFloatExtra(EXTRA_ACCURACY, 4f) ?: 4f
        val mode = runCatching {
            SpoofMode.valueOf(intent?.getStringExtra(EXTRA_MODE) ?: SpoofMode.FIXED.name)
        }.getOrDefault(SpoofMode.FIXED)
        val route = intent?.getStringExtra(EXTRA_ROUTE)?.let(::parseRoute) ?: emptyList()

        startForegroundCompat()

        if (providers.isEmpty()) {
            try { setUpProviders() } catch (e: SecurityException) {
                notifyState(false, "仮の現在地情報アプリに設定されていません")
                ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            wake?.acquire(12 * 60 * 60 * 1000L)
            lastTick = 0L
            h.post(tick)
        }

        if (!lat.isNaN() && !lng.isNaN()) {
            val prev = if (engine.running) engine.snapshot() else null
            engine.start(lat, lng, acc, mode, route, prev?.lat, prev?.lng)
        }
        push()
        notifyState(true, null)
        return START_STICKY
    }

    private fun startForegroundCompat() {
        ServiceCompat.startForeground(
            this, NOTIF_ID, buildNotification(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION else 0
        )
    }

    private fun setUpProviders() {
        val list = mutableListOf(
            LocationManager.GPS_PROVIDER,
            LocationManager.NETWORK_PROVIDER,
            LocationManager.PASSIVE_PROVIDER
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) list += LocationManager.FUSED_PROVIDER
        for (name in list) {
            try { lm.removeTestProvider(name) } catch (_: IllegalArgumentException) {}
            try {
                @Suppress("DEPRECATION")
                lm.addTestProvider(name, name == LocationManager.NETWORK_PROVIDER,
                    name == LocationManager.GPS_PROVIDER, false, false, true, true, true,
                    Criteria.POWER_LOW, Criteria.ACCURACY_FINE)
                lm.setTestProviderEnabled(name, true)
                providers += name
            } catch (_: IllegalArgumentException) { }
        }
        if (providers.isEmpty()) throw SecurityException("no provider")
    }

    private fun push() {
        val s = engine.snapshot()
        val sats = if (s.accuracy < 8f) 11 + Random.nextInt(4) else 4 + Random.nextInt(3)
        val extras = Bundle().apply {
            putInt("satellites", sats); putInt("satelliteCount", sats)
            putFloat("maxCn0", 40f + Random.nextFloat() * 8f)
            putFloat("meanCn0", 24f + Random.nextFloat() * 8f)
        }
        for (name in providers) {
            val loc = Location(name).apply {
                latitude = s.lat; longitude = s.lng
                altitude = s.altitude; accuracy = s.accuracy
                speed = s.speed; bearing = s.bearing.toFloat()
                time = System.currentTimeMillis()
                elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
                verticalAccuracyMeters = s.accuracy * 1.4f
                speedAccuracyMetersPerSecond = 0.35f
                bearingAccuracyDegrees = 6f
                if (Build.VERSION.SDK_INT >= 34) mslAltitudeMeters = s.altitude
                this.extras = Bundle(extras)
            }
            try { lm.setTestProviderLocation(name, loc) } catch (_: Exception) {}
            try {
                lm.setTestProviderStatus(name, LocationProvider.AVAILABLE, Bundle(extras), SystemClock.elapsedRealtime())
            } catch (_: Exception) {}
        }
        notifyState(true, null)
        updateNotification(s)
    }

    private fun teardown() {
        h.removeCallbacks(tick)
        for (name in providers) { try { lm.removeTestProvider(name) } catch (_: Exception) {} }
        providers.clear()
        engine.stop()
        try { wake?.let { if (it.isHeld) it.release() } } catch (_: Exception) {}
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        notifyState(false, null)
        stopSelf()
    }

    override fun onDestroy() {
        if (providers.isNotEmpty()) teardown()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "位置情報の偽装", NotificationManager.IMPORTANCE_LOW))
        val stop = PendingIntent.getService(this, 0,
            Intent(this, MockLocationService::class.java).setAction(ACTION_STOP), PendingIntent.FLAG_IMMUTABLE)
        val open = PendingIntent.getActivity(this, 0,
            Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_pin).setContentTitle("位置を偽装中")
            .setContentText("準備中").setContentIntent(open)
            .addAction(0, "停止", stop).setOngoing(true).setOnlyAlertOnce(true).build()
    }

    private fun updateNotification(s: SpoofEngine.State) {
        getSystemService(NotificationManager::class.java).notify(NOTIF_ID,
            NotificationCompat.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_pin)
                .setContentTitle("%s  %.6f, %.6f".format(s.mode.name, s.lat, s.lng))
                .setContentText("精度 ±%.1fm / 速度 %.1fm/s".format(s.accuracy, s.speed))
                .setOnlyAlertOnce(true).setOngoing(true).build())
    }

    private fun notifyState(running: Boolean, error: String?) {
        isRunning = running
        engine.snapshot().let { currentLat = it.lat; currentLng = it.lng }
        stateListener?.invoke(running, error)
    }

    private fun parseCoords(s: String): Pair<Double, Double>? {
        val p = s.split(",").map { it.trim().toDoubleOrNull() ?: return null }
        if (p.size != 2) return null
        return p[0] to p[1]
    }

    private fun parseRoute(s: String): List<Pair<Double, Double>> = s.lines().mapNotNull(::parseCoords)

    companion object {
        const val ACTION_STOP = "com.example.fakegps.STOP"
        const val ACTION_UPDATE = "com.example.fakegps.UPDATE"
        const val EXTRA_LAT = "lat"
        const val EXTRA_LNG = "lng"
        const val EXTRA_ACCURACY = "accuracy"
        const val EXTRA_MODE = "mode"
        const val EXTRA_ROUTE = "route"
        const val EXTRA_COORDS = "coords"
        private const val CHANNEL_ID = "mock_location"
        private const val NOTIF_ID = 1
        private const val TICK_MS = 700L
        @Volatile var isRunning = false
            private set
        @Volatile var currentLat = 0.0
            private set
        @Volatile var currentLng = 0.0
            private set
        var stateListener: ((Boolean, String?) -> Unit)? = null
    }
}
EOF

cat > "$PKG/MainActivity.kt" <<'EOF'
package com.example.fakegps

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.text.InputType
import android.view.View
import android.widget.*
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

class MainActivity : AppCompatActivity() {

    private lateinit var editLat: EditText
    private lateinit var editLng: EditText
    private lateinit var editAcc: EditText
    private lateinit var editRoute: EditText
    private lateinit var editWigle: EditText
    private lateinit var txtStatus: TextView
    private lateinit var txtHealth: TextView
    private lateinit var txtArea: TextView
    private var mode = SpoofMode.FIXED

    private val prefs by lazy { getSharedPreferences("fakegps", Context.MODE_PRIVATE) }

    private val permLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { r ->
            if (r[Manifest.permission.ACCESS_FINE_LOCATION] == true) startNow()
            else toast("位置情報の権限が必要です")
        }

    override fun onCreate(s: Bundle?) {
        super.onCreate(s)
        buildUi()
        editLat.setText(prefs.getString("lat", "35.681236"))
        editLng.setText(prefs.getString("lng", "139.767125"))
        editAcc.setText(prefs.getString("acc", "4"))
        editWigle.setText(prefs.getString("wigle", ""))
    }

    override fun onResume() {
        super.onResume()
        MockLocationService.stateListener = { run, err ->
            runOnUiThread { if (err != null) toast(err); refreshStatus(run) }
        }
        refreshStatus(MockLocationService.isRunning)
        refreshHealth()
    }

    override fun onPause() {
        MockLocationService.stateListener = null
        super.onPause()
    }

    private fun buildUi() {
        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(40, 60, 40, 60)
        }
        txtStatus = TextView(this).apply { textSize = 15f; setTextColor(Color.DKGRAY) }
        txtHealth = TextView(this).apply { textSize = 13f }
        txtArea = TextView(this).apply { textSize = 13f; setPadding(0, 16, 0, 0) }

        root.addView(txtStatus)
        root.addView(txtHealth)
        root.addView(divider())
        root.addView(section("座標"))
        root.addView(labeled("緯度", EditText(this).also { editLat = it; it.inputType = num() }))
        root.addView(labeled("経度", EditText(this).also { editLng = it; it.inputType = num() }))
        root.addView(labeled("精度(m) ※2〜6 推奨", EditText(this).also { editAcc = it; it.inputType = num() }))
        root.addView(row(btn("現在地を取得") { grabCurrent() }, btn("地図で開く") { openMap() }))
        val search = EditText(this)
        root.addView(labeled("住所で検索", search))
        root.addView(btn("検索") {
            val q = search.text.toString().trim()
            if (q.isNotEmpty()) GeoPresets.forward(this, q) { la, ln, label ->
                runOnUiThread { editLat.setText(la.toString()); editLng.setText(ln.toString()); toast(label) }
            }
        })

        root.addView(section("プリセット"))
        val chips = LinearLayout(this)
        for ((name, c) in GeoPresets.presets) {
            chips.addView(btn(name) {
                editLat.setText(c.first.toString()); editLng.setText(c.second.toString())
            })
        }
        root.addView(HorizontalScrollView(this).apply { addView(chips) })

        root.addView(section("モード"))
        val modes = LinearLayout(this)
        for (m in SpoofMode.values()) {
            modes.addView(RadioButton(this).apply {
                text = m.name; isChecked = m == SpoofMode.FIXED
                setOnCheckedChangeListener { _, on -> if (on) mode = m }
            })
        }
        root.addView(modes)
        root.addView(labeled("経路 (ROUTE: 1行1点 \"lat,lng\")",
            EditText(this).also { editRoute = it; it.minLines = 3 }))

        root.addView(section("開始 / 停止"))
        root.addView(row(
            btn("配信開始") { requestPerms() },
            btn("停止") {
                startService(Intent(this, MockLocationService::class.java)
                    .setAction(MockLocationService.ACTION_STOP))
            }
        ))
        root.addView(CheckBox(this).apply {
            text = "再起動後に自動で再開"
            isChecked = prefs.getBoolean("autoResume", false)
            setOnCheckedChangeListener { _, v -> prefs.edit().putBoolean("autoResume", v).apply() }
        })
        root.addView(divider())
        root.addView(section("周辺環境の耐性チェック"))
        root.addView(labeled("WiGLE API token (任意)", EditText(this).also {
            editWigle = it
            it.setOnFocusChangeListener { _, _ -> prefs.edit().putString("wigle", it.text.toString()).apply() }
        }))
        root.addView(btn("この座標を調査") { checkArea() })
        root.addView(txtArea)

        setContentView(ScrollView(this).apply { addView(root) })
    }

    private fun section(t: String) = TextView(this).apply {
        text = t; textSize = 16f; setTextColor(Color.BLACK); setPadding(0, 32, 0, 8)
    }
    private fun divider() = View(this).apply {
        setBackgroundColor(Color.LTGRAY)
        layoutParams = LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 2)
    }
    private fun num() = InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_FLAG_DECIMAL or
        InputType.TYPE_NUMBER_FLAG_SIGNED
    private fun btn(t: String, f: () -> Unit) = Button(this).apply { text = t; setOnClickListener { f() } }
    private fun labeled(label: String, v: EditText): View = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        addView(TextView(this@MainActivity).apply { text = label; textSize = 12f })
        addView(v)
    }
    private fun row(vararg v: View) = LinearLayout(this).apply { v.forEach { addView(it) } }
    private fun toast(t: String) = Toast.makeText(this, t, Toast.LENGTH_LONG).show()

    private fun refreshStatus(running: Boolean) {
        val mock = if (HealthCheck.isMockApp(this)) "設定済み" else "未設定"
        txtStatus.text = if (running)
            "配信中: %.6f, %.6f (%s)".format(MockLocationService.currentLat, MockLocationService.currentLng, mode.name)
        else "停止中 / 仮の現在地情報アプリ: $mock"
    }

    private fun refreshHealth() {
        val items = HealthCheck.run(this)
        txtHealth.text = items.joinToString("\n") { i ->
            val mark = when (i.severity) { 0 -> "OK  "; 1 -> "△  "; else -> "NG  " }
            "$mark${i.label}: ${i.hint}"
        }
        txtHealth.setOnClickListener {
            items.firstOrNull { it.severity > 0 && it.fix != null }?.fix?.let { startActivity(it) }
        }
    }

    private fun grabCurrent() {
        val lm = getSystemService(Context.LOCATION_SERVICE) as android.location.LocationManager
        @Suppress("MissingPermission")
        val l = lm.getLastKnownLocation(android.location.LocationManager.GPS_PROVIDER)
            ?: lm.getLastKnownLocation(android.location.LocationManager.NETWORK_PROVIDER)
        if (l == null) { toast("現在地を取得できません"); return }
        editLat.setText(l.latitude.toString()); editLng.setText(l.longitude.toString())
    }

    private fun openMap() {
        val la = editLat.text.toString().toDoubleOrNull() ?: return
        val ln = editLng.text.toString().toDoubleOrNull() ?: return
        startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("geo:$la,$ln?q=$la,$ln")))
    }

    private fun checkArea() {
        val la = editLat.text.toString().toDoubleOrNull() ?: return
        val ln = editLng.text.toString().toDoubleOrNull() ?: return
        val token = editWigle.text.toString().trim()
        txtArea.text = "照会中..."
        Thread {
            val known = if (token.isEmpty()) emptyList() else NetFaker.wigle(la, ln, token)
            val msg = buildString {
                appendLine("既知AP: ${known.size} 件")
                appendLine(if (known.isEmpty())
                    "→ DB未整備。Wi-Fi融合に負けて実位置へ戻りやすい"
                else "→ DBに載っている地点。融合が働いても同じ所に収束しやすい")
            }
            runOnUiThread { txtArea.text = msg }
        }.start()
    }

    private fun requestPerms() {
        val need = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) need += Manifest.permission.POST_NOTIFICATIONS
        val missing = need.filter { ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED }
        if (missing.isEmpty()) startNow() else permLauncher.launch(missing.toTypedArray())
    }

    private fun startNow() {
        if (!HealthCheck.isMockApp(this)) {
            toast("開発者オプションで「仮の現在地情報アプリ」にこのアプリを選んでください")
            startActivity(Intent(android.provider.Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
            return
        }
        val la = editLat.text.toString().toDoubleOrNull()
        val ln = editLng.text.toString().toDoubleOrNull()
        val acc = editAcc.text.toString().toFloatOrNull() ?: 4f
        if (la == null || ln == null || la !in -90.0..90.0 || ln !in -180.0..180.0) {
            toast("座標が不正です"); return
        }
        if (mode == SpoofMode.ROUTE) {
            val pts = editRoute.text.toString().lines().mapNotNull {
                val p = it.split(",").map { s -> s.trim().toDoubleOrNull() }
                if (p.size == 2 && p[0] != null && p[1] != null) p[0]!! to p[1]!! else null
            }
            if (pts.size < 2) { toast("ROUTE には2点以上の経路が必要です"); return }
        }
        prefs.edit().putString("lat", la.toString()).putString("lng", ln.toString())
            .putString("acc", acc.toString()).apply()
        ContextCompat.startForegroundService(this,
            Intent(this, MockLocationService::class.java)
                .putExtra(MockLocationService.EXTRA_LAT, la)
                .putExtra(MockLocationService.EXTRA_LNG, ln)
                .putExtra(MockLocationService.EXTRA_ACCURACY, acc.coerceIn(1f, 100f))
                .putExtra(MockLocationService.EXTRA_MODE, mode.name)
                .putExtra(MockLocationService.EXTRA_ROUTE, editRoute.text.toString()))
    }
}
EOF

echo "== 3/6 マニフェスト / Gradle 改修 =="
python3 - <<'PY'
import pathlib, re
mf = next(pathlib.Path("app/src/main").glob("AndroidManifest.xml"))
s = mf.read_text()
perms = ["ACCESS_FINE_LOCATION","ACCESS_COARSE_LOCATION","ACCESS_BACKGROUND_LOCATION",
         "FOREGROUND_SERVICE","FOREGROUND_SERVICE_LOCATION","POST_NOTIFICATIONS",
         "WAKE_LOCK","RECEIVE_BOOT_COMPLETED","INTERNET","ACCESS_WIFI_STATE",
         "REQUEST_IGNORE_BATTERY_OPTIMIZATIONS"]
nl = s.index("\n", s.index("<manifest")) + 1
add = "".join(f'    <uses-permission android:name="android.permission.{p}" />\n'
              for p in perms if f'android.permission.{p}"' not in s)
s = s[:nl] + add + s[nl:]
if 'android:name=".MockLocationService"' not in s:
    block = ('        <service android:name=".MockLocationService" android:exported="false"\n'
             '            android:foregroundServiceType="location" />\n'
             '        <receiver android:name=".BootReceiver" android:exported="true">\n'
             '            <intent-filter>\n'
             '                <action android:name="android.intent.action.BOOT_COMPLETED" />\n'
             '                <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />\n'
             '            </intent-filter>\n'
             '        </receiver>\n')
    s = s.replace("</application>", block + "    </application>", 1)
mf.write_text(s)

for g in pathlib.Path(".").glob("app/build.gradle.kts"):
    t = g.read_text()
    t = re.sub(r"compileSdk\s*=\s*\d+", "compileSdk = 34", t)
    t = re.sub(r"targetSdk\s*=\s*\d+", "targetSdk = 34", t)
    t = re.sub(r"minSdk\s*=\s*\d+", "minSdk = 26", t)
    if "namespace" not in t:
        t = re.sub(r"(android\s*\{)", r'\1\n    namespace = "com.example.fakegps"', t, count=1)
        s = mf.read_text().replace(' package="com.example.fakegps"', "")
        mf.write_text(s)
    if "isMinifyEnabled = true" in t:
        t = t.replace("isMinifyEnabled = true", "isMinifyEnabled = false")
    g.write_text(t)
print("patched")
PY

cat > tools/setup-noroot.sh <<'EOF'
#!/usr/bin/env bash
# adb で root 不要の下ごしらえを行う(PC で1回)
set -e
PKG="com.example.fakegps"
adb shell settings put secure location_mode 1
adb shell settings put secure wifi_scan_always_enabled 0
adb shell settings put secure ble_scan_always_enabled 0
adb shell appops set "$PKG" android:mock_location allow
adb shell dumpsys deviceidle whitelist +"$PKG"
adb shell pm grant "$PKG" android.permission.ACCESS_FINE_LOCATION
adb shell pm grant "$PKG" android.permission.ACCESS_COARSE_LOCATION
echo "完了。設定 → 位置情報 が「デバイスのみ」になっているか確認。"
echo "効かない端末では Google 位置情報の精度 を手動で OFF にすること。"
EOF
chmod +x tools/setup-noroot.sh

cat > README-TIER1.md <<'EOF'
# 偽GPS Tier1 (root 不要)

## ビルド
    ./gradlew assembleDebug
    # 出力: app/build/outputs/apk/debug/app-debug.apk

JDK 17 / SDK Platform 34 / build-tools が必要。

## 初期設定
1. 設定 → 端末情報 → ビルド番号 を7回タップ
2. 設定 → システム → 開発者向けオプション → 仮の現在地情報アプリ → 本アプリ
3. `tools/setup-noroot.sh` を PC で実行(adb)
4. アプリ上部のヘルスチェックを全部 OK にする

## 使い方
座標を入れる → 「この座標を調査」で既知AP件数を確認 → 配信開始。
遠方へ移すときは配信中に座標変更して再実行(GLIDE で等速移動)。

## モード
- FIXED: その場に固定(既定)
- JITTER: 数m揺らす
- WALK: 歩行
- ROUTE: 経路を等速移動(1行1点 "lat,lng")
- GLIDE: 遠方へ移動する時に自動で挟まる

## root なしの限界
Wi-Fi スキャン結果 / セルタワー / センサー値 / isMock フラグは偽装できない。
そのため「Google 位置情報の精度」と Wi-Fi・BLE スキャンを OFF にする運用が必須。
EOF

echo "== 4/6 クリーンアップ =="
rm -rf app/build build .gradle .git
printf '\n# bundle\nfakegps*.zip\ntools/fakegps.jks\n' >> .gitignore

if [[ $WITH_APK -eq 1 ]]; then
  echo "== 5/6 APK ビルド =="
  ./gradlew --quiet assembleDebug
  cp app/build/outputs/apk/debug/app-debug.apk ./app-debug.apk
  rm -rf app/build build .gradle
else
  echo "== 5/6 APK ビルド (スキップ) =="
fi

echo "== 6/6 zip 化 =="
cd "$(dirname "$WORK")"
OUT="fakegps-tier1.zip"
rm -f "$OUT"
if command -v zip >/dev/null; then
  zip -qr "$OUT" "$(basename "$WORK")" -x '*/build/*' '*/.gradle/*' '*/.git/*'
else
  OUT="fakegps-tier1.tar.gz"
  tar czf "$OUT" --exclude=build --exclude=.gradle --exclude=.git "$(basename "$WORK")"
fi

echo
echo "完成: $PWD/$OUT"
echo "サイズ: $(du -h "$OUT" | cut -f1)"
echo "SHA256: $(sha256sum "$OUT" | cut -d' ' -f1)"
echo
echo "中身:"
find "$(basename "$WORK")" -type f | sed "s|^|  |"
