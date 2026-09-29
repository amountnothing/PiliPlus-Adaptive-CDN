import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, min;
import 'dart:typed_data';

import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/utils/video_utils.dart';

enum CdnRelayTrack { video, audio }

typedef CdnRelaySwitchCallback = void Function(
  CdnRelayTrack track,
  String failedUrl,
  String nextUrl,
);

typedef CdnRelayRecoveryCallback = void Function(
  CdnRelayTrack track,
  int offset,
  String reason,
);

typedef CdnRelayLogCallback = void Function(String message);
typedef CdnRelaySwitchGuard = bool Function();

/// A loopback HTTP range relay. The player keeps one stable local URL while
/// upstream byte requests can move between CDN mirrors.
///
/// Once response bytes reach the player, a switch closes that response so mpv
/// retries a fresh Range request against the new CDN without losing its buffer.
class CdnRelayServer {
  CdnRelayServer({
    Future<bool> Function()? connectivityProbe,
    Duration unreachableSwitchDelay = const Duration(seconds: 5),
    this.upstreamSilenceTimeout = const Duration(seconds: 5),
  }) : _connectivityProbe = connectivityProbe ?? _probePublicDns,
       _offlineSwitchDelay = unreachableSwitchDelay;

  static final CdnRelayServer shared = CdnRelayServer();

  final Map<String, CdnRelaySession> _sessions = {};
  final Future<bool> Function() _connectivityProbe;
  final Duration _offlineSwitchDelay;
  final Duration upstreamSilenceTimeout;
  HttpServer? _server;
  ServerSocket? _listener;
  final Map<int, Stream<void>> _disconnects = {};
  Future<void>? _switchGate;

  Future<void> waitBeforeCdnSwitch() => _switchGate ??= _waitBeforeCdnSwitch()
      .whenComplete(() => _switchGate = null);

  Future<void> _waitBeforeCdnSwitch() async {
    if (await _connectivityProbe()) return;
    await Future<void>.delayed(_offlineSwitchDelay);
  }

  static Future<bool> _probePublicDns() async {
    final reachable = await Future.wait([
      _probeHost('1.1.1.1'),
      _probeHost('223.5.5.5'),
    ]);
    return reachable.any((value) => value);
  }

  static Future<bool> _probeHost(String host) async {
    Socket? socket;
    try {
      socket = await Socket.connect(
        host,
        53,
        timeout: const Duration(milliseconds: 800),
      );
      return true;
    } catch (_) {
      return false;
    } finally {
      socket?.destroy();
    }
  }

  Future<CdnRelaySession> createSession({
    required List<String> videoCandidates,
    required int videoIndex,
    List<String> audioCandidates = const [],
    int audioIndex = 0,
    required Duration cooldown,
    required int maxSwitches,
    int? maxAudioSwitches,
    int initialSwitchCount = 0,
    int initialAudioSwitchCount = 0,
    CdnRelaySwitchCallback? onSwitch,
    CdnRelayRecoveryCallback? onRecoveryRequired,
    CdnRelayLogCallback? onLog,
  }) async {
    await _ensureStarted();
    final token = _newToken();
    final session = CdnRelaySession._(
      this,
      token,
      videoCandidates: videoCandidates,
      videoIndex: videoIndex,
      audioCandidates: audioCandidates,
      audioIndex: audioIndex,
      cooldown: cooldown,
      maxSwitches: maxSwitches,
      maxAudioSwitches: maxAudioSwitches ?? maxSwitches,
      initialSwitchCount: initialSwitchCount,
      initialAudioSwitchCount: initialAudioSwitchCount,
      onSwitch: onSwitch,
      onRecoveryRequired: onRecoveryRequired,
      onLog: onLog,
    );
    _sessions[token] = session;
    return session;
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _listener = listener;
    final server =
        HttpServer.listenOn(
            _RelayServerSocket(listener, (socket) {
              final port = socket.remotePort;
              final observed = _RelaySocket(socket);
              _disconnects[port] = observed.disconnected;
              observed.disconnected.listen(
                null,
                onDone: () {
                  if (identical(_disconnects[port], observed.disconnected)) {
                    _disconnects.remove(port);
                  }
                },
              );
              return observed;
            }),
          )
          ..autoCompress = false
          ..listen(_handleRequest);
    _server = server;
  }

