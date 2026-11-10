package com.example.photobridge

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
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * LocationManager のテストプロバイダ機能を使って、端末の位置情報を
 * 指定した座標に差し替え続けるフォアグラウンドサービス。
 */
class MockLocationService : Service() {

    private lateinit var locationManager: LocationManager
    private val handler = Handler(Looper.getMainLooper())
    private val activeProviders = mutableListOf<String>()

    private var latitude = 0.0
    private var longitude = 0.0
    private var accuracy = 5f

    private val tick = object : Runnable {
        override fun run() {
            // 現在地に固定するだけ。座標は動かさず、同じ地点を送り続ける。
            pushLocation()
            handler.postDelayed(this, UPDATE_INTERVAL_MS)
        }
    }

    override fun onCreate() {
        super.onCreate()
        locationManager = getSystemService(Context.LOCATION_SERVICE) as LocationManager
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopMocking()
            return START_NOT_STICKY
        }

        latitude = intent?.getDoubleExtra(EXTRA_LAT, latitude) ?: latitude
        longitude = intent?.getDoubleExtra(EXTRA_LNG, longitude) ?: longitude
        accuracy = intent?.getFloatExtra(EXTRA_ACCURACY, accuracy) ?: accuracy

        ServiceCompat.startForeground(
            this,
            NOTIFICATION_ID,
            buildNotification(),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION
            } else {
                0
            }
        )

        if (activeProviders.isEmpty()) {
            try {
                setUpProviders()
            } catch (e: SecurityException) {
                notifyState(false, getString(R.string.not_mock_app))
                stopMocking()
                return START_NOT_STICKY
            }
            handler.post(tick)
        } else {
            // 実行中に座標だけ更新された場合は即座に反映
            pushLocation()
        }

        notifyState(true, null)
        return START_STICKY
    }

    private fun setUpProviders() {
        val providers = mutableListOf(LocationManager.GPS_PROVIDER, LocationManager.NETWORK_PROVIDER)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            providers += LocationManager.FUSED_PROVIDER
        }
        for (name in providers) {
            // 前回の異常終了で残っている場合に備えて一度削除
            try {
                locationManager.removeTestProvider(name)
            } catch (_: IllegalArgumentException) {
            }
            try {
                @Suppress("DEPRECATION")
                locationManager.addTestProvider(
                    name,
                    name == LocationManager.NETWORK_PROVIDER, // requiresNetwork
                    name == LocationManager.GPS_PROVIDER,     // requiresSatellite
                    false,                                    // requiresCell
                    false,                                    // hasMonetaryCost
                    true,                                     // supportsAltitude
                    true,                                     // supportsSpeed
                    true,                                     // supportsBearing
                    Criteria.POWER_LOW,
                    Criteria.ACCURACY_FINE
                )
                locationManager.setTestProviderEnabled(name, true)
                activeProviders += name
            } catch (e: IllegalArgumentException) {
                // 端末がこのプロバイダをサポートしていない場合はスキップ
            }
        }
    }

    private fun pushLocation() {
        for (name in activeProviders) {
            val location = Location(name).apply {
                latitude = this@MockLocationService.latitude
                longitude = this@MockLocationService.longitude
                altitude = 10.0
                accuracy = this@MockLocationService.accuracy
                speed = 0f
                time = System.currentTimeMillis()
                elapsedRealtimeNanos = SystemClock.elapsedRealtimeNanos()
                verticalAccuracyMeters = 3f
                speedAccuracyMetersPerSecond = 0.5f
            }
            try {
                locationManager.setTestProviderLocation(name, location)
            } catch (_: IllegalArgumentException) {
            } catch (_: SecurityException) {
            }
        }
        notifyState(true, null)
    }

    private fun stopMocking() {
        handler.removeCallbacks(tick)
        for (name in activeProviders) {
            try {
                locationManager.removeTestProvider(name)
            } catch (_: Exception) {
            }
        }
        activeProviders.clear()
        ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
        stopSelf()
        notifyState(false, null)
    }

    override fun onDestroy() {
        if (activeProviders.isNotEmpty()) stopMocking()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val nm = getSystemService(NotificationManager::class.java)
        nm.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, getString(R.string.channel_name), NotificationManager.IMPORTANCE_LOW)
        )
        val stopIntent = PendingIntent.getService(
            this, 0,
            Intent(this, MockLocationService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE
        )
        val openIntent = PendingIntent.getActivity(
            this, 0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_pin)
            .setContentTitle(getString(R.string.notif_title))
            .setContentText("%.6f, %.6f".format(latitude, longitude))
            .setContentIntent(openIntent)
            .addAction(0, getString(R.string.stop), stopIntent)
            .setOngoing(true)
            .build()
    }

    private fun notifyState(running: Boolean, error: String?) {
        isRunning = running
        currentLat = latitude
        currentLng = longitude
        stateListener?.invoke(running, error)
    }

    companion object {
        const val ACTION_STOP = "com.example.photobridge.STOP"
        const val EXTRA_LAT = "lat"
        const val EXTRA_LNG = "lng"
        const val EXTRA_ACCURACY = "accuracy"

        private const val CHANNEL_ID = "mock_location"
        private const val NOTIFICATION_ID = 1
        private const val UPDATE_INTERVAL_MS = 1000L

        @Volatile var isRunning = false
            private set
        @Volatile var currentLat = 0.0
            private set
        @Volatile var currentLng = 0.0
            private set

        /** メインスレッドから呼ばれる状態通知 (running, errorMessage) */
        var stateListener: ((Boolean, String?) -> Unit)? = null
    }
}
