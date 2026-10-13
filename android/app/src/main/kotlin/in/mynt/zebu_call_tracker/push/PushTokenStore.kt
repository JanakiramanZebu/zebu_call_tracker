package `in`.mynt.zebu_call_tracker.push

import android.content.Context
import com.google.firebase.FirebaseApp

/**
 * Local state for the FCM token (Mobile API Guide §3.3, "Register the token").
 *
 * - **pending**: a token FCM handed us that the server has not taken yet.
 *   Written by `onNewToken` before anything else, so a token is never lost to
 *   a process death between FCM and the upload.
 * - **accepted**: the last token the server answered 200 for, and the device
 *   it was registered against. "On app start, if the token differs from the
 *   last one the server accepted" is a comparison against this.
 * - **rejected**: a token the server answered 422 for. "Do not retry the same
 *   value."
 *
 * Plain preferences: an FCM token addresses this install, it does not
 * authenticate anyone. It is still never logged.
 */
object PushTokenStore {

    private const val PREFS = "push_token"
    private const val KEY_PENDING = "pending"
    private const val KEY_ACCEPTED = "accepted"
    private const val KEY_ACCEPTED_DEVICE = "accepted_device_uuid"
    private const val KEY_REJECTED = "rejected"

    /**
     * Whether this build can use FCM at all: false when it was built without
     * google-services.json, so FirebaseApp was never initialised and any
     * FirebaseMessaging call would throw.
     */
    fun isConfigured(context: Context): Boolean = try {
        FirebaseApp.getApps(context.applicationContext).isNotEmpty()
    } catch (_: Exception) {
        false
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun pending(context: Context): String? =
        prefs(context).getString(KEY_PENDING, null)?.takeIf { it.isNotBlank() }

    fun setPending(context: Context, token: String) {
        // commit, not apply: onNewToken may be the last thing this process does.
        prefs(context).edit().putString(KEY_PENDING, token).commit()
    }

    fun isAccepted(context: Context, token: String, deviceUuid: String): Boolean {
        val p = prefs(context)
        return p.getString(KEY_ACCEPTED, null) == token &&
            p.getString(KEY_ACCEPTED_DEVICE, null) == deviceUuid
    }

    fun markAccepted(context: Context, token: String, deviceUuid: String) {
        val p = prefs(context)
        val editor = p.edit()
            .putString(KEY_ACCEPTED, token)
            .putString(KEY_ACCEPTED_DEVICE, deviceUuid)
        // A newer token may have arrived while this one was in flight.
        if (p.getString(KEY_PENDING, null) == token) editor.remove(KEY_PENDING)
        editor.apply()
    }

    /** Forgets the server's copy, so the next check uploads again. */
    fun clearAccepted(context: Context) {
        prefs(context).edit().remove(KEY_ACCEPTED).remove(KEY_ACCEPTED_DEVICE).apply()
    }

    fun isRejected(context: Context, token: String): Boolean =
        prefs(context).getString(KEY_REJECTED, null) == token

    fun markRejected(context: Context, token: String) {
        val p = prefs(context)
        val editor = p.edit().putString(KEY_REJECTED, token)
        if (p.getString(KEY_PENDING, null) == token) editor.remove(KEY_PENDING)
        editor.apply()
    }

    /**
     * Whether the server may be missing this install's token: one is pending,
     * or none has been accepted for [deviceUuid]. A cheap preferences read for
     * the hourly safety net, which then enqueues the upload.
     */
    fun mayNeedUpload(context: Context, deviceUuid: String): Boolean {
        val p = prefs(context)
        return pending(context) != null || p.getString(KEY_ACCEPTED_DEVICE, null) != deviceUuid
    }

    /** Sign-out. */
    fun clear(context: Context) {
        prefs(context).edit().clear().commit()
    }
}
