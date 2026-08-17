import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:clipshare_clipboard_listener/clipboard_manager.dart';
import 'package:clipshare_clipboard_listener/enums.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localization/flutter_localization.dart';
import 'package:image/image.dart' as img;

import 'package:wind_send/clipboard_sync/clipboard_domain.dart';
import 'package:wind_send/device.dart';
import 'package:wind_send/language.dart';

import 'clipboard_bubble.dart';
import 'clipboard_sync_session.dart';

class ClipboardSyncPage extends StatefulWidget {
  const ClipboardSyncPage({super.key, required this.device});

  final Device device;

  @override
  State<ClipboardSyncPage> createState() => _ClipboardSyncPageState();
}

class _ClipboardSyncPageState extends State<ClipboardSyncPage> {
  late final ClipboardSyncPageSession _session;
  final TextEditingController _textController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  int _lastTimelineLength = 0;

  @override
  void initState() {
    super.initState();
    _session = ClipboardSyncPageSessionStore.instance.acquire(widget.device);
    _lastTimelineLength = _session.timeline.length;
    _session.addListener(_handleSessionChanged);
  }

  @override
  void didUpdateWidget(covariant ClipboardSyncPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.device.remotePeerKey != widget.device.remotePeerKey) {
      return;
    }
    _session.updateDevice(widget.device);
  }

  @override
  void dispose() {
    _session.removeListener(_handleSessionChanged);
    ClipboardSyncPageSessionStore.instance.release(_session);
    _textController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AnimatedBuilder(
      animation: _session,
      builder: (context, _) {
        final timeline = _session.timeline;
        final isRunning = _session.isRunning;

        return Scaffold(
          backgroundColor: colorScheme.surface,
          appBar: AppBar(
            scrolledUnderElevation: 0.5,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  context.formatString(AppLocale.csClipboardSync, []),
                  style: const TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 18),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _statusColor(context),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${widget.device.targetDeviceName} · ${_resolvePhaseLabel(context)}',
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: _statusColor(context),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            actions: [
              if (_session.isAutoManagedCapabilities)
                Tooltip(
                  message: context.formatString(
                    AppLocale.csAutoSyncManaging,
                    [],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.only(right: 16),
                    child: Icon(
                      Icons.auto_awesome,
                      size: 22,
                      color: _statusColor(context),
                    ),
                  ),
                )
              else
                Tooltip(
                  message: isRunning
                      ? context.formatString(AppLocale.csStopSession, [])
                      : context.formatString(AppLocale.csRestartSession, []),
                  child: Switch(
                    value: isRunning,
                    onChanged: (value) {
                      unawaited(_session.toggleRunning(value));
                    },
                  ),
                ),
              const SizedBox(width: 16),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: Container(
                  color: colorScheme.surfaceContainerLowest,
                  child: timeline.isEmpty
                      ? _buildEmptyState(context)
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.only(top: 8, bottom: 16),
                          itemCount: timeline.length + 1,
                          itemBuilder: (context, index) {
                            if (index == 0) {
                              return _buildSessionHeader(context);
                            }
                            final item = timeline[index - 1];
                            return switch (item) {
                              ClipboardSyncEventTimelineItem() =>
                                ClipboardBubble(
                                  item: item,
                                  onDelete: () {
                                    _session.removeTimelineItem(item.id);
                                  },
                                ),
                              ClipboardSyncStatusTimelineItem() =>
                                _buildStatusItem(context, item),
                            };
                          },
                        ),
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(8, 12, 12, 16),
                decoration: BoxDecoration(
                  color: colorScheme.surface,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.05),
                      offset: const Offset(0, -2),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _textController,
                          enabled: isRunning,
                          decoration: InputDecoration(
                            hintText: context.formatString(
                                AppLocale.csTypeTextToCopy, []),
                            hintStyle: TextStyle(
                              color: colorScheme.onSurfaceVariant
                                  .withValues(alpha: 0.7),
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(24),
                              borderSide: BorderSide.none,
                            ),
                            filled: true,
                            fillColor: colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.5),
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 20,
                              vertical: 12,
                            ),
                            isDense: true,
                          ),
                          minLines: 1,
                          maxLines: 4,
                          textInputAction: TextInputAction.send,
                          onSubmitted: (_) => _handleManualCopy(),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: IconButton(
                          onPressed: isRunning ? _handleSendImage : null,
                          tooltip: context.formatString(
                            AppLocale.csSendImage,
                            [],
                          ),
                          icon: const Icon(Icons.image_outlined),
                          color: isRunning
                              ? colorScheme.primary
                              : colorScheme.onSurfaceVariant,
                          iconSize: 22,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: isRunning
                                ? colorScheme.primary
                                : colorScheme.surfaceContainerHighest,
                            shape: BoxShape.circle,
                          ),
                          child: IconButton(
                            onPressed: isRunning ? _handleManualCopy : null,
                            icon: const Icon(Icons.send_rounded),
                            color: isRunning
                                ? colorScheme.onPrimary
                                : colorScheme.onSurfaceVariant,
                            iconSize: 20,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSessionHeader(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final watcherStatus = _session.watcherStatus;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colorScheme.secondaryContainer.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.secondaryContainer.withValues(alpha: 0.8),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 16, color: colorScheme.onSecondaryContainer),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _resolveLocaleText(context, watcherStatus.label),
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: colorScheme.onSecondaryContainer,
                  ),
                ),
              ),
              if (_session.lastRemoteAckUpTo != null)
                Text(
                  context.formatString(
                    AppLocale.csAckLabel,
                    [_session.lastRemoteAckUpTo!],
                  ),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSecondaryContainer
                        .withValues(alpha: 0.8),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            _resolveLocaleText(context, watcherStatus.details),
            style: theme.textTheme.bodySmall?.copyWith(
              color: colorScheme.onSecondaryContainer.withValues(alpha: 0.8),
            ),
          ),
          if (watcherStatus.suggestShizuku) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _resolveLocaleText(
                      context,
                      const LocaleText(AppLocale.csShizukuBanner),
                    ),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton.tonal(
                  onPressed: _handleOpenShizukuGuide,
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                  child: Text(
                    _resolveLocaleText(
                      context,
                      const LocaleText(AppLocale.csShizukuEnable),
                    ),
                    style: theme.textTheme.labelSmall,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _handleOpenShizukuGuide() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => const _ShizukuGuideSheet(),
    );
  }

  Widget _buildStatusItem(
    BuildContext context,
    ClipboardSyncStatusTimelineItem item,
  ) {
    final colorScheme = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: Center(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(16),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(item.icon, size: 16, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    _resolveLocaleText(context, item.content),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final theme = Theme.of(context);

    return SingleChildScrollView(
      child: Column(
        children: [
          _buildSessionHeader(context),
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primaryContainer
                          .withValues(alpha: 0.5),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      Icons.sync_alt,
                      size: 48,
                      color: theme.colorScheme.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    context.formatString(
                        AppLocale.csNoClipboardActivity, []),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    context.formatString(
                        AppLocale.csEmptyStateDescription, []),
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleManualCopy() {
    final text = _textController.text.trim();
    if (text.isEmpty) {
      return;
    }
    unawaited(_session.copyTextToLocalClipboard(text));
    _textController.clear();
  }

  Future<void> _handleSendImage() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final paths = await _session.device.pickFiles();
      if (paths.isEmpty) {
        return;
      }
      await _session.device.doSendAction(() => context, paths);
      if (!mounted) {
        return;
      }
      var recordedImage = false;
      for (final path in paths) {
        final payload = await _buildManualImagePayload(path);
        if (payload != null) {
          _session.recordManualOutgoing(payload);
          recordedImage = true;
        }
      }
      if (!recordedImage) {
        _session.recordManualStatus(
          LocaleText(AppLocale.csImageSent, [_session.device.targetDeviceName]),
        );
      }
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            context.formatString(AppLocale.csImageSent, [
              _session.device.targetDeviceName,
            ]),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      messenger.showSnackBar(
        SnackBar(
          content: Text(context.formatString(AppLocale.csSendImageFailed, [])),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      );
    }
  }

  Future<ClipboardPayload?> _buildManualImagePayload(String path) async {
    const imageExtensions = {'jpg', 'jpeg', 'png', 'bmp', 'gif', 'webp'};
    final dotIndex = path.lastIndexOf('.');
    if (dotIndex < 0) {
      return null;
    }
    final ext = path.substring(dotIndex + 1).toLowerCase();
    if (!imageExtensions.contains(ext)) {
      return null;
    }
    final file = File(path);
    if (!await file.exists()) {
      return null;
    }
    final bytes = await file.readAsBytes();
    if (ext == 'png') {
      return ClipboardPayload.imagePng(bytes);
    }
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      return null;
    }
    return ClipboardPayload.imagePng(
      Uint8List.fromList(img.encodePng(decoded)),
    );
  }

  void _handleSessionChanged() {
    final timelineLength = _session.timeline.length;
    if (timelineLength <= _lastTimelineLength) {
      _lastTimelineLength = timelineLength;
      return;
    }

    _lastTimelineLength = timelineLength;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) {
        return;
      }
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Color _statusColor(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (_session.phase) {
      ClipboardSyncPagePhase.active => Colors.green,
      ClipboardSyncPagePhase.connecting ||
      ClipboardSyncPagePhase.subscribing ||
      ClipboardSyncPagePhase.reconnecting => Colors.orange,
      ClipboardSyncPagePhase.paused => Theme.of(context).disabledColor,
      ClipboardSyncPagePhase.closing ||
      ClipboardSyncPagePhase.closed => colorScheme.error,
    };
  }

  String _resolvePhaseLabel(BuildContext context) {
    return switch (_session.phase) {
      ClipboardSyncPagePhase.connecting =>
        context.formatString(AppLocale.csPhaseConnecting, []),
      ClipboardSyncPagePhase.subscribing =>
        context.formatString(AppLocale.csPhaseSubscribing, []),
      ClipboardSyncPagePhase.active =>
        _session.transportKind == ClipboardSyncTransportKind.relay
            ? context.formatString(AppLocale.csPhaseActiveRelay, [])
            : context.formatString(AppLocale.csPhaseActiveDirect, []),
      ClipboardSyncPagePhase.reconnecting =>
        context.formatString(AppLocale.csPhaseReconnecting, []),
      ClipboardSyncPagePhase.paused =>
        context.formatString(AppLocale.csPhasePaused, []),
      ClipboardSyncPagePhase.closing =>
        context.formatString(AppLocale.csPhaseStopping, []),
      ClipboardSyncPagePhase.closed =>
        context.formatString(AppLocale.csPhaseClosed, []),
    };
  }

  /// Recursively resolves a [LocaleText] to a localized string.
  ///
  /// Nested [LocaleText] args are resolved before formatting the parent.
  String _resolveLocaleText(BuildContext context, LocaleText text) {
    final resolvedArgs = text.args.map((arg) {
      if (arg is LocaleText) {
        return _resolveLocaleText(context, arg);
      }
      return arg;
    }).toList();
    return context.formatString(text.key, resolvedArgs);
  }
}

class _ShizukuGuideSheet extends StatefulWidget {
  const _ShizukuGuideSheet();

  @override
  State<_ShizukuGuideSheet> createState() => _ShizukuGuideSheetState();
}

class _ShizukuGuideSheetState extends State<_ShizukuGuideSheet> {
  bool _checking = true;
  bool _granting = false;
  String? _statusKey;

  @override
  void initState() {
    super.initState();
    _refreshStatus();
  }

  Future<void> _refreshStatus() async {
    setState(() {
      _checking = true;
      _statusKey = null;
    });
    String? key;
    try {
      final version = await clipboardManager.getShizukuVersion();
      if (version == null) {
        key = AppLocale.csShizukuNotInstalled;
      } else {
        final granted = await clipboardManager.checkPermission(
          EnvironmentType.shizuku,
        );
        key = granted
            ? AppLocale.csShizukuGranted
            : AppLocale.csShizukuNotRunning;
      }
    } catch (_) {
      key = AppLocale.csShizukuNotInstalled;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _checking = false;
      _statusKey = key;
    });
  }

  Future<void> _handleGrant() async {
    setState(() => _granting = true);
    try {
      await clipboardManager.requestPermission(EnvironmentType.shizuku);
    } catch (_) {}
    if (!mounted) {
      return;
    }
    setState(() => _granting = false);
    await _refreshStatus();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.security_rounded,
                    color: colorScheme.primary, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.formatString(AppLocale.csShizukuGuideTitle, []),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              context.formatString(AppLocale.csShizukuGuideStep1, []),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.formatString(AppLocale.csShizukuGuideStep2, []),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.formatString(AppLocale.csShizukuGuideStep3, []),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text(
              context.formatString(AppLocale.csShizukuGuideStep4, []),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            Text(
              context.formatString(AppLocale.csShizukuAdbHint, []),
              style: theme.textTheme.bodySmall?.copyWith(
                color: colorScheme.onSurfaceVariant,
                fontFamily: 'monospace',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _checking
                        ? ''
                        : context.formatString(_statusKey!, []),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.primary,
                    ),
                  ),
                ),
                FilledButton.icon(
                  onPressed: _granting ? null : _handleGrant,
                  icon: _granting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.check_circle_outline, size: 18),
                  label: Text(
                    context.formatString(AppLocale.csShizukuGrant, []),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