  String _newToken() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(18, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  Uri _uri(String token, CdnRelayTrack track) => Uri(
    scheme: 'http',
    host: InternetAddress.loopbackIPv4.address,
    port: _server!.port,
    pathSegments: ['relay', token, track.name],
  );

  Future<void> _handleRequest(HttpRequest request) async {
    final segments = request.uri.pathSegments;
    if (segments.length != 3 || segments.first != 'relay') {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final session = _sessions[segments[1]];
    final track = switch (segments[2]) {
      'video' => CdnRelayTrack.video,
      'audio' => CdnRelayTrack.audio,
      _ => null,
    };
    if (session == null || track == null || session.isDisposed) {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
      return;
    }
    final disconnected = Completer<void>();
    final subscription = _disconnects[request.connectionInfo?.remotePort]
        ?.listen(
          null,
          onDone: disconnected.complete,
        );
    try {
      await session._serve(request, track, disconnected.future);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // Headers may already have been sent before every upstream failed.
      }
    } finally {
      // A keepalive socket can serve many ranges. Do not retain completed
      // request closures until that socket eventually disconnects.
      await subscription?.cancel();
    }
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList(growable: false)) {
      await session.dispose();
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
    await _listener?.close();
    _listener = null;
  }
}

class CdnRelaySession {
  CdnRelaySession._(
    this._owner,
    this._token, {
    required List<String> videoCandidates,
    required int videoIndex,
    required List<String> audioCandidates,
    required int audioIndex,
    required Duration cooldown,
    required this.maxSwitches,
    required this.maxAudioSwitches,
    required int initialSwitchCount,
    required int initialAudioSwitchCount,
    required CdnRelaySwitchCallback? onSwitch,
    required this.onRecoveryRequired,
    required this.onLog,
  }) : _videoSwitches = initialSwitchCount < 0
           ? 0
           : initialSwitchCount > maxSwitches
           ? maxSwitches
           : initialSwitchCount,
       _audioSwitches = initialAudioSwitchCount < 0
           ? 0
           : initialAudioSwitchCount > maxAudioSwitches
           ? maxAudioSwitches
           : initialAudioSwitchCount,
       _video = _RelayTrackState(
         type: CdnRelayTrack.video,
         candidates: videoCandidates,
         index: videoIndex,
         cooldown: cooldown,
         onSwitch: onSwitch,
       ),
       _audio = _RelayTrackState(
         type: CdnRelayTrack.audio,
         candidates: audioCandidates,
         index: audioIndex,
         cooldown: cooldown,
         onSwitch: onSwitch,
       ) {
    _client.autoUncompress = false;
    _log(
      'session video=${_video.candidates.isEmpty ? '-' : _host(_video.currentUrl)} '
      'audio=${_audio.candidates.isEmpty ? '-' : _host(_audio.currentUrl)} '
      'candidates=${_video.candidates.length}/${_audio.candidates.length}',
    );
  }

  final CdnRelayServer _owner;
  final String _token;
  CdnRelayRecoveryCallback? onRecoveryRequired;
  CdnRelayLogCallback? onLog;
  final _RelayTrackState _video;
  final _RelayTrackState _audio;
  final _NetworkImpairmentGuard _networkGuard = _NetworkImpairmentGuard();
  final HttpClient _client = HttpClient();
  final int maxSwitches;
  final int maxAudioSwitches;
  int _videoSwitches;
  int _audioSwitches;
  bool _disposed = false;
  bool _retired = false;
  bool _playbackPaused = false;
  Completer<void>? _resumeCompleter;
  final Set<void Function()> _pauseListeners = {};

  bool get isDisposed => _disposed;
  int get switchCount => _videoSwitches;
  int get audioSwitchCount => _audioSwitches;
  int get remainingSwitches =>
      _videoSwitches >= maxSwitches ? 0 : maxSwitches - _videoSwitches;
  int get remainingAudioSwitches => _audioSwitches >= maxAudioSwitches
      ? 0
      : maxAudioSwitches - _audioSwitches;
  bool get isNetworkSwitchPaused => _networkGuard.isPaused;
  String get videoUrl => _owner._uri(_token, CdnRelayTrack.video).toString();
  String? get audioUrl => _audio.candidates.isEmpty
      ? null
      : _owner._uri(_token, CdnRelayTrack.audio).toString();
  String get currentVideoSource => _video.currentUrl;
  String? get currentAudioSource =>
      _audio.candidates.isEmpty ? null : _audio.currentUrl;

  void retire() {
    if (_retired) return;
    _retired = true;
    onRecoveryRequired = null;
    onLog = null;
    _video.onSwitch = null;
    _audio.onSwitch = null;
  }

