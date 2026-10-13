package `in`.mynt.zebu_call_tracker.whatsapp

import android.Manifest
import android.app.Notification
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.ContactsContract
import android.service.notification.StatusBarNotification
import android.util.Log
import androidx.core.content.ContextCompat
import `in`.mynt.zebu_call_tracker.background.BackgroundScheduler
import `in`.mynt.zebu_call_tracker.background.NativeCallOutboxDao
import `in`.mynt.zebu_call_tracker.call.CallWireFormat
import `in`.mynt.zebu_call_tracker.platform.NativeBridge
import org.json.JSONObject
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Rebuilds WhatsApp calls from the notifications [WhatsAppCallListener] sees.
 *
 * One call, as WhatsApp shows it:
 *
 * ```
 * incoming:  RING posted ─► (answered) ONGOING posted ─► all removed = ended
 *                       └─► all removed, never ongoing         = missed
 * outgoing:  ONGOING posted (no ring) ─► connected = answered ─► removed
 *                                    └─► removed, never connected = cancelled
 * missed:    MISSED posted on its own (ring was not seen)   = missed
 * ```
 *
 * "Connected" on an outgoing call is the hard part: the ongoing notification
 * exists from "Calling…" onwards. A call timer settles it; without one the
 * text does ("Ongoing voice call", or a 0:42-style duration); and in a
 * language the text patterns do not know, the third distinct text WhatsApp
 * shows — after "Calling…" and "Ringing…" — is taken as the connect.
 *
 * Classification leans on notification structure before wording, because
 * WhatsApp follows the phone's language: a full-screen intent rings, a
 * non-dismissable call notification is a call in progress, and a dismissable
 * one is a missed call. English text is only a fallback for the cases
 * structure leaves open.
 *
 * A call is keyed by app + the person/group WhatsApp names in the title, so
 * the ringing notification and the ongoing one that replaces it are the same
 * call even when WhatsApp gives them different notification ids.
 *
 * Callbacks arrive on the main thread; the database write goes to [io].
 */
object WhatsAppCallTracker {

    private const val TAG = "WhatsAppCallTracker"

    /**
     * How long after its last notification disappears a call is considered
     * over. WhatsApp removes the ringing notification a moment before it posts
     * the ongoing one; finishing on the first removal would split one answered
     * call into a "missed" call and an outgoing one.
     */
    private const val END_GRACE_MS = 4_000L

    /** A MISSED notification this soon after we recorded a missed ring is the same call. */
    private const val MISSED_DEDUPE_MS = 3 * 60_000L

    private const val CALL_TYPE_INCOMING = 1 // Notification.CallStyle.CALL_TYPE_INCOMING
    private const val CALL_TYPE_ONGOING = 2 // Notification.CallStyle.CALL_TYPE_ONGOING
    private const val EXTRA_CALL_TYPE = "android.callType"
    private const val EXTRA_CALL_PERSON = "android.callPerson"
    private const val CATEGORY_MISSED_CALL = "missed_call"

    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()

    private enum class Kind { RING, ONGOING, MISSED, OTHER }

    private class ActiveCall(
        val app: String,
        val peer: String,
        val incoming: Boolean,
        val startedAtMillis: Long,
    ) {
        val notificationKeys = mutableSetOf<String>()
        var answeredAtMillis: Long? = null
        var video = false
        var pendingEnd: Runnable? = null

        /** Distinct texts the ongoing notification has shown, in any language. */
        val textsSeen = mutableSetOf<String>()
    }

    private val active = mutableMapOf<String, ActiveCall>()

    /** peer key → when we last recorded an unanswered incoming call from them. */
    private val recentMissed = mutableMapOf<String, Long>()

    fun onPosted(context: Context, sbn: StatusBarNotification) {
        val n = sbn.notification ?: return
        if (n.flags and Notification.FLAG_GROUP_SUMMARY != 0) return
        val kind = classify(n)
        if (kind == Kind.OTHER) return
        val peer = peerOf(n) ?: return
        val key = "${sbn.packageName}|$peer"
        val text = textOf(n)
        val video = text.contains("video")

        when (kind) {
            Kind.RING -> {
                val call = active.getOrPut(key) {
                    ActiveCall(sbn.packageName, peer, incoming = true, startedAtMillis = sbn.postTime)
                }
                call.notificationKeys += sbn.key
                call.video = call.video || video
                cancelPendingEnd(call)
            }

            Kind.ONGOING -> {
                val call = active.getOrPut(key) {
                    // No ring seen first: this phone placed the call.
                    ActiveCall(sbn.packageName, peer, incoming = false, startedAtMillis = sbn.postTime)
                }
                call.notificationKeys += sbn.key
                call.video = call.video || video
                cancelPendingEnd(call)
                if (text.isNotBlank()) call.textsSeen += text

                if (call.answeredAtMillis == null) {
                    call.answeredAtMillis = connectedAt(call, n, sbn.postTime, text)
                }
            }

            Kind.MISSED -> {
                if (active.containsKey(key)) return // the ring will finish it
                val last = recentMissed[key]
                if (last != null && sbn.postTime - last < MISSED_DEDUPE_MS) return
                val at = if (n.`when` in 1..sbn.postTime) n.`when` else sbn.postTime
                recentMissed[key] = at
                save(
                    context,
                    app = sbn.packageName,
                    peer = peer,
                    incoming = true,
                    startedAtMillis = at,
                    answeredAtMillis = null,
                    endedAtMillis = at,
                    video = video,
                )
            }

            Kind.OTHER -> Unit
        }
    }

