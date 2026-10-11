package com.thirvusoft.homegeniecom

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

class LocationBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != Intent.ACTION_MY_PACKAGE_REPLACED
        ) {
            return
        }

        if (!LocationTrackingManager.isTrackingActive(context)) return

        // After boot the app is in the background, so Android 14+ only allows
        // a location foreground service when background location is granted.
        // Starting it with "while in use" permission throws and crashes.
        if (!LocationTrackingManager.hasRequiredLocationPermissions(context) ||
            !LocationTrackingManager.hasBackgroundLocationPermission(context)
        ) {
            Log.w(TAG, "Not resuming live tracking: background location permission is missing")
            return
        }

        val prefs = LocationTrackingManager.prefs(context)
        val userId = prefs.getString(LocationTrackingManager.KEY_USER_ID, null)
        val authToken = prefs.getString(LocationTrackingManager.KEY_AUTH_TOKEN, null)
        val siteUrl = prefs.getString(LocationTrackingManager.KEY_SITE_URL, null)

        if (userId.isNullOrBlank() || authToken.isNullOrBlank() || siteUrl.isNullOrBlank()) {
            Log.w(TAG, "Not resuming live tracking: saved session data is incomplete")
            return
        }

        try {
            LocationTrackingManager.startTracking(context, userId, authToken, siteUrl)
            Log.i(TAG, "Resumed live tracking after $action")
        } catch (error: Exception) {
            Log.e(TAG, "Could not resume live tracking after $action", error)
        }
    }

    companion object {
        private const val TAG = "LocationBootReceiver"
    }
}
