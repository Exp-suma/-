package com.example.photobridge

import android.Manifest
import android.annotation.SuppressLint
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.provider.Settings
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat

/**
 * photobridge は「端末の実際の現在地に位置を固定する」ことだけを行う。
 *
 * 任意の座標を入力したり、別の場所のプリセットに飛ばしたり、歩行を
 * 擬似的に動かしたりはできない。配信される座標は必ず端末の本当の現在地なので、
 * 別の場所にいるように見せかける用途（勤怠の偽装、位置情報ゲームの不正など）には使えない。
 *
 * 固定した位置も OS からは mock として扱われ、isMock() は true のまま。
 * この挙動を打ち消す手段は用意しない。
 */
class MainActivity : AppCompatActivity() {

    private lateinit var txtStatus: TextView
    private lateinit var locationManager: LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private var acquiring = false

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            if (result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
            ) {
                acquireCurrentLocationAndStart()
            } else {
                Toast.makeText(this, "位置情報の権限が必要です", Toast.LENGTH_LONG).show()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        findViewById<Button>(R.id.btnDevOptions).setOnClickListener {
            try {
                startActivity(Intent(Settings.ACTION_APPLICATION_DEVELOPMENT_SETTINGS))
            } catch (_: Exception) {
                startActivity(Intent(Settings.ACTION_DEVICE_INFO_SETTINGS))
            }
        }
        findViewById<Button>(R.id.btnStart).setOnClickListener { requestPermissionsAndStart() }
        findViewById<Button>(R.id.btnStop).setOnClickListener {
            startService(Intent(this, MockLocationService::class.java).setAction(MockLocationService.ACTION_STOP))
        }
        findViewById<Button>(R.id.btnLocationTest).setOnClickListener {
            startActivity(Intent(this, LocationTestActivity::class.java))
        }
        txtStatus = findViewById(R.id.txtStatus)
    }

    override fun onResume() {
        super.onResume()
        MockLocationService.stateListener = { running, error ->
            runOnUiThread {
                if (error != null) Toast.makeText(this, error, Toast.LENGTH_LONG).show()
                updateStatus(running)
            }
        }
        updateStatus(MockLocationService.isRunning)
    }

    override fun onPause() {
        MockLocationService.stateListener = null
        super.onPause()
    }

    private fun updateStatus(running: Boolean) {
        val mockApp = if (isSelectedMockApp()) "設定済み ✓" else "未設定 ✗（開発者オプションで選択してください）"
        val state = when {
            acquiring -> "現在地を取得中…"
            running -> "現在地に固定中: %.6f, %.6f".format(MockLocationService.currentLat, MockLocationService.currentLng)
            else -> "停止中"
        }
        txtStatus.text = "仮の現在地情報アプリ: $mockApp\n状態: $state"
    }

    private fun isSelectedMockApp(): Boolean {
        val appOps = getSystemService(AppOpsManager::class.java)
        val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            appOps.unsafeCheckOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName)
        } else {
            @Suppress("DEPRECATION")
            appOps.checkOpNoThrow(AppOpsManager.OPSTR_MOCK_LOCATION, Process.myUid(), packageName)
        }
        return mode == AppOpsManager.MODE_ALLOWED
    }

    private fun requestPermissionsAndStart() {
        if (!isSelectedMockApp()) {
            Toast.makeText(this, R.string.not_mock_app, Toast.LENGTH_LONG).show()
            return
        }
        val needed = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.ACCESS_COARSE_LOCATION,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            needed += Manifest.permission.POST_NOTIFICATIONS
        }
        val missing = needed.filter {
            ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isEmpty()) acquireCurrentLocationAndStart()
        else permissionLauncher.launch(missing.toTypedArray())
    }

    /**
     * 端末の本当の現在地を1回だけ取得し、その座標で固定を開始する。
     * ユーザーが座標を指定する余地はない（取得できた実測値のみを使う）。
     * mock プロバイダを起動する前に実測値を取るため、取得値は本物の位置。
     */
    @SuppressLint("MissingPermission")
    private fun acquireCurrentLocationAndStart() {
        if (acquiring || MockLocationService.isRunning) return
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_COARSE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            Toast.makeText(this, "位置情報の権限が必要です", Toast.LENGTH_LONG).show()
            return
        }
        acquiring = true
        updateStatus(false)

        val providers = buildList {
            if (locationManager.isProviderEnabled(LocationManager.GPS_PROVIDER)) add(LocationManager.GPS_PROVIDER)
            if (locationManager.isProviderEnabled(LocationManager.NETWORK_PROVIDER)) add(LocationManager.NETWORK_PROVIDER)
        }
        if (providers.isEmpty()) {
            finishAcquire(null, "位置情報をオンにしてください")
            return
        }

        var settled = false
        val listeners = mutableListOf<Pair<String, LocationListener>>()
        val timeout = Runnable {
            if (settled) return@Runnable
            // 単発取得が間に合わなければ、最後に分かっている実測値を使う
            val last = providers.mapNotNull { locationManager.getLastKnownLocation(it) }
                .maxByOrNull { it.time }
            settled = true
            listeners.forEach { (_, l) -> locationManager.removeUpdates(l) }
            finishAcquire(last, if (last == null) "現在地を取得できませんでした。屋外などで再試行してください" else null)
        }

        for (provider in providers) {
            val l = LocationListener { loc ->
                if (settled) return@LocationListener
                settled = true
                handler.removeCallbacks(timeout)
                listeners.forEach { (_, li) -> locationManager.removeUpdates(li) }
                finishAcquire(loc, null)
            }
            listeners += provider to l
            locationManager.requestLocationUpdates(provider, 0L, 0f, l, Looper.getMainLooper())
        }
        handler.postDelayed(timeout, 15_000L)
    }

    private fun finishAcquire(location: Location?, error: String?) {
        acquiring = false
        if (location == null) {
            if (error != null) Toast.makeText(this, error, Toast.LENGTH_LONG).show()
            updateStatus(false)
            return
        }
        val intent = Intent(this, MockLocationService::class.java)
            .putExtra(MockLocationService.EXTRA_LAT, location.latitude)
            .putExtra(MockLocationService.EXTRA_LNG, location.longitude)
            .putExtra(MockLocationService.EXTRA_ACCURACY, location.accuracy.coerceAtLeast(1f))
        ContextCompat.startForegroundService(this, intent)
        Toast.makeText(
            this,
            "現在地に固定します: %.6f, %.6f".format(location.latitude, location.longitude),
            Toast.LENGTH_LONG
        ).show()
    }
}
