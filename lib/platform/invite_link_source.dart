import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/config/app_config.dart';
import '../state/app_state.dart';

/// The small native/web input adapter used by the invite flow.
///
/// Supabase also owns an [AppLinks] listener for auth callbacks.  This class
/// deliberately listens to the same broadcast source and forwards every URI
/// to the controller; the controller's strict parser decides whether it is an
/// invite or an auth/recovery URI.  Keeping the source dumb avoids duplicating
/// token validation (and, importantly, avoids logging or displaying a token).
///
/// [main] attaches the source only after `Supabase.initialize` has completed,
/// so the auth observer gets first ownership of callback setup.  The source
/// then performs its own `getInitialLink` probe for a cold invite.  A cold URI
/// can still arrive before the provider tree exists; such URIs are held in a
/// short in-memory queue until [InviteLinkBinding] attaches the controller.
/// The queue contains URI objects only and is never persisted.
class InviteLinkSource {
  factory InviteLinkSource({
    AppLinks? appLinks,
    Stream<Uri>? linkStream,
    Future<Uri?> Function()? initialLink,
  }) => InviteLinkSource._(appLinks ?? AppLinks(), linkStream, initialLink);

  InviteLinkSource._(this._appLinks, this._linkStream, this._initialLink);

  final AppLinks _appLinks;
  final Stream<Uri>? _linkStream;
  final Future<Uri?> Function()? _initialLink;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();
  final List<Uri> _buffer = <Uri>[];
  final Map<String, DateTime> _seen = <String, DateTime>{};
  StreamSubscription<Uri>? _subscription;
  bool _started = false;
  bool _disposed = false;

  Stream<Uri> get stream => _controller.stream;

  /// Start listening once.  It is safe to call this from tests and from the
  /// app bootstrap more than once.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    final source = _linkStream ?? _appLinks.uriLinkStream;
    _subscription = source.listen(_publish, onError: _ignoreError);
    unawaited(_readInitialLink());
  }

  /// Remove cold-start values that arrived before a controller listener was
  /// attached.  Call this immediately after `bindInviteLinkStream` so that a
  /// new warm event cannot be mistaken for an initial event.
  List<Uri> takeBuffered() {
    if (_buffer.isEmpty) return const <Uri>[];
    final result = List<Uri>.unmodifiable(_buffer);
    _buffer.clear();
    return result;
  }

  Future<void> _readInitialLink() async {
    try {
      final link = await (_initialLink ?? _appLinks.getInitialLink)();
      if (link != null) _publish(link);
    } catch (_) {
      // A missing initial link is expected on ordinary launches.  Auth and
      // invite errors are handled by their own controllers once a URI exists;
      // never surface plugin/provider details from this best-effort probe.
    }
  }

  void _publish(Uri link) {
    if (_disposed) return;
    // AppLinks can report the same URI through both the initial probe and the
    // stream.  Keep a bounded in-memory dedupe set; URI strings never leave
    // this process and are not written to logs or analytics.
    final key = link.toString();
    final now = DateTime.now();
    final previous = _seen[key];
    // Initial-link and stream deliveries are normally adjacent.  Keep the
    // suppression window short so opening the same invite again after a user
    // cancels remains a valid action in the same process.
    if (previous != null &&
        now.difference(previous) < const Duration(seconds: 2)) {
      return;
    }
    _seen[key] = now;
    if (_seen.length > 32) {
      final oldest = _seen.entries.reduce(
        (left, right) => left.value.isBefore(right.value) ? left : right,
      );
      _seen.remove(oldest.key);
    }
    if (_controller.hasListener) {
      _controller.add(link);
    } else {
      _buffer.add(link);
      if (_buffer.length > 8) _buffer.removeAt(0);
    }
  }

  void _ignoreError(Object error, StackTrace stackTrace) {
    // A platform link stream can close during app shutdown.  Do not expose
    // plugin/provider errors to users or accidentally include URI data.
    // Keep the callback typed to match Stream.listen while intentionally
    // discarding both values. The analyzer does not warn for intentionally
    // unused callback parameters here.
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription?.cancel();
    _subscription = null;
    // Do not wait for a consumer that may intentionally keep the binding
    // alive until widget teardown; closing the broadcast stream still sends
    // its done event when that consumer eventually cancels.
    unawaited(_controller.close());
    _buffer.clear();
    _seen.clear();
  }
}

/// Establishes the Supabase/auth callback observer before attaching the
/// passive invite source.  The source starts in `finally` so a failed remote
/// initialization cannot lose a native cold link; [initialize] remains the
/// caller's responsibility for reporting its stable, token-free error.
///
/// Keeping this tiny lifecycle seam injectable allows tests to prove ordering
/// without invoking the process-global Supabase initializer.
Future<void> initializeBeforeInviteSource({
  required Future<void> Function() initialize,
  required void Function() startInviteSource,
}) async {
  try {
    await initialize();
  } finally {
    startInviteSource();
  }
}

/// Binds the early source to the Riverpod controller once the widget tree has
/// created the controller.  Keeping this as a widget makes the bootstrap
/// dependency injectable in tests without changing the auth/repository API.
class InviteLinkBinding extends ConsumerStatefulWidget {
  const InviteLinkBinding({
    required this.source,
    required this.child,
    this.config,
    this.isRelease = kReleaseMode,
    super.key,
  });

  final InviteLinkSource source;
  final Widget child;
  final AppConfig? config;
  final bool isRelease;

  @override
  ConsumerState<InviteLinkBinding> createState() => _InviteLinkBindingState();
}

class _InviteLinkBindingState extends ConsumerState<InviteLinkBinding> {
  @override
  void initState() {
    super.initState();
    final controller = ref.read(plannerControllerProvider);
    controller.bindInviteLinkStream(
      widget.source.stream,
      config: widget.config,
      isRelease: widget.isRelease,
    );
    for (final uri in widget.source.takeBuffered()) {
      controller.captureInviteUri(
        uri,
        config: widget.config ?? AppConfig.fromEnvironment(),
        isRelease: widget.isRelease,
      );
    }
  }

  @override
  void dispose() {
    // The source belongs to the app bootstrap, not to this short-lived
    // binding widget.  main disposes it when the process is torn down.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
