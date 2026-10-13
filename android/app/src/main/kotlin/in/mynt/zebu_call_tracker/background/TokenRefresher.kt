package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.util.Base64
import android.util.Log
import org.json.JSONObject
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL

/**
 * The only place in the app that may exchange a refresh token.
 *
 * ## Why this exists
 *
 * `POST /auth/refresh` **rotates**: the token you send is invalidated the
 * moment the server answers, and presenting an already-rotated one is treated
 * as theft — the server revokes the entire session chain and every request
 * afterwards returns `INVALID_TOKEN` (Mobile API Guide §2.3, rule 2).
 *
 * Before this class there were four token holders and three separate
 * "single-flight" mutexes: three `ApiClient` instances on the Dart side, each
 * with its own `_refreshCompleter`, and the native coordinator, which
 * refreshed straight into [IngestStore] and told nobody. Whichever refreshed
 * second replayed a dead token and signed the user out. Each mutex was
 * per-instance, so none of them ever did the job its name claimed.
 *
 * Every refresh — Dart-initiated over the method channel, or native-initiated
 * from [SyncCoordinator] — now funnels through [refresh]. [IngestStore] is the
 * single store of record for the pair; Dart mirrors whatever this returns.
 *
 * ## Single-flight
 *
 * Blocking, not suspending, deliberately: the callers are `HttpURLConnection`
 * code already sitting on `Dispatchers.IO` and the `MethodChannel` handler, and
 * a plain monitor serves both without colouring either as `suspend`.
 *
 * The [staleToken] check is what makes a queued stampede cheap. Five requests
 * that all 401 at once arrive here one at a time; the first refreshes, and the
 * other four find the stored token no longer equal to the one they came in
 * with, so they take it and return without touching the network. That is the
 * behaviour "the first caller refreshes, the others await its result" is meant
 * to produce.
 */
object TokenRefresher {

    private const val TAG = "TokenRefresher"
    private val lock = Any()

    /**
     * Why a refresh produced no token.
     *
     * The distinction is the difference between "wait and try again" and "make
     * the user sign in again". Collapsing the two is how a dropped connection
     * used to destroy a perfectly good session.
     */
    enum class Failure {
        /** The server refused the token itself. Terminal — sign in again. */
        INVALID,

        /** Timeout, 5xx, no connectivity. Keep the session and retry later. */
        TRANSIENT,

        /** Nothing to refresh with: signed out, or never signed in. */
        NO_SESSION,
    }

    data class Result(
        val accessToken: String? = null,
        val refreshToken: String? = null,
        /** RFC 3339, straight from the server. Null when it did not say. */
        val accessTokenExpiresAt: String? = null,
        val refreshTokenExpiresAt: String? = null,
        val failure: Failure? = null,
    ) {
        val isSuccess: Boolean get() = accessToken != null
    }

    /**
     * Returns a usable access token, refreshing only if nobody else already has.
     *
     * @param staleToken the access token the caller held when it received a
     *   401. When the stored token has moved on from it another caller has
     *   already refreshed, and the current one is handed back untouched. Pass
     *   null to force a refresh.
     */
    fun refresh(context: Context, baseUrl: String, staleToken: String?): Result =
        synchronized(lock) {
            val appContext = context.applicationContext

            val current = IngestStore.getAuthToken(appContext)
            if (!current.isNullOrBlank() && staleToken != null && current != staleToken) {
                Log.i(TAG, "Token already rotated by another caller; reusing it.")
                return Result(
                    accessToken = current,
                    refreshToken = IngestStore.getRefreshToken(appContext),
                )
            }

            val refreshToken = IngestStore.getRefreshToken(appContext)
            if (refreshToken.isNullOrBlank()) {
                Log.w(TAG, "No refresh token stored; cannot refresh.")
                return Result(failure = Failure.NO_SESSION)
            }

            return performRefresh(appContext, normalizeBaseUrl(baseUrl), refreshToken)
        }

    /**
     * [token], or a newer one when [token] is past 75 % of its life (§2.3
     * rule 4).
     *
     * Waiting for the 401 works, but costs a failed request and a replay at
     * every expiry — on a weak network, in the middle of a long upload. Age is
     * measured on the handset's own clock from when the token arrived, against
     * the lifetime the token states (`exp − iat`), so clock skew between phone
     * and server cannot make a fresh token look old. With no recorded arrival
     * time or an unreadable token nothing is refreshed early and the 401 path
     * still covers it.
     *
     * Never makes things worse than not calling it: any failure hands back
     * [token] unchanged, and a refused refresh has already cleared the session
     * exactly as a 401-driven one would.
     */
    fun ensureFresh(context: Context, baseUrl: String, token: String): String {
        val appContext = context.applicationContext
        if (IngestStore.getAuthToken(appContext) != token) return token
        val receivedAt = IngestStore.getAccessTokenReceivedAt(appContext) ?: return token
        val lifetime = lifetimeMillis(token) ?: return token
        val age = System.currentTimeMillis() - receivedAt
        // A negative age means the clock moved backwards; the token's real age
        // is unknowable, so treat it as due rather than trust it.
        if (age in 0 until (lifetime * REFRESH_AT_FRACTION).toLong()) return token

        Log.i(TAG, "Access token past ${(REFRESH_AT_FRACTION * 100).toInt()}% of its life; refreshing early.")
        return refresh(appContext, baseUrl, token).accessToken ?: token
    }

