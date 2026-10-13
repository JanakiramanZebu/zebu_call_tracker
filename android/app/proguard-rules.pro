# R8 rules for release builds (isMinifyEnabled = true).
#
# Only entries that R8 cannot infer are listed. Anything reachable from the
# manifest or from Dart via a normal call is already kept, and adding blanket
# -keep rules would give back the size and speed minification is here to win.

# --- background execution ----------------------------------------------------
# WorkManager instantiates workers reflectively, by class name, from its own
# database — there is no code path R8 can trace from the manifest to the
# constructor. work-runtime ships a consumer rule for ListenableWorker
# subclasses, but this app's background capture is the one thing that must not
# break silently in a release build a month after shipping, so it is pinned
# here explicitly rather than relying on a transitive dependency's rules.
-keep class in.mynt.zebu_call_tracker.background.CallIngestWorker {
    public <init>(android.content.Context, androidx.work.WorkerParameters);
}

# Manifest-registered receivers. Kept by the manifest today; named here so that
# a future refactor which moves a receiver out of the manifest (to a runtime
# registration, say) does not quietly strip it.
-keep class in.mynt.zebu_call_tracker.background.BootReceiver { <init>(); }
-keep class in.mynt.zebu_call_tracker.call.CallStateReceiver { <init>(); }

# --- diagnostics -------------------------------------------------------------
# Line numbers in release stack traces, with the original file name hidden.
# Without this a crash report from a fleet handset is unmappable.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# --- logging -----------------------------------------------------------------
# Verbose, debug and info logs are stripped from release builds: the ingest and
# sync paths log every claim, match and batch, which on a fleet handset is log
# spam the user pays for in battery and that can carry call metadata into
# logcat. Warnings and errors stay, since they are what a field report needs.
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
