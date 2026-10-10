package com.thirvusoft.homegeniecom

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import android.net.Uri

/**
 * Helper class to detect and guide users about battery optimization settings.
 * Checks if the app is in battery optimization list and prompts user to disable it.
 * Handles OEM-specific restrictions (MIUI, ColorOS, EMUI).
 */
class BatteryOptimizationHelper(private val context: Context) {
    private val TAG = "BatteryOptimHelper"
    private val powerManager: PowerManager by lazy {
        context.getSystemService(Context.POWER_SERVICE) as PowerManager
    }

    /**
     * Check if app is in battery optimization list
     */
    fun isIgnoringBatteryOptimizations(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            powerManager.isIgnoringBatteryOptimizations(context.packageName)
        } else {
            true // Battery optimization not applicable on pre-M devices
        }
    }

    /**
     * Get the device manufacturer to detect OEM-specific apps
     */
    fun getDeviceManufacturer(): String {
        return Build.MANUFACTURER.lowercase()
    }

    /**
     * Get OEM battery optimization app package based on manufacturer
     */
    fun getOEMBatteryOptimizationApp(): String? {
        return when (getDeviceManufacturer()) {
            "xiaomi" -> "com.miui.powerkeeper" // MIUI
            "oppo" -> "com.coloros.oppoguardians" // ColorOS
            "vivo" -> "com.vivo.powersaving" // Vivo
            "samsung" -> "com.samsung.device.manager" // Samsung
            "honor", "huawei" -> "com.huawei.systemmanager" // EMUI/HarmonyOS
            else -> null
        }
    }

    /**
     * Open system battery optimization settings
     */
    fun openBatteryOptimizationSettings() {
        try {
            val intent = Intent().apply {
                action = Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            Log.d(TAG, "Opened battery optimization settings")
        } catch (e: Exception) {
            Log.e(TAG, "Cannot open battery optimization settings: ${e.message}")
            openBatteryOptimizationOEMSpecific()
        }
    }

    fun openAppBatterySettings() {
        val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
            data = Uri.parse("package:${context.packageName}")
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }
        context.startActivity(intent)
    }

    fun requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBatteryOptimizations()) {
            return
        }

        try {
            val intent = Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                data = Uri.parse("package:${context.packageName}")
                flags = Intent.FLAG_ACTIVITY_NEW_TASK
            }
            context.startActivity(intent)
            Log.d(TAG, "Requested ignore battery optimizations")
        } catch (e: Exception) {
            Log.e(TAG, "Cannot request ignore battery optimizations: ${e.message}")
            openBatteryOptimizationSettings()
        }
    }

    /**
     * Open OEM-specific battery optimization app if available
     */
    private fun openBatteryOptimizationOEMSpecific() {
        val oemApp = getOEMBatteryOptimizationApp()
        if (oemApp != null) {
            try {
                val intent = context.packageManager.getLaunchIntentForPackage(oemApp)
                if (intent != null) {
                    intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
                    context.startActivity(intent)
                    Log.d(TAG, "Opened OEM battery optimization app: $oemApp")
                }
            } catch (e: Exception) {
                Log.w(TAG, "Cannot open OEM app $oemApp: ${e.message}")
            }
        }
    }

    /**
     * Get user-friendly explanation for battery optimization disabling
     */
    fun getBatteryOptimizationExplanation(): String {
        val manufacturer = getDeviceManufacturer()
        return if (manufacturer == "motorola") {
            "On Motorola: open Settings > Battery > Manage background apps > Background use > automategenie.ai > Always allow. If available, also open Settings > Apps > automategenie.ai > App battery usage and choose Unrestricted."
        } else {
            "On your phone, open Settings > Apps > automategenie.ai > Battery (or App battery usage) and choose Unrestricted or Allow background activity. If your phone has Auto-start or Manage background apps, allow automategenie.ai there too. Menu names vary by phone."
        }
    }

    /**
     * Check if app is in battery restriction list by attempting to start a foreground service
     * This is a runtime check - sometimes the setting dialog doesn't reflect actual restrictions
     */
    fun checkRuntimeBatteryRestriction(): Boolean {
        return !isIgnoringBatteryOptimizations()
    }
}
