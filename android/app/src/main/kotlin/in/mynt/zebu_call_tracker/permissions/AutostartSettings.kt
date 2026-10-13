package `in`.mynt.zebu_call_tracker.permissions

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.util.Log

/**
 * The maker's own "Auto-start" switch, on the firmware that has one.
 *
 * Xiaomi (Redmi, POCO), Oppo and Realme, Vivo and iQOO, Huawei and Honor, and
 * some OnePlus builds treat swiping the app out of Recents as a force-stop
 * unless Auto-start is on. A force-stopped app gets nothing from Android, no
 * call broadcasts, no scheduled work, no FCM push, until the user opens it
 * again. The battery exemption does not cover this; it is a separate switch
 * on a separate screen, and no API reports its state, so the app can only
 * open the screen and trust the user.
 */
object AutostartSettings {

    private const val TAG = "AutostartSettings"
    private const val PREFS = "zebu_autostart"
    private const val KEY_OPENED = "opened"

    private val MAKERS = setOf(
        "xiaomi", "redmi", "poco", "oppo", "realme", "vivo", "iqoo",
        "huawei", "honor", "oneplus", "asus", "letv",
    )

    /** Known screens, in the order tried. Most makers moved theirs at least once. */
    private val SCREENS = listOf(
        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.startupapp.StartupAppListActivity"),
        ComponentName("com.oppo.safe", "com.oppo.safe.permission.startup.StartupAppListActivity"),
        ComponentName("com.vivo.permissionmanager", "com.vivo.permissionmanager.activity.BgStartUpManagerActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.BgStartUpManager"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.optimize.process.ProtectActivity"),
        ComponentName("com.hihonor.systemmanager", "com.hihonor.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.oneplus.security", "com.oneplus.security.chainlaunch.view.ChainLaunchAppListActivity"),
        ComponentName("com.asus.mobilemanager", "com.asus.mobilemanager.autostart.AutoStartActivity"),
        ComponentName("com.letv.android.letvsafe", "com.letv.android.letvsafe.AutobootManageActivity"),
    )

    /** Whether this handset's maker is one with an Auto-start switch. */
    fun isRelevant(): Boolean {
        val maker = (Build.MANUFACTURER ?: "").lowercase()
        val brand = (Build.BRAND ?: "").lowercase()
        return maker in MAKERS || brand in MAKERS
    }

    /** Whether the user has been taken to the screen at least once. */
    fun wasOpened(context: Context): Boolean =
        prefs(context).getBoolean(KEY_OPENED, false)

    /**
     * Opens the maker's Auto-start screen, or this app's App info page when
     * none of the known screens exists on this build. True when something
     * opened.
     */
    fun open(context: Context): Boolean {
        val opened = SCREENS.any { component ->
            tryStart(context, Intent().setComponent(component))
        } || tryStart(
            context,
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                .setData(Uri.fromParts("package", context.packageName, null)),
        )
        if (opened) prefs(context).edit().putBoolean(KEY_OPENED, true).apply()
        return opened
    }

    private fun tryStart(context: Context, intent: Intent): Boolean = try {
        context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        true
    } catch (e: Exception) {
        // Not on this build (ActivityNotFoundException), or not exported to
        // third parties (SecurityException). Try the next one.
        Log.d(TAG, "Auto-start screen ${intent.component?.className} unavailable: ${e.javaClass.simpleName}")
        false
    }

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}
