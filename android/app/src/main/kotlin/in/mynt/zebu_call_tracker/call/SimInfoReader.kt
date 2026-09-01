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
                    "iccId" to info.iccId,
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
     * Maps `CallLog.Calls.PHONE_ACCOUNT_ID` to a 1-based SIM slot.
     *
     * The call log stores a subscription id on most OEMs, an opaque ICCID on
     * some, and null on single-SIM handsets. Anything that cannot be resolved
     * returns slot 1 rather than failing: an unattributed call is still a valid
     * call record, and the feasibility report is explicit that SIM attribution
     * is best-effort.
     *
     * Pass the result of [activeSubscriptions] so a batch resolves against one
     * lookup instead of querying SubscriptionManager per row.
     */
    fun slotForAccountId(
        accountId: String?,
        subscriptions: List<Map<String, Any?>>,
    ): Int {
        if (accountId.isNullOrBlank() || subscriptions.isEmpty()) return 1

        // Usual case: the account id IS the subscription id.
        val asSubscriptionId = accountId.toIntOrNull()
        if (asSubscriptionId != null) {
            val match = subscriptions.firstOrNull {
                (it["subscriptionId"] as? Number)?.toInt() == asSubscriptionId
            }
            val slot = (match?.get("simSlotIndex") as? Number)?.toInt()
            // simSlotIndex is 0-based; the wire format and UI are 1-based.
            if (slot != null && slot >= 0) return slot + 1
        }

        // ICCID form: some OEMs write the SIM serial instead.
        val byIccid = subscriptions.firstOrNull {
            (it["iccId"] as? String)?.isNotBlank() == true &&
                it["iccId"] == accountId
        }
        val iccSlot = (byIccid?.get("simSlotIndex") as? Number)?.toInt()
        if (iccSlot != null && iccSlot >= 0) return iccSlot + 1

        return 1
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
