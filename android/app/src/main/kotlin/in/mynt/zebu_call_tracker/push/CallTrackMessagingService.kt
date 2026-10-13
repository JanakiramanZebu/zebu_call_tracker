package `in`.mynt.zebu_call_tracker.push

import android.util.Log
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import `in`.mynt.zebu_call_tracker.background.CallTrackingService
import `in`.mynt.zebu_call_tracker.background.IngestStore
import `in`.mynt.zebu_call_tracker.background.RequestedRecordingUploadWorker

/**
 * Receives the server's push wake-up (Mobile API Guide §3.3).
 *
 * The push is a hint, not a guarantee: FCM may delay or drop it, so the
 * hourly safety net and heartbeat stay exactly as they are. This only
 * shortens the gap on a phone Android has been holding back.
 */
class CallTrackMessagingService : FirebaseMessagingService() {

    override fun onNewToken(token: String) {
        // Persist first, then upload: the worker retries with backoff, and the
        // pending token survives a process death in between.
        PushTokenStore.setPending(applicationContext, token)
        PushTokenWorker.enqueue(applicationContext, force = true)
    }

    override fun onMessageReceived(message: RemoteMessage) {
        val data = message.data
        when (data["type"]) {
            TYPE_SYNC_REQUEST -> onSyncRequest(data)
            TYPE_UPLOAD_RECORDING -> onUploadRecording(data)
            // Ignore unknown types: new ones may be added later.
            else -> Unit
        }
    }

    /**
     * An administrator asked for one call's recording. Handed to its own
     * unique work at once, keyed by call, so repeated pushes for the same call
     * do nothing while one is queued or running. The same request also comes
     * through `GET /sync/status`, for a phone that never sees this push.
     */
    private fun onUploadRecording(data: Map<String, String>) {
        val request = RequestedRecordingUploadWorker.Request.of(
            callId = data["call_id"],
            requestId = data["request_id"],
            externalCallId = data["external_call_id"],
            startedAt = data["started_at"],
            phoneNumber = null,
            source = "push",
        )
        if (request == null) {
            Log.w(TAG, "UPLOAD_RECORDING without a usable call_id; ignored.")
            return
        }
        Log.i(TAG, "UPLOAD_RECORDING received (call=${request.callId}, request=${request.requestId}).")
        RequestedRecordingUploadWorker.enqueue(applicationContext, request)
    }

    private fun onSyncRequest(data: Map<String, String>) {
        // Logged, never branched on: every reason gets the same answer.
        val reason = data["reason"] ?: "unspecified"
        Log.i(TAG, "SYNC_REQUEST received (reason=$reason, sent_at=${data["sent_at"]}).")

        // Always enqueue, even when there turns out to be nothing to send:
        // Android downgrades high-priority messages for apps that receive
        // them and never act. About ten seconds are allowed here, so the
        // work is handed off and never done inline.
        PushSyncWorker.enqueue(applicationContext, reason)

        // A high-priority message briefly allows a foreground-service start,
        // which is exactly what a phone whose always-on service was killed by
        // a vendor battery manager needs. reconcile() honours the stored
        // `keepalive_service` and does nothing without a session.
        if (IngestStore.hasSession(applicationContext)) {
            CallTrackingService.reconcile(applicationContext)
        }
    }

    private companion object {
        const val TAG = "CallTrackMessaging"
        const val TYPE_SYNC_REQUEST = "SYNC_REQUEST"
        const val TYPE_UPLOAD_RECORDING = "UPLOAD_RECORDING"
    }
}
