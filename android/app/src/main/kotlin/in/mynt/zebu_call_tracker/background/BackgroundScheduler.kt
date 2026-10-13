package `in`.mynt.zebu_call_tracker.background

import android.content.Context
import android.provider.CallLog
import android.provider.MediaStore
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.Data
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import java.util.concurrent.TimeUnit

/**
 * The one place that decides when background ingest and sync run.
 *
 * WorkManager rather than an AlarmManager or a bare service, for three reasons
 * this app cannot work around:
 *  - Android 12+ throws when a background broadcast starts a foreground
 *    service, which rules out doing the work inline in the call-state receiver.
 *  - Work survives process death, app update and reboot, which a registered
 *    receiver or a live service does not.
 *  - The OEM battery managers on this fleet (Samsung in particular) kill
 *    ad-hoc services aggressively but honour scheduled jobs.
 *
 * The wake-up model is event-driven. Capture runs when something happened —
 * a call ended ([enqueueNow] from the call-state receiver), the call log or
 * MediaStore changed ([armContentTrigger]) — plus one hourly safety net
 * ([ensurePeriodic]). Sync runs when a capture pass changed the outbox and
 * when the network (any network) comes back with work owed. The always-on
 * [CallTrackingService] keeps the process warm beside all of this, for OEM
 * builds that starve a closed app's broadcasts and jobs; it captures on a
 * 15-minute fallback loop but is not what the triggers above depend on.
 */
object BackgroundScheduler {

    private const val WORK_IMMEDIATE = "zebu.call-ingest.now"
    private const val WORK_CONTENT_TRIGGER = "zebu.call-ingest.on-change"
    private const val WORK_SAFETY_NET = "zebu.safety-net.hourly"
    private const val WORK_SYNC_NOW = "zebu.call-sync.now"
    private const val WORK_SYNC_AFTER_RECORDING = "zebu.call-sync.after-recording"
    private const val WORK_SYNC_AFTER_RATE_LIMIT = "zebu.call-sync.after-rate-limit"

    /**
     * Unique work older builds left armed, cancelled by [ensurePeriodic]:
     *  - the two 15-minute periodic jobs the hourly safety net replaced, one
     *    for ingest and one for sync, so a handset does not run the old pair
     *    beside it;
     *  - the sync that waited for Wi-Fi to send recordings held off mobile
     *    data. Recordings go over any network now, and a job still parked on
     *    an UNMETERED constraint would only fire a redundant run later.
     */
    private val LEGACY_WORK = listOf(
        "zebu.call-ingest.periodic",
        "zebu.call-sync.periodic",
        "zebu.call-sync.unmetered",
    )

    const val REASON_CALL_ENDED = "call-ended"
    const val REASON_BOOT = "boot"
    const val REASON_PERIODIC = "periodic"
    const val REASON_CONTENT_CHANGE = "content-change"

    /**
     * Prefix of the delayed post-call pass. Its only job is linking a
     * recording the dialer wrote after the call-log row, so [CallIngestWorker]
     * skips it outright when no captured call is waiting for one.
     */
    const val REASON_RECORDING_PASS_PREFIX = "call_ended_delay_"

    /**
     * The safety net's interval. Everything time-critical is event-driven now,
     * so this only has to catch what the events missed: a trigger dropped by
     * an OEM battery manager, a row whose backoff expired with no new call to
     * carry it, a recording the dialer indexed hours late. An hour bounds that
     * at four times fewer wake-ups than the two 15-minute jobs it replaces.
     */
    private const val SAFETY_NET_INTERVAL_MINUTES = 60L

    /**
     * Content-trigger batching. The update delay lets a burst of changes (a
     * recording being written and re-indexed, the call log's row and its
     * "new" flag) settle into one run; the max delay bounds how long a steady
     * stream of unrelated media changes can hold that run back.
     */
    private const val TRIGGER_UPDATE_DELAY_SECONDS = 5L
    private const val TRIGGER_MAX_DELAY_SECONDS = 60L

    /**
     * How long an answered call's metadata waits for its recording.
     *
     * Long enough for the content trigger (at most [TRIGGER_MAX_DELAY_SECONDS]
     * after the dialer's first write, usually ~5 s after its last) or the 30 s
     * fallback pass to link the file, so metadata and audio leave in one radio
     * burst instead of two a minute apart. Approved by the product owner.
     */
    const val SYNC_AFTER_RECORDING_DELAY_SECONDS = 45L

