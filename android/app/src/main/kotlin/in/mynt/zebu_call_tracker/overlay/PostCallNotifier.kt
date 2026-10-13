package `in`.mynt.zebu_call_tracker.overlay

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import `in`.mynt.zebu_call_tracker.R

/**
 * The post-call card's way in when it cannot be drawn over other apps.
 *
 * Android Go refuses "Display over other apps" to every app, and elsewhere the
 * user may have turned it off. Either way the call is still tracked; what is
 * lost is the card appearing by itself. This posts one notification instead,
 * and tapping it opens [PostCallActivity] — the same card, in the middle of the
 * screen, closed only by its own buttons. An app's own activity needs no
 * overlay permission, and a tap on a notification is always allowed to start
 * one.
 *
 * One notification at a time: the next call's replaces it, as the next card
 * replaces the last. It is never cancelled by a timer.
 */
object PostCallNotifier {

    private const val TAG = "PostCallNotifier"
    private const val CHANNEL_ID = "post_call"

    // 1001-1006 belong to ingest, sync, the tracking service, the coordinator's
    // legacy notification, the push sync and requested recording uploads.
    private const val NOTIF_ID = 1007

    private const val ZEBU_BLUE = 0xFF0037B7.toInt()

    fun post(context: Context, data: PostCallData) {
        val app = context.applicationContext
        val manager = NotificationManagerCompat.from(app)
        if (!manager.areNotificationsEnabled()) {
            Log.i(TAG, "Notifications are off; no post-call card this time.")
            return
        }
        ensureChannel(app)

        val open = data.writeTo(
            Intent(app, PostCallActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
        )
        val pending = PendingIntent.getActivity(
            app,
            NOTIF_ID,
            open,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val title = when {
            data.direction == "missed" -> "Missed call"
            data.direction == "rejected" || data.direction == "blocked" -> "Declined call"
            data.direction == "outgoing" && data.durationSeconds <= 0 -> "Call not answered"
            else -> "Call ended"
        }
        val who = data.displayName.takeIf { it.isNotBlank() && it != "Call ended" }

        // What the lock screen shows: no name, no number.
        val public = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setColor(ZEBU_BLUE)
            .setContentTitle(title)
            .setContentText("Tap to see the call")
            .build()

        val endedAt = data.startedAtMillis.takeIf { it > 0L }
            ?.let { it + data.durationSeconds * 1000L }
            ?: System.currentTimeMillis()

        val notification = NotificationCompat.Builder(app, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_launcher_monochrome)
            .setColor(ZEBU_BLUE)
            .setContentTitle(if (who != null) "$title · $who" else title)
            .setContentText("Tap to see the call")
            .setContentIntent(pending)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .setVisibility(NotificationCompat.VISIBILITY_PRIVATE)
            .setPublicVersion(public)
            .setWhen(endedAt)
            .setShowWhen(true)
            .build()

        try {
            manager.notify(NOTIF_ID, notification)
        } catch (e: SecurityException) {
            // POST_NOTIFICATIONS withdrawn between the check and the post.
            Log.w(TAG, "Could not post the post-call notification: ${e.message}")
        }
    }

    private fun ensureChannel(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL_ID, "After a call", NotificationManager.IMPORTANCE_HIGH).apply {
                description = "Opens the call card on phones that cannot show it over other apps."
                setShowBadge(false)
                setSound(null, null)
            },
        )
    }
}
