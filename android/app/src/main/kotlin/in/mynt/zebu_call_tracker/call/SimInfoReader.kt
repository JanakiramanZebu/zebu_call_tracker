package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector

/**
 * Dual-SIM / subscription attribution.
 *
 * Deliberately best-effort. Per the feasibility report this is DEVICE
 * DEPENDENT: PHONE_ACCOUNT_ID in the call log is null or an opaque ICCID on
 * several OEMs, so a call record must remain valid with no SIM attached to it.
 * Every accessor here returns null rather than throwing.
 */
object SimInfoReader {

    fun activeSubscriptions(context: Context): List<Map<String, Any?>> {
        if (!PermissionInspector.isGranted(context, PermissionInspector.PHONE_STATE)) {
            return emptyList()
        }
        val sm = context.getSystemService(SubscriptionManager::class.java) ?: return emptyList()

        return try {
            sm.activeSubscriptionInfoList.orEmpty().map { info ->
                mapOf(
                    "subscriptionId" to info.subscriptionId,
                    "simSlotIndex" to info.simSlotIndex,
                    "carrierName" to info.carrierName?.toString(),
                    "displayName" to info.displayName?.toString(),
                    "countryIso" to info.countryIso,
                )
            }
        } catch (e: SecurityException) {
            // Some OEMs additionally gate this behind carrier privileges.
            emptyList()
        }
    }

    /**
     * Simultaneous-call capability, used to size the state machine. Single-SIM
     * devices report 1 and must still work end to end.
     */
    fun simCount(context: Context): Int {
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return 0
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) tm.activeModemCount
            else @Suppress("DEPRECATION") tm.phoneCount
        } catch (e: SecurityException) {
            0
        }
    }
}