    fun onRemoved(context: Context, sbn: StatusBarNotification) {
        val call = active.values.firstOrNull { sbn.key in it.notificationKeys } ?: return
        call.notificationKeys -= sbn.key
        if (call.notificationKeys.isNotEmpty()) return

        val endedAt = System.currentTimeMillis()
        val finish = Runnable { finish(context, call, endedAt) }
        call.pendingEnd = finish
        main.postDelayed(finish, END_GRACE_MS)
    }

    private fun cancelPendingEnd(call: ActiveCall) {
        call.pendingEnd?.let { main.removeCallbacks(it) }
        call.pendingEnd = null
    }

    private fun finish(context: Context, call: ActiveCall, endedAtMillis: Long) {
        val key = "${call.app}|${call.peer}"
        if (active[key] !== call || call.notificationKeys.isNotEmpty()) return
        active.remove(key)

        if (call.incoming && call.answeredAtMillis == null) {
            recentMissed[key] = call.startedAtMillis
        }
        save(
            context,
            app = call.app,
            peer = call.peer,
            incoming = call.incoming,
            startedAtMillis = call.startedAtMillis,
            answeredAtMillis = call.answeredAtMillis,
            endedAtMillis = endedAtMillis,
            video = call.video,
        )
    }

    private fun save(
        context: Context,
        app: String,
        peer: String,
        incoming: Boolean,
        startedAtMillis: Long,
        answeredAtMillis: Long?,
        endedAtMillis: Long,
        video: Boolean,
    ) {
        val answered = answeredAtMillis != null
        val duration =
            if (answered) ((endedAtMillis - answeredAtMillis!!) / 1000L).coerceAtLeast(0).toInt() else 0

        // Stored in the server's vocabulary; the uploader maps it again with
        // CallWireFormat.outcomeFor, which agrees with these.
        val direction = if (incoming) CallWireFormat.Direction.INCOMING else CallWireFormat.Direction.OUTGOING
        val status = when {
            answered -> CallWireFormat.Status.ENDED
            incoming -> CallWireFormat.Status.MISSED
            else -> CallWireFormat.Status.CANCELLED
        }

        io.execute {
            try {
                val number = numberFor(context, peer)
                val externalId = "whatsapp-$startedAtMillis-${shortHash("$app|$peer")}"
                val metadata = JSONObject()
                    .put("channel", "whatsapp")
                    .put("app", if (app == WhatsAppCallListener.WHATSAPP_BUSINESS) "whatsapp_business" else "whatsapp")
                    .put("media", if (video) "video" else "voice")
                    .toString()

                val inserted = NativeCallOutboxDao.insertExternalCall(
                    context,
                    NativeCallOutboxDao.ExternalCall(
                        externalCallId = externalId,
                        idempotencyKey = CallWireFormat.Identity.keyFor(externalId, startedAtMillis),
                        phoneNumber = number,
                        contactName = peer.takeUnless { looksLikeNumber(it) },
                        direction = direction,
                        status = status,
                        startedAtMillis = startedAtMillis,
                        answeredAtMillis = answeredAtMillis,
                        endedAtMillis = endedAtMillis,
                        durationSeconds = duration,
                        metadataJson = metadata,
                    ),
                )
                if (inserted) {
                    Log.d(TAG, "Recorded WhatsApp $direction/$status call, ${duration}s")
                    BackgroundScheduler.enqueueSync(context)
                    NativeBridge.notifyCallsChanged()
                }
            } catch (e: Exception) {
                Log.e(TAG, "Could not record WhatsApp call: ${e.message}")
            }
        }
    }

    // ── Reading WhatsApp's notifications ─────────────────────────────────────