  void setPlaybackPaused(bool paused) {
    if (_disposed || _playbackPaused == paused) return;
    _playbackPaused = paused;
    if (paused) {
      _resumeCompleter = Completer<void>();
      // Keep the active Range response and its exact byte position alive. The
      // read loop stops requesting chunks after at most the in-flight chunk,
      // so Dart/MPV backpressure stops upstream traffic without forcing MPV to
      // discover a prematurely closed response when playback resumes.
    } else {
      final completer = _resumeCompleter;
      _resumeCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
    for (final listener in _pauseListeners.toList()) {
      listener();
    }
  }

  // Only arm this while awaiting upstream IO, never while flushing to MPV.
  // Pauses discard elapsed silence and resume with a fresh observation window.
  Future<T> _waitForUpstream<T>(Future<T> future) async {
    final timeout = Completer<T>();
    Timer? timer;
    void updateTimer() {
      timer?.cancel();
      if (!_playbackPaused && !_disposed) {
        timer = Timer(_owner.upstreamSilenceTimeout, () {
          if (!timeout.isCompleted) {
            timeout.completeError(TimeoutException('Upstream silence'));
          }
        });
      }
    }

    _pauseListeners.add(updateTimer);
    updateTimer();
    try {
      return await Future.any([future, timeout.future]);
    } finally {
      timer?.cancel();
      _pauseListeners.remove(updateTimer);
    }
  }

  Future<bool> _waitUntilPlaybackResumes(Future<Object> downstreamDone) async {
    while (_playbackPaused && !_disposed) {
      final result = await Future.any<Object?>([
        _resumeCompleter?.future ?? Future<void>.value(),
        downstreamDone,
      ]);
      if (result is _RelayDownstreamClosed) return false;
    }
    return true;
  }

  void updateSources({
    required List<String> videoCandidates,
    required int videoIndex,
    required List<String> audioCandidates,
    required int audioIndex,
  }) {
    if (_disposed || _retired) return;
    _video.update(videoCandidates, videoIndex);
    _audio.update(audioCandidates, audioIndex);
  }

  Future<bool> switchVideo({
    String? expectedUrl,
    String reason = 'buffer-stall',
    CdnRelaySwitchGuard? canSwitch,
  }) async {
    if (_disposed || _retired || _video.candidates.length < 2) return false;
    if (expectedUrl != null && _video.currentUrl != expectedUrl) return true;
    return _switchTrack(
      _video,
      expectedUrl: expectedUrl,
      reason: reason,
      canSwitch: canSwitch,
    );
  }

  Future<void> _serve(
    HttpRequest request,
    CdnRelayTrack type,
    Future<void>? disconnected,
  ) async {
    final response = request.response;
    final track = type == CdnRelayTrack.video ? _video : _audio;
    // A retired relay no longer switches or reports callbacks, but it remains
    // readable until its short grace period ends. MPV can issue one final
    // Range request while the replacement source is taking ownership.
    if (_disposed || track.candidates.isEmpty) {
      response.statusCode = HttpStatus.notFound;
      await response.close();
      return;
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      response.statusCode = HttpStatus.methodNotAllowed;
      await response.close();
      return;
    }

    final requestedRange = request.headers.value(HttpHeaders.rangeHeader);
    final parsedRange = _ByteRange.tryParse(requestedRange);
    if (requestedRange != null && parsedRange == null) {
      response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
      await response.close();
      return;
    }

    var attempts = 0;
    var headersSent = false;
    var responseStart = parsedRange?.start ?? 0;
    var deliveredBytes = 0;
    var downstreamClosed = false;
    final downstreamDone =
        Future.any<void>([
          response.done.then<void>((_) {}),
          ?disconnected,
        ]).then<Object>(
          (_) {
            downstreamClosed = true;
            return const _RelayDownstreamClosed();
          },
          onError: (Object _, StackTrace _) {
            downstreamClosed = true;
            return const _RelayDownstreamClosed();
          },
        );

    while (!_disposed && attempts <= track.candidates.length) {
      if (!await _waitUntilPlaybackResumes(downstreamDone)) return;
      if (_disposed) break;
      final sourceUrl = track.currentUrl;
      final sourceGeneration = track.generation;
      StreamIterator<List<int>>? iterator;
      HttpClientRequest? activeRequest;
      var attemptEnded = false;
      var sourceBytes = 0;
      var scoreBytes = 0;
      var networkWait = Duration.zero;
      var countAttempt = true;
      try {
        final openFuture = _openUpstream(
          request: request,
          sourceUrl: sourceUrl,
          range: requestedRange,
          onRequest: (upstreamRequest) {
            activeRequest = upstreamRequest;
            if (attemptEnded) upstreamRequest.abort();
          },
        );
        final sourceChanged = Object();
        final openWaiter = track.waitForChange(sourceGeneration);
        late final Object openResult;
        try {
          openResult = await _waitForUpstream(
            Future.any<Object>([
              openFuture.then<Object>((response) => response),
              openWaiter.future.then<Object>((_) => sourceChanged),
              downstreamDone,
            ]),
          );
        } catch (_) {
          unawaited(
            openFuture.then<void>(
              _cancelResponse,
              onError: (Object _, StackTrace _) {},
            ),
          );
          rethrow;
        } finally {
          openWaiter.cancel();
        }
        if (identical(openResult, sourceChanged) ||
            openResult is _RelayDownstreamClosed) {
          unawaited(
            openFuture.then<void>(
              _cancelResponse,
              onError: (Object _, StackTrace _) {},
            ),
          );
          if (openResult is _RelayDownstreamClosed) throw openResult;
          throw const _RelaySourceChanged();
        }
        final upstream = openResult as HttpClientResponse;
        if (track.generation != sourceGeneration) {
          await _cancelResponse(upstream);
          throw const _RelaySourceChanged();
        }

        final contentRange = _ContentRange.tryParse(
          upstream.headers.value(HttpHeaders.contentRangeHeader),
        );
        if (requestedRange != null &&
            (upstream.statusCode != HttpStatus.partialContent ||
                (parsedRange?.start != null &&
                    contentRange?.start != parsedRange!.start))) {
          await _cancelResponse(upstream);
          throw const _RelaySourceMismatch();
        }
        final absoluteStart = contentRange?.start ?? 0;
        final expectedResponseBytes = contentRange == null
            ? (upstream.contentLength >= 0 ? upstream.contentLength : null)
            : contentRange.end - contentRange.start + 1;
        final totalLength =
            contentRange?.total ??
            (upstream.contentLength >= 0
                ? absoluteStart + upstream.contentLength
                : null);
        if (!track.acceptLength(totalLength)) {
          await _cancelResponse(upstream);
          throw const _RelaySourceMismatch();
        }

        if (!headersSent) {
          responseStart = absoluteStart;
          _copyResponseHeaders(upstream, response);
          headersSent = true;
          if (request.method == 'HEAD') {
            await upstream.drain<void>();
            await response.close();
            return;
          }
        }

        iterator = StreamIterator<List<int>>(upstream);
        while (true) {
          if (!await _waitUntilPlaybackResumes(downstreamDone)) return;
          if (_disposed) {
            await _closeInterruptedResponse(response);
            return;
          }
          if (track.generation != sourceGeneration) {
            throw const _RelaySourceChanged();
          }
          final stopwatch = Stopwatch()..start();
          final changed = Object();
          final waiter = track.waitForChange(sourceGeneration);
          late final Object readResult;
          try {
            readResult = await _waitForUpstream(
              Future.any<Object>([
                iterator.moveNext().then<Object>((value) => value),
                waiter.future.then<Object>((_) => changed),
                downstreamDone,
              ]),
            );
          } finally {
            waiter.cancel();
          }
          stopwatch.stop();
          networkWait += stopwatch.elapsed;
          if (readResult is _RelayDownstreamClosed) throw readResult;
          if (identical(readResult, changed)) {
            throw const _RelaySourceChanged();
          }
          final hasNext = readResult as bool;
          if (!hasNext) break;
          final chunk = iterator.current;
          // A pause can arrive while moveNext is waiting on the network. Hold
          // that single chunk and resume the same response instead of closing
          // it and requiring a new Range request.
          if (!await _waitUntilPlaybackResumes(downstreamDone)) return;
          if (_disposed) {
            await _closeInterruptedResponse(response);
            return;
          }
          if (track.generation != sourceGeneration) {
            throw const _RelaySourceChanged();
          }
          sourceBytes += chunk.length;
          scoreBytes += chunk.length;
          try {
            response.add(chunk);
            // Respect mpv backpressure. A blocked local client is not a CDN
            // failure and must not change the selected upstream.
            await response.flush();
          } catch (_) {
            throw const _RelayDownstreamClosed();
          }
          deliveredBytes += chunk.length;
          if (track.currentUrl != sourceUrl) {
            throw const _RelaySourceChanged();
          }
          if (!_retired && scoreBytes >= 4 * 1024 * 1024) {
            CdnScoreService.recordSuccess(
              sourceUrl,
              bytes: scoreBytes,
              networkWait: networkWait,
            );
            scoreBytes = 0;
            networkWait = Duration.zero;
          }
        }
        if (expectedResponseBytes != null &&
            sourceBytes < expectedResponseBytes) {
          throw HttpException(
            'Upstream response ended early: received $sourceBytes of '
            '$expectedResponseBytes bytes',
            uri: Uri.parse(sourceUrl),
          );
        }
        if (!_retired) {
          CdnScoreService.recordSuccess(
            sourceUrl,
            bytes: scoreBytes,
            networkWait: networkWait,
          );
        }
        await response.close();
        return;
      } on _RelayDownstreamClosed {
        return;
      } on _RelaySourceChanged {
        countAttempt = sourceUrl != track.currentUrl;
        if (headersSent) {
          await _closeInterruptedResponse(response);
          return;
        }
      } catch (error) {
        if (_disposed || downstreamClosed) return;
        if (track.generation != sourceGeneration) {
          if (headersSent) {
            await _closeInterruptedResponse(response);
            return;
          }
          continue;
        }
        if (_playbackPaused) {
          // A connection may independently expire while held by an explicit
          // pause. Do not score or switch the CDN for that pause-side failure.
          countAttempt = false;
          if (!await _waitUntilPlaybackResumes(downstreamDone)) return;
          if (headersSent) {
            await _closeInterruptedResponse(response);
            return;
          }
          continue;
        }
        if (_retired) {
          if (headersSent) {
            await _closeInterruptedResponse(response);
            return;
          }
          response.statusCode = HttpStatus.badGateway;
          await response.close();
          return;
        }
        final mismatch = error is _RelaySourceMismatch;
        final reason = mismatch ? 'source-mismatch' : _failureReason(error);
        if (!mismatch &&
            _networkGuard.shouldPauseAfterFailure(
              type: type,
              url: sourceUrl,
              bytes: sourceBytes,
            )) {
          _log('network-guard track=${type.name} reason=$reason');
          if (headersSent) {
            await _closeInterruptedResponse(response);
            return;
          }
          rethrow;
        }
        bool canSwitch() =>
            !downstreamClosed && track.generation == sourceGeneration;
        if (!await _switchAfterFailure(
          type,
          sourceUrl,
          reason: reason,
          canSwitch: canSwitch,
        )) {
          if (_disposed || downstreamClosed) return;
          if (_playbackPaused || track.generation != sourceGeneration) {
            if (headersSent) {
              await _closeInterruptedResponse(response);
              return;
            }
            continue;
          }
          if (headersSent) {
            _requestRecovery(type, responseStart + deliveredBytes, reason);
            await _closeInterruptedResponse(response);
            return;
          }
          rethrow;
        }
        if (headersSent) {
          await _closeInterruptedResponse(response);
          return;
        }
      } finally {
        attemptEnded = true;
        activeRequest?.abort();
        await iterator?.cancel();
      }
      if (countAttempt) attempts += 1;
    }

    if (_disposed) {
      await _closeInterruptedResponse(response);
      return;
    }
    if (!headersSent) {
      response.statusCode = HttpStatus.badGateway;
    } else {
      _requestRecovery(
        type,
        responseStart + deliveredBytes,
        'attempts-exhausted',
      );
    }
    try {
      await response.close();
    } catch (_) {}
  }

  Future<bool> _switchAfterFailure(
    CdnRelayTrack type,
    String expectedUrl, {
    required String reason,
    required CdnRelaySwitchGuard canSwitch,
  }) {
    final track = type == CdnRelayTrack.video ? _video : _audio;
    return _switchTrack(
      track,
      expectedUrl: expectedUrl,
      reason: reason,
      canSwitch: canSwitch,
    );
  }

  Future<bool> _switchTrack(
    _RelayTrackState track, {
    String? expectedUrl,
    required String reason,
    CdnRelaySwitchGuard? canSwitch,
  }) async {
    if (_disposed ||
        _retired ||
        _playbackPaused ||
        _switchesFor(track.type) >= _maxSwitchesFor(track.type) ||
        (canSwitch != null && !canSwitch())) {
      return false;
    }
    await _owner.waitBeforeCdnSwitch();
    if (_disposed ||
        _retired ||
        _playbackPaused ||
        _switchesFor(track.type) >= _maxSwitchesFor(track.type) ||
        (canSwitch != null && !canSwitch())) {
      return false;
    }
    final failedUrl = track.currentUrl;
    final switched = track.switchNext(expectedUrl: expectedUrl);
    if (switched && failedUrl != track.currentUrl) {
      _incrementSwitches(track.type);
      if (track.type == CdnRelayTrack.video && _audio.candidates.isNotEmpty) {
        // Every video failover (controller-driven or Relay-detected) must
        // restart the paired audio Range. This keeps both EDL streams attached
        // to one timeline without changing or penalizing the healthy audio CDN.
        _audio.interrupt();
      }
      _log(
        'switch track=${track.type.name} reason=$reason '
        'from=${_host(failedUrl)} to=${_host(track.currentUrl)} '
        'generation=${track.generation}',
      );
    }
    return switched;
  }

  int _switchesFor(CdnRelayTrack track) =>
      track == CdnRelayTrack.video ? _videoSwitches : _audioSwitches;

  int _maxSwitchesFor(CdnRelayTrack track) =>
      track == CdnRelayTrack.video ? maxSwitches : maxAudioSwitches;

  void _incrementSwitches(CdnRelayTrack track) {
    if (track == CdnRelayTrack.video) {
      _videoSwitches += 1;
    } else {
      _audioSwitches += 1;
    }
  }

  void _requestRecovery(CdnRelayTrack track, int offset, String reason) {
    if (_retired) return;
    _log('rebuild-required track=${track.name} offset=$offset reason=$reason');
    onRecoveryRequired?.call(track, offset, reason);
  }

  void _log(String message) {
    final id = _token.substring(0, min(6, _token.length));
    onLog?.call('AdaptiveCDN relay=$id $message');
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  static String _failureReason(Object error) => switch (error) {
    TimeoutException() => 'upstream-silence',
    SocketException() => 'socket-error',
    HttpException() => 'http-error',
    _ => error.runtimeType.toString(),
  };

  static Future<void> _cancelResponse(HttpClientResponse response) async {
    final subscription = response.listen(null);
    await subscription.cancel();
  }

  static Future<void> _closeInterruptedResponse(HttpResponse response) async {
    try {
      final socket = await response.detachSocket();
      socket.destroy();
    } catch (_) {
      try {
        await response.close();
      } catch (_) {}
    }
  }

  Future<HttpClientResponse> _openUpstream({
    required HttpRequest request,
    required String sourceUrl,
    required String? range,
    required void Function(HttpClientRequest) onRequest,
  }) async {
    final upstreamRequest = await _client.openUrl(
      request.method,
      Uri.parse(sourceUrl),
    );
    onRequest(upstreamRequest);
    upstreamRequest
      ..followRedirects = true
      ..maxRedirects = 8
      ..headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
    for (final header in const [
      HttpHeaders.userAgentHeader,
      HttpHeaders.refererHeader,
      'origin',
      HttpHeaders.cookieHeader,
    ]) {
      final value = request.headers.value(header);
      if (value != null) upstreamRequest.headers.set(header, value);
    }

    if (range != null) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, range);
    }

    final upstream = await upstreamRequest.close();
    if (upstream.statusCode != HttpStatus.ok &&
        upstream.statusCode != HttpStatus.partialContent) {
      await _cancelResponse(upstream);
      throw HttpException(
        'CDN returned HTTP ${upstream.statusCode}',
        uri: Uri.parse(sourceUrl),
      );
    }
    return upstream;
  }

