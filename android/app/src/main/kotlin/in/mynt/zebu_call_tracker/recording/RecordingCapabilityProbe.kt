package `in`.mynt.zebu_call_tracker.recording

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
import androidx.core.content.ContextCompat
import java.io.File

/**
 * Answers "can this device actually record a cellular call?" — honestly.
 *
 * The whole point of this class is to REFUSE to produce a recording we cannot
 * genuinely capture. From Android 10 (API 29):
 *   - VOICE_CALL / VOICE_DOWNLINK / VOICE_UPLINK need CAPTURE_AUDIO_OUTPUT,
 *     which is signature|privileged and ungrantable to a normal app.
 *   - MIC capture is silenced by the platform while a call is active, so it
 *     yields a well-formed file containing silence.
 * A silent file reported as a recording is worse than no recording, so we
 * report `osRestricted` and let the sync layer store the reason.
 */
object RecordingCapabilityProbe {

    /** Mirrors the Dart RecordingCapability enum. */
    enum class Verdict { SUPPORTED, PERMISSION_REQUIRED, OS_RESTRICTED, DEVICE_UNSUPPORTED }

    /**
     * Directories OEM system dialers are known to write their own call
     * recordings into (feasibility option B). We only report reachability —
     * reading them needs MANAGE_EXTERNAL_STORAGE and internal distribution.
     */
    private val OEM_RECORDING_DIRS = listOf(
        "MIUI/sound_recorder/call_rec",
        "Recordings/Call",
        "Sounds/CallRecord",
        "Record/Call",
        "PhoneRecord",
    )

    fun probe(context: Context): Map<String, Any?> {
        val sdk = Build.VERSION.SDK_INT
        val hasRecordAudio = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED

        // Never granted to a normal app; probed so the report states a fact
        // rather than an assumption.
        val hasCaptureAudioOutput = ContextCompat.checkSelfPermission(
            context, "android.permission.CAPTURE_AUDIO_OUTPUT",
        ) == PackageManager.PERMISSION_GRANTED

        val verdict = when {
            hasCaptureAudioOutput -> Verdict.SUPPORTED
            sdk >= Build.VERSION_CODES.Q -> Verdict.OS_RESTRICTED
            !hasRecordAudio -> Verdict.PERMISSION_REQUIRED
            else -> Verdict.SUPPORTED
        }

        val reason = when (verdict) {
            Verdict.OS_RESTRICTED ->
                "Android $sdk (API $sdk) blocks third-party capture of call audio. " +
                    "VOICE_CALL needs the privileged CAPTURE_AUDIO_OUTPUT permission, " +
                    "and MIC capture is silenced during calls."
            Verdict.PERMISSION_REQUIRED -> "RECORD_AUDIO has not been granted."
            Verdict.SUPPORTED -> "Call audio capture is available on this build."
            Verdict.DEVICE_UNSUPPORTED -> "No usable audio capture path on this device."
        }

        return mapOf(
            "verdict" to verdict.name,
            "reason" to reason,
            "sdkInt" to sdk,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "hasRecordAudioPermission" to hasRecordAudio,
            "hasCaptureAudioOutputPermission" to hasCaptureAudioOutput,
            "oemRecordingDirs" to scanOemDirs(),
        )
    }

    /**
     * Evidence for feasibility option B. On API 30+ a normal app cannot list
     * these without All-files access, so `readable=false` here means
     * "not visible to us", not "absent".
     */
    private fun scanOemDirs(): List<Map<String, Any?>> {
        val root = Environment.getExternalStorageDirectory()
        return OEM_RECORDING_DIRS.map { relative ->
            val dir = File(root, relative)
            mapOf(
                "path" to relative,
                "exists" to runCatching { dir.exists() }.getOrDefault(false),
                "readable" to runCatching { dir.canRead() }.getOrDefault(false),
                "fileCount" to runCatching { dir.listFiles()?.size }.getOrNull(),
            )
        }
    }
}
