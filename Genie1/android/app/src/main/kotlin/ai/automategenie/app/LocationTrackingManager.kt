package ai.automategenie.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.location.Geocoder
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.Locale
import java.util.concurrent.TimeUnit

object LocationTrackingManager {
    private const val TAG = "LocationTrackingManager"

    const val PREFS_NAME = "live_location_tracking"
    const val KEY_TRACKING_ACTIVE = "tracking_active"
    // Recheck eligibility after upgrading from the former broader role policy.
    const val KEY_ROLE_ALLOWED = "tracking_role_allowed_v2"
    const val KEY_USER_ID = "tracking_user_id"
    const val KEY_AUTH_TOKEN = "tracking_auth_token"
    const val KEY_SITE_URL = "tracking_site_url"
    // Time of the last *successful* upload to the server (not the last GPS
    // fix); the fallback worker relies on this to detect missed uploads.
    const val KEY_LAST_UPDATE_TIME = "last_update_time"

    const val EXTRA_USER_ID = "userId"
    const val EXTRA_AUTH_TOKEN = "authToken"
    const val EXTRA_SITE_URL = "siteUrl"

    const val NOTIFICATION_CHANNEL_ID = "live_tracking_channel"
    const val NOTIFICATION_CHANNEL_NAME = "Live Location Tracking"
    const val NOTIFICATION_ID = 1001

    private const val PERIODIC_WORK_NAME = "location_fallback"
    private const val ONE_TIME_WORK_NAME = "location_fallback_onetime"

    private val okHttpClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(15, TimeUnit.SECONDS)
        .build()

    fun startTracking(
        context: Context,
        userId: String,
        authToken: String,
        siteUrl: String,
        trackingAllowed: Boolean = false
    ) {
        if (!trackingAllowed) {
            stopTracking(context)
            return
        }
        prefs(context).edit().putBoolean(KEY_ROLE_ALLOWED, true).apply()
        persistTrackingState(context, true, userId, authToken, siteUrl)
        ContextCompat.startForegroundService(
            context,
            buildServiceIntent(context, userId, authToken, siteUrl)
        )
        scheduleFallback(context)
    }

    fun stopTracking(context: Context) {
        prefs(context).edit()
            .putBoolean(KEY_TRACKING_ACTIVE, false)
            .remove(KEY_ROLE_ALLOWED)
            .remove(KEY_USER_ID)
            .remove(KEY_AUTH_TOKEN)
            .remove(KEY_SITE_URL)
            .remove(KEY_LAST_UPDATE_TIME)
            .apply()
        cancelFallback(context)
        context.stopService(Intent(context, LocationService::class.java))
    }

    fun buildServiceIntent(
        context: Context,
        userId: String? = null,
        authToken: String? = null,
        siteUrl: String? = null
    ): Intent {
        return Intent(context, LocationService::class.java).apply {
            userId?.let { putExtra(EXTRA_USER_ID, it) }
            authToken?.let { putExtra(EXTRA_AUTH_TOKEN, it) }
            siteUrl?.let { putExtra(EXTRA_SITE_URL, it) }
        }
    }

    fun scheduleFallback(context: Context) {
        val periodicWork = PeriodicWorkRequestBuilder<LocationFallbackWorker>(
            15, TimeUnit.MINUTES
        ).build()

        WorkManager.getInstance(context).enqueueUniquePeriodicWork(
            PERIODIC_WORK_NAME,
            ExistingPeriodicWorkPolicy.UPDATE,
            periodicWork
        )

        val oneTimeWork = OneTimeWorkRequestBuilder<LocationFallbackWorker>()
            .setInitialDelay(15, TimeUnit.MINUTES)
            .build()

        WorkManager.getInstance(context).enqueueUniqueWork(
            ONE_TIME_WORK_NAME,
            ExistingWorkPolicy.REPLACE,
            oneTimeWork
        )
    }

    fun cancelFallback(context: Context) {
        WorkManager.getInstance(context).cancelUniqueWork(PERIODIC_WORK_NAME)
        WorkManager.getInstance(context).cancelUniqueWork(ONE_TIME_WORK_NAME)
    }

    fun persistTrackingState(
        context: Context,
        active: Boolean,
        userId: String?,
        authToken: String?,
        siteUrl: String?
    ) {
        prefs(context).edit()
            .putBoolean(KEY_TRACKING_ACTIVE, active)
            .putString(KEY_USER_ID, userId)
            .putString(KEY_AUTH_TOKEN, authToken)
            .putString(KEY_SITE_URL, siteUrl)
            .apply()
    }