  static void _copyResponseHeaders(
    HttpClientResponse upstream,
    HttpResponse downstream,
  ) {
    downstream.statusCode = upstream.statusCode;
    downstream.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
    for (final header in const [
      HttpHeaders.contentTypeHeader,
      HttpHeaders.contentRangeHeader,
      HttpHeaders.etagHeader,
      HttpHeaders.lastModifiedHeader,
    ]) {
      final value = upstream.headers.value(header);
      if (value != null) downstream.headers.set(header, value);
    }
    if (upstream.contentLength >= 0) {
      downstream.contentLength = upstream.contentLength;
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    final resumeCompleter = _resumeCompleter;
    _resumeCompleter = null;
    if (resumeCompleter != null && !resumeCompleter.isCompleted) {
      resumeCompleter.complete();
    }
    _video.interrupt();
    _audio.interrupt();
    _owner._sessions.remove(_token);
    _client.close(force: true);
  }
}

// dart:io pauses HTTP request parsing while a response is active. Observe the
// socket input independently so a player FIN is visible even during CDN silence.
// Only request bytes are buffered here (never media), with a hard 64 KiB cap.
class _RelaySocket extends Stream<Uint8List> implements Socket {
  _RelaySocket(this._socket) {
    _input = StreamController<Uint8List>(
      sync: true,
      onResume: () => _queuedBytes = 0,
      onCancel: destroy,
    );
    _subscription = _socket.listen(
      (data) {
        if (_input.isPaused || !_input.hasListener) {
          _queuedBytes += data.length;
          if (_queuedBytes > 64 * 1024) {
            destroy();
            return;
          }
        }
        _input.add(data);
      },
      onError: (Object error, StackTrace stack) {
        _input.addError(error, stack);
        destroy();
      },
      onDone: destroy,
    );
  }

