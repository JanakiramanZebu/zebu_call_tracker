package `in`.mynt.zebu_call_tracker.whatsapp

import android.content.ComponentName
import android.content.Context
import android.content.pm.PackageManager
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.app.NotificationManagerCompat

/**
 * Watches WhatsApp's own call notifications and turns them into call records.
 *
 * WhatsApp calls never reach Android's CallLog, and WhatsApp offers no API for
 * its call history. What it does do is post a system notification for every
 * call — "Incoming voice call" while ringing, an ongoing notification with a
 * running timer while connected, "Missed voice call" afterwards — and a
 * notification listener sees each of those appear and disappear. That is the
 * whole signal; [WhatsAppCallTracker] rebuilds direction, start, answer and end
 * times from it.
 *
 * Only `com.whatsapp` and `com.whatsapp.w4b` are looked at. Every other app's
 * notifications return on the first line and are never read.
 *
 * Needs "Notification access", which the user grants in system Settings (see
 * [isEnabled]). On Android 13+ a sideloaded APK must first be allowed
 * "restricted settings" from its App info screen before that switch can be
 * turned on.
 */
class WhatsAppCallListener : NotificationListenerService() {

    override fun onListenerConnected() {
        super.onListenerConnected()
        // A call already in progress when the listener (re)binds — after a
        // reboot, an app update, or the user granting access mid-call — has
        // no "posted" event coming. Seed the tracker from what is on screen.
        try {
            activeNotifications?.forEach { onNotificationPosted(it) }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read active notifications: ${e.message}")
        }
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        // The system unbinds listeners under memory pressure; ask to come back
        // rather than silently missing calls until the next reboot.
        try {
            requestRebind(ComponentName(this, WhatsAppCallListener::class.java))
        } catch (e: Exception) {
            Log.w(TAG, "Rebind request failed: ${e.message}")
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification) {
        if (sbn.packageName !in PACKAGES) return
        WhatsAppCallTracker.onPosted(applicationContext, sbn)
    }

    override fun onNotificationRemoved(sbn: StatusBarNotification) {
        if (sbn.packageName !in PACKAGES) return
        WhatsAppCallTracker.onRemoved(applicationContext, sbn)
    }

    companion object {
        private const val TAG = "WhatsAppCallListener"

        const val WHATSAPP = "com.whatsapp"
        const val WHATSAPP_BUSINESS = "com.whatsapp.w4b"
        val PACKAGES = setOf(WHATSAPP, WHATSAPP_BUSINESS)

        /** Whether the user has granted this app notification access. */
        fun isEnabled(context: Context): Boolean =
            NotificationManagerCompat.getEnabledListenerPackages(context)
                .contains(context.packageName)

        /**
         * Whether WhatsApp or WhatsApp Business is installed. Without either
         * there is nothing to listen to, and the permission is not asked for.
         * Needs the matching `<queries>` entries in the manifest (API 30+).
         */
        fun isWhatsAppInstalled(context: Context): Boolean =
            PACKAGES.any { pkg ->
                try {
                    context.packageManager.getPackageInfo(pkg, 0)
                    true
                } catch (_: PackageManager.NameNotFoundException) {
                    false
                }
            }
    }
}
