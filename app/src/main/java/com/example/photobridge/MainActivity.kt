package com.example.photobridge

import android.Manifest
import android.app.AppOpsManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Process
import android.provider.Settings
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import androidx.core.content.ContextCompat
import com.google.android.material.chip.Chip
import com.google.android.material.chip.ChipGroup
import com.google.android.material.materialswitch.MaterialSwitch
import com.google.android.material.textfield.TextInputEditText

class MainActivity : AppCompatActivity() {

    private lateinit var editLat: TextInputEditText
    private lateinit var editLng: TextInputEditText
    private lateinit var editAccuracy: TextInputEditText
    private lateinit var switchWalk: MaterialSwitch
    private lateinit var txtStatus: TextView

    private val prefs by lazy { getSharedPreferences("photobridge", Context.MODE_PRIVATE) }

    private val presets = listOf(
        "東京駅" to (35.681236 to 139.767125),
        "大阪駅" to (34.702485 to 135.495951),
        "札幌駅" to (43.068661 to 141.350755),
        "那覇空港" to (26.206389 to 127.646389),
        "NYタイムズスクエア" to (40.758000 to -73.985500),
        "パリ エッフェル塔" to (48.858370 to 2.294481),
    )

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            if (result[Manifest.permission.ACCESS_FINE_LOCATION] == true ||
                result[Manifest.permission.ACCESS_COARSE_LOCATION] == true
            ) {
                startMocking()
            } else {
                Toast.makeText(this, "位置情報の権限が必要です", Toast.LENGTH_LONG).show()
            }
        }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        editLat = findViewById(R.id.editLat)
        editLng = findViewById(R.id.editLng)
        editAccuracy = findViewById(R.id.editAccuracy)
        switchWalk = findViewById(R.id.switchWalk)
        txtStatus = findViewById(R.id.txtStatus)

        editLat.setText(prefs.getString("lat", "35.681236"))
        editLng.setText(prefs.getString("lng", "139.767125"))

        val group = findViewById<ChipGroup>(R.id.presetGroup)
        for ((label, coords) in presets) {
            group.addView(Chip(this).apply {
                text = label
                setOnClickListener {
                    editLat.setText(coords.first.toString())
                    editLng.setText(coords.second.toString())
                }
            })
        }

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
        val state = if (running) {
            "配信中: %.6f, %.6f".format(MockLocationService.currentLat, MockLocationService.currentLng)
        } else {
            "停止中"
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
        if (missing.isEmpty()) startMocking() else permissionLauncher.launch(missing.toTypedArray())
    }

    private fun startMocking() {
        val lat = editLat.text?.toString()?.trim()?.toDoubleOrNull()
        val lng = editLng.text?.toString()?.trim()?.toDoubleOrNull()
        val acc = editAccuracy.text?.toString()?.trim()?.toFloatOrNull() ?: 5f
        if (lat == null || lng == null || lat !in -90.0..90.0 || lng !in -180.0..180.0) {
            Toast.makeText(this, R.string.invalid_coords, Toast.LENGTH_LONG).show()
            return
        }
        if (!isSelectedMockApp()) {
            Toast.makeText(this, R.string.not_mock_app, Toast.LENGTH_LONG).show()
            return
        }
        prefs.edit().putString("lat", lat.toString()).putString("lng", lng.toString()).apply()

        val intent = Intent(this, MockLocationService::class.java)
            .putExtra(MockLocationService.EXTRA_LAT, lat)
            .putExtra(MockLocationService.EXTRA_LNG, lng)
            .putExtra(MockLocationService.EXTRA_ACCURACY, acc.coerceAtLeast(1f))
            .putExtra(MockLocationService.EXTRA_WALK, switchWalk.isChecked)
        ContextCompat.startForegroundService(this, intent)
    }
}
