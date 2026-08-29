abstract final class ApiEndpoints {
  // Auth
  static const login = '/auth/login';
  static const registerMobile = '/mobile/register';
  static const refresh = '/auth/refresh';
  static const logout = '/auth/logout';
  static const me = '/auth/me';
  static const changePassword = '/auth/change-password';
  static const sessions = '/auth/sessions';
  static String sessionById(String id) => '/auth/sessions/$id';

  // Devices
  static const registerDevice = '/devices/register';
  static const myDevices = '/devices/me';
  static String heartbeat(String uuid) => '/devices/heartbeat?device_uuid=$uuid';
  static String updateDevice(String uuid) => '/devices/$uuid';

  // Sync
  static const syncStatus = '/sync/status';
  static const syncCalls = '/sync/calls';
  static const syncLookup = '/sync/lookup';

  // Calls
  static const calls = '/calls';
  static String callById(String id) => '/calls/$id';
  static String callRecording(String callId) => '/calls/$callId/recording';

  // Recordings
  static const recordings = '/recordings';
  static String recordingStream(String recId) => '/recordings/$recId/stream';
  static String recordingDownload(String recId) => '/recordings/$recId/download';
  static String playbackToken(String recId) => '/recordings/$recId/playback-token';

  // User & Dashboard
  static const userMe = '/users/me';
  static const dashboard = '/dashboard';
}