  final Socket _socket;
  final _disconnected = StreamController<void>.broadcast();
  bool _destroyed = false;
  late final StreamController<Uint8List> _input;
  late final StreamSubscription<Uint8List> _subscription;
  int _queuedBytes = 0;
  Stream<void> get disconnected => _disconnected.stream;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _input.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    unawaited(_disconnected.close());
    _socket.destroy();
    unawaited(_subscription.cancel());
    unawaited(_input.close());
  }

  @override
  InternetAddress get address => _socket.address;
  @override
  InternetAddress get remoteAddress => _socket.remoteAddress;
  @override
  int get port => _socket.port;
  @override
  int get remotePort => _socket.remotePort;
  @override
  Encoding get encoding => _socket.encoding;
  @override
  set encoding(Encoding value) => _socket.encoding = value;
  @override
  Future<void> get done => _socket.done;
  @override
  void add(List<int> data) => _socket.add(data);
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _socket.addError(error, stackTrace);
  @override
  Future<void> addStream(Stream<List<int>> stream) => _socket.addStream(stream);
  @override
  Future<void> flush() => _socket.flush();
  @override
  Future<void> close() async {
    try {
      await _socket.close();
    } finally {
      destroy();
    }
  }

  @override
  void write(Object? object) => _socket.write(object);
  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _socket.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _socket.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _socket.writeln(object);
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _socket.setOption(option, enabled);
  @override
  void setRawOption(RawSocketOption option) => _socket.setRawOption(option);
  @override
  Uint8List getRawOption(RawSocketOption option) =>
      _socket.getRawOption(option);
}

class _RelayServerSocket extends Stream<Socket> implements ServerSocket {
  _RelayServerSocket(this._server, this._observe);
  final ServerSocket _server;
  final Socket Function(Socket) _observe;
  @override
  InternetAddress get address => _server.address;
  @override
  int get port => _server.port;
  @override
  Future<ServerSocket> close() => _server.close();
  @override
  StreamSubscription<Socket> listen(
    void Function(Socket)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _server
      .map(_observe)
      .listen(
        onData,
        onError: onError,
        onDone: onDone,
        cancelOnError: cancelOnError,
      );
}

class _RelayTrackState {
  _RelayTrackState({
    required this.type,
    required List<String> candidates,
    required int index,
    required this.cooldown,
    required this.onSwitch,
  }) : candidates = List<String>.of(candidates),
       index = candidates.isEmpty ? 0 : index.clamp(0, candidates.length - 1);

