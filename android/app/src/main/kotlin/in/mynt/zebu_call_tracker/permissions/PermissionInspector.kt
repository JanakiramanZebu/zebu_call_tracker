package `in`.mynt.zebu_call_tracker.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat
import `in`.mynt.zebu_call_tracker.whatsapp.WhatsAppCallListener

/**
 * Reports which of the call-tracking permissions are currently granted.
 *
 * This is a *read-only* inspector: it never triggers a dialog. Requesting is
 * driven from Dart (progressive, with rationale) via permission_handler; this
 * class exists so the native readers can fail fast with a precise reason
 * instead of throwing an opaque SecurityException.
 */
object PermissionInspector {

    const val PHONE_STATE = Manifest.permission.READ_PHONE_STATE
    const val CALL_LOG = Manifest.permission.READ_CALL_LOG
    const val CONTACTS = Manifest.permission.READ_CONTACTS

    // READ_PHONE_NUMBERS is gone from the manifest and from [snapshot]. It was
    // declared for SIM attribution, which needs only READ_PHONE_STATE (the
    // subscription list) — nothing here ever read a line number — and no Dart
    // code read the `readPhoneNumbers` key it was reported under.

    /**
     * Referenced only by [in.mynt.zebu_call_tracker.recording.RecordingCapabilityProbe],
     * which reports on the platform's *own* recording ability.
     *
     * Deliberately absent from [snapshot]: this app captures no audio and does
     * not declare RECORD_AUDIO, so reporting it always returned false and
     * invited the reader to conclude something was broken.
     */
    const val RECORD_AUDIO = Manifest.permission.RECORD_AUDIO

    fun isGranted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun snapshot(context: Context): Map<String, Boolean> = mapOf(
        "readPhoneState" to isGranted(context, PHONE_STATE),
        "readCallLog" to isGranted(context, CALL_LOG),
        "readContacts" to isGranted(context, CONTACTS),
        // WhatsApp call capture: notification access, and whether there is a
        // WhatsApp to capture from at all.
        "whatsappCalls" to WhatsAppCallListener.isEnabled(context),
        "whatsappInstalled" to WhatsAppCallListener.isWhatsAppInstalled(context),
        "lowRamDevice" to isLowRamDevice(context),
    )

    /**
     * Android Go and other low-RAM builds. On these the system itself refuses
     * "Display over other apps" and "Notification access" to every app ("not
     * available ... to improve performance"), so neither can be asked for:
     * the switch never turns on, whatever the user does.
     */
    fun isLowRamDevice(context: Context): Boolean = try {
        (context.getSystemService(Context.ACTIVITY_SERVICE) as android.app.ActivityManager)
            .isLowRamDevice
    } catch (_: Exception) {
        false
    }
}
