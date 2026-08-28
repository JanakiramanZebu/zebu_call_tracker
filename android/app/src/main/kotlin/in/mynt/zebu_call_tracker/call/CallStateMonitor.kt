package `in`.mynt.zebu_call_tracker.call

import android.content.Context
import android.os.Build
import android.telephony.PhoneStateListener
import android.telephony.TelephonyCallback
import android.telephony.TelephonyManager
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import java.util.concurrent.Executor

/**
 * Live, in-process call-state signal.
 *
 * This is the FAST but LOSSY half of the two-stage design: it tells us a call
 * is happening right now, so the app can react (start an upload window, show
 * live UI) without waiting for the system to flush the call log. It is NOT the
 * source of truth — duration and final status always come from CallLogReader.
 *
 * Only valid while the process is alive. Background/after-death detection is
 * the manifest CallStateReceiver's job.
 */
class CallStateMonitor(private val context: Context) {

    fun interface Sink {
        fun onState(state: String, atMillis: Long)
    }

    private var sink: Sink? = null
    private var telephonyCallback: Any? = null

    @Suppress("DEPRECATION")
    private var legacyListener: PhoneStateListener? = null

    fun start(sink: Sink): Boolean {
        if (!PermissionInspector.isGranted(context, PermissionInspector.PHONE_STATE)) return false
        val tm = context.getSystemService(TelephonyManager::class.java) ?: return false
        this.sink = sink

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // PhoneStateListener is deprecated from API 31 and throws on some
            // builds; TelephonyCallback is the supported path.
            val executor = Executor { it.run() }
            val cb = object : TelephonyCallback(), TelephonyCallback.CallStateListener {
                override fun onCallStateChanged(state: Int) = emit(state)
            }
            telephonyCallback = cb
            tm.registerTelephonyCallback(executor, cb)
            true
        } else {
            val listener = object : PhoneStateListener() {
                override fun onCallStateChanged(state: Int, phoneNumber: String?) = emit(state)
            }
            legacyListener = listener
            tm.listen(listener, PhoneStateListener.LISTEN_CALL_STATE)
            true
        }
    }

    fun stop() {
        val tm = context.getSystemService(TelephonyManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            (telephonyCallback as? TelephonyCallback)?.let { tm?.unregisterTelephonyCallback(it) }
        } else {
            @Suppress("DEPRECATION")
            legacyListener?.let { tm?.listen(it, PhoneStateListener.LISTEN_NONE) }
        }
        telephonyCallback = null
        legacyListener = null
        sink = null
    }

    private fun emit(state: Int) {
        val name = when (state) {
            TelephonyManager.CALL_STATE_RINGING -> "ringing"
            TelephonyManager.CALL_STATE_OFFHOOK -> "offhook"
            TelephonyManager.CALL_STATE_IDLE -> "idle"
            else -> "unknown"
        }
        sink?.onState(name, System.currentTimeMillis())
    }
}
