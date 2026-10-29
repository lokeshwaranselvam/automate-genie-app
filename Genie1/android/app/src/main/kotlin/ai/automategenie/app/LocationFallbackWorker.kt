package ai.automategenie.app

import android.content.Context
import android.location.Location
import android.os.SystemClock
import android.util.Log
import androidx.work.Worker
import androidx.work.WorkerParameters
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import com.google.android.gms.tasks.CancellationTokenSource
import com.google.android.gms.tasks.Tasks
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

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

        // KEY_LAST_UPDATE_TIME is the last *successful* upload (service or
        // worker), so a running service whose uploads keep failing no longer
        // looks healthy here.
        val lastUploadTime = LocationTrackingManager.prefs(applicationContext)
            .getLong(LocationTrackingManager.KEY_LAST_UPDATE_TIME, 0L)

        // While the service is running it uploads every 15 minutes; allow it
        // a grace period so the worker does not race it and post duplicates.
        val threshold = if (LocationService.isRunning) {
            SERVICE_RUNNING_THRESHOLD_MS
        } else {
            FALLBACK_THRESHOLD_MS
        }
        val currentTime = System.currentTimeMillis()
        if (lastUploadTime != 0L && currentTime - lastUploadTime < threshold) {
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

            // A cached fix can be hours old; request a fresh one instead of
            // uploading a stale position as the current location.
            val location = if (lastKnownLocation != null && !isStale(lastKnownLocation)) {
                lastKnownLocation
            } else {
                requestCurrentLocation(fusedLocationClient)
            }

            if (location == null) {
                Log.w(TAG, "Fallback worker could not obtain a fresh location")
                Result.retry()
            } else {
                sendFallbackLocation(location)
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
        } else if (!LocationTrackingManager.isTrackingActive(applicationContext)) {
            // Tracking was stopped (e.g. the server rejected the credential);
            // nothing left to retry.
            Result.success()
        } else {
            Result.retry()
        }
    }

    private fun isStale(location: Location): Boolean {
        val ageNanos = SystemClock.elapsedRealtimeNanos() - location.elapsedRealtimeNanos
        return ageNanos > TimeUnit.MILLISECONDS.toNanos(MAX_LOCATION_AGE_MS)
    }

    private fun requestCurrentLocation(
        fusedLocationClient: FusedLocationProviderClient
    ): Location? {
        val cancellation = CancellationTokenSource()
        return try {
            Tasks.await(
                fusedLocationClient.getCurrentLocation(
                    Priority.PRIORITY_HIGH_ACCURACY,
                    cancellation.token
                ),
                30,
                TimeUnit.SECONDS
            )?.takeUnless { isStale(it) }
        } catch (error: TimeoutException) {
            Log.w(TAG, "Timed out waiting for a current location")
            null
        } finally {
            cancellation.cancel()
        }
    }

    companion object {
        private const val TAG = "LocationFallbackWorker"
        private val FALLBACK_THRESHOLD_MS = TimeUnit.MINUTES.toMillis(15)
        private val SERVICE_RUNNING_THRESHOLD_MS = TimeUnit.MINUTES.toMillis(20)
        private val MAX_LOCATION_AGE_MS = TimeUnit.MINUTES.toMillis(10)
    }
}
