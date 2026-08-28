package `in`.mynt.zebu_call_tracker.platform

import android.content.Context
import android.os.Build
import `in`.mynt.zebu_call_tracker.call.CallLogReader
import `in`.mynt.zebu_call_tracker.call.CallStateJournal
import `in`.mynt.zebu_call_tracker.call.CallStateMonitor
import `in`.mynt.zebu_call_tracker.call.ContactResolver
import `in`.mynt.zebu_call_tracker.call.Dialer
import `in`.mynt.zebu_call_tracker.call.SimInfoReader
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.IngestStore
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
 * touches a MethodChannel directly (brief §31). Two channels only:
 *   - a MethodChannel for request/response reads
 *   - an EventChannel for the live call-state stream
 *
 * Errors are returned as typed error codes rather than exceptions so the Dart
 * repository layer can map them onto its Result/Failure types.
 */
class NativeBridge(private val context: Context) : MethodChannel.MethodCallHandler {

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private var monitor: CallStateMonitor? = null

    fun attach(messenger: BinaryMessenger) {
        methodChannel = MethodChannel(messenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(messenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                val m = CallStateMonitor(context)
                val started = m.start { state, atMillis ->
                    events?.success(mapOf("state" to state, "atMillis" to atMillis))
                }
                if (!started) {
                    events?.error(
                        "PERMISSION_DENIED",
                        "READ_PHONE_STATE is required for the live call-state stream.",
                        null,
                    )
                    return
                }
                monitor = m
            }

            override fun onCancel(arguments: Any?) {
                monitor?.stop()
                monitor = null
            }
        })
    }

    fun detach() {
        monitor?.stop()
        monitor = null
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "getPermissionStatus" -> result.success(PermissionInspector.snapshot(context))

                "readCallLog" -> {
                    val since = (call.argument<Any>("sinceMillis") as? Number)?.toLong() ?: 0L
                    val before = (call.argument<Any>("beforeMillis") as? Number)?.toLong() ?: 0L
                    val limit = call.argument<Int>("limit") ?: 100
                    result.success(
                        CallLogReader.read(context, since, limit.coerceIn(1, 1000), before),
                    )
                }

                "getCallLogCount" -> result.success(CallLogReader.count(context))

                "readCallLogForNumber" -> {
                    val number = call.argument<String>("number")
                    val limit = call.argument<Int>("limit") ?: 50
                    if (number.isNullOrBlank()) {
                        result.success(emptyList<Map<String, Any?>>())
                    } else {
                        result.success(
                            CallLogReader.readForNumber(
                                context,
                                number,
                                limit.coerceIn(1, 500),
                            ),
                        )
                    }
                }

                "dialNumber" -> result.success(
                    Dialer.dial(context, call.argument<String>("number") ?: ""),
                )

                "getRecordingUri" -> {
                    val id = (call.argument<Any>("mediaStoreId") as? Number)?.toLong()
                    if (id == null) {
                        result.error("INVALID_ARGUMENT", "mediaStoreId is required", null)
                    } else {
                        result.success(RecordingScanner.contentUri(id))
                    }
                }

                "getSimInfo" -> result.success(
                    mapOf(
                        "simCount" to SimInfoReader.simCount(context),
                        "subscriptions" to SimInfoReader.activeSubscriptions(context),
                    ),
                )

                "resolveContact" -> result.success(
                    ContactResolver.resolve(context, call.argument<String>("number")),
                )

                "resolveContacts" -> result.success(
                    ContactResolver.resolveBatch(
                        context,
                        call.argument<List<String>>("numbers") ?: emptyList(),
                    ),
                )

                "probeRecordingCapability" ->
                    result.success(RecordingCapabilityProbe.probe(context))

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
                    val limit = call.argument<Int>("limit") ?: 200
                    result.success(
                        RecordingScanner.scan(context, since, limit.coerceIn(1, 2000)),
                    )
                }

                "hashRecording" -> {
                    val id = (call.argument<Any>("mediaStoreId") as? Number)?.toLong()
                    if (id == null) {
                        result.error("INVALID_ARGUMENT", "mediaStoreId is required", null)
                    } else {
                        result.success(RecordingScanner.sha256(context, id))
                    }
                }

                "readCallStateJournal" -> result.success(CallStateJournal.read(context))

                "clearCallStateJournal" -> {
                    CallStateJournal.clear(context)
                    result.success(null)
                }

                "getDeviceInfo" -> result.success(deviceInfo())

                // --- background execution ------------------------------------
                "getBackgroundStatus" -> result.success(
                    IngestStore.read(context).filterKeys { it != "batches" } +
                        BatteryOptimization.status(context),
                )

                "readIngestBatches" -> result.success(IngestStore.read(context))

                "clearIngestBatches" -> {
                    IngestStore.clearBatches(context)
                    result.success(null)
                }

                "startBackgroundTracking" -> {
                    BackgroundScheduler.ensurePeriodic(context)
                    BackgroundScheduler.enqueueNow(
                        context,
                        call.argument<String>("reason") ?: BackgroundScheduler.REASON_APP_START,
                    )
                    result.success(null)
                }

                "stopBackgroundTracking" -> {
                    BackgroundScheduler.cancelAll(context)
                    // Names resolved for the previous user must not survive into
                    // the next one's session on a shared handset.
                    ContactResolver.clearCache()
                    result.success(null)
                }

                "requestBatteryExemption" ->
                    result.success(BatteryOptimization.requestExemption(context))

                "openVendorBackgroundSettings" ->
                    result.success(BatteryOptimization.openVendorSettings(context))

                else -> result.notImplemented()
            }
        } catch (e: RecordingScanner.MissingPermission) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: CallLogReader.MissingPermission) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: SecurityException) {
            result.error("PERMISSION_DENIED", e.message, null)
        } catch (e: Exception) {
            result.error("PLATFORM_ERROR", e.message, e::class.java.simpleName)
        }
    }

    /**
     * Only what device registration (brief §14) actually needs. No IMEI, no
     * advertising id, no serial — none of it is required to attribute a call to
     * an employee device, and collecting it would be a liability.
     */
    private fun deviceInfo(): Map<String, Any?> = mapOf(
        "manufacturer" to Build.MANUFACTURER,
        "model" to Build.MODEL,
        "device" to Build.DEVICE,
        "osVersion" to Build.VERSION.RELEASE,
        "sdkInt" to Build.VERSION.SDK_INT,
        "fingerprintHash" to Build.FINGERPRINT.hashCode().toString(),
    )

    companion object {
        private const val METHOD_CHANNEL = "in.mynt.zebu_call_tracker/native"
        private const val EVENT_CHANNEL = "in.mynt.zebu_call_tracker/call_state"
    }
}
