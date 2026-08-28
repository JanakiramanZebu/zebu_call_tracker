package `in`.mynt.zebu_call_tracker.permissions

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import androidx.core.content.ContextCompat

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
    const val RECORD_AUDIO = Manifest.permission.RECORD_AUDIO
    const val PHONE_NUMBERS = Manifest.permission.READ_PHONE_NUMBERS

    fun isGranted(context: Context, permission: String): Boolean =
        ContextCompat.checkSelfPermission(context, permission) ==
            PackageManager.PERMISSION_GRANTED

    fun snapshot(context: Context): Map<String, Boolean> = mapOf(
        "readPhoneState" to isGranted(context, PHONE_STATE),
        "readCallLog" to isGranted(context, CALL_LOG),
        "readContacts" to isGranted(context, CONTACTS),
        "recordAudio" to isGranted(context, RECORD_AUDIO),
        "readPhoneNumbers" to isGranted(context, PHONE_NUMBERS),
    )
}
