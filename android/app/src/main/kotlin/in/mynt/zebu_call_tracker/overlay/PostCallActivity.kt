package `in`.mynt.zebu_call_tracker.overlay

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Hosts the post-call card when it cannot be drawn over other apps (see
 * [PostCallNotifier]). Opened from the notification only.
 *
 * Holds no UI of its own: [PostCallOverlayController] builds the very card the
 * overlay shows — scrim, centred card, the same buttons — and its buttons and
 * the next call close this exactly as they take the overlay down. Translucent,
 * outside the app's task and out of Recents, so closing it returns the user to
 * whatever they were doing.
 */
class PostCallActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        showFrom(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        showFrom(intent)
    }

    override fun onDestroy() {
        PostCallOverlayController.detach(this)
        super.onDestroy()
    }

    private fun showFrom(intent: Intent?) {
        val data = PostCallData.readFrom(intent)
        if (data == null) {
            finish()
            return
        }
        PostCallOverlayController.showIn(this, data)
    }
}
