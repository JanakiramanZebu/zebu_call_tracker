// Native background execution redesign:
// All background synchronization is managed natively by Android WorkManager (CallSyncWorker)
// and SyncCoordinator. Flutter background isolates are disabled to prevent duplicate sync tasks
// and memory overhead.

const String backgroundSyncTaskName = "sync_calls_task";

@pragma('vm:entry-point')
void callbackDispatcher() {
  // No-op: Native Android WorkManager handles background execution.
}
