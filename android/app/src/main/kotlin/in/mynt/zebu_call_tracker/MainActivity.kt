package `in`.mynt.zebu_call_tracker

import android.content.Intent
import android.os.Bundle
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.overlay.PostCallOverlayService
import `in`.mynt.zebu_call_tracker.platform.NativeBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {

    private var bridge: NativeBridge? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Re-arm on every launch. The periodic schedule is kept if it already
        // exists, so this is a no-op on a healthy install and a repair on one
        // where the OEM battery manager cancelled the job.
        BackgroundScheduler.ensurePeriodic(this)
        // Handle the case where the app was launched cold by the overlay tap.
        handleOverlayIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // onNewIntent fires when the activity is already running (singleTop)
        // and the overlay sends FLAG_ACTIVITY_SINGLE_TOP.
        handleOverlayIntent(intent)
    }

    /**
     * If [intent] carries a post-call overlay payload, forward it to the bridge
     * so Flutter can navigate to the matching call detail screen.
     */
    private fun handleOverlayIntent(intent: Intent?) {
        val startedAt = intent?.getLongExtra(PostCallOverlayService.EXTRA_OPEN_CALL, -1L) ?: -1L
        if (startedAt != -1L) {
            bridge?.handleOverlayOpenCall(startedAt)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // applicationContext, not `this`: the readers outlive a config change
        // and must not pin the Activity.
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