package ai.automategenie.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.location.Location
import android.os.Build
import android.os.IBinder
import android.os.Looper
import android.util.Log
import androidx.core.app.NotificationCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.Tasks
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

class LocationService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    @Volatile private var lastPostedTime = 0L
    @Volatile private var lastAttemptTime = 0L
    private val postInFlight = AtomicBoolean(false)

    // The continuous stream only paces the upload/retry checks below (one
    // callback roughly every minute), so it uses balanced (Wi-Fi/cell) power
    // instead of keeping GPS hot. When an upload is actually due, a single
    // high-accuracy fix is requested so the posted point stays as accurate
    // as before.
    private val locationRequest by lazy {
        LocationRequest.Builder(Priority.PRIORITY_BALANCED_POWER_ACCURACY, LOCATION_INTERVAL_MS)
            .setMinUpdateIntervalMillis(MIN_LOCATION_INTERVAL_MS)
            .setWaitForAccurateLocation(false)
            .build()
    }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(locationResult: LocationResult) {
            val location = locationResult.lastLocation ?: run {
                Log.w(TAG, "Received null location update")
                return
            }

            // Only post to server if 15 minutes have passed since last post.
            // Updates arrive about once a minute while a post (plus the
            // accurate fix) can take up to ~45s, so skip while one is in
            // flight, and wait a minute between failed attempts instead of
            // retrying on every update.
            val currentTime = System.currentTimeMillis()
            if (currentTime - lastPostedTime >= POST_INTERVAL_MS &&
                currentTime - lastAttemptTime >= RETRY_INTERVAL_MS &&
                postInFlight.compareAndSet(false, true)
            ) {
                lastAttemptTime = currentTime
                serviceScope.launch {
                    try {
                        val fix = requestAccurateFix() ?: location
                        val sent = LocationTrackingManager.sendLocationToServer(
                            applicationContext,
                            fix.latitude,
                            fix.longitude
                        )
                        if (sent) {
                            lastPostedTime = currentTime
                            // Record only successful uploads so the fallback
                            // worker can tell when uploads are failing.
                            LocationTrackingManager.markLocationUpdate(applicationContext)
                            Log.d(TAG, "Location posted to server")
                        } else {
                            Log.w(TAG, "Location update could not be sent")
                        }
                    } finally {
                        postInFlight.set(false)
                    }
                }
            }
        }
    }

    override fun onCreate() {
        super.onCreate()
        fusedLocationClient = LocationServices.getFusedLocationProviderClient(this)

        // Initialize last posted time from SharedPreferences
        val prefs = LocationTrackingManager.prefs(this)
        lastPostedTime = prefs.getLong(LocationTrackingManager.KEY_LAST_UPDATE_TIME, 0L)
        
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Always enter the foreground first: the service is launched with
        // startForegroundService, and stopping it before startForeground()
        // crashes the app ("did not then call Service.startForeground()"),
        // e.g. when tracking is stopped right after being started.
        try {
            startForeground(LocationTrackingManager.NOTIFICATION_ID, buildNotification())
        } catch (error: Exception) {
            // Android 12+ throws when a foreground service is started from the
            // background without the needed permission; stop instead of crashing.
            Log.e(TAG, "Unable to start location foreground service", error)
            stopSelf()
            return START_NOT_STICKY
        }

        // Older installs have no verified role marker. Wait for the app's
        // authenticated attendance/role check before resuming that service.
        if (!LocationTrackingManager.isTrackingActive(this)) {
            LocationTrackingManager.stopTracking(this)
            stopSelf()
            return START_NOT_STICKY
        }

        if (!LocationTrackingManager.hasRequiredLocationPermissions(this)) {
            Log.e(TAG, "Location permissions are missing; stopping service")
            stopSelf()
            return START_NOT_STICKY
        }

        val prefs = LocationTrackingManager.prefs(this)
        val userId = intent?.getStringExtra(LocationTrackingManager.EXTRA_USER_ID)
            ?: prefs.getString(LocationTrackingManager.KEY_USER_ID, null)
        val authToken = intent?.getStringExtra(LocationTrackingManager.EXTRA_AUTH_TOKEN)
            ?: prefs.getString(LocationTrackingManager.KEY_AUTH_TOKEN, null)
        val siteUrl = intent?.getStringExtra(LocationTrackingManager.EXTRA_SITE_URL)
            ?: prefs.getString(LocationTrackingManager.KEY_SITE_URL, null)

        if (userId.isNullOrBlank() || authToken.isNullOrBlank() || siteUrl.isNullOrBlank()) {
            Log.e(TAG, "Tracking session data is missing; stopping service")
            stopSelf()
            return START_NOT_STICKY
        }

        LocationTrackingManager.persistTrackingState(this, true, userId, authToken, siteUrl)
        
        // Reset lastPostedTime to 0 to post immediately on first location update
        lastPostedTime = 0L
        lastAttemptTime = 0L
        
        startLocationUpdates()
        return START_STICKY
    }

    override fun onDestroy() {
        isRunning = false
        fusedLocationClient.removeLocationUpdates(locationCallback)
        serviceScope.cancel()
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startLocationUpdates() {
        try {
            fusedLocationClient.removeLocationUpdates(locationCallback)
            fusedLocationClient.requestLocationUpdates(
                locationRequest,
                locationCallback,
                Looper.getMainLooper()
            ).addOnSuccessListener {
                isRunning = true
                Log.d(TAG, "Live tracking location updates started")
            }.addOnFailureListener { error ->
                isRunning = false
                Log.e(TAG, "Unable to register location updates", error)
                stopSelf()
            }
        } catch (securityException: SecurityException) {
            Log.e(TAG, "Location permission denied", securityException)
            stopSelf()
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start location updates", error)
            stopSelf()
        }
    }

    /**
     * One-shot high-accuracy fix for an upload. Runs on the IO dispatcher
     * (blocking await). Returns null on timeout/error so the caller can fall
     * back to the latest streamed location.
     */
    private fun requestAccurateFix(): Location? {
        val cancellation = CancellationTokenSource()
        return try {
            Tasks.await(
                fusedLocationClient.getCurrentLocation(
                    Priority.PRIORITY_HIGH_ACCURACY,
                    cancellation.token
                ),
                ACCURATE_FIX_TIMEOUT_MS,
                TimeUnit.MILLISECONDS
            )
        } catch (securityException: SecurityException) {
            Log.w(TAG, "Accurate fix not permitted; using streamed location", securityException)
            null
        } catch (error: Exception) {
            Log.w(TAG, "Accurate fix unavailable; using streamed location", error)
            null
        } finally {
            cancellation.cancel()
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                LocationTrackingManager.NOTIFICATION_CHANNEL_ID,
                LocationTrackingManager.NOTIFICATION_CHANNEL_NAME,
                NotificationManager.IMPORTANCE_LOW
            )
            val notificationManager = getSystemService(NotificationManager::class.java)
            notificationManager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, LocationTrackingManager.NOTIFICATION_CHANNEL_ID)
            .setContentTitle("Live tracking active")
            .setContentText("Live tracking active")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setContentIntent(pendingIntent)
            .build()
    }

    companion object {
        @Volatile var isRunning = false
            private set
        private const val TAG = "LocationService"
        // Uploads happen every 15 min with 1-min retries, so a ~1-min stream
        // is enough to drive them; faster updates only cost battery.
        private const val LOCATION_INTERVAL_MS = 60_000L
        private const val MIN_LOCATION_INTERVAL_MS = 30_000L
        private const val ACCURATE_FIX_TIMEOUT_MS = 30_000L
        private const val POST_INTERVAL_MS = 15 * 60 * 1000L // 15 minutes
        private const val RETRY_INTERVAL_MS = 60 * 1000L // 1 minute after a failed post
    }
}
