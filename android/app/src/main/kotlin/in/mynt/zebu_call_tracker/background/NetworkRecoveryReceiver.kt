package `in`.mynt.zebu_call_tracker.background

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Native Network Recovery Listener.
 *
 * Automatically triggers [SyncCoordinator] whenever network connectivity is restored
 * (Wi-Fi or Cellular network available), ensuring offline queued calls are uploaded
 * without waiting for manual user intervention or periodic polling.
 */
class NetworkRecoveryReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ConnectivityManager.CONNECTIVITY_ACTION) {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            val networkInfo = cm?.activeNetworkInfo
            if (networkInfo != null && networkInfo.isConnected) {
                Log.i(TAG, "Network re-connected via broadcast; triggering SyncCoordinator...")
                CoroutineScope(Dispatchers.IO).launch {
                    SyncCoordinator.runSync(context, "network_connected_broadcast")
                }
            }
        }
    }

    companion object {
        private const val TAG = "NetworkRecoveryReceiver"
        private var networkCallback: ConnectivityManager.NetworkCallback? = null

        /**
         * Registers a process-wide [ConnectivityManager.NetworkCallback] to listen
         * for network restoration events while the application process is alive.
         */
        fun registerNetworkCallback(context: Context) {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager ?: return
            if (networkCallback != null) return

            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()

            val callback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    Log.i(TAG, "Network restored via NetworkCallback; triggering SyncCoordinator...")
                    CoroutineScope(Dispatchers.IO).launch {
                        SyncCoordinator.runSync(context, "network_restored_callback")
                    }
                }
            }

            try {
                cm.registerNetworkCallback(request, callback)
                networkCallback = callback
                Log.i(TAG, "Successfully registered network recovery callback.")
            } catch (e: Exception) {
                Log.w(TAG, "Failed to register network callback: ${e.message}")
            }
        }
    }
}
