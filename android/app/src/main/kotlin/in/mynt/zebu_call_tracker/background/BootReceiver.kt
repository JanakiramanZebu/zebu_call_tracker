package `in`.mynt.zebu_call_tracker.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Re-arms background ingest after the two events that clear scheduled work.
 *
 *  - **BOOT_COMPLETED.** WorkManager does restore its own database across a
 *    reboot, so this is belt-and-braces for the safety net and the content
 *    trigger — but the immediate sweep matters: calls taken between the last
 *    run and the shutdown are caught up straight away rather than in an hour.
 *  - **MY_PACKAGE_REPLACED.** An app update force-stops the package. Until
 *    something starts a component, the manifest receivers stay inert, so the
 *    first sweep after an update has to be kicked off from here. It is also
 *    the first moment an upgraded install runs this build, which is when the
 *    old 15-minute jobs are retired and the tracking service comes up.
 *
 * Idempotent by construction: `ensurePeriodic` keeps any existing schedule
 * and an armed trigger, and `enqueueNow` keeps a pending sweep rather than
 * queueing a second, so a duplicate broadcast costs one no-op. Every step
 * refuses to act for a signed-out handset.
 */
class BootReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            "android.intent.action.QUICKBOOT_POWERON",
            -> {
                Log.i(TAG, "re-arming ingest after ${intent.action}")
                // The tracking service, on every signed-in handset unless the
                // server's policy says otherwise. Boot is when it matters most:
                // an employee who never opens the app after a restart would
                // otherwise be left to OEM firmware that starves a closed app.
                //
                // Started from boot on every API level. Android 15 forbids a
                // BOOT_COMPLETED receiver from starting a `dataSync` service,
                // which is why this used to be skipped there; the service is
                // `specialUse` from Android 14, which the rule does not cover,
                // and below 14 `dataSync` was never restricted. Both
                // broadcasts are exempt from the Android 12 background-start
                // ban.
                CallTrackingService.reconcile(context)
                // Safety net plus the content trigger; both refuse a
                // signed-out handset.
                BackgroundScheduler.ensurePeriodic(context)
                BackgroundScheduler.enqueueNow(context, BackgroundScheduler.REASON_BOOT)
            }
        }
    }

    companion object {
        private const val TAG = "BootReceiver"
    }
}
