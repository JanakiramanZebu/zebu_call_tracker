package `in`.mynt.zebu_call_tracker.call

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.net.Uri

/**
 * Places a call back to a number from the app.
 *
 * Uses ACTION_DIAL, not ACTION_CALL. The difference matters:
 *
 *  - ACTION_DIAL opens the system dialer with the number filled in and needs no
 *    permission at all. The user taps once more to connect.
 *  - ACTION_CALL dials immediately but requires CALL_PHONE, a sensitive
 *    permission that has to be justified to Google Play and that a call
 *    *tracker* has no business holding — it observes calls, it does not need
 *    the right to make them unattended.
 *
 * The extra tap also keeps the resulting call in the system log the same way a
 * manually dialled one is, which is what the tracker reconciles against.
 */
object Dialer {

    /** False when there is no dialer to open — a tablet with no telephony. */
    fun dial(context: Context, number: String): Boolean {
        val trimmed = number.trim()
        if (trimmed.isEmpty()) return false

        // tel: requires the number percent-encoded; '#' in particular is a
        // fragment separator and would silently truncate a USSD-style number.
        val intent = Intent(Intent.ACTION_DIAL, Uri.parse("tel:${Uri.encode(trimmed)}"))
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

        return try {
            if (intent.resolveActivity(context.packageManager) == null) return false
            context.startActivity(intent)
            true
        } catch (e: ActivityNotFoundException) {
            false
        } catch (e: SecurityException) {
            false
        }
    }
}
