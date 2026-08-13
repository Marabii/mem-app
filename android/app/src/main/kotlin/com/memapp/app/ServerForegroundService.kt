package com.memapp.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Keeps the Dart HTTP server reachable while the screen is off.
 *
 * The server itself is `shelf` running on the app's own isolate, so it lives
 * exactly as long as the process does. Turning the screen off does not stop
 * Dart — but it does let Android put the process into the cached state, where
 * the app freezer suspends it and Doze cuts its network. Both exemptions come
 * from the same place: a foreground service.
 *
 * So this service does not serve anything itself. It exists to hold:
 *   - foreground status, which keeps the process out of the freezer,
 *   - a partial wake lock, so the CPU still schedules the isolate,
 *   - a Wi-Fi lock, so the radio does not drop to a power-saving duty cycle,
 *   - the ongoing notification, which is where the user stops the server from.
 *
 * `specialUse` is the honest foreground service type here: this is not a media
 * player or a location tracker, and unlike `dataSync` it carries no per-day
 * time budget that would cut a long editing session short.
 */
class ServerForegroundService : Service() {

    companion object {
        const val ACTION_START = "com.memapp.app.SERVER_START"
        const val ACTION_STOP = "com.memapp.app.SERVER_STOP"
        const val EXTRA_URL = "url"

        private const val CHANNEL_ID = "memapp_server"
        private const val NOTIFICATION_ID = 2000

        /** True while the service is foregrounded, for the Dart side to read. */
        @Volatile
        var isRunning: Boolean = false
            private set

        /**
         * Invoked when the user taps "Stop" on the notification. MainActivity
         * installs a listener that tells Dart to close the socket; the service
         * stops either way.
         */
        @Volatile
        var onStopRequested: (() -> Unit)? = null

        fun start(context: Context, url: String) {
            val intent = Intent(context, ServerForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_URL, url)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, ServerForegroundService::class.java).apply {
                action = ACTION_STOP
            }
            // A stopService is enough once the service is up; going through
            // startService keeps the stop path identical whether or not the
            // service happens to be running.
            runCatching { context.startService(intent) }
                .onFailure { context.stopService(intent) }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                // Only the first stop is reported: Dart's own stop path calls
                // back in here, and answering that would bounce forever.
                if (isRunning) onStopRequested?.invoke()
                shutdown()
                return START_NOT_STICKY
            }
            else -> {
                val url = intent?.getStringExtra(EXTRA_URL).orEmpty()
                startInForeground(url)
                acquireLocks()
            }
        }
        // Restarting this service after the process is killed would leave a
        // notification pointing at a server that no longer exists.
        return START_NOT_STICKY
    }

    private fun startInForeground(url: String) {
        createChannel()

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_IMMUTABLE,
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, ServerForegroundService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )

        val notification: Notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("MemApp server running")
            .setContentText(
                if (url.isEmpty()) "Reachable on this Wi-Fi network"
                else "$url — reachable by anyone on this Wi-Fi"
            )
            .setSmallIcon(R.mipmap.ic_launcher)
            .setOngoing(true)
            .setShowWhen(false)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setContentIntent(open)
            .addAction(0, "Stop", stop)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        isRunning = true
    }

    private fun acquireLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(
                PowerManager.PARTIAL_WAKE_LOCK,
                "MemApp:webserver",
            ).apply {
                setReferenceCounted(false)
                acquire()
            }
        }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                @Suppress("DEPRECATION")
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "MemApp:webserver").apply {
                setReferenceCounted(false)
                acquire()
            }
        }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    private fun shutdown() {
        releaseLocks()
        isRunning = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    /**
     * Swiping the app away kills the Flutter engine, and with it the server, so
     * the notification must not outlive the task. (`android:stopWithTask` is
     * declared too; this covers the engine-still-alive case.)
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        onStopRequested?.invoke()
        shutdown()
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        releaseLocks()
        isRunning = false
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        // Matches the channel the Dart notification service declares, so the
        // user sees one "Web server" entry in system settings either way.
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Web server",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shown while the on-device web server is running."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
