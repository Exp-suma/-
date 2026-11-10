package com.example.photobridge

import android.Manifest
import android.annotation.SuppressLint
import android.content.Intent
import android.content.pm.PackageManager
import android.location.Location
import android.location.LocationListener
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 実機で「位置を受け取る側」の挙動を確認するテスト画面。
 *
 * 受信した位置ごとに 時刻・座標・精度・プロバイダ・mock 判定・受理/拒否 を記録し、
 * CSV として共有できる。偽装検出は BuildConfig.ALLOW_MOCK が false のときだけ有効。
 *   - release     : ALLOW_MOCK=false → mock は拒否（配布版の挙動）
 *   - debug       : ALLOW_MOCK=true  → mock も受け入れてテスト可能
 *   - releaseTest : ALLOW_MOCK=true  → release に近い状態で mock を検証
 * ALLOW_MOCK を実行時に切り替える手段は持たない。
 */
class LocationTestActivity : AppCompatActivity() {

    private data class Entry(
        val time: Long,
        val provider: String,
        val lat: Double,
        val lng: Double,
        val accuracy: Float,
        val mock: Boolean,
        val accepted: Boolean,
    )

    private lateinit var txtLog: TextView
    private lateinit var txtSummary: TextView
    private lateinit var locationManager: LocationManager
    private val entries = mutableListOf<Entry>()
    private val clock = SimpleDateFormat("HH:mm:ss", Locale.US)
    private val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSZ", Locale.US)

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
        txtSummary = findViewById(R.id.txtSummary)
        locationManager = getSystemService(LOCATION_SERVICE) as LocationManager

        findViewById<Button>(R.id.btnShare).setOnClickListener { shareCsv() }
        findViewById<Button>(R.id.btnClear).setOnClickListener {
            entries.clear()
            txtLog.text = ""
            updateSummary()
        }
        updateSummary()
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
            Toast.makeText(this, "位置情報の権限が必要です", Toast.LENGTH_LONG).show()
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
        val accepted = !(mock && !BuildConfig.ALLOW_MOCK)
        val e = Entry(
            time = System.currentTimeMillis(),
            provider = loc.provider ?: "?",
            lat = loc.latitude,
            lng = loc.longitude,
            accuracy = loc.accuracy,
            mock = mock,
            accepted = accepted,
        )
        entries += e

        val mark = if (accepted) "✓" else "✗"
        val mockTag = if (mock) "mock" else "real"
        val line = "%s %s %-7s %s %.6f, %.6f ±%.0fm".format(
            clock.format(Date(e.time)), mark, e.provider, mockTag, e.lat, e.lng, e.accuracy
        )
        txtLog.text = "$line\n${txtLog.text}"
        updateSummary()
        // accepted のときだけ、ここで本来の処理（地図表示・計算など）を行う
    }

    private fun updateSummary() {
        val policy = if (BuildConfig.ALLOW_MOCK) "mock を受け入れる" else "mock を拒否する"
        val total = entries.size
        val mock = entries.count { it.mock }
        val rejected = entries.count { !it.accepted }
        txtSummary.text = "ビルド: ${BuildConfig.BUILD_TYPE}（ALLOW_MOCK=${BuildConfig.ALLOW_MOCK} → $policy）\n" +
            "受信 $total 件 / うち mock $mock 件 / 拒否 $rejected 件"
    }

    private fun shareCsv() {
        if (entries.isEmpty()) {
            Toast.makeText(this, "まだ記録がありません", Toast.LENGTH_SHORT).show()
            return
        }
        val csv = buildString {
            appendLine("time,provider,latitude,longitude,accuracy_m,is_mock,accepted,build_type,allow_mock")
            for (e in entries) {
                appendLine(
                    "%s,%s,%.6f,%.6f,%.1f,%s,%s,%s,%s".format(
                        Locale.US, iso.format(Date(e.time)), e.provider, e.lat, e.lng, e.accuracy,
                        e.mock, e.accepted, BuildConfig.BUILD_TYPE, BuildConfig.ALLOW_MOCK
                    )
                )
            }
        }
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "photobridge 位置受信ログ")
            putExtra(Intent.EXTRA_TEXT, csv)
        }
        startActivity(Intent.createChooser(send, getString(R.string.share_csv)))
    }
}
