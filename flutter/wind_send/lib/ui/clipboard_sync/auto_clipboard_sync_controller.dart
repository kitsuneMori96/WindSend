import 'dart:async';

import 'package:logger/logger.dart';

import 'package:wind_send/clipboard_sync/sync_session_protocol.dart';
import 'package:wind_send/db/shared_preferences/cnf.dart';
import 'package:wind_send/device.dart';
import 'package:wind_send/utils/logger.dart';

import 'clipboard_sync_session.dart';

/// Keeps a single persistent, text-only clipboard-sync session running with
/// the default sync device while auto clipboard sync is enabled.
///
/// The session pushes text clipboard changes in both directions automatically
/// (phone -> PC and PC -> phone). Images and files are never part of this
/// session; they keep using the original manual transfer logic.
class AutoClipboardSyncController {
  AutoClipboardSyncController._();

  static final AutoClipboardSyncController instance =
      AutoClipboardSyncController._();

  static const List<Duration> _retryBackoff = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  ClipboardSyncPageSession? _session;
  Device? _targetDevice;
  bool _started = false;
  Future<void> _busy = Future<void>.value();
  Timer? _retryTimer;
  int _retryAttempt = 0;

  bool get isEnabled => LocalConfig.enableAutoClipboardSync;

  bool get isActive => _session != null;

  /// Re-reads the toggle and device list, then (re)establishes or closes the
  /// auto session accordingly.
  ///
  /// Call this after the toggle changes, the device list changes, or when the
  /// app resumes (WiFi network may have changed the auto-selected device).
  Future<void> syncWithAutoTarget() {
    _retryTimer?.cancel();
    _retryTimer = null;
    final run = _busy.then((_) => _runSync());
    _busy = run.catchError((Object _) {});
    return run;
  }

  Future<void> ensureStarted() async {
    if (_started) {
      return;
    }
    _started = true;
    await syncWithAutoTarget();
  }

  Future<void> _runSync() async {
    try {
      if (!LocalConfig.enableAutoClipboardSync) {
        _logger().w('auto clipboard sync is disabled; releasing session.');
        await _release();
        return;
      }

      final device = await _resolveAutoTarget();
      if (device == null) {
        _logger().w(
          'no auto sync target device (empty device list); releasing session.',
        );
        await _release();
        return;
      }

      final current = _session;
      if (current != null && !current.isDisposed && _targetDevice != null) {
        if (_targetDevice!.remotePeerKey == device.remotePeerKey) {
          current.updateDevice(device);
          _targetDevice = device;
          return;
        }
      }

      await _release();
      _targetDevice = device;
      _session = ClipboardSyncPageSessionStore.instance.acquire(
        device,
        capabilities: buildTextOnlySyncCapabilities(),
      );
      _logger().d(
        'auto clipboard sync session established for ${device.targetDeviceName}.',
      );
    } catch (error) {
      _logger().e('auto clipboard sync failed: $error');
      _scheduleRetry();
    }
  }

  Future<Device?> _resolveAutoTarget() async {
    final device = await resolveTargetDevice(defaultSyncDevice: true);
    if (device != null) {
      return device;
    }
    final devices = LocalConfig.devices;
    if (devices.isNotEmpty) {
      return devices.first;
    }
    return null;
  }

  Future<void> _release() async {
    _retryAttempt = 0;
    final session = _session;
    _session = null;
    _targetDevice = null;
    if (session == null || session.isDisposed) {
      return;
    }
    ClipboardSyncPageSessionStore.instance.release(session);
  }

  void _scheduleRetry() {
    if (_retryTimer?.isActive ?? false) {
      return;
    }
    final attempt = _retryAttempt < _retryBackoff.length
        ? _retryAttempt
        : _retryBackoff.length - 1;
    _retryAttempt += 1;
    final delay = _retryBackoff[attempt];
    _logger().d('auto clipboard sync retry scheduled in ${delay.inSeconds}s.');
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      unawaited(syncWithAutoTarget());
    });
  }

  Logger _logger() => SharedLogger().logger;
}
