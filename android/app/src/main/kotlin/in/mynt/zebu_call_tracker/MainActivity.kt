package `in`.mynt.zebu_call_tracker

import android.content.Intent
import android.os.Bundle
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.NetworkRecoveryReceiver
import `in`.mynt.zebu_call_tracker.background.SyncCoordinator
import `in`.mynt.zebu_call_tracker.overlay.PostCallOverlayService
import `in`.mynt.zebu_call_tracker.platform.NativeBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {

    private var bridge: NativeBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Re-arm on every launch.
        BackgroundScheduler.ensurePeriodic(this)
        
        // Register network restoration callback listener
        NetworkRecoveryReceiver.registerNetworkCallback(applicationContext)

        // Trigger automatic native sync on app startup
        CoroutineScope(Dispatchers.IO).launch {
            SyncCoordinator.runSync(applicationContext, "app_startup")
        }

        // Handle the case where the app was launched cold by the overlay tap.
        handleOverlayIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOverlayIntent(intent)
    }

    private fun handleOverlayIntent(intent: Intent?) {
        val startedAt = intent?.getLongExtra(PostCallOverlayService.EXTRA_OPEN_CALL, -1L) ?: -1L
        if (startedAt != -1L) {
            bridge?.handleOverlayOpenCall(startedAt)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = NativeBridge(applicationContext).also {
            it.attach(flutterEngine.dartExecutor.binaryMessenger)
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        bridge?.detach()
        bridge = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}