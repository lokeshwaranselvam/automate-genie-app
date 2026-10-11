package com.thirvusoft.homegeniecom

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
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
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class LocationService : Service() {
    private val serviceScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var fusedLocationClient: FusedLocationProviderClient
    private var lastPostedTime = 0L

    private val locationRequest by lazy {
        LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, LOCATION_INTERVAL_MS)
            .setMinUpdateIntervalMillis(LOCATION_INTERVAL_MS)
            .setWaitForAccurateLocation(false)
            .build()
    }

    private val locationCallback = object : LocationCallback() {
        override fun onLocationResult(locationResult: LocationResult) {
            val location = locationResult.lastLocation ?: run {
                Log.w(TAG, "Received null location update")
                return
            }

            LocationTrackingManager.markLocationUpdate(applicationContext)

            // Only post to server if 15 minutes have passed since last post
            val currentTime = System.currentTimeMillis()
            if (currentTime - lastPostedTime >= POST_INTERVAL_MS) {
                serviceScope.launch {
                    val sent = LocationTrackingManager.sendLocationToServer(
                        applicationContext,
                        location.latitude,
                        location.longitude
                    )
                    if (sent) {
                        lastPostedTime = currentTime
                        Log.d(TAG, "Location posted to server")
                    } else {
                        Log.w(TAG, "Location update could not be sent")
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
        try {
            startForeground(LocationTrackingManager.NOTIFICATION_ID, buildNotification())
        } catch (error: Exception) {
            // Android 12+ throws when a foreground service is started from the
            // background without the needed permission; stop instead of crashing.
            Log.e(TAG, "Unable to start location foreground service", error)
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
        
        startLocationUpdates()
        return START_STICKY
    }

    override fun onDestroy() {
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
            )
        } catch (securityException: SecurityException) {
            Log.e(TAG, "Location permission denied", securityException)
            stopSelf()
        } catch (error: Exception) {
            Log.e(TAG, "Unable to start location updates", error)
            stopSelf()
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
        private const val TAG = "LocationService"
        private const val LOCATION_INTERVAL_MS = 10_000L
        private const val POST_INTERVAL_MS = 15 * 60 * 1000L // 15 minutes
    }
}
