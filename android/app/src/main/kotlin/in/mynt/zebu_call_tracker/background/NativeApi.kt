package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.util.UUID

/**
 * A small authenticated JSON request for the native paths that are not the
 * upload itself: the status check-in and the FCM token calls.
 *
 * The 401 handling is the coordinator's: one refresh through the single-flight
 * [TokenRefresher], then one replay, so none of these callers can race an
 * upload into replaying a rotated refresh token.
 */
object NativeApi {

    private const val TAG = "NativeApi"

    class Response(
        /** Null when the request never got an answer. */
        val status: Int?,
        val body: String?,
        /** Set when a 401 led to a refresh that produced no token. */
        val refreshFailure: TokenRefresher.Failure? = null,
    ) {
        val isSuccess: Boolean get() = status != null && status in 200..299

        /** `error.code` from the envelope (§1), when there is one. */
        val errorCode: String?
            get() = try {
                body?.let { JSONObject(it).optJSONObject("error")?.optString("code") }
                    ?.takeIf { it.isNotBlank() }
            } catch (_: Exception) {
                null
            }

        /** `data` from the envelope, when it is an object. */
        val data: JSONObject?
            get() = try {
                body?.let { JSONObject(it).optJSONObject("data") }
            } catch (_: Exception) {
                null
            }
    }

    /**
     * The stored API base URL in `/api/v1` form, or null without a session.
     */
    fun baseUrl(context: Context): String? =
        IngestStore.getApiBaseUrl(context)
            ?.takeIf { it.isNotBlank() }
            ?.let { TokenRefresher.normalizeBaseUrl(it) }

    /**
     * Blocking: call off the main thread. Never throws.
     *
     * @param path relative to the `/api/v1` base, query string included.
     */
    fun request(context: Context, method: String, path: String, body: JSONObject? = null): Response {
        val appContext = context.applicationContext
        val baseUrl = baseUrl(appContext) ?: return Response(null, null, TokenRefresher.Failure.NO_SESSION)
        val stored = IngestStore.getAuthToken(appContext)
        if (stored.isNullOrBlank()) return Response(null, null, TokenRefresher.Failure.NO_SESSION)
        val token = TokenRefresher.ensureFresh(appContext, baseUrl, stored)

        val url = "$baseUrl$path"
        val first = send(method, url, body, token)
        if (first.status != 401) return first

        val refreshed = TokenRefresher.refresh(appContext, baseUrl, token)
        val fresh = refreshed.accessToken
            ?: return Response(first.status, first.body, refreshed.failure)
        return send(method, url, body, fresh)
    }

    private fun send(method: String, url: String, body: JSONObject?, token: String): Response {
        var conn: HttpURLConnection? = null
        // Our own correlation id (§1), so a failure logged here can be found
        // in the server's trace.
        val requestId = UUID.randomUUID().toString().replace("-", "")
        return try {
            conn = (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = method
                connectTimeout = 15000
                readTimeout = 20000
                setRequestProperty("Accept", "application/json")
                setRequestProperty("Authorization", "Bearer $token")
                setRequestProperty("X-Request-ID", requestId)
                if (body != null) {
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                }
            }
            if (body != null) {
                OutputStreamWriter(conn.outputStream, "UTF-8").use { it.write(body.toString()) }
            }
            val status = conn.responseCode
            val text = try {
                (if (status in 200..299) conn.inputStream else conn.errorStream)
                    ?.bufferedReader()?.use { it.readText() }
            } catch (_: Exception) {
                null
            }
            if (status !in 200..299) {
                Log.w(TAG, "$method ${url.substringBefore('?')} -> $status (request_id=$requestId)")
            }
            Response(status, text)
        } catch (e: Exception) {
            Log.w(TAG, "$method ${url.substringBefore('?')} did not complete (request_id=$requestId): ${e.message}")
            Response(null, null)
        } finally {
            conn?.disconnect()
        }
    }
}
