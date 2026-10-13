package `in`.mynt.zebu_call_tracker.permissions

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

/**
 * Whether the OS will actually let this app run in the background — and how to
 * ask it to.
 *
 * This is not a runtime permission and cannot be requested with the normal
 * dialog, but on this fleet it decides whether background ingest happens at
 * all: Doze defers a scheduled job for hours unless the app is exempt.
 */
object BatteryOptimization {

    /**
     * True when the app is exempt from Doze's app-standby buckets.
     *
     * Below API 23 there is no Doze, so the answer is always yes.
     */
    fun isIgnoring(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        val pm = context.getSystemService(PowerManager::class.java) ?: return false
        return pm.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Opens the exemption prompt.
     *
     * ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS shows a single yes/no dialog,
     * which is far likelier to be completed than dumping the user in the full
     * battery settings list. Google Play restricts the permission that backs it
     * to apps whose core function needs it; a fleet call tracker distributed
     * internally qualifies, and the fallback below covers a refusal to resolve.
     */
    fun requestExemption(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return true
        if (isIgnoring(context)) return true

        val direct = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        if (start(context, direct)) return true

        // Some builds (and some MDM policies) block the direct request but
        // still allow the list it lives in.
        return start(
            context,
            Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
        )
    }

    fun status(context: Context): Map<String, Any?> = mapOf(
        "ignoringBatteryOptimizations" to isIgnoring(context),
    )

    private fun start(context: Context, intent: Intent): Boolean = try {
        if (intent.resolveActivity(context.packageManager) != null) {
            context.startActivity(intent)
            true
        } else {
            false
        }
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }
}
