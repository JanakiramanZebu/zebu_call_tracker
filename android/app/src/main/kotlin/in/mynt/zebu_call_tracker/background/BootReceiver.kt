package `in`.mynt.zebu_call_tracker.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms background ingest after the two events that clear scheduled work.
 *
 *  - **BOOT_COMPLETED.** WorkManager does restore its own database across a
 *    reboot, so this is belt-and-braces for the periodic job — but the
 *    immediate sweep matters: calls taken between the last run and the
 *    shutdown are caught up straight away rather than in six hours.
 *  - **MY_PACKAGE_REPLACED.** An app update force-stops the package. Until
 *    something starts a component, the manifest receivers stay inert, so the
 *    first sweep after an update has to be kicked off from here.
 *
 * Idempotent by construction: `ensurePeriodic` keeps any existing schedule and
 * `enqueueNow` replaces rather than queues, so a duplicate broadcast costs one
 * no-op.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> {
                Log.i(TAG, "re-arming ingest after ${intent.action}")
                BackgroundScheduler.ensurePeriodic(context)
                BackgroundScheduler.enqueueNow(context, BackgroundScheduler.REASON_BOOT)
            }
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