  final CdnRelayTrack type;
  final Duration cooldown;
  CdnRelaySwitchCallback? onSwitch;
  List<String> candidates;
  int index;
  int generation = 0;
  int? expectedLength;
  final Set<String> failedHosts = {};
  final Set<Completer<void>> _changeWaiters = {};

  String get currentUrl => candidates[index];

  void update(List<String> nextCandidates, int nextIndex) {
    if (candidates.isEmpty && nextCandidates.isEmpty) return;
    final nextUrl = nextCandidates.isEmpty
        ? null
        : nextCandidates[nextIndex.clamp(0, nextCandidates.length - 1)];
    final current = candidates.isEmpty ? null : currentUrl;
    final sameCandidates =
        candidates.length == nextCandidates.length &&
        candidates.every(nextCandidates.contains);
    if (sameCandidates && nextUrl == current) {
      candidates = List<String>.of(nextCandidates);
      index = candidates.indexOf(nextUrl!);
      return;
    }
    _notifyChanged();
    candidates = List<String>.of(nextCandidates);
    index = candidates.isEmpty ? 0 : nextIndex.clamp(0, candidates.length - 1);
    expectedLength = null;
  }

  bool acceptLength(int? length) {
    if (length == null || length <= 0) return true;
    expectedLength ??= length;
    return expectedLength == length;
  }