    /** `exp − iat` of a JWT, in millis. Null when the token is not one we can read. */
    private fun lifetimeMillis(token: String): Long? = try {
        val payload = token.split('.').getOrNull(1) ?: return null
        val json = JSONObject(
            String(
                Base64.decode(payload, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP),
                Charsets.UTF_8,
            ),
        )
        val iat = json.optLong("iat", 0L)
        val exp = json.optLong("exp", 0L)
        if (iat > 0L && exp > iat) (exp - iat) * 1000L else null
    } catch (e: Exception) {
        null
    }

    private const val REFRESH_AT_FRACTION = 0.75

    private fun performRefresh(
        context: Context,
        baseUrl: String,
        refreshToken: String,
    ): Result {
        var conn: HttpURLConnection? = null
        try {
            conn = (URL("$baseUrl/auth/refresh").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10000
                readTimeout = 15000
                doOutput = true
                doInput = true
                setRequestProperty("Content-Type", "application/json; charset=UTF-8")
                setRequestProperty("Accept", "application/json")
            }

            OutputStreamWriter(conn.outputStream, "UTF-8").use { writer ->
                writer.write(JSONObject().put("refresh_token", refreshToken).toString())
                writer.flush()
            }

            val statusCode = conn.responseCode
            val body = if (statusCode in 200..299) {
                conn.inputStream.bufferedReader().use { it.readText() }
            } else {
                conn.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
            }

            if (statusCode in 200..299) {
                // `/auth/refresh` returns the pair directly under `data`;
                // `/mobile/register` nests it under `data.tokens`. Reading only
                // the nested shape found nothing on a successful refresh, kept
                // the refresh token the server had just retired, and the next
                // refresh replayed it — which revokes the whole session. That
                // was fixed once (5cd0be1) and lost when refresh moved here.
                val data = JSONObject(body).optJSONObject("data")
                val tokens = data?.optJSONObject("tokens") ?: data
                val access = tokens?.optString("access_token")?.takeIf { it.isNotBlank() }
                val newRefresh = tokens?.optString("refresh_token")?.takeIf { it.isNotBlank() }
                val accessExpiry =
                    tokens?.optString("access_token_expires_at")?.takeIf { it.isNotBlank() }
                val refreshExpiry =
                    tokens?.optString("refresh_token_expires_at")?.takeIf { it.isNotBlank() }

                if (access == null) {
                    // A 2xx carrying no token is not something a retry fixes,
                    // but neither is it proof the session is dead.
                    Log.w(TAG, "Refresh returned $statusCode with no access token.")
                    return Result(failure = Failure.TRANSIENT)
                }

                // Rule 1 of §2.3: the new pair is persisted BEFORE the new
                // access token is handed to anyone. If the process dies between
                // the response and this write, the session is lost for good.
                IngestStore.updateAuthTokens(
                    context,
                    access,
                    newRefresh,
                    accessExpiry,
                    refreshExpiry,
                )
                Log.i(TAG, "Refreshed access token.")
                return Result(
                    accessToken = access,
                    refreshToken = newRefresh,
                    accessTokenExpiresAt = accessExpiry,
                    refreshTokenExpiresAt = refreshExpiry,
                )
            }

            // 401/403/422 here means the refresh token itself is dead —
            // expired, revoked, or already rotated. Retrying replays it and,
            // per §2.3, makes the situation strictly worse.
            if (statusCode == 401 || statusCode == 403 || statusCode == 422) {
                Log.w(TAG, "Refresh rejected with HTTP $statusCode; clearing session.")
                IngestStore.clearAuthSession(context)
                // After the clear, not before: clearAuthSession removes the
                // credential, and this tombstone is what tells Dart on next
                // start that it was taken away rather than never present. A
                // background refusal reaches nobody otherwise, so the app kept
                // rendering a signed-in shell over a session the server had
                // already destroyed.
                IngestStore.recordSessionRevoked(context)
                return Result(failure = Failure.INVALID)
            }

            Log.w(TAG, "Refresh failed with HTTP $statusCode; treating as transient.")
            return Result(failure = Failure.TRANSIENT)
        } catch (e: Exception) {
            // No response at all. The session is very probably fine; the
            // network is not. Clearing it here is what used to sign users out
            // mid-commute.
            Log.w(TAG, "Refresh network error: ${e.message}")
            return Result(failure = Failure.TRANSIENT)
        } finally {
            conn?.disconnect()
        }
    }

    /** Accepts a base URL with or without the `/api/v1` suffix or a trailing slash. */
    fun normalizeBaseUrl(raw: String): String {
        var url = raw.trim()
        if (url.endsWith("/")) url = url.substring(0, url.length - 1)
        if (!url.endsWith("/api/v1")) {
            url = if (url.endsWith("/api")) "$url/v1" else "$url/api/v1"
        }
        return url
    }
}
