package `in`.mynt.zebu_call_tracker.push

import android.content.Context
import android.util.Log
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.google.android.gms.tasks.Tasks
import com.google.firebase.messaging.FirebaseMessaging
import `in`.mynt.zebu_call_tracker.background.IngestStore
import `in`.mynt.zebu_call_tracker.background.NativeApi
import `in`.mynt.zebu_call_tracker.background.TokenRefresher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * `PUT /devices/fcm-token` (Mobile API Guide §3.3, "Register the token").
 *
 * Enqueued from the three places §3.3 lists:
 *  1. right after registration — pairing, and Dart's re-registration of a
 *     device the server did not know ([enqueue] with `force`);
 *  2. `onNewToken`, after the token is persisted as pending;
 *  3. app start, through `setAuthSession`, which uploads only when the token
 *     differs from the last one the server accepted.
 * Plus the hourly safety net, when [PushTokenStore.mayNeedUpload] says the
 * server may be missing it — "a token the server never receives means the
 * phone can never be woken".
 *
 * Network errors and 5xx retry with WorkManager's exponential backoff, capped
 * at [MAX_ATTEMPTS] (§10.2); the token stays pending for the next trigger.
 */
class PushTokenWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result = withContext(Dispatchers.IO) {
        val ctx = applicationContext
        if (!PushTokenStore.isConfigured(ctx)) return@withContext Result.success()
        // Signed out: sign-in enqueues this again, and the token waits as pending.
        if (!IngestStore.hasSession(ctx)) return@withContext Result.success()
        val deviceUuid = IngestStore.getDeviceUuid(ctx)
        if (deviceUuid.isNullOrBlank()) return@withContext Result.success()

        val token = PushTokenStore.pending(ctx) ?: currentToken()
            ?: return@withContext retryOrHold("FCM has no token yet")

        val force = inputData.getBoolean(KEY_FORCE, false)
        if (!force && PushTokenStore.isAccepted(ctx, token, deviceUuid)) {
            return@withContext Result.success()
        }
        // 422 for this exact value already: "Do not retry the same value."
        if (PushTokenStore.isRejected(ctx, token)) return@withContext Result.success()

        val response = NativeApi.request(
            ctx,
            "PUT",
            "/devices/fcm-token?device_uuid=" + URLEncoder.encode(deviceUuid, "UTF-8"),
            JSONObject().put("fcm_token", token),
        )
        val status = response.status
        val code = response.errorCode

        when {
            response.isSuccess -> {
                PushTokenStore.markAccepted(ctx, token, deviceUuid)
                Log.i(TAG, "FCM token registered with the server.")
                Result.success()
            }

            status == null -> retryOrHold("no response")

            // The refresh behind the 401 failed. A dead session is not ours to
            // fix; a dropped connection is worth another try.
            status == 401 ->
                if (response.refreshFailure == TokenRefresher.Failure.TRANSIENT) {
                    retryOrHold("token refresh did not complete")
                } else {
                    Result.success()
                }

            // Registration (Dart's check-in) re-enqueues with force once the
            // server knows the device again.
            code == "DEVICE_NOT_REGISTERED" -> {
                PushTokenStore.clearAccepted(ctx)
                Log.w(TAG, "Device not registered; the token is sent after registration.")
                Result.success()
            }

            // DEVICE_REVOKED / DEVICE_INACTIVE: "Stop. Same handling as for sync."
            status == 403 -> {
                Log.w(TAG, "FCM token refused ($code); not retrying.")
                Result.success()
            }

            status == 422 -> {
                PushTokenStore.markRejected(ctx, token)
                Log.w(TAG, "FCM token rejected as malformed; not retrying this value.")
                Result.success()
            }

            status == 429 || status >= 500 -> retryOrHold("HTTP $status")

            else -> {
                Log.w(TAG, "FCM token upload answered $status ($code); not retrying.")
                Result.success()
            }
        }
    }

    private fun retryOrHold(why: String): Result {
        if (runAttemptCount + 1 >= MAX_ATTEMPTS) {
            Log.w(TAG, "FCM token upload gave up after $MAX_ATTEMPTS attempts ($why); held for the next trigger.")
            return Result.success()
        }
        Log.w(TAG, "FCM token upload will retry: $why")
        return Result.retry()
    }

    companion object {
        private const val TAG = "PushTokenWorker"
        private const val WORK_NAME = "zebu.push.fcm-token"
        private const val KEY_FORCE = "force"

        /** §10.2: "Cap attempts (≈8) and then hold until the next scheduled sync." */
        private const val MAX_ATTEMPTS = 8

        /**
         * Queues an upload. [force] sends even when the server already has
         * this token: a registration may have created a new device row that
         * has no token on it. Cheap and safe to call often; the server treats
         * the same token again as a no-op.
         */
        fun enqueue(context: Context, force: Boolean = false) {
            if (!PushTokenStore.isConfigured(context)) return
            val request = OneTimeWorkRequestBuilder<PushTokenWorker>()
                .setConstraints(
                    Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
                )
                .setInputData(Data.Builder().putBoolean(KEY_FORCE, force).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
                .build()
            // A forced or new-token request supersedes one waiting out a
            // backoff; a routine check must not reset one that is.
            val policy = if (force) ExistingWorkPolicy.REPLACE else ExistingWorkPolicy.KEEP
            WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
        }

        /** The hourly safety net's check: enqueues only when the server may lack the token. */
        fun enqueueIfNeeded(context: Context) {
            if (!PushTokenStore.isConfigured(context)) return
            val deviceUuid = IngestStore.getDeviceUuid(context)
            if (deviceUuid.isNullOrBlank() || !IngestStore.hasSession(context)) return
            if (PushTokenStore.mayNeedUpload(context, deviceUuid)) enqueue(context)
        }

        /**
         * Sign-out (§3.3, "Remove it on sign-out"): `DELETE /devices/fcm-token`
         * while the access token is still held, then FCM's own deleteToken,
         * then the local state.
         *
         * Blocking: call off the main thread, and BEFORE the session is
         * cleared. Never throws, and never holds sign-out hostage: a DELETE
         * that fails still ends with the token deleted at FCM, which makes the
         * server's copy undeliverable anyway.
         */
        fun unregister(context: Context) {
            val ctx = context.applicationContext
            WorkManager.getInstance(ctx).cancelUniqueWork(WORK_NAME)
            if (!PushTokenStore.isConfigured(ctx)) {
                PushTokenStore.clear(ctx)
                return
            }
            val deviceUuid = IngestStore.getDeviceUuid(ctx)
            if (IngestStore.hasSession(ctx) && !deviceUuid.isNullOrBlank()) {
                val response = NativeApi.request(
                    ctx,
                    "DELETE",
                    "/devices/fcm-token?device_uuid=" + URLEncoder.encode(deviceUuid, "UTF-8"),
                )
                Log.i(TAG, "FCM token removal answered ${response.status}.")
            }
            try {
                Tasks.await(FirebaseMessaging.getInstance().deleteToken(), 15, TimeUnit.SECONDS)
            } catch (e: Exception) {
                Log.w(TAG, "FCM deleteToken failed: ${e.message}")
            }
            PushTokenStore.clear(ctx)
        }

        /** FCM's current token for this install, or null. Blocking. */
        private fun currentToken(): String? = try {
            Tasks.await(FirebaseMessaging.getInstance().token, 30, TimeUnit.SECONDS)
                ?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            Log.w(TAG, "Could not read the FCM token: ${e.message}")
            null
        }
    }
}