  bool switchNext({String? expectedUrl}) {
    if (expectedUrl != null && currentUrl != expectedUrl) return true;
    if (candidates.length < 2) return false;
    final failedUrl = currentUrl;
    final failedHost = VideoUtils.cdnHost(failedUrl);
    if (failedHost != null) failedHosts.add(failedHost);
    VideoUtils.markCdnFailed(failedUrl, cooldown: cooldown);
    CdnScoreService.recordFailure(failedUrl);

    for (final next in CdnScoreService.rankCandidates(candidates)) {
      if (next == failedUrl) continue;
      final host = VideoUtils.cdnHost(next);
      if (host != null && failedHosts.contains(host)) continue;
      if (VideoUtils.isCdnCoolingDown(next)) continue;
      index = candidates.indexOf(next);
      _notifyChanged();
      onSwitch?.call(type, failedUrl, next);
      return true;
    }
    return false;
  }

  _TrackChangeWaiter waitForChange(int observedGeneration) {
    final completer = Completer<void>();
    if (observedGeneration != generation) {
      completer.complete();
    } else {
      _changeWaiters.add(completer);
    }
    return _TrackChangeWaiter(this, completer);
  }

  void interrupt() => _notifyChanged();

  void _notifyChanged() {
    generation += 1;
    for (final waiter in _changeWaiters) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _changeWaiters.clear();
  }
}

class _TrackChangeWaiter {
  const _TrackChangeWaiter(this.owner, this.completer);

