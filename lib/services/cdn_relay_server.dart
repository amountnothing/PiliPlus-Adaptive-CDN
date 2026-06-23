import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:PiliPlus/utils/video_utils.dart';

enum CdnRelayTrack { video, audio }

typedef CdnRelaySwitchCallback =
    void Function(
      CdnRelayTrack track,
      String failedUrl,
      String nextUrl,
    );

/// A loopback HTTP range relay. The player keeps one stable local URL while
/// upstream byte requests can move between byte-identical CDN mirrors.
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
    required Duration stallTimeout,
    required Duration cooldown,
    required int maxSwitches,
    CdnRelaySwitchCallback? onSwitch,
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
      stallTimeout: stallTimeout,
      cooldown: cooldown,
      maxSwitches: maxSwitches,
      onSwitch: onSwitch,
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
    required this.stallTimeout,
    required Duration cooldown,
    required int maxSwitches,
    required CdnRelaySwitchCallback? onSwitch,
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
    _client
      ..autoUncompress = false
      ..connectionTimeout = stallTimeout;
  }

  final CdnRelayServer _owner;
  final String _token;
  final Duration stallTimeout;
  final _RelayTrackState _video;
  final _RelayTrackState _audio;
  final HttpClient _client = HttpClient();
  bool _disposed = false;

  bool get isDisposed => _disposed;
  String get videoUrl => _owner._uri(_token, CdnRelayTrack.video).toString();
  String? get audioUrl => _audio.candidates.isEmpty
      ? null
      : _owner._uri(_token, CdnRelayTrack.audio).toString();
  String get currentVideoSource => _video.currentUrl;
  String? get currentAudioSource =>
      _audio.candidates.isEmpty ? null : _audio.currentUrl;

  void updateSources({
    required List<String> videoCandidates,
    required int videoIndex,
    required List<String> audioCandidates,
    required int audioIndex,
  }) {
    _video.update(videoCandidates, videoIndex);
    _audio.update(audioCandidates, audioIndex);
  }

  bool switchVideo({String? expectedUrl, bool switchMatchingAudio = true}) {
    if (_disposed || _video.candidates.length < 2) return false;
    if (expectedUrl != null && _video.currentUrl != expectedUrl) return true;
    final failedHost = VideoUtils.cdnHost(_video.currentUrl);
    final switched = _video.switchNext(expectedUrl: expectedUrl);
    if (switched && switchMatchingAudio && failedHost != null) {
      if (VideoUtils.cdnHost(currentAudioSource) == failedHost) {
        _audio.switchNext();
      }
    }
    return switched;
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

    var bytesSent = 0;
    int? absoluteStart = parsedRange?.start;
    var headersSent = false;
    var attempts = 0;

    while (!_disposed && attempts <= track.candidates.length) {
      final sourceUrl = track.currentUrl;
      StreamIterator<List<int>>? iterator;
      try {
        final upstream = await _openUpstream(
          request: request,
          sourceUrl: sourceUrl,
          originalRange: requestedRange,
          absoluteStart: absoluteStart,
          bytesSent: bytesSent,
          end: parsedRange?.end,
        );

        final contentRange = _ContentRange.tryParse(
          upstream.headers.value(HttpHeaders.contentRangeHeader),
        );
        final expectedStart = (absoluteStart ?? 0) + bytesSent;
        if ((bytesSent > 0 &&
                (upstream.statusCode != HttpStatus.partialContent ||
                    contentRange?.start != expectedStart)) ||
            (bytesSent == 0 &&
                requestedRange != null &&
                upstream.statusCode != HttpStatus.partialContent)) {
          await _cancelResponse(upstream);
          throw const _RelaySourceMismatch();
        }
        absoluteStart ??= contentRange?.start ?? 0;
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
          _copyResponseHeaders(upstream, response);
          headersSent = true;
          if (request.method == 'HEAD') {
            await upstream.drain<void>();
            await response.close();
            return;
          }
        }

        iterator = StreamIterator<List<int>>(upstream);
        while (await iterator.moveNext().timeout(stallTimeout)) {
          final chunk = iterator.current;
          response.add(chunk);
          bytesSent += chunk.length;
          // Respect mpv backpressure. A blocked local client is not a CDN stall.
          await response.flush();
          if (track.currentUrl != sourceUrl) {
            throw const _RelaySourceChanged();
          }
        }
        await response.close();
        return;
      } on _RelaySourceChanged {
        // The controller or another in-flight request already selected a new
        // upstream. Continue this same downstream response at the next byte.
      } on TimeoutException {
        if (!_switchAfterFailure(type, sourceUrl)) rethrow;
      } on SocketException {
        if (!_switchAfterFailure(type, sourceUrl)) rethrow;
      } on HttpException {
        if (!_switchAfterFailure(type, sourceUrl)) rethrow;
      } on _RelaySourceMismatch {
        if (!_switchAfterFailure(type, sourceUrl)) rethrow;
      } catch (_) {
        if (!_switchAfterFailure(type, sourceUrl)) rethrow;
      } finally {
        await iterator?.cancel();
      }
      attempts += 1;
    }

    if (!headersSent) response.statusCode = HttpStatus.badGateway;
    try {
      await response.close();
    } catch (_) {}
  }

  bool _switchAfterFailure(CdnRelayTrack type, String expectedUrl) {
    return type == CdnRelayTrack.video
        ? switchVideo(expectedUrl: expectedUrl, switchMatchingAudio: true)
        : _audio.switchNext(expectedUrl: expectedUrl);
  }

  static Future<void> _cancelResponse(HttpClientResponse response) async {
    final subscription = response.listen(null);
    await subscription.cancel();
  }

  Future<HttpClientResponse> _openUpstream({
    required HttpRequest request,
    required String sourceUrl,
    required String? originalRange,
    required int? absoluteStart,
    required int bytesSent,
    required int? end,
  }) async {
    final upstreamRequest = await _client
        .openUrl(request.method, Uri.parse(sourceUrl))
        .timeout(stallTimeout);
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

    if (bytesSent == 0 && originalRange != null) {
      upstreamRequest.headers.set(HttpHeaders.rangeHeader, originalRange);
    } else if (bytesSent > 0) {
      final start = (absoluteStart ?? 0) + bytesSent;
      upstreamRequest.headers.set(
        HttpHeaders.rangeHeader,
        'bytes=$start-${end ?? ''}',
      );
    }

    final upstream = await upstreamRequest.close().timeout(stallTimeout);
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
  int? expectedLength;
  final Set<String> failedHosts = {};

  String get currentUrl => candidates[index];

  void update(List<String> nextCandidates, int nextIndex) {
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

    for (var offset = 1; offset < candidates.length; offset++) {
      final nextIndex = (index + offset) % candidates.length;
      final next = candidates[nextIndex];
      final host = VideoUtils.cdnHost(next);
      if (host != null && failedHosts.contains(host)) continue;
      if (VideoUtils.isCdnCoolingDown(next)) continue;
      index = nextIndex;
      switches += 1;
      onSwitch?.call(type, failedUrl, next);
      return true;
    }
    return false;
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
  const _ContentRange(this.start, this.total);

  final int start;
  final int? total;

  static _ContentRange? tryParse(String? value) {
    if (value == null) return null;
    final match = RegExp(r'^bytes (\d+)-(\d+)/(\d+|\*)$').firstMatch(value);
    if (match == null) return null;
    return _ContentRange(
      int.parse(match.group(1)!),
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
