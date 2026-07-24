import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random, min;

import 'package:PiliPlus/services/cdn_score_service.dart';
import 'package:PiliPlus/utils/video_utils.dart';

enum CdnRelayTrack { video, audio }

typedef CdnRelaySwitchCallback =
    void Function(
      CdnRelayTrack track,
      String failedUrl,
      String nextUrl,
    );

typedef CdnRelayRecoveryCallback =
    void Function(CdnRelayTrack track, int offset, String reason);

typedef CdnRelayLogCallback = void Function(String message);

/// A loopback HTTP range relay. The player keeps one stable local URL while
/// upstream byte requests can move between CDN mirrors.
///
/// Once response bytes reach the player, a switch closes that response so mpv
/// retries a fresh Range request against the new CDN without losing its buffer.
class CdnRelayServer {
  CdnRelayServer();

  static final CdnRelayServer shared = CdnRelayServer();

  final Map<String, CdnRelaySession> _sessions = {};
  HttpServer? _server;

  Future<CdnRelaySession> createSession({
    required List<String> videoCandidates,
    required int videoIndex,
    List<String> audioCandidates = const [],
    int audioIndex = 0,
    required Duration cooldown,
    required int maxSwitches,
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
      onSwitch: onSwitch,
      onRecoveryRequired: onRecoveryRequired,
      onLog: onLog,
    );
    _sessions[token] = session;
    return session;
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server
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
    try {
      await session._serve(request, track);
    } catch (_) {
      try {
        request.response.statusCode = HttpStatus.badGateway;
        await request.response.close();
      } catch (_) {
        // Headers may already have been sent before every upstream failed.
      }
    }
  }

