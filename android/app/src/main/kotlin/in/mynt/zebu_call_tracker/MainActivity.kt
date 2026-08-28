package `in`.mynt.zebu_call_tracker

import android.os.Bundle
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
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