  final _RelayTrackState owner;
  final Completer<void> completer;

  Future<void> get future => completer.future;
  void cancel() => owner._changeWaiters.remove(completer);
}

class _NetworkFailureSample {
  const _NetworkFailureSample({
    required this.at,
    required this.host,
    required this.type,
  });

  final DateTime at;
  final String? host;
  final CdnRelayTrack type;
}

class _NetworkImpairmentGuard {
  static const _sampleWindow = Duration(seconds: 15);
  static const _pauseDuration = Duration(seconds: 20);
  static const _nearZeroBytes = 64 * 1024;

  final Queue<_NetworkFailureSample> _samples = Queue();
  DateTime _pauseUntil = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isPaused => DateTime.now().isBefore(_pauseUntil);

  bool shouldPauseAfterFailure({
    required CdnRelayTrack type,
    required String url,
    required int bytes,
  }) {
    final now = DateTime.now();
    if (now.isBefore(_pauseUntil)) return true;
    if (bytes >= _nearZeroBytes) {
      _samples.clear();
      return false;
    }

    final threshold = now.subtract(_sampleWindow);
    while (_samples.isNotEmpty && _samples.first.at.isBefore(threshold)) {
      _samples.removeFirst();
    }

    _samples.add(
      _NetworkFailureSample(
        at: now,
        host: VideoUtils.cdnHost(url),
        type: type,
      ),
    );

    final hosts = <String>{};
    final tracks = <CdnRelayTrack>{};
    for (final sample in _samples) {
      final host = sample.host;
      if (host != null) hosts.add(host);
      tracks.add(sample.type);
    }

    final looksGlobal =
        _samples.length >= 3 &&
        (_samples.length >= 4 || hosts.length >= 2 || tracks.length >= 2);
    if (!looksGlobal) return false;

    _samples.clear();
    _pauseUntil = now.add(_pauseDuration);
    return true;
  }
}

class _ByteRange {
  const _ByteRange(this.start, this.end);

  final int? start;
  final int? end;

  static _ByteRange? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value.trim());
    if (match == null) return null;
    final start = int.tryParse(match.group(1)!);
    final end = int.tryParse(match.group(2)!);
    if (start == null && end == null) return null;
    if (start != null && end != null && end < start) return null;
    return _ByteRange(start, end);
  }
}

class _ContentRange {
  const _ContentRange(this.start, this.end, this.total);

  final int start;
  final int end;
  final int? total;

  static _ContentRange? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null) return null;
    return _ContentRange(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      match.group(3) == '*' ? null : int.parse(match.group(3)!),
    );
  }
}

class _RelaySourceChanged implements Exception {
  const _RelaySourceChanged();
}

class _RelaySourceMismatch implements Exception {
  const _RelaySourceMismatch();
}

class _RelayDownstreamClosed implements Exception {
  const _RelayDownstreamClosed();
}
