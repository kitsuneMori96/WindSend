import 'package:flutter/foundation.dart';

import 'package:wind_send/clipboard_sync/sync_session_protocol.dart';
import 'package:wind_send/db/shared_preferences/cnf.dart';
import 'package:wind_send/device.dart';

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

  ClipboardSyncPageSession? _session;
  Device? _targetDevice;
  bool _started = false;
  Future<void> _busy = Future<void>.value();

  bool get isEnabled => LocalConfig.enableAutoClipboardSync;

  bool get isActive => _session != null;

  /// Re-reads the toggle and device list, then (re)establishes or closes the
  /// auto session accordingly.
  ///
  /// Call this after the toggle changes, the device list changes, or when the
  /// app resumes (WiFi network may have changed the auto-selected device).
  Future<void> syncWithAutoTarget() {
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
        await _release();
        return;
      }

      final device = await _resolveAutoTarget();
      if (device == null) {
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
    } catch (error) {
      debugPrint('AutoClipboardSyncController sync failed: $error');
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
    final session = _session;
    _session = null;
    _targetDevice = null;
    if (session == null || session.isDisposed) {
      return;
    }
    ClipboardSyncPageSessionStore.instance.release(session);
  }
}