    /** Records a successful server upload. Call only after sendLocationToServer returns true. */
    fun markLocationUpdate(context: Context) {
        prefs(context).edit()
            .putLong(KEY_LAST_UPDATE_TIME, System.currentTimeMillis())
            .apply()
    }

    fun isTrackingActive(context: Context): Boolean {
        val saved = prefs(context)
        return saved.getBoolean(KEY_TRACKING_ACTIVE, false) &&
            saved.getBoolean(KEY_ROLE_ALLOWED, false)
    }

    fun hasRequiredLocationPermissions(context: Context): Boolean {
        val fineGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_FINE_LOCATION
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        val coarseGranted = ContextCompat.checkSelfPermission(
            context,
            Manifest.permission.ACCESS_COARSE_LOCATION
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED

        // Attendance starts the location foreground service from a visible
        // check-in action. Android permits that service with either foreground
        // location permission; requiring background permission here prevented
        // tracking for users who granted location while using the app.
        return fineGranted || coarseGranted
    }

    fun hasBackgroundLocationPermission(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.ACCESS_BACKGROUND_LOCATION
            ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        } else {
            true
        }
    }

    fun sendLocationToServer(context: Context, lat: Double, lng: Double): Boolean {
        if (!isTrackingActive(context)) return false
        val prefs = prefs(context)
        val userId = prefs.getString(KEY_USER_ID, null)
        val authToken = prefs.getString(KEY_AUTH_TOKEN, null)
        val siteUrl = prefs.getString(KEY_SITE_URL, null)

        if (userId.isNullOrBlank() || authToken.isNullOrBlank() || siteUrl.isNullOrBlank()) {
            Log.w(TAG, "Tracking session is incomplete; skipping location sync")
            return false
        }

        if (!hasInternetConnection(context)) {
            Log.w(TAG, "No internet connection; will retry later")
            return false
        }

        val address = getAddress(context, lat, lng)
        val payload = JSONObject().apply {
            put("latitude", lat)
            put("longitude", lng)
            put("location", address)
            put("user", userId)
        }

        return try {
            val requestBuilder = Request.Builder()
                .url(siteUrl.trimEnd('/') + "/api/resource/Live%20Location")
                .post(
                    payload.toString()
                        .toRequestBody("application/json; charset=utf-8".toMediaType())
                )
                .addHeader("Content-Type", "application/json")
                .addHeader("Accept", "application/json")

            // Attendance supplies the same API token used by its REST calls.
            // Session-cookie POSTs without a CSRF token can be rejected by ERP.
            if (authToken.startsWith("token ")) {
                requestBuilder.addHeader("Authorization", authToken)
            } else {
                // Keep the prior credential format readable for existing
                // persisted services until the next attendance start refreshes it.
                requestBuilder.addHeader("Cookie", "sid=$authToken")
            }
            val request = requestBuilder.build()

            // null = success, true = credential rejected, false = other failure.
            val authRejected: Boolean? = okHttpClient.newCall(request).execute().use { response ->
                if (response.isSuccessful) return@use null
                Log.w(
                    TAG,
                    "Location sync failed: code=${response.code}"
                )
                response.code == 401 || response.code == 403
            }
            when (authRejected) {
                null -> true
                true -> {
                    // A revoked/expired credential will never succeed on
                    // retry; stop tracking exactly like an explicit stop so
                    // the service does not keep GPS running indefinitely.
                    // The app restarts tracking after its next authenticated
                    // attendance/role check with a fresh token.
                    Log.e(TAG, "Location sync rejected by server (auth); stopping live tracking")
                    stopTracking(context)
                    false
                }
                false -> false
            }
        } catch (error: Exception) {
            Log.e(TAG, "Location sync failed", error)
            false
        }
    }

    @Suppress("DEPRECATION")
    private fun getAddress(context: Context, lat: Double, lng: Double): String {
        return try {
            val address = Geocoder(context, Locale.getDefault())
                .getFromLocation(lat, lng, 1)
                ?.firstOrNull()
                ?.getAddressLine(0)
                ?.trim()

            address?.takeIf { it.isNotEmpty() } ?: "$lat, $lng"
        } catch (error: Exception) {
            Log.w(TAG, "Reverse geocoding failed; using coordinates as location", error)
            "$lat, $lng"
        }
    }

    fun prefs(context: Context): SharedPreferences {
        return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun hasInternetConnection(context: Context): Boolean {
        val connectivityManager = context.getSystemService(Context.CONNECTIVITY_SERVICE)
                as ConnectivityManager
        val network = connectivityManager.activeNetwork ?: return false
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return false
        return capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }
}
