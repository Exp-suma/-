package com.example.photobridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.widget.TextView
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 「位置を受け取る側」のサンプル画面。
 *
 * 受け取った位置が mock かどうかを判定し、偽装検出のロジックを通す。
 * ただしその検出は BuildConfig.ALLOW_MOCK が false のときだけ有効。
 *   - release        : ALLOW_MOCK=false → mock は拒否（配布版の挙動）
 *   - debug          : ALLOW_MOCK=true  → mock も受け入れてテスト可能
 *   - releaseTest    : ALLOW_MOCK=true  → release に近い状態で mock を検証
 *
 * ALLOW_MOCK を実行時に切り替える手段（パスワード等の隠し経路）は持たない。
 * 値はビルド時に固定され、配布する release では解除できない。
 */
class LocationTestActivity : AppCompatActivity() {

    private lateinit var txtLog: TextView
    private lateinit var locationManager: LocationManager
    private val time = SimpleDateFormat("HH:mm:ss", Locale.US)

    private val listener = LocationListener { loc -> onLocation(loc) }

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
            startUpdates()
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_location_test)
        title = getString(R.string.location_test_title)
        txtLog = findViewById(R.id.txtLog)
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        val policy = if (BuildConfig.ALLOW_MOCK) {
            "mock を受け入れます（テスト用）"
        } else {
            "mock は拒否します（配布版の挙動）"
        }
        append("ビルド種別: ${BuildConfig.BUILD_TYPE}")
        append("ALLOW_MOCK = ${BuildConfig.ALLOW_MOCK} → $policy")
        append("――― 位置の受信待ち ―――")
    }

    override fun onStart() {
        super.onStart()
        val fine = ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
        if (fine == PackageManager.PERMISSION_GRANTED) {
            startUpdates()
        } else {
            permissionLauncher.launch(
                arrayOf(
                    Manifest.permission.ACCESS_FINE_LOCATION,
                    Manifest.permission.ACCESS_COARSE_LOCATION,
                )
            )
        }
    }

    override fun onStop() {
        locationManager.removeUpdates(listener)
        super.onStop()
    }

    @SuppressLint("MissingPermission")
    private fun startUpdates() {
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) {
            append("位置情報の権限が必要です")
            return
        }
        for (provider in listOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)) {
            try {
                locationManager.requestLocationUpdates(provider, 1000L, 0f, listener)
            } catch (_: IllegalArgumentException) {
            }
        }
    }

    private fun isMock(loc: Location): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            loc.isMock
        } else {
            @Suppress("DEPRECATION") loc.isFromMockProvider
        }

    /** 位置を受け取ったときの処理。偽装検出はここで行う。 */
    private fun onLocation(loc: Location) {
        val mock = isMock(loc)
        val coord = "%.6f, %.6f".format(loc.latitude, loc.longitude)

        if (mock && !BuildConfig.ALLOW_MOCK) {
            // 配布版はここで偽装位置を捨てる
            append("✗ 拒否 (mock) $coord")
            return
        }

        val tag = if (mock) "✓ 受理 (mock) " else "✓ 受理 "
        append("$tag$coord")
        // ここで本来の処理（地図表示・計算など）を行う
    }

    private fun append(line: String) {
        txtLog.text = "${time.format(Date())}  $line\n${txtLog.text}"
    }
}
