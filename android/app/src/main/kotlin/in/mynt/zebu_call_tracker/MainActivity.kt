package `in`.mynt.zebu_call_tracker

import android.content.Intent
import android.os.Bundle
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.CallTrackingService
import `in`.mynt.zebu_call_tracker.background.NetworkRecoveryReceiver
import `in`.mynt.zebu_call_tracker.overlay.PostCallData
import `in`.mynt.zebu_call_tracker.platform.NativeBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: NativeBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        
        // Starts only when a session exists -- CallTrackingService.start
        // enforces that itself, so opening the app while signed out no longer
        // raises a foreground service and a "tracking calls" notification for a
        // phone that is tracking nothing.
        CallTrackingService.start(applicationContext)

        // Re-arm on every launch.
        BackgroundScheduler.ensurePeriodic(this)
        
        // Register network restoration callback listener
        NetworkRecoveryReceiver.registerNetworkCallback(applicationContext)

        // No sync is kicked off here any more, and the omission is deliberate.
        //
        // This ran on Dispatchers.IO from onCreate, which is BEFORE Flutter has
        // built AuthController and reconciled the token pair. A run that
        // started here could refresh — rotating the pair in IngestStore — and
        // then have Dart's about-to-arrive restore write the pre-rotation token
        // back over it milliseconds later. The next 401 replayed a dead token
        // and the server revoked the session chain.
        //
        // AuthController.build() now triggers the startup sync itself, once the
        // stores agree. Nothing is lost by waiting: the WorkManager schedule
        // armed above is the durable trigger, and this was only ever the
        // fast path.

        // Handle the case where the app was launched cold by the overlay tap.
        handleOverlayIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOverlayIntent(intent)
    }

    private fun handleOverlayIntent(intent: Intent?) {
        val startedAt = intent?.getLongExtra(PostCallData.EXTRA_OPEN_CALL, -1L) ?: -1L
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