    /**
     * KEEP, not REPLACE, for every one-shot job below. REPLACE cancels a run
     * that is already in progress, and these are enqueued far more often than
     * they take to run — every call end, every Flutter pause, every network
     * handover. An upload cancelled mid-file starts again from byte zero.
     *
     * Ingest needs nothing more: [NativeCallIngestor] is single-flight with a
     * follow-up pass of its own, and the call log is durable, so a dropped
     * duplicate trigger loses nothing. Sync gets its follow-up from
     * [SyncCoordinator.requestFollowUp] — see [CallSyncWorker].
     *
     * Ingest is refused outright without a session: a signed-out handset has
     * no employee to attribute a call to.
     */
    fun enqueueNow(context: Context, reason: String) {
        if (!IngestStore.hasSession(context)) return
        val request = OneTimeWorkRequestBuilder<CallIngestWorker>()
            .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, reason).build())
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .addTag(TAG_INGEST)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_IMMEDIATE, ExistingWorkPolicy.KEEP, request)
    }

    /**
     * A delayed ingest pass, for an OEM dialer that indexes its recording in
     * MediaStore some seconds after the call-log row.
     *
     * Only a fallback now: the MediaStore content trigger usually links the
     * file first. Callers send a [REASON_RECORDING_PASS_PREFIX] reason so the
     * worker can skip the pass when nothing is waiting for a recording.
     */
    fun enqueueDelayedIngest(context: Context, delaySeconds: Long, reason: String) {
        if (!IngestStore.hasSession(context)) return
        val workName = "zebu.call-ingest.delayed.${delaySeconds}s"
        val request = OneTimeWorkRequestBuilder<CallIngestWorker>()
            .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, reason).build())
            .setInitialDelay(delaySeconds, TimeUnit.SECONDS)
            .addTag(TAG_INGEST)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(workName, ExistingWorkPolicy.KEEP, request)
    }

    /**
     * Wakes ingest when the call log or the audio MediaStore changes.
     *
     * One-time work with content-URI triggers (API 24+, which is minSdk) —
     * JobScheduler cannot repeat a content-triggered job, so it is re-armed at
     * the end of every [CallIngestWorker] run, whatever started that run, and
     * by [ensurePeriodic], `startBackgroundTracking` and boot.
     *
     * The call-log URI is registered with descendants too. The provider
     * notifies on the table URI on the builds this was checked against, and
     * an observer there would be enough, but a vendor provider that notifies
     * per row would otherwise never fire it; the call log has nothing else
     * underneath that could add noise.
     *
     * No tight loop is possible: ingest only READS both providers, so its own
     * run cannot fire the trigger it re-arms. A run started only by an
     * unrelated media change (a voice note, a download) costs one EXISTS query
     * on the outbox and returns; see [CallIngestWorker].
     *
     * [fromTriggerRun] is true only when called from inside the trigger's own
     * run. That run is still RUNNING under [WORK_CONTENT_TRIGGER], so KEEP
     * would drop the new request and REPLACE would cancel the caller.
     * APPEND_OR_REPLACE queues the new request behind the running one, and
     * every other caller uses KEEP so an armed trigger (or one queued behind a
     * run) is never duplicated or reset.
     */
    fun armContentTrigger(context: Context, fromTriggerRun: Boolean = false) {
        if (!IngestStore.hasSession(context)) return
        val constraints = Constraints.Builder()
            .addContentUriTrigger(CallLog.Calls.CONTENT_URI, true)
            .addContentUriTrigger(MediaStore.Audio.Media.EXTERNAL_CONTENT_URI, true)
            .setTriggerContentUpdateDelay(TRIGGER_UPDATE_DELAY_SECONDS, TimeUnit.SECONDS)
            .setTriggerContentMaxDelay(TRIGGER_MAX_DELAY_SECONDS, TimeUnit.SECONDS)
            .build()

        // Not expedited: expedited work may not carry content triggers, and
        // nothing here is more urgent than the trigger delay already allows.
        val request = OneTimeWorkRequestBuilder<CallIngestWorker>()
            .setConstraints(constraints)
            .setInputData(
                Data.Builder().putString(CallIngestWorker.KEY_REASON, REASON_CONTENT_CHANGE).build(),
            )
            .addTag(TAG_INGEST)
            .build()

        val policy = if (fromTriggerRun) ExistingWorkPolicy.APPEND_OR_REPLACE else ExistingWorkPolicy.KEEP
        WorkManager.getInstance(context).enqueueUniqueWork(WORK_CONTENT_TRIGGER, policy, request)
    }

    /**
     * Enqueues immediate native call sync with connected network constraint.
     *
     * The single entry point for uploads that should go now. Cheap to call
     * repeatedly: WorkManager keeps one pending job, and a call made while that
     * job is running is remembered as a follow-up instead of cancelling it.
     *
     * Independent of [enqueueSyncAfterRecording]: a different unique name, so
     * a delayed sync waiting out its 45 seconds never holds this one back.
     */
    fun enqueueSync(context: Context) {
        SyncCoordinator.requestFollowUp()

        val constraints = Constraints.Builder()
            .setRequiredNetworkType(NetworkType.CONNECTED)
            .build()

        val request = OneTimeWorkRequestBuilder<CallSyncWorker>()
            .setConstraints(constraints)
            .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_SYNC)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_SYNC_NOW, ExistingWorkPolicy.KEEP, request)
    }

    /**
     * A sync held back [SYNC_AFTER_RECORDING_DELAY_SECONDS] so an answered
     * call's recording is linked before its metadata leaves.
     *
     * Its own unique name, KEEP: a second answered call inside the window
     * rides on the sync already waiting rather than pushing it out again, so a
     * run of back-to-back calls cannot postpone delivery indefinitely. The
     * worst case for that second call is the old behaviour — metadata now,
     * audio on the next sync once its file links.
     *
     * Does NOT request a follow-up: that flag is for "send now", and a delayed
     * job consuming it early would be a no-op anyway.
     */
    fun enqueueSyncAfterRecording(context: Context) {
        val request = OneTimeWorkRequestBuilder<CallSyncWorker>()
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
            .setInputData(onlyIfWork())
            .setInitialDelay(SYNC_AFTER_RECORDING_DELAY_SECONDS, TimeUnit.SECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_SYNC)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_SYNC_AFTER_RECORDING, ExistingWorkPolicy.KEEP, request)
    }

    /**
     * The next run, booked for when the server's rate-limit window reopens
     * ([untilMillis]) plus a few seconds of jitter.
     *
     * Its own unique name, REPLACE: the latest booking is the one that counts.
     * The worker that booked it returns success rather than retry(), so
     * WorkManager's exponential backoff, which knows nothing of the server's
     * window, does not decide when uploads resume.
     */
    fun enqueueSyncAt(context: Context, untilMillis: Long) {
        val jitterMillis = (1_000L..5_000L).random()
        val delayMillis = (untilMillis - System.currentTimeMillis()).coerceAtLeast(0L) + jitterMillis
        val request = OneTimeWorkRequestBuilder<CallSyncWorker>()
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
            .setInputData(onlyIfWork())
            .setInitialDelay(delayMillis, TimeUnit.MILLISECONDS)
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 30, TimeUnit.SECONDS)
            .addTag(TAG_SYNC)
            .build()

        WorkManager.getInstance(context)
            .enqueueUniqueWork(WORK_SYNC_AFTER_RATE_LIMIT, ExistingWorkPolicy.REPLACE, request)
    }

    /** See [CallSyncWorker.KEY_ONLY_IF_WORK]. */
    private fun onlyIfWork(): Data =
        Data.Builder().putBoolean(CallSyncWorker.KEY_ONLY_IF_WORK, true).build()

    /**
     * The durable floor under everything else: one hourly job that ingests,
     * then syncs only if the outbox owes the server something.
     *
     * It replaces two 15-minute jobs (ingest, and a network-constrained sync)
     * that between them woke the handset eight times an hour whether or not a
     * call had been made. The events now carry the time-critical work, so this
     * only catches what they missed.
     *
     * No network constraint: capture must run offline so a recording is
     * snapshotted before the dialer rotates it, and the sync it hands off to
     * waits for a network on its own.
     *
     * UPDATE, not REPLACE: re-arming on every launch must not reset the
     * interval and push the next run an hour out each time the user opens the
     * app, which REPLACE would. Unlike KEEP, UPDATE also carries a future
     * change to this request (its interval, say) onto handsets that already
     * have it armed; a job that is running finishes and takes the change on
     * its next run.
     *
     * Not armed without a session — launch, boot and the service's quota
     * timeout all call this, and used to schedule capture on a signed-out
     * phone. Sign-in arms it through `startBackgroundTracking`.
     */
    fun ensurePeriodic(context: Context) {
        if (!IngestStore.hasSession(context)) return
        val workManager = WorkManager.getInstance(context)

        retireLegacyWork(workManager)

        workManager.enqueueUniquePeriodicWork(
            WORK_SAFETY_NET,
            ExistingPeriodicWorkPolicy.UPDATE,
            PeriodicWorkRequestBuilder<CallIngestWorker>(SAFETY_NET_INTERVAL_MINUTES, TimeUnit.MINUTES)
                .setInputData(Data.Builder().putString(CallIngestWorker.KEY_REASON, REASON_PERIODIC).build())
                .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, 60, TimeUnit.SECONDS)
                .addTag(TAG_INGEST)
                .build(),
        )

        armContentTrigger(context)
    }

    @Volatile
    private var legacyRetired = false

    /**
     * Cancels the [LEGACY_WORK] names, once per process.
     *
     * Cancelling a name that no longer exists is a no-op, so repeating this on
     * every launch would be harmless — but it is a WorkManager database
     * transaction each time, and once per process is enough to catch an
     * upgraded install.
     */
    private fun retireLegacyWork(workManager: WorkManager) {
        if (legacyRetired) return
        LEGACY_WORK.forEach { workManager.cancelUniqueWork(it) }
        legacyRetired = true
    }

    const val TAG_INGEST = "zebu.ingest"
    const val TAG_SYNC = "zebu.sync"
}