  Future<void> close() async {
    for (final session in _sessions.values.toList(growable: false)) {
      await session.dispose();
    }
    final server = _server;
    _server = null;
    await server?.close(force: true);
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
    required int maxSwitches,
    required CdnRelaySwitchCallback? onSwitch,
    required this.onRecoveryRequired,
    required this.onLog,
  }) : _video = _RelayTrackState(
         type: CdnRelayTrack.video,
         candidates: videoCandidates,
         index: videoIndex,
         maxSwitches: maxSwitches,
         cooldown: cooldown,
         onSwitch: onSwitch,
       ),
       _audio = _RelayTrackState(
         type: CdnRelayTrack.audio,
         candidates: audioCandidates,
         index: audioIndex,
         maxSwitches: maxSwitches,
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
  final CdnRelayRecoveryCallback? onRecoveryRequired;
  final CdnRelayLogCallback? onLog;
  final _RelayTrackState _video;
  final _RelayTrackState _audio;
  final _NetworkImpairmentGuard _networkGuard = _NetworkImpairmentGuard();
  final HttpClient _client = HttpClient();
  bool _disposed = false;
  bool _playbackPaused = false;
  Completer<void>? _resumeCompleter;

  bool get isDisposed => _disposed;
  bool get isNetworkSwitchPaused => _networkGuard.isPaused;
  String get videoUrl => _owner._uri(_token, CdnRelayTrack.video).toString();
  String? get audioUrl => _audio.candidates.isEmpty
      ? null
      : _owner._uri(_token, CdnRelayTrack.audio).toString();
  String get currentVideoSource => _video.currentUrl;
  String? get currentAudioSource =>
      _audio.candidates.isEmpty ? null : _audio.currentUrl;

  void setPlaybackPaused(bool paused) {
    if (_disposed || _playbackPaused == paused) return;
    _playbackPaused = paused;
    if (paused) {
      _resumeCompleter = Completer<void>();
      // Wake a pending upstream read so it cannot expire and penalize the CDN
      // while the user intentionally keeps the player paused.
      _video.interrupt();
      _audio.interrupt();
    } else {
      final completer = _resumeCompleter;
      _resumeCompleter = null;
      if (completer != null && !completer.isCompleted) completer.complete();
    }
  }

  Future<void> _waitUntilPlaybackResumes() async {
    while (_playbackPaused && !_disposed) {
      await (_resumeCompleter?.future ?? Future<void>.value());
    }
  }

  void updateSources({
    required List<String> videoCandidates,
    required int videoIndex,
    required List<String> audioCandidates,
    required int audioIndex,
  }) {
    _video.update(videoCandidates, videoIndex);
    _audio.update(audioCandidates, audioIndex);
  }

  bool switchVideo({
    String? expectedUrl,
    String reason = 'buffer-stall',
  }) {
    if (_disposed || _video.candidates.length < 2) return false;
    if (expectedUrl != null && _video.currentUrl != expectedUrl) return true;
    return _switchTrack(
      _video,
      expectedUrl: expectedUrl,
      reason: reason,
    );
  }

  Future<void> _serve(HttpRequest request, CdnRelayTrack type) async {
    final response = request.response;
    final track = type == CdnRelayTrack.video ? _video : _audio;
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

    while (!_disposed && attempts <= track.candidates.length) {
      await _waitUntilPlaybackResumes();
      if (_disposed) break;
      final sourceUrl = track.currentUrl;
      final sourceGeneration = track.generation;
      StreamIterator<List<int>>? iterator;
      var sourceBytes = 0;
      var scoreBytes = 0;
      var networkWait = Duration.zero;
      var countAttempt = true;
      try {
        final openFuture = _openUpstream(
          request: request,
          sourceUrl: sourceUrl,
          range: requestedRange,
        );
        final sourceChanged = Object();
        final openWaiter = track.waitForChange(sourceGeneration);
        late final Object openResult;
        try {
          openResult = await Future.any<Object>([
            openFuture.then<Object>((response) => response),
            openWaiter.future.then<Object>((_) => sourceChanged),
          ]);
        } finally {
          openWaiter.cancel();
        }
        if (identical(openResult, sourceChanged)) {
          unawaited(
            openFuture.then<void>(
              _cancelResponse,
              onError: (Object _, StackTrace _) {},
            ),
          );
          throw const _RelaySourceChanged();
        }
        final upstream = openResult as HttpClientResponse;
        if (_playbackPaused || track.generation != sourceGeneration) {
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
          if (_playbackPaused || track.generation != sourceGeneration) {
            throw const _RelaySourceChanged();
          }
          final stopwatch = Stopwatch()..start();
          final changed = Object();
          final waiter = track.waitForChange(sourceGeneration);
          late final Object readResult;
          try {
            readResult = await Future.any<Object>([
              iterator.moveNext().then<Object>((value) => value),
              waiter.future.then<Object>((_) => changed),
            ]);
          } finally {
            waiter.cancel();
          }
          stopwatch.stop();
          networkWait += stopwatch.elapsed;
          if (identical(readResult, changed)) {
            throw const _RelaySourceChanged();
          }
          final hasNext = readResult as bool;
          if (!hasNext) break;
          final chunk = iterator.current;
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
          if (scoreBytes >= 4 * 1024 * 1024) {
            CdnScoreService.recordSuccess(
              sourceUrl,
              bytes: scoreBytes,
              networkWait: networkWait,
            );
            scoreBytes = 0;
            networkWait = Duration.zero;
          }
        }
        CdnScoreService.recordSuccess(
          sourceUrl,
          bytes: scoreBytes,
          networkWait: networkWait,
        );
        await response.close();
        return;
      } on _RelayDownstreamClosed {
        return;
      } on _RelaySourceChanged {
        countAttempt = !_playbackPaused && sourceUrl != track.currentUrl;
        if (headersSent) {
          await _closeInterruptedResponse(response);
          return;
        }
      } catch (error) {
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
        if (!_switchAfterFailure(type, sourceUrl, reason: reason)) {
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

  bool _switchAfterFailure(
    CdnRelayTrack type,
    String expectedUrl, {
    required String reason,
  }) {
    final track = type == CdnRelayTrack.video ? _video : _audio;
    return _switchTrack(track, expectedUrl: expectedUrl, reason: reason);
  }

  bool _switchTrack(
    _RelayTrackState track, {
    String? expectedUrl,
    required String reason,
  }) {
    final failedUrl = track.currentUrl;
    final switched = track.switchNext(expectedUrl: expectedUrl);
    if (switched && failedUrl != track.currentUrl) {
      _log(
        'switch track=${track.type.name} reason=$reason '
        'from=${_host(failedUrl)} to=${_host(track.currentUrl)} '
        'generation=${track.generation}',
      );
    }
    return switched;
  }

  void _requestRecovery(CdnRelayTrack track, int offset, String reason) {
    _log('rebuild-required track=${track.name} offset=$offset reason=$reason');
    onRecoveryRequired?.call(track, offset, reason);
  }

  void _log(String message) {
    final id = _token.substring(0, min(6, _token.length));
    onLog?.call('AdaptiveCDN relay=$id $message');
  }

  static String _host(String url) => Uri.tryParse(url)?.host ?? url;

  static String _failureReason(Object error) => switch (error) {
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
  }) async {
    final upstreamRequest = await _client.openUrl(
      request.method,
      Uri.parse(sourceUrl),
    );
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
      await upstream.drain<void>();
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

class _RelayTrackState {
  _RelayTrackState({
    required this.type,
    required List<String> candidates,
    required int index,
    required this.maxSwitches,
    required this.cooldown,
    required this.onSwitch,
  }) : candidates = List<String>.of(candidates),
       index = candidates.isEmpty ? 0 : index.clamp(0, candidates.length - 1);

  final CdnRelayTrack type;
  final int maxSwitches;
  final Duration cooldown;
  final CdnRelaySwitchCallback? onSwitch;
  List<String> candidates;
  int index;
  int switches = 0;
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
    switches = 0;
    expectedLength = null;
    failedHosts.clear();
  }

  bool acceptLength(int? length) {
    if (length == null || length <= 0) return true;
    expectedLength ??= length;
    return expectedLength == length;
  }

  bool switchNext({String? expectedUrl}) {
    if (expectedUrl != null && currentUrl != expectedUrl) return true;
    if (candidates.length < 2 || switches >= maxSwitches) return false;
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
      switches += 1;
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
