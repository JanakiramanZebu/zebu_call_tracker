package `in`.mynt.zebu_call_tracker.platform

import `in`.mynt.zebu_call_tracker.whatsapp.WhatsAppCallListener
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.call.CallStateJournal
import `in`.mynt.zebu_call_tracker.call.ContactResolver
import `in`.mynt.zebu_call_tracker.call.Dialer
import `in`.mynt.zebu_call_tracker.call.SimInfoReader
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.CallTrackingService
import `in`.mynt.zebu_call_tracker.background.IngestStore
import `in`.mynt.zebu_call_tracker.background.NativeHeartbeat
import `in`.mynt.zebu_call_tracker.background.SyncCoordinator
import `in`.mynt.zebu_call_tracker.push.PushTokenWorker
import `in`.mynt.zebu_call_tracker.background.SyncPolicyStore
import `in`.mynt.zebu_call_tracker.background.TokenRefresher
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import `in`.mynt.zebu_call_tracker.permissions.AutostartSettings
import `in`.mynt.zebu_call_tracker.permissions.BatteryOptimization
import `in`.mynt.zebu_call_tracker.permissions.PermissionInspector
import `in`.mynt.zebu_call_tracker.recording.RecordingCapabilityProbe
import `in`.mynt.zebu_call_tracker.recording.RecordingScanner
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The single seam between Dart and Android.
 *
 * Everything platform-specific goes through here, so the Flutter side never
 * touches a MethodChannel directly (brief §31). Three channels only:
 *   - a MethodChannel for request/response calls
 *   - an EventChannel for post-call "View Details" taps
 *   - an EventChannel saying the local call list changed underneath Dart
 *
 * Errors are returned as typed error codes rather than exceptions so the Dart
 * repository layer can map them onto its Result/Failure types.
 *
 * Calls arrive on the Android main thread. Anything that touches a content
 * provider, a database or a file runs on [ioScope] and replies from the main
 * thread, as Flutter requires — a call-log page or a recording scan on the
 * main thread is a dropped frame at best and an ANR at worst.
 */
class NativeBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    private lateinit var methodChannel:  MethodChannel
    private lateinit var overlayChannel: EventChannel  // post-call "View Details" events
    private var overlaySink:     EventChannel.EventSink? = null
    private lateinit var callsChannel:   EventChannel  // "calls changed" pings

    /**
     * Cancelled on [detach], recreated on [attach], so a bridge whose engine
     * has gone does not keep a scope (and whatever it was waiting on) alive
     * for the life of the process.
     *
     * Cancelling cannot cut a token refresh short: [TokenRefresher.refresh]
     * and every [background] block are blocking calls, which coroutine
     * cancellation does not interrupt. A block already running finishes and
     * persists; only its reply — to an engine that is gone — is dropped.
     */
    private var ioScope = newIoScope()

    private fun newIoScope() = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun attach(messenger: BinaryMessenger) {
        if (!ioScope.isActive) ioScope = newIoScope()
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        overlayChannel = EventChannel(messenger, OVERLAY_CHANNEL)
        overlayChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                overlaySink = events
                // Deliver a pending event that arrived before Dart subscribed.
                pendingOverlayEvent?.let { events?.success(it) }
                pendingOverlayEvent = null
            }
            override fun onCancel(arguments: Any?) { overlaySink = null }
        })

        callsChannel = EventChannel(messenger, CALLS_CHANNEL)
        callsChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                callsSink = events
            }
            override fun onCancel(arguments: Any?) { callsSink = null }
        })
    }

    fun detach() {
        overlaySink = null
        callsSink = null
        methodChannel.setMethodCallHandler(null)
        overlayChannel.setStreamHandler(null)
        callsChannel.setStreamHandler(null)
        ioScope.cancel()
    }

    /**
     * Runs [block] off the main thread and replies with its value on it.
     * Failures map onto the same codes as the synchronous path.
     */
    private fun background(result: MethodChannel.Result, block: () -> Any?) {
        ioScope.launch {
            val outcome = runCatching(block)
            withContext(Dispatchers.Main) {
                outcome.fold(
                    onSuccess = { result.success(it) },
                    onFailure = { reportError(result, it) },
                )
            }
        }
    }

    private fun reportError(result: MethodChannel.Result, e: Throwable) {
        when (e) {
            // Both MissingPermission types are SecurityExceptions.
            is SecurityException -> result.error("PERMISSION_DENIED", e.message, null)
            else -> result.error("PLATFORM_ERROR", e.message, e::class.java.simpleName)
        }
    }

    /**
     * Called by [MainActivity] when it receives an intent with [EXTRA_OPEN_CALL].
     * Pushes an event to the Dart overlay event stream so [HomeShell] can
     * navigate to the matching [CallDetailScreen].
     */
    fun handleOverlayOpenCall(startedAtMillis: Long) {
        val payload = mapOf("startedAtMillis" to startedAtMillis)
        if (overlaySink != null) {
            overlaySink!!.success(payload)
        } else {
            pendingOverlayEvent = payload   // deliver once Dart subscribes
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getPermissionStatus" -> background(result) { PermissionInspector.snapshot(context) }

                "readCallLog" -> {
                    val since = (call.argument<Any>("sinceMillis") as? Number)?.toLong() ?: 0L
                    val before = (call.argument<Any>("beforeMillis") as? Number)?.toLong() ?: 0L
                    val limit = call.argument<Int>("limit") ?: 100
                    background(result) {
                        CallLogReader.read(context, since, limit.coerceIn(1, 1000), before)
                    }
                }

                "getCallLogCount" -> background(result) { CallLogReader.count(context) }

                "readCallLogForNumber" -> {
                    val number = call.argument<String>("number")
                    val limit = call.argument<Int>("limit") ?: 50
                    if (number.isNullOrBlank()) {
                        result.success(emptyList<Map<String, Any?>>())
                    } else {
                        background(result) {
                            CallLogReader.readForNumber(context, number, limit.coerceIn(1, 500))
                        }
                    }
                }

                "dialNumber" -> result.success(
                    Dialer.dial(context, call.argument<String>("number") ?: ""),
                )

                // Stays on the main thread: it only builds a URI string and
                // never touches the provider.
                "getRecordingUri" -> {
                    val id = (call.argument<Any>("mediaStoreId") as? Number)?.toLong()
                    if (id == null) {
                        result.error("INVALID_ARGUMENT", "mediaStoreId is required", null)
                    } else {
                        result.success(RecordingScanner.contentUri(id))
                    }
                }

                "getSimInfo" -> background(result) {
                    mapOf(
                        "simCount" to SimInfoReader.simCount(context),
                        "subscriptions" to SimInfoReader.activeSubscriptions(context),
                    )
                }

                "resolveContact" -> {
                    val number = call.argument<String>("number")
                    background(result) { ContactResolver.resolve(context, number) }
                }

                "resolveContacts" -> {
                    val numbers = call.argument<List<String>>("numbers") ?: emptyList()
                    background(result) { ContactResolver.resolveBatch(context, numbers) }
                }

                "probeRecordingCapability" ->
                    background(result) { RecordingCapabilityProbe.probe(context) }

                // --- recording INGESTION (discover files the device already
                // wrote; this app never records) ------------------------------
                "getRecordingAccess" -> result.success(
                    mapOf(
                        "permission" to RecordingScanner.requiredPermission(),
                        "granted" to RecordingScanner.hasPermission(context),
                    ),
                )

                "scanRecordings" -> {
                    val since = (call.argument<Any>("sinceEpochSeconds") as? Number)?.toLong() ?: 0L
                    val before = (call.argument<Any>("beforeEpochSeconds") as? Number)?.toLong() ?: 0L
                    val limit = call.argument<Int>("limit") ?: 200
                    background(result) {
                        RecordingScanner.scan(context, since, limit.coerceIn(1, 2000), before)
                    }
                }

                // Reads the whole file: never on the main thread.
                "hashRecording" -> {
                    val id = (call.argument<Any>("mediaStoreId") as? Number)?.toLong()
                    if (id == null) {
                        result.error("INVALID_ARGUMENT", "mediaStoreId is required", null)
                    } else {
                        background(result) { RecordingScanner.sha256(context, id) }
                    }
                }

                "readCallStateJournal" -> background(result) { CallStateJournal.read(context) }

                "getDeviceInfo" -> result.success(deviceInfo())

                // --- background execution ------------------------------------
                // `keepaliveService` (added): whether the always-on tracking
                // service is enabled (the default; the server can switch it
                // off), for the diagnostics screen.
                "getBackgroundStatus" -> background(result) {
                    IngestStore.runStatus(context) +
                        BatteryOptimization.status(context) +
                        mapOf(
                            "keepaliveService" to CallTrackingService.isEnabled(context),
                            "autostartRelevant" to AutostartSettings.isRelevant(),
                            "autostartOpened" to AutostartSettings.wasOpened(context),
                            "forceStoppedAtMillis" to ForceStopDetector.unacknowledgedStopAtMillis(context),
                        )
                }

                "openAutostartSettings" -> result.success(AutostartSettings.open(context))

                "acknowledgeForceStop" -> {
                    ForceStopDetector.acknowledge(context)
                    result.success(null)
                }

                // --- auth & background sync ----------------------------------
                // `authoritative` must be true ONLY for a fresh pairing. See
                // IngestStore.saveAuthSession: a restore that claims authority
                // overwrites a refresh token this store has already rotated,
                // and replaying that token makes the server revoke the whole
                // session chain. Defaults to false so a caller that forgets the
                // argument gets the harmless behaviour.
                "setAuthSession" -> {
                    val token = call.argument<String>("token") ?: ""
                    val refreshToken = call.argument<String>("refreshToken")
                    val apiBaseUrl = call.argument<String>("apiBaseUrl") ?: ""
                    val deviceUuid = call.argument<String>("deviceUuid") ?: ""
                    val authoritative = call.argument<Boolean>("authoritative") ?: false
                    IngestStore.saveAuthSession(
                        context,
                        token,
                        refreshToken,
                        apiBaseUrl,
                        deviceUuid,
                        authoritative,
                        call.argument<String>("accessTokenExpiresAt"),
                        call.argument<String>("refreshTokenExpiresAt"),
                    )
                    // §3.3: the FCM token goes up after registration (a pairing
                    // is one, so it is forced) and on app start when it differs
                    // from the last one the server accepted (a restore).
                    PushTokenWorker.enqueue(context, force = authoritative)
                    result.success(null)
                }

                // §3.3, after Dart's check-in registered a device the server
                // did not know: that device row has no token on it yet.
                "syncPushToken" -> {
                    PushTokenWorker.enqueue(context, force = call.argument<Boolean>("force") == true)
                    result.success(null)
                }

                // §3.3. The app has no sign-out; this runs only when a session
                // the server already refused is reset to pairing, and before
                // clearAuthSession, which discards any access token left.
                "unregisterPushToken" -> background(result) {
                    PushTokenWorker.unregister(context)
                    null
                }

                // §3.2: the foreground heartbeat, through the same
                // once-a-minute gate as the background and push senders.
                // True when one went out and the server took it.
                "sendHeartbeat" -> background(result) { NativeHeartbeat.send(context) != null }

                // The other half of the contract TokenRefresher's own doc
                // comment claimed and nothing implemented: "IngestStore is the
                // single store of record for the pair; Dart mirrors whatever
                // this returns." Without a read-back there was no way for Dart
                // to mirror anything, so the two stores diverged on the first
                // background refresh and stayed diverged.
                "getAuthSession" -> result.success(IngestStore.getAuthSession(context))

                "clearAuthSession" -> {
                    IngestStore.clearAuthSession(context)
                    IngestStore.clearSessionRevoked(context)
                    result.success(null)
                }

                // Dart does not exchange refresh tokens itself. It asks here,
                // so that every refresh in the app — foreground request,
                // background upload — passes the one single-flight gate in
                // TokenRefresher and writes to the one store of record.
                //
                // The alternative, which this replaces, was for Dart and the
                // coordinator to refresh independently against a server that
                // invalidates the token you present. The loser of that race
                // replayed a dead token, and the server revoked the entire
                // session chain in response.
                "refreshAuthTokens" -> {
                    val staleToken = call.argument<String>("staleToken")
                    val baseUrl = call.argument<String>("apiBaseUrl")
                        ?: IngestStore.getApiBaseUrl(context)
                        ?: ""
                    if (baseUrl.isBlank()) {
                        result.success(
                            mapOf(
                                "ok" to false,
                                "failure" to TokenRefresher.Failure.NO_SESSION.name,
                            ),
                        )
                    } else {
                        // Blocking network work: it cannot run on the platform
                        // thread, and the reply has to come back on it.
                        ioScope.launch {
                            val outcome = TokenRefresher.refresh(context, baseUrl, staleToken)
                            withContext(Dispatchers.Main) {
                                result.success(
                                    mapOf(
                                        "ok" to outcome.isSuccess,
                                        "accessToken" to outcome.accessToken,
                                        "refreshToken" to outcome.refreshToken,
                                        "accessTokenExpiresAt" to outcome.accessTokenExpiresAt,
                                        "refreshTokenExpiresAt" to outcome.refreshTokenExpiresAt,
                                        "failure" to outcome.failure?.name,
                                    ),
                                )
                            }
                        }
                    }
                }

                // The server's own limits, from GET /sync/status. The app used
                // to fetch these, parse them, and then hardcode every value the
                // coordinator actually used.
                "setSyncPolicy" -> {
                    val json = call.argument<String>("policyJson")
                    if (json.isNullOrBlank()) {
                        result.success(false)
                    } else {
                        val keepaliveBefore = CallTrackingService.isEnabled(context)
                        SyncPolicyStore.save(context, json)
                        // `keepalive_service` is the server's switch for the
                        // always-on service (absent means on); act on a change
                        // straight away rather than at the next launch. Dart
                        // calls this with the app in the foreground, where
                        // starting it is allowed.
                        if (CallTrackingService.isEnabled(context) != keepaliveBefore) {
                            CallTrackingService.reconcile(context)
                        }
                        result.success(true)
                    }
                }

                "getNativeSyncStatus" -> background(result) { IngestStore.getLastSyncInfo(context) }

                // Enqueue only. This used to start an in-process sync as well,
                // which raced the job it had just enqueued; the coordinator's
                // lock turned one of them away, but only after both had spun
                // up. The job waits for a network and survives the app closing.
                //
                // `reviveFailed` (optional, default false): a deliberate "Sync
                // now" may ask for FAILED rows to be given another chance, and
                // always enqueues.
                //
                // Without it, enqueues only when the outbox owes the server
                // something. Dart also calls this on app pause (its counters
                // include FAILED rows, which a sync will not touch until their
                // revival is due) and after a hand-picked recording, and an
                // empty sync still spins up a worker and a wake lock to claim
                // nothing. Off the main thread: it reads the outbox. Still
                // replies null.
                "triggerNativeSync" -> {
                    val reviveFailed = call.argument<Boolean>("reviveFailed") == true
                    background(result) {
                        if (reviveFailed) {
                            IngestStore.requestFailureRevival(context)
                            BackgroundScheduler.enqueueSync(context)
                        } else if (SyncCoordinator.hasWorkToSend(context)) {
                            BackgroundScheduler.enqueueSync(context)
                        }
                        null
                    }
                }

                "startBackgroundTracking" -> {
                    val reason = call.argument<String>("reason") ?: "app_start"
                    // Runs one capture through the always-on tracking service,
                    // starting it (which matters here: this is sign-in, and
                    // POST_NOTIFICATIONS may just have been granted). Only if
                    // the server's policy has switched the service off does
                    // it go through WorkManager, with any running instance
                    // stopped.
                    CallTrackingService.triggerImmediate(context, reason)
                    // Sign-in is the moment the safety net and the content
                    // trigger can first be armed: both are refused for a
                    // signed-out handset, so launching the app before signing
                    // in no longer arms them.
                    BackgroundScheduler.ensurePeriodic(context)
                    // App start and sign-in are when a failure's cause is most
                    // likely to have been fixed; see SyncCoordinator.
                    IngestStore.requestFailureRevival(context)
                    result.success(null)
                }

                "requestBatteryExemption" ->
                    result.success(BatteryOptimization.requestExemption(context))

                // The clock alert's action. It used to open this app's own
                // settings page, which has nothing to do with the clock.
                "openDateSettings" -> {
                    val opened = listOf(
                        Intent(Settings.ACTION_DATE_SETTINGS),
                        Intent(Settings.ACTION_SETTINGS),
                    ).any { intent ->
                        try {
                            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            true
                        } catch (_: Exception) {
                            false
                        }
                    }
                    result.success(opened)
                }

                // --- post-call overlay permission ----------------------------
                "checkOverlayPermission" ->
                    result.success(Settings.canDrawOverlays(context))

                "requestOverlayPermission" -> {
                    // Opens the system "Display over other apps" settings page
                    // for this specific package. Returns true if the intent
                    // resolved (i.e. the settings page opened). The actual grant
                    // state is polled by Dart via checkOverlayPermission on resume.
                    val intent = Intent(
                        Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
                        Uri.parse("package:${context.packageName}"),
                    ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
                    return try {
                        context.startActivity(intent)
                        result.success(true)
                    } catch (_: Exception) {
                        result.success(false)
                    }
                }

                // --- WhatsApp call capture: notification access ---------------
                "requestNotificationListenerAccess" -> {
                    // Straight to this app's own switch where Android has that
                    // screen (API 30+), else the full listener list. The grant
                    // is re-read by Dart on resume via getPermissionStatus.
                    val component = ComponentName(context, WhatsAppCallListener::class.java)
                    val detail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                            .putExtra(
                                Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME,
                                component.flattenToString(),
                            )
                    } else {
                        null
                    }
                    val list = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
                    val opened = listOfNotNull(detail, list).any { intent ->
                        try {
                            context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                            true
                        } catch (_: Exception) {
                            false
                        }
                    }
                    result.success(opened)
                }

                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            reportError(result, e)
        }
    }

    /**
     * Only what device registration (brief §14) actually needs. No IMEI, no
     * advertising id, no serial — none of it is required to attribute a call to
     * an employee device, and collecting it would be a liability.
     *
     * `androidId` is the one exception, because the server asks for it as
     * `mobile_unique_id` (Mobile login flow §3). Since Android 8 it is scoped to
     * this app's signing key and survives a reinstall, so an employee who
     * reinstalls comes back as the same device instead of a new one.
     */
    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "osVersion" to Build.VERSION.RELEASE,
        "sdkInt" to Build.VERSION.SDK_INT,
        "fingerprintHash" to Build.FINGERPRINT.hashCode().toString(),
        "androidId" to try {
            Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        } catch (_: Exception) {
            null
        },
    )

    companion object {
        private const val METHOD_CHANNEL  = "in.mynt.zebu_call_tracker/native"
        const val         OVERLAY_CHANNEL = "in.mynt.zebu_call_tracker/overlay_events"
        const val         CALLS_CHANNEL   = "in.mynt.zebu_call_tracker/call_events"

        /** Holds an overlay event until the Dart listener subscribes. */
        private var pendingOverlayEvent: Map<String, Any>? = null

        /** Main thread only. Null while no Flutter screen is listening. */
        private var callsSink: EventChannel.EventSink? = null
        private val main = android.os.Handler(android.os.Looper.getMainLooper())

        /**
         * Tells an open app that a call row appeared that it has no other way
         * to notice. WhatsApp calls never touch Android's call log, so neither
         * the call-log observer nor a resume that lands inside the tracker's
         * end-of-call grace window would show them. Safe from any thread; a
         * no-op when no app screen is open — the next launch or resume loads
         * the row anyway.
         */
        fun notifyCallsChanged() {
            main.post { callsSink?.success(null) }
        }
    }
}
