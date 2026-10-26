package ai.automategenie.app

import android.content.Intent
import android.os.Build
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val RECORDING_CHANNEL = "com.example.audioapp/record"
    private val TRACKING_CHANNEL = "com.example.homegenieapp/tracking"
    private val TAG = "MainActivity"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Recording Service Channel (unchanged for backward compatibility)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, RECORDING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startService" -> {
                        val intent = Intent(this, RecordingService::class.java)
                        startForegroundService(intent)
                        result.success("Service started")
                    }

                    "stopService" -> {
                        val intent = Intent(this, RecordingService::class.java)
                        stopService(intent)
                        result.success("Service stopped")
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }

        // Location Tracking Service Channel (new for live location)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, TRACKING_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startLocationTracking", "employeeCheckIn" -> {
                        try {
                            val userId = call.argument<String>("userId")
                            val authToken = call.argument<String>("authToken")
                            val siteUrl = call.argument<String>("siteUrl")
                            val trackingAllowed = call.argument<Boolean>("trackingAllowed") == true

                            if (!trackingAllowed) {
                                stopTracking(this)
                                result.error("TRACKING_NOT_ALLOWED", "Live tracking requires an eligible checked-in user", null)
                                return@setMethodCallHandler
                            }

                            if (userId.isNullOrEmpty() || authToken.isNullOrEmpty() || siteUrl.isNullOrEmpty()) {
                                result.error("INVALID_ARGS", "Missing required parameters: userId, authToken, or siteUrl", null)
                                return@setMethodCallHandler
                            }

                            if (!LocationTrackingManager.hasRequiredLocationPermissions(this)) {
                                result.error(
                                    "PERMISSION_DENIED",
                                    "Location permissions are required before check-in",
                                    null
                                )
                                return@setMethodCallHandler
                            }

                            startTracking(this, userId, authToken, siteUrl, trackingAllowed)
                            result.success("Employee check-in started live tracking")
                        } catch (e: Exception) {
                            Log.e(TAG, "Error starting location tracking: ${e.message}", e)
                            result.error("START_ERROR", "Failed to start location tracking: ${e.message}", null)
                        }
                    }

                    "stopLocationTracking", "employeeCheckOut" -> {
                        try {
                            stopTracking(this)
                            result.success("Employee checkout stopped live tracking")
                        } catch (e: Exception) {
                            Log.e(TAG, "Error stopping location tracking: ${e.message}", e)
                            result.error("STOP_ERROR", "Failed to stop location tracking: ${e.message}", null)
                        }
                    }

                    "isLocationTracking" -> {
                        val expectedUser = call.argument<String>("userId")
                        val saved = LocationTrackingManager.prefs(this)
                        if (expectedUser != null &&
                            (expectedUser != saved.getString(LocationTrackingManager.KEY_USER_ID, null) ||
                             call.argument<String>("authToken") != saved.getString(LocationTrackingManager.KEY_AUTH_TOKEN, null) ||
                             call.argument<String>("siteUrl") != saved.getString(LocationTrackingManager.KEY_SITE_URL, null))
                        ) {
                            stopTracking(this)
                            result.success(false)
                        } else {
                            result.success(LocationService.isRunning && LocationTrackingManager.isTrackingActive(this))
                        }
                    }

                    "hasLocationPermissions" -> {
                        result.success(LocationTrackingManager.hasRequiredLocationPermissions(this))
                    }

                    "requestLocationPermissions" -> {
                        // Check and return current permission status
                        // Note: Actual permission request should be handled by Dart using permission_handler plugin
                        result.success(LocationTrackingManager.hasRequiredLocationPermissions(this))
                    }

                    "isBatteryOptimized" -> {
                        try {
                            val batteryHelper = BatteryOptimizationHelper(this)
                            val isOptimized = !batteryHelper.isIgnoringBatteryOptimizations()
                            result.success(mapOf(
                                "isOptimized" to isOptimized,
                                "explanation" to batteryHelper.getBatteryOptimizationExplanation(),
                                "manufacturer" to batteryHelper.getDeviceManufacturer()
                            ))
                        } catch (e: Exception) {
                            result.error("CHECK_ERROR", "Failed to check battery optimization: ${e.message}", null)
                        }
                    }

                    "requestIgnoreBatteryOptimization" -> {
                        try {
                            BatteryOptimizationHelper(this).requestIgnoreBatteryOptimizations()
                            result.success(true)
                        } catch (e: Exception) {
                            result.error("BATTERY_ERROR", "Failed to request ignore battery optimization: ${e.message}", null)
                        }
                    }

                    "openBatteryOptimizationSettings" -> {
                        try {
                            val batteryHelper = BatteryOptimizationHelper(this)
                            batteryHelper.openBatteryOptimizationSettings()
                            result.success("Battery optimization settings opened")
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", "Failed to open settings: ${e.message}", null)
                        }
                    }

                    "openAppBatterySettings" -> {
                        try {
                            BatteryOptimizationHelper(this).openAppBatterySettings()
                            result.success("automategenie.ai app settings opened")
                        } catch (e: Exception) {
                            result.error("SETTINGS_ERROR", "Failed to open automategenie.ai settings: ${e.message}", null)
                        }
                    }

                    else -> {
                        result.notImplemented()
                    }
                }
            }
    }

    private fun startTracking(
        context: android.content.Context,
        userId: String,
        authToken: String,
        siteUrl: String,
        trackingAllowed: Boolean
    ) {
        LocationTrackingManager.startTracking(context, userId, authToken, siteUrl, trackingAllowed)
    }

    private fun stopTracking(context: android.content.Context) {
        LocationTrackingManager.stopTracking(context)
    }
}

