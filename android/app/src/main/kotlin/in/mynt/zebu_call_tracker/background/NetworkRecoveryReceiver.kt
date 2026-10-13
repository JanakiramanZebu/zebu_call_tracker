package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.util.Log

/**
 * Native Network Recovery Listener.
 *
 * Asks for a sync when the handset comes back online while the process is
 * alive, so calls queued offline go up without waiting for the safety net.
 *
 * Only a real offline -> online transition counts. The callback is registered
 * with [ConnectivityManager.registerDefaultNetworkCallback], which reports the
 * DEFAULT network: `onAvailable` for each new default, and `onLost` only when
 * the default goes and nothing replaces it. A Wi-Fi/cellular handover is
 * therefore an `onAvailable` with a default already in hand, and is ignored.
 * The old registration listened to every INTERNET-capable network, so each
 * handover — and the registration itself — looked like "network came back"
 * and enqueued a sync.
 *
 * Even a real recovery enqueues only when the outbox owes the server something
 * ([SyncCoordinator.hasWorkToSend]), recordings included, whatever the
 * network. And it only ever ENQUEUES — [BackgroundScheduler.enqueueSync]
 * keeps at most one pending job.
 *
 * An object, not a BroadcastReceiver: the manifest entry for the old
 * CONNECTIVITY_CHANGE receiver was removed because that broadcast is no longer
 * delivered to manifest receivers, and the `onReceive` it left behind could
 * never run.
 */
object NetworkRecoveryReceiver {

    private const val TAG = "NetworkRecoveryReceiver"

    @Volatile
    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    /**
     * The default network as last reported, or null while there is none.
     * Callbacks arrive on one ConnectivityManager thread, in order.
     */
    @Volatile
    private var defaultNetwork: Network? = null

    /**
     * Registers a process-wide default-network callback to listen for network
     * restoration while the application process is alive.
     */
    fun registerNetworkCallback(context: Context) {
        val appContext = context.applicationContext
        val cm = appContext.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return

        synchronized(this) {
            if (networkCallback != null) return

            // Seeded before registering, so the onAvailable that registration
            // delivers for the current default reads as "still online", not as
            // a recovery. Starting offline leaves this null, and the first
            // default network to appear is then a genuine recovery.
            defaultNetwork = try {
                cm.activeNetwork
            } catch (e: Exception) {
                null
            }

            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    val wasOffline = defaultNetwork == null
                    defaultNetwork = network
                    if (wasOffline) onNetworkRestored(appContext)
                }

                override fun onLost(network: Network) {
                    if (network == defaultNetwork) defaultNetwork = null
                }
            }

            try {
                cm.registerDefaultNetworkCallback(callback)
                networkCallback = callback
                Log.i(TAG, "Successfully registered network recovery callback.")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register network callback: ${e.message}")
            }
        }
    }

    /**
     * Runs on the ConnectivityManager callback thread, not the main thread, so
     * the outbox EXISTS query here is fine.
     */
    private fun onNetworkRestored(appContext: Context) {
        if (!IngestStore.hasSession(appContext)) return
        if (!SyncCoordinator.hasWorkToSend(appContext)) {
            Log.d(TAG, "Network restored; nothing owed, no sync.")
            return
        }
        Log.i(TAG, "Network restored with work owed; requesting a sync.")
        BackgroundScheduler.enqueueSync(appContext)
    }
}