    private fun classify(n: Notification): Kind {
        // Chat messages first, and out. A message saying "calling you later"
        // or "sorry, missed your call" must never become a call record, so no
        // text heuristic below ever sees a messaging notification.
        val isMessage = n.category == Notification.CATEGORY_MESSAGE ||
            n.extras?.containsKey(Notification.EXTRA_MESSAGES) == true
        if (isMessage) return Kind.OTHER

        val text = textOf(n)
        val channel = channelOf(n)
        if (n.category == CATEGORY_MISSED_CALL || channel.contains("missed") ||
            MISSED.containsMatchIn(text)
        ) {
            return Kind.MISSED
        }

        // Android 12+ CallStyle states the type outright.
        when (n.extras?.getInt(EXTRA_CALL_TYPE, 0) ?: 0) {
            CALL_TYPE_INCOMING -> return Kind.RING
            CALL_TYPE_ONGOING -> return Kind.ONGOING
        }

        // Otherwise only a notification WhatsApp itself marks as a call — by
        // category or by a call/voip channel, both language-independent — or
        // an ongoing one whose text names a call.
        val ongoing = n.flags and
            (Notification.FLAG_ONGOING_EVENT or Notification.FLAG_FOREGROUND_SERVICE) != 0
        val isCall = n.category == Notification.CATEGORY_CALL ||
            channel.contains("call") || channel.contains("voip") ||
            (ongoing && CALL.containsMatchIn(text))
        if (!isCall) return Kind.OTHER
        if (n.fullScreenIntent != null || INCOMING.containsMatchIn(text)) return Kind.RING
        // A call notification the user can swipe away is not a live call. In
        // English the MISSED pattern above already caught it; in any other
        // language this is what keeps a missed call from becoming a phantom
        // outgoing one that "ends" whenever the user clears the shade.
        if (!ongoing) return Kind.MISSED
        return Kind.ONGOING
    }

    /**
     * When an outgoing call connected, or null while it has not. Incoming calls
     * connect the moment the ongoing notification replaces the ring.
     */
    private fun connectedAt(call: ActiveCall, n: Notification, postedAt: Long, text: String): Long? {
        // The timer's base is the moment the call connected.
        chronometerBase(n, call.startedAtMillis)?.let { return it }
        if (call.incoming) return postedAt
        if (CONNECTED.containsMatchIn(text)) return postedAt
        if (PRE_CONNECT.containsMatchIn(text) || NOT_CONNECTED.containsMatchIn(text)) return null
        // Wording this code does not know: "Calling…", "Ringing…", then the
        // connected state is the third text WhatsApp shows.
        return if (call.textsSeen.size >= 3) postedAt else null
    }

    private fun channelOf(n: Notification): String =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) n.channelId?.lowercase().orEmpty() else ""

    /** The connect time, when the notification shows a running call timer. */
    private fun chronometerBase(n: Notification, startedAtMillis: Long): Long? {
        val showsTimer = n.extras?.getBoolean(Notification.EXTRA_SHOW_CHRONOMETER, false) == true
        if (!showsTimer) return null
        val base = n.`when`
        val now = System.currentTimeMillis()
        // Trust it only when it is plausible for this call.
        return base.takeIf { it in (startedAtMillis - 60_000L)..now }
    }

    private fun peerOf(n: Notification): String? {
        val extras = n.extras ?: return null
        val person = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            @Suppress("DEPRECATION")
            (extras.getParcelable(EXTRA_CALL_PERSON) as? android.app.Person)?.name?.toString()
        } else {
            null
        }
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()
        return (person ?: title)?.trim()?.takeIf { it.isNotEmpty() && it !in APP_TITLES }
    }

    private fun textOf(n: Notification): String {
        val extras = n.extras ?: return ""
        return listOfNotNull(
            extras.getCharSequence(Notification.EXTRA_TEXT),
            extras.getCharSequence(Notification.EXTRA_SUB_TEXT),
        ).joinToString(" ").lowercase()
    }

    /**
     * The caller's number. WhatsApp titles an unsaved caller with the number
     * itself; a saved one with the contact's name, which is looked up in
     * Contacts. "Unknown" when neither gives a number — the server stores that
     * as a withheld caller rather than inventing one.
     */
    private fun numberFor(context: Context, peer: String): String {
        if (looksLikeNumber(peer)) return peer.filter { it.isDigit() || it == '+' }
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS)
            != PackageManager.PERMISSION_GRANTED
        ) {
            return "Unknown"
        }
        return try {
            context.contentResolver.query(
                ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
                arrayOf(ContactsContract.CommonDataKinds.Phone.NUMBER),
                "${ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME} = ?",
                arrayOf(peer),
                null,
            )?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
                ?.filter { it.isDigit() || it == '+' }
                ?.takeIf { it.length >= 6 }
                ?: "Unknown"
        } catch (e: Exception) {
            "Unknown"
        }
    }

    private fun looksLikeNumber(s: String) = NUMBER.matches(s)

    private fun shortHash(s: String): String =
        MessageDigest.getInstance("SHA-1").digest(s.toByteArray())
            .take(6).joinToString("") { "%02x".format(it) }

    private val NUMBER = Regex("""^\+?[\d\s\-()]{6,}$""")
    private val MISSED = Regex("""missed (voice|video) call""")
    private val INCOMING = Regex("""incoming (voice|video) call""")
    private val CALL = Regex("""(voice|video) call|calling|ringing""")
    private val CONNECTED = Regex("""ongoing|\b\d{1,2}:\d{2}\b""")
    private val PRE_CONNECT = Regex("""calling|ringing|connecting""")
    private val NOT_CONNECTED = Regex("""declined|unavailable|busy|no answer|not answered|ended""")
    private val APP_TITLES = setOf("WhatsApp", "WhatsApp Business")
}
