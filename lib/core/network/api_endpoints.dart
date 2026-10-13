abstract final class ApiEndpoints {
  // Auth
  static const registerMobile = '/mobile/register';
  static const lookupEmployee = '/mobile/lookup';

  // Devices
  static const registerDevice = '/devices/register';
  // `/devices/heartbeat` and `/devices/fcm-token` are called natively; see
  // NativeHeartbeat and PushTokenWorker.

  // Sync
  static const syncStatus = '/sync/status';

  // Calls
  static String callById(String id) => '/calls/$id';

  // Recordings
  static String recordingPlaybackToken(String id) =>
      '/recordings/$id/playback-token';
}

