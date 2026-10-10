package com.thirvusoft.homegeniecom

import android.content.Context
import android.location.Location
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.location.LocationServices
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit

class LocationFallbackWorker(
    appContext: Context,
    workerParams: WorkerParameters
) : Worker(appContext, workerParams) {

    override fun doWork(): Result {
        if (!LocationTrackingManager.isTrackingActive(applicationContext)) {
            return Result.success()
        }

        if (
            !LocationTrackingManager.hasRequiredLocationPermissions(applicationContext) ||
            !LocationTrackingManager.hasBackgroundLocationPermission(applicationContext)
        ) {
            Log.e(TAG, "Fallback worker stopped because permissions are missing")
            return Result.failure()
        }

        val lastUpdateTime = LocationTrackingManager.prefs(applicationContext)
            .getLong(LocationTrackingManager.KEY_LAST_UPDATE_TIME, 0L)

        val currentTime = System.currentTimeMillis()
        if (lastUpdateTime != 0L && currentTime - lastUpdateTime < FALLBACK_THRESHOLD_MS) {
            return Result.success()
        }

        return try {
            val fusedLocationClient =
                LocationServices.getFusedLocationProviderClient(applicationContext)
            val lastKnownLocation = Tasks.await(
                fusedLocationClient.lastLocation,
                15,
                TimeUnit.SECONDS
            )

            if (lastKnownLocation == null) {
                Log.w(TAG, "Fallback worker found no last known location")
                Result.retry()
            } else {
                sendFallbackLocation(lastKnownLocation)
            }
        } catch (securityException: SecurityException) {
            Log.e(TAG, "Fallback worker permission error", securityException)
            Result.failure()
        } catch (error: Exception) {
            Log.e(TAG, "Fallback worker failed", error)
            Result.retry()
        }
    }

    private fun sendFallbackLocation(location: Location): Result {
        val sent = LocationTrackingManager.sendLocationToServer(
            applicationContext,
            location.latitude,
            location.longitude
        )

        return if (sent) {
            LocationTrackingManager.markLocationUpdate(applicationContext)
            Result.success()
        } else {
            Result.retry()
        }
    }

    companion object {
        private const val TAG = "LocationFallbackWorker"
        private val FALLBACK_THRESHOLD_MS = TimeUnit.MINUTES.toMillis(15)
    }
}
