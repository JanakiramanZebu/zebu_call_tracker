package `in`.mynt.zebu_call_tracker.call

import android.content.ComponentName
import android.content.Context
import android.os.Build
import android.telecom.PhoneAccountHandle
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
 *
 * Needs READ_PHONE_STATE only. The ICCID is not read: from API 29
 * `SubscriptionInfo.getIccId()` returns "" to any app without carrier
 * privilege, so matching an ICCID-form account id against it could never
 * succeed on most of the fleet, and it is an identifier this app has no other
 * use for.
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
     * Maps `CallLog.Calls.PHONE_ACCOUNT_ID` to a 1-based SIM slot.
     *
     * The call log stores a subscription id on most OEMs, an opaque ICCID on
     * some, and null on single-SIM handsets. Only the subscription-id form is
     * resolved (see the class comment for why not the ICCID). Anything else
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

        return 1
    }

    /**
     * [slotForAccountId], plus the cases it cannot resolve on its own.
     *
     * Many dual-SIM builds (Samsung among them) write the SIM's ICCID into
     * PHONE_ACCOUNT_ID, not the subscription id, and every such call was sent
     * to the server as SIM 1. From API 30 Telecom resolves the account itself:
     * the id plus PHONE_ACCOUNT_COMPONENT_NAME make a PhoneAccountHandle, and
     * TelephonyManager maps that to its subscription — no ICCID read involved.
     * A handset with one active SIM has only one answer.
     */
    fun slotForCallLogRow(
        context: Context,
        accountId: String?,
        componentName: String?,
        subscriptions: List<Map<String, Any?>>,
    ): Int {
        if (accountId.isNullOrBlank() || subscriptions.isEmpty()) return 1
        if (subscriptions.size == 1) {
            val only = (subscriptions[0]["simSlotIndex"] as? Number)?.toInt()
            return if (only != null && only >= 0) only + 1 else 1
        }

        val asSubscriptionId = accountId.toIntOrNull()
        if (asSubscriptionId != null &&
            subscriptions.any { (it["subscriptionId"] as? Number)?.toInt() == asSubscriptionId }
        ) {
            return slotForAccountId(accountId, subscriptions)
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && !componentName.isNullOrBlank()) {
            try {
                val component = ComponentName.unflattenFromString(componentName)
                val tm = context.getSystemService(TelephonyManager::class.java)
                if (component != null && tm != null) {
                    val subId = tm.getSubscriptionId(PhoneAccountHandle(component, accountId))
                    if (subId != SubscriptionManager.INVALID_SUBSCRIPTION_ID) {
                        return slotForAccountId(subId.toString(), subscriptions)
                    }
                }
            } catch (_: Exception) {
                // Best effort, like everything here.
            }
        }
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
