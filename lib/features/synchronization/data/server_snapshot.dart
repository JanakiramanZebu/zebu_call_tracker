import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_repository.dart';

/// What the server last said about this handset and its calls, from
/// `GET /sync/status` (Mobile API Guide §5.1).
///
/// Everything else the app shows is the phone's own view: "sent" means the
/// coordinator got a 2xx. This is the other side of it — the server's count of
/// what it actually holds — and whether the server will still accept this
/// device at all.
///
/// Persisted, because the check-in runs at most every half hour and an app
/// that forgets on every cold start showed a revoked device, or a clock the
/// server rejects calls for, as healthy until the next check came due.
class ServerSnapshot {
  const ServerSnapshot({
    required this.checkedAt,
    required this.deviceStatus,
    this.clockSkewMinutes,
    this.lastSyncAt,
    this.lastCallAt,
    this.totalCalls,
    this.callsToday,
    this.callsLast7Days,
    this.recordingsStored,
  });

  /// When the server answered, on this phone's clock.
  final DateTime checkedAt;

  /// `ACTIVE`, `REVOKED`, `INACTIVE`, ...
  final String deviceStatus;

  /// Non-null when the phone clock was outside the server's tolerance.
  final int? clockSkewMinutes;

  final DateTime? lastSyncAt;
  final DateTime? lastCallAt;
  final int? totalCalls;
  final int? callsToday;
  final int? callsLast7Days;
  final int? recordingsStored;

  bool get isDeviceActive => deviceStatus == 'ACTIVE';

  /// `calls_today` is the server's "today", so it means nothing once the
  /// local date has moved on since the check.
  bool get callsTodayIsCurrent {
    final now = DateTime.now();
    final at = checkedAt.toLocal();
    return now.year == at.year && now.month == at.month && now.day == at.day;
  }

  factory ServerSnapshot.from(SyncStatusResponse s, {int? clockSkewMinutes}) =>
      ServerSnapshot(
        checkedAt: DateTime.now().toUtc(),
        deviceStatus: s.deviceStatus,
        clockSkewMinutes: clockSkewMinutes,
        lastSyncAt: s.lastSyncAt,
        lastCallAt: s.lastCallAt,
        totalCalls: s.totalCalls,
        callsToday: s.callsToday,
        callsLast7Days: s.callsLast7Days,
        recordingsStored: s.recordingsStored,
      );

  Map<String, Object?> toJson() => {
        'checked_at': checkedAt.toIso8601String(),
        'device_status': deviceStatus,
        'clock_skew_minutes': clockSkewMinutes,
        'last_sync_at': lastSyncAt?.toIso8601String(),
        'last_call_at': lastCallAt?.toIso8601String(),
        'total_calls': totalCalls,
        'calls_today': callsToday,
        'calls_last_7_days': callsLast7Days,
        'recordings_stored': recordingsStored,
      };

  static ServerSnapshot? fromJson(Map<String, Object?> j) {
    final checkedAt = DateTime.tryParse(j['checked_at'] as String? ?? '');
    if (checkedAt == null) return null;
    DateTime? time(String key) =>
        DateTime.tryParse(j[key] as String? ?? '')?.toUtc();
    int? count(String key) => (j[key] as num?)?.toInt();
    return ServerSnapshot(
      checkedAt: checkedAt.toUtc(),
      deviceStatus: j['device_status'] as String? ?? 'ACTIVE',
      clockSkewMinutes: count('clock_skew_minutes'),
      lastSyncAt: time('last_sync_at'),
      lastCallAt: time('last_call_at'),
      totalCalls: count('total_calls'),
      callsToday: count('calls_today'),
      callsLast7Days: count('calls_last_7_days'),
      recordingsStored: count('recordings_stored'),
    );
  }
}

final serverSnapshotProvider =
    AsyncNotifierProvider<ServerSnapshotController, ServerSnapshot?>(
  ServerSnapshotController.new,
);

class ServerSnapshotController extends AsyncNotifier<ServerSnapshot?> {
  static const _key = 'zebu.sync.server_snapshot.v1';

  @override
  Future<ServerSnapshot?> build() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key);
      if (raw == null) return null;
      return ServerSnapshot.fromJson(
        (jsonDecode(raw) as Map).cast<String, Object?>(),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> report(ServerSnapshot snapshot) async {
    state = AsyncData(snapshot);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, jsonEncode(snapshot.toJson()));
    } catch (_) {}
  }

  /// Sign-out: the next employee's phone state is not this one's.
  Future<void> clear() async {
    state = const AsyncData(null);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_key);
    } catch (_) {}
  }
}
