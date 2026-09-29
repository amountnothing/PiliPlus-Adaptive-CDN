(function () {
  "use strict";

  if (window.__piliPlusAdaptiveCdnInstalled) return;
  window.__piliPlusAdaptiveCdnInstalled = true;

  function markInstalled() {
    document.documentElement?.setAttribute("data-pili-adaptive-cdn", "ready");
  }
  markInstalled();
  document.addEventListener("DOMContentLoaded", markInstalled, { once: true });

  const Core = window.PiliPlusAdaptiveCdnCore;
  if (!Core) return;

  const PAGE_SOURCE = "pili-adaptive-cdn-page";
  const BRIDGE_SOURCE = "pili-adaptive-cdn-bridge";
  const nativeFetch = window.fetch.bind(window);
  const nativeXhrOpen = XMLHttpRequest.prototype.open;
  const nativeXhrSend = XMLHttpRequest.prototype.send;
  const nativeXhrAbort = XMLHttpRequest.prototype.abort;
  const nativeXhrHeader = XMLHttpRequest.prototype.setRequestHeader;
  const nativeJsonParse = JSON.parse.bind(JSON);

  const sessionPathKey = () => location.pathname.replace(/\/+$/, "") +
    "?p=" + (new URLSearchParams(location.search).get("p") || "1");
  let playInfoSequence = 0;

  let settings = Core.normalizeSettings();
  let scores = {};
  let cooldowns = {};
  let sessionPath = sessionPathKey();
  let switchCount = 0;
  let lastReason = "等待播放地址";
  let lastBufferSeconds = 0;
  let lastRewardAt = Date.now();
  let lastRewardPosition = 0;
  let health = Core.createHealthState(Date.now());
  let frameVideo = null;
  let stopFrameTracking = () => {};
  let lastVideoFrameAt = Date.now();
  let lastVideoFramePosition = 0;
  let videoPlayStartedAt = Date.now();
  let videoHasStartedPlayback = false;
  let videoFrameRecoveryUntil = 0;
  let pageVisibleAt = Date.now();
  let networkGuard = Core.createNetworkGuardState();
  const CANDIDATE_WINDOW_MS = 15_000;
  // Before any byte of a candidate has arrived a shorter per-attempt bound is
  // used so a dead first candidate cannot hold the player hostage.
  const FIRST_BYTE_WINDOW_MS = 5_000;
  // Definitive failures (HTTP 4xx/5xx, TypeError network errors) carry real
  // information: only a short cooldown is needed before trying the next
  // candidate. Silence (connected, no bytes) or timeout proves nothing and
  // still waits the full observation window.
  const DEFINITIVE_FAILURE_REASONS = new Set(["http-error", "network-error"]);
  let userPaused = false;

  document.addEventListener("visibilitychange", () => {
    if (!document.hidden) pageVisibleAt = Date.now();
  });

  const resources = new Set();
  const aliases = new Map();
  const failedHosts = new Set();
  const activeFetches = new Map();
  const activeXhrs = new Set();
  const processedObjects = new WeakSet();
  const processedScripts = new WeakSet();

  function post(type, payload) {
    window.postMessage({ source: PAGE_SOURCE, type, payload }, "*");
  }

  function canPlayCodec(codec) {
    if (!window.MediaSource?.isTypeSupported) return false;
    return window.MediaSource.isTypeSupported(`video/mp4; codecs="${codec}"`);
  }

  function cleanExpiredState(now = Date.now()) {
    for (const [host, until] of Object.entries(cooldowns)) {
      if (Number(until) <= now) delete cooldowns[host];
    }

  }

  function updateScore(host, delta) {
    if (!host) return;
    const current = Core.scoreOf(scores, host);
    scores[host] = Math.max(0, Math.min(100, current + delta));
    post("scores", scores);
  }

  function markFailed(host) {
    if (!host || failedHosts.has(host)) return;
    failedHosts.add(host);
    cooldowns[host] = Date.now() + settings.cooldownSec * 1000;
    updateScore(host, -28);
    post("cooldowns", cooldowns);
  }

  function candidatesFor(resource, excludeFailed = true) {
    cleanExpiredState();
    return Core.rankCandidates(
      resource.urls,
      scores,
      resource.cooldowns,
      excludeFailed ? resource.failedHosts : null,
    );
  }

  function setStreamUrls(stream, ordered) {
    if (!ordered.length) return;
    if (Object.prototype.hasOwnProperty.call(stream, "baseUrl")) {
      stream.baseUrl = ordered[0];
    }
    if (Object.prototype.hasOwnProperty.call(stream, "base_url")) {
      stream.base_url = ordered[0];
    }
    if (Object.prototype.hasOwnProperty.call(stream, "backupUrl")) {
      stream.backupUrl = ordered.slice(1);
    }
    if (Object.prototype.hasOwnProperty.call(stream, "backup_url")) {
      stream.backup_url = ordered.slice(1);
    }
  }

  function registerStream(stream) {
    const kind = Core.streamKind(stream);
    // Signed host substitution is not evidence of availability. Use only API URLs.
    const urls = Core.streamUrls(stream);
    if (!urls.length) return;
    const ordered = Core.rankCandidates(urls, scores, cooldowns, null);
    const effective = ordered.length ? ordered : urls;
    setStreamUrls(stream, effective);

    let resource = null;
    for (const url of urls) {
      resource = aliases.get(Core.resourceKey(url));
      if (resource) break;
    }
    if (!resource) {
      resource = {
        urls: [],
        currentUrl: effective[0],
        lastRequestAt: 0,
        switchCount: 0,
        generation: 0,
        candidateStartedAt: null,
        firstByteAt: null,
        lastFailureReason: null,
        failedHosts: new Set(),
        cooldowns: { ...cooldowns },
        recovery: null,
        exhausted: false,
        kind,
      };
      resources.add(resource);
    }
    if (!resource.kind) resource.kind = kind;
    resource.urls = Core.uniqueUrls([...resource.urls, ...urls]);
    const currentHost = Core.hostOf(resource.currentUrl);
    resource.currentUrl =
      effective.find((url) => Core.hostOf(url) === currentHost) || resource.currentUrl;
    for (const url of resource.urls) aliases.set(Core.resourceKey(url), resource);
  }

  function processPlayInfo(value) {
    if (sessionPathKey() !== sessionPath) resetVideoSession();
    if (!value || typeof value !== "object" || processedObjects.has(value)) return value;
    const streams = Core.collectStreams(value);
    if (!streams.length) return value;
    processedObjects.add(value);
    Core.reorderVideoArrays(value, settings.preferredCodec, canPlayCodec);
    for (const stream of streams) registerStream(stream);
    lastReason = `已发现 ${new Set([...resources].flatMap((item) => item.urls.map(Core.hostOf))).size} 个 CDN`;
    emitStatus();
    return value;
  }

  function trapInitialPlayInfo(name) {
    try {
      let current = window[name];
      Object.defineProperty(window, name, {
        configurable: true,
        enumerable: true,
        get() {
          return current;
        },
        set(value) {
          current = processPlayInfo(value);
        },
      });
      if (current !== undefined) current = processPlayInfo(current);
    } catch (_) {}
  }

  // The current web page assigns __playinfo__ in an inline script and the
  // player deletes it almost immediately. A polling-only solution misses it.
  trapInitialPlayInfo("__playinfo__");
  trapInitialPlayInfo("playurlSSRData");

  function scanEmbeddedPlayInfo() {
    for (const script of document.scripts) {
      if (processedScripts.has(script)) continue;
      const text = script.textContent || "";
      const marker = text.startsWith("window.__playinfo__=")
        ? "window.__playinfo__="
        : text.startsWith("window.playurlSSRData=")
          ? "window.playurlSSRData="
          : null;
      if (!marker) continue;
      processedScripts.add(script);
      try {
        const json = text.slice(marker.length).replace(/;\s*$/, "");
        processPlayInfo(nativeJsonParse(json));
      } catch (_) {}
    }
  }

  function lookupResource(url) {
    return aliases.get(Core.resourceKey(url));
  }

  function rewriteMediaUrl(url) {
    if (!settings.enabled || !Core.isMediaUrl(url)) return { url, resource: null };
    const resource = lookupResource(url);
    if (!resource) return { url, resource: null };
    resource.lastRequestAt = Date.now();
    if (resource.candidateStartedAt === null) resource.candidateStartedAt = Date.now();
    return { url: resource.currentUrl || url, resource };
  }

  function abortInflightMedia(targets = null, cancel = false) {
    const targetSet = targets ? new Set(targets) : null;
    for (const [controller, request] of activeFetches) {
      if (targetSet && !targetSet.has(request.resource)) continue;
      if (cancel) controller.abort(new DOMException("Retired media session", "AbortError"));
      else request.restart?.();
    }
    for (const xhr of activeXhrs) {
      if (targetSet && !targetSet.has(xhr.__piliAdaptiveResource)) continue;
      try {
        const state = xhr.__piliAdaptiveState;
        if (cancel) { xhr.abort(); continue; }
        if (!state || state.cancelled || state.pending || state.attempted.has(state.resource.currentUrl)) continue;
        state.pending = true;
        nativeXhrAbort.call(xhr);
        scheduleXhrRetry(xhr, state, 0);
      } catch (_) {}
    }
  }

  function activeResources() {
    const threshold = Date.now() - 90_000;
    const active = [...resources].filter((item) => item.lastRequestAt >= threshold);
    return active.length ? active : [...resources];
  }

  function switchCdn(reason, manual = false, failedHost = null, failedResource = null, coordinated = false) {
    if (!settings.enabled || !resources.size) return false;
    if (!manual && !coordinated) {
      for (const resource of Core.selectSwitchTargets(activeResources(), failedResource)) {
        void recoverCandidate(reason, resource, resource.generation);
      }
      return false;
    }
    const maximum = settings.traverseAllCdns ? Infinity : settings.maxSwitches;
    const targets = Core.selectSwitchTargets(activeResources(), failedResource)
      .filter(resource => manual || resource.switchCount < maximum);
    if (!targets.length) {
      if (failedResource) failedResource.exhausted = true;
      lastReason = "已达到当前资源最大切换次数";
      emitStatus();
      return false;
    }
    const currentHosts = new Set(
      (failedHost ? [failedHost] : targets.map((item) => Core.hostOf(item.currentUrl))).filter(Boolean),
    );
    for (const host of currentHosts) markFailed(host);

    let changed = 0;
    for (const resource of targets) {
      const previous = resource.currentUrl;
      resource.failedHosts.add(Core.hostOf(previous));
      const ranked = candidatesFor(resource);
      const next = ranked.find((url) => Core.hostOf(url) !== Core.hostOf(previous));
      if (!next) { resource.exhausted = true; continue; }
      if (manual) resource.recovery?.controller.abort();
      resource.currentUrl = next;
      resource.generation += 1;
      resource.candidateStartedAt = Date.now();
      resource.firstByteAt = null;
      resource.lastFailureReason = null;
      resource.switchCount += 1;
      changed += 1;
    }
    if (!changed) {
      lastReason = `候选 CDN 已遍历完（${reason}）`;
      emitStatus();
      showToast(lastReason, true);
      return false;
    }

    switchCount += 1;
    health.lastSwitchAt = Date.now();
    health.lastBufferProgressAt = Date.now();
    health.bufferBelowTarget = false;
    abortInflightMedia(targets);
    const hosts = [...new Set(targets.map((item) => Core.hostOf(item.currentUrl)).filter(Boolean))];
    lastReason = `${reasonLabel(reason)} → ${hosts.join(" / ")}`;
    emitStatus();
    showToast(`Adaptive CDN：${lastReason}`);
    return true;
  }

  function candidateDeadline(resource, reason) {
    const start = resource.candidateStartedAt ?? Date.now();
    const windowMs = DEFINITIVE_FAILURE_REASONS.has(reason)
      ? settings.failCooldownMs
      : CANDIDATE_WINDOW_MS;
    return start + windowMs;
  }

  // Wait until `deadline`, but let the wait be cut short: a wake() re-enters
  // the loop (deadline moved earlier) and a forced recovery (play after an
  // automatic pause) breaks out immediately.
  function waitForDeadline(deadline, signal, recovery) {
    return new Promise((resolve, reject) => {
      let timer = 0;
      const cleanup = () => {
        clearTimeout(timer);
        signal.removeEventListener("abort", onAbort);
        recovery.wake = null;
      };
      const finish = () => { cleanup(); resolve(false); };
      const onAbort = () => { cleanup(); reject(signal.reason); };
      timer = setTimeout(finish, Math.max(0, deadline - Date.now()));
      recovery.wake = () => { cleanup(); resolve(true); };
      if (signal.aborted) onAbort();
      else signal.addEventListener("abort", onAbort, { once: true });
    });
  }

  function recoverCandidate(reason, resource, generation, owner = null) {
    if (!resource || !resources.has(resource) || sessionPathKey() !== sessionPath ||
        !settings.enabled || userPaused || resource.exhausted || generation !== resource.generation) return Promise.resolve(false);
    if (resource.recovery?.generation === generation && !resource.recovery.controller.signal.aborted) {
      if (owner) resource.recovery.owners.add(owner);
      else resource.recovery.background = true;
      const deadline = candidateDeadline(resource, reason);
      if (deadline < resource.recovery.deadline) {
        resource.recovery.deadline = deadline;
        resource.recovery.wake?.();
      }
      return resource.recovery.promise;
    }
    const controller = new AbortController();
    const recovery = {
      generation, controller, owners: new Set(owner ? [owner] : []), background: !owner,
      deadline: candidateDeadline(resource, reason), wake: null, force: false,
    };
    resource.recovery = recovery;
    if (resource.candidateStartedAt === null) resource.candidateStartedAt = Date.now();
    recovery.deadline = Math.min(recovery.deadline, candidateDeadline(resource, reason));
    const valid = () => !controller.signal.aborted && settings.enabled &&
      resources.has(resource) && sessionPathKey() === sessionPath && resource.generation === generation;
    // One observation window and one network-guard observation per candidate,
    // not per Range request. Definitive failures wait only the short cooldown;
    // silence and timeouts still wait the full candidate window.
    recovery.promise = (async () => {
      try {
        while (!recovery.force) {
          const advanced = await waitForDeadline(recovery.deadline, controller.signal, recovery);
          if (recovery.force || !advanced) break;
        }
        if (!valid()) return false;
        if (reason === "network-error" && Core.shouldPauseNetworkSwitch(networkGuard,
            {host: Core.hostOf(resource.currentUrl), kind: resource.kind}, Date.now())) {
          lastReason = "检测到整体网络异常，暂停 CDN 切换 20 秒";
          emitStatus();
          await waitUntil(networkGuard.pauseUntil, controller.signal);
        }
        if (!valid()) return false;
        return switchCdn(reason, false, Core.hostOf(resource.currentUrl), resource, true);
      } catch (_) { return false; }
      finally { if (resource.recovery === recovery) resource.recovery = null; }
    })();
    return recovery.promise;
  }

  function releaseRecovery(resource, owner) {
    const recovery = resource?.recovery;
    if (!recovery || !recovery.owners.delete(owner)) return;
    if (!recovery.owners.size && !recovery.background) recovery.controller.abort();
  }

  // The web player fires pause/play by itself during startup and quality
  // switches. Such a pause must NOT abort retries that are already waiting
  // (that left the player stuck with no request at all); it only blocks new
  // recovery entries. On play, pending recoveries are forced to finish so the
  // last failed Range is re-sent on the current/next candidate immediately.
  document.addEventListener("pause", event => {
    if (event.target !== document.querySelector("video")) return;
    userPaused = true;
  }, true);
  document.addEventListener("play", event => {
    if (event.target !== document.querySelector("video")) return;
    userPaused = false;
    for (const resource of resources) {
      const recovery = resource.recovery;
      if (recovery && !recovery.controller.signal.aborted) {
        recovery.force = true;
        recovery.wake?.();
      } else if (resource.lastFailureReason && !resource.exhausted) {
        // Resource still pending but no in-flight request: re-arm the switch.
        void recoverCandidate(resource.lastFailureReason, resource, resource.generation);
      }
    }
  }, true);

  // A fatal MediaError cannot be healed by changing a URL in an already
  // poisoned MSE. Prepare one handoff per source, but never invent a reload API,
  // call play(), or overwrite the user's position. Site/user reload is required.
  let fatalVideos = new WeakSet();
  document.addEventListener("loadstart", event => {
    if (event.target === document.querySelector("video")) fatalVideos.delete(event.target);
  }, true);
  document.addEventListener("error", async event => {
    const video = event.target;
    if (!settings.enabled || video !== document.querySelector("video") ||
        !video?.error || video.error.code === 1 || fatalVideos.has(video) ||
        sessionPathKey() !== sessionPath) return;
    fatalVideos.add(video);
    const path = sessionPath;
    const changed = (await Promise.all(Core.selectSwitchTargets(activeResources(), null)
      .map(resource => recoverCandidate("media-error", resource, resource.generation)))).some(Boolean);
    if (path !== sessionPath || userPaused) return;
    lastReason = changed
      ? "播放器致命错误：已准备下一候选并重试在途请求；MSE 仍需网页播放器或手动重载"
      : "播放器致命错误：无可用下一候选；需网页播放器或手动重载";
    emitStatus();
    showToast(lastReason, true);
  }, true);

  function reasonLabel(reason) {
    return (
      {
        "buffer-stall": "缓冲停止增长",
        "low-buffer": "缓冲降至阈值",
        "network-error": "网络请求失败",
        "http-error": "CDN 返回错误",
        manual: "手动切换",
      }[reason] || reason
    );
  }

  function combineSignal(controller, input, init) {
    const signal = init?.signal || (input instanceof Request ? input.signal : null);
    const abort = () => controller.abort(signal.reason);
    if (signal) {
      if (signal.aborted) abort();
      else signal.addEventListener("abort", abort, { once: true });
    }
    return () => signal?.removeEventListener("abort", abort);
  }

  function waitUntil(deadline, signal) {
    return new Promise((resolve, reject) => {
      const finish = () => { signal.removeEventListener("abort", abort); resolve(); };
      const abort = () => { clearTimeout(timer); signal.removeEventListener("abort", abort); reject(signal.reason); };
      const timer = setTimeout(finish, Math.max(0, deadline - Date.now()));
      if (signal.aborted) abort();
      else signal.addEventListener("abort", abort, { once: true });
    });
  }

  function mediaFetchInput(input, targetUrl) {
    if (!(input instanceof Request)) return targetUrl;
    return new Request(targetUrl, {
      method: input.method,
      headers: input.headers,
      mode: input.mode,
      credentials: input.credentials,
      cache: input.cache,
      redirect: input.redirect,
      referrer: input.referrer,
      referrerPolicy: input.referrerPolicy,
      integrity: input.integrity,
      keepalive: input.keepalive,
    });
  }

  async function patchPlayUrlResponse(response, path, sequence) {
    try {
      const data = nativeJsonParse(await response.clone().text());
      if (path !== sessionPathKey() || sequence !== playInfoSequence) return response;
      if (!Core.collectStreams(data).length) return response;
      processPlayInfo(data);
      const headers = new Headers(response.headers);
      headers.delete("content-length");
      headers.delete("content-encoding");
      return new Response(JSON.stringify(data), {
        status: response.status,
        statusText: response.statusText,
        headers,
      });
    } catch (_) {
      return response;
    }
  }

  window.fetch = async function adaptiveFetch(input, init) {
    const originalUrl = input instanceof Request ? input.url : String(input);
    if (settings.enabled && Core.isPlayUrlApi(originalUrl)) {
      const path = sessionPathKey();
      const sequence = ++playInfoSequence;
      return patchPlayUrlResponse(await nativeFetch(input, init), path, sequence);
    }

    const rewritten = rewriteMediaUrl(originalUrl);
    const method = init?.method || (input instanceof Request ? input.method : "GET");
    if (!rewritten.resource || method.toUpperCase() !== "GET") return nativeFetch(input, init);

    const controller = new AbortController();
    const disconnect = combineSignal(controller, input, init);
    const tracked = { createdAt: Date.now(), resource: rewritten.resource };
    activeFetches.set(controller, tracked);
    const attempted = new Set();
    let url = rewritten.url;
    try {
      while (true) {
        const generation = rewritten.resource.generation;
        attempted.add(url);
        let response;
        let failure;
        const attempt = new AbortController();
        tracked.restart = () => attempt.abort(new DOMException("Adaptive CDN handoff", "AbortError"));
        const unlink = combineSignal(attempt, null, { signal: controller.signal });
        const timeout = setTimeout(() => attempt.abort(new DOMException("CDN response timeout", "TimeoutError")),
          rewritten.resource.firstByteAt ? CANDIDATE_WINDOW_MS : FIRST_BYTE_WINDOW_MS);
        try {
          response = await nativeFetch(mediaFetchInput(input, url), {
            ...init,
            signal: attempt.signal,
          });
          if (controller.signal.aborted || !resources.has(rewritten.resource) || sessionPathKey() !== sessionPath) {
            await response.body?.cancel().catch(() => {});
            throw new DOMException("Obsolete media request", "AbortError");
          }
          if (!Core.shouldSwitchForRequestFailure(response.status, false)) {
            rewritten.resource.firstByteAt ??= Date.now();
            rewritten.resource.lastFailureReason = null;
            return response;
          }
        } catch (error) {
          failure = error;
          if (controller.signal.aborted || !resources.has(rewritten.resource) || sessionPathKey() !== sessionPath) throw error;
        } finally {
          clearTimeout(timeout);
          unlink();
        }
        const reason = response
          ? "http-error"
          : failure?.name === "TimeoutError" || failure?.name === "AbortError"
            ? "candidate-timeout"
            : "network-error";
        rewritten.resource.lastFailureReason = reason;
        tracked.waiting = true;
        const recovery = recoverCandidate(reason, rewritten.resource, generation, tracked);
        let onAbort;
        try {
          await Promise.race([recovery, new Promise((_, reject) => {
            onAbort = () => reject(controller.signal.reason);
            if (controller.signal.aborted) onAbort();
            else controller.signal.addEventListener("abort", onAbort, {once:true});
          })]);
        } catch (error) {
          if (response?.body) await response.body.cancel().catch(() => {});
          throw error;
        } finally {
          tracked.waiting = false;
          releaseRecovery(rewritten.resource, tracked);
          controller.signal.removeEventListener("abort", onAbort);
        }
        const next = rewritten.resource.currentUrl;
        if (!settings.enabled || controller.signal.aborted || attempted.has(next) || !resources.has(rewritten.resource)) {
          if (failure) throw failure;
          return response;
        }
        // No bytes have been exposed to the player: replay the identical Range
        // on the next signed candidate, preserving the existing MSE buffers.
        if (response?.body) await response.body.cancel().catch(() => {});
        url = next;
      }
    } finally {
      disconnect();
      activeFetches.delete(controller);
    }
  };

  // Intercept completion before the page observes a terminal failure. The
  // native XHR object and success events stay intact; only failed GET attempts
  // are hidden and replayed. No response bytes are concatenated across hosts.
  function fireXhrRetry(xhr, state) {
    if (xhr.__piliAdaptiveState !== state || state.cancelled || !settings.enabled ||
        state.path !== sessionPathKey() || !resources.has(state.resource)) return;

    const responseType = xhr.responseType;
    const credentials = xhr.withCredentials;
    const timeout = xhr.timeout;
    const target = state.resource.currentUrl;
    if (state.attempted.has(target)) {
      state.pending = false;
      state.finished = true;
      activeXhrs.delete(xhr);
      // Preserve terminal semantics if settings/budget prevent recovery.
      xhr.dispatchEvent(new Event("readystatechange"));
      xhr.dispatchEvent(new Event(state.terminalEvent || "error"));
      xhr.dispatchEvent(new Event("loadend"));
      return;
    }
    state.url = target;
    state.generation = state.resource.generation;
    state.attempted.add(target);
    state.timedOut = false;
    state.recoveryStarted = false;
    xhr.__piliAdaptiveHost = Core.hostOf(target);
    nativeXhrOpen.call(xhr, state.method, target, ...state.rest);
    xhr.responseType = responseType;
    xhr.withCredentials = credentials;
    xhr.timeout = timeout;
    for (const [name, value] of state.headers) nativeXhrHeader.call(xhr, name, value);
    state.pending = false;
    nativeXhrSend.call(xhr, state.body);
  }

  function scheduleXhrRetry(xhr, state) {
    // A task (not a microtask) lets the native load/error/loadend sequence
    // finish before reopening; every event from that attempt is suppressed.
    state.timer = setTimeout(() => fireXhrRetry(xhr, state), 0);
  }

  function observeXhr(xhr) {
    if (xhr.__piliAdaptiveObserved) return;
    xhr.__piliAdaptiveObserved = true;
    const onEvent = event => {
      const state = xhr.__piliAdaptiveState;
      if (!state) return;
      if (state.pending) {
        if (["load","error","timeout"].includes(event.type)) {
          state.terminalEvent = event.type;
          if (!state.recoveryStarted) {
            // Recovery is triggered by the native terminal event, not the
            // final readystatechange: only load/error/timeout can tell a
            // silent timeout apart from a hard network error.
            state.recoveryStarted = true;
            event.stopImmediatePropagation();
            const reason = event.type === "timeout" ? "candidate-timeout"
              : event.type === "error" ? "network-error"
              : xhr.status ? "http-error" : "network-error";
            state.resource.lastFailureReason = reason;
            recoverCandidate(reason, state.resource, state.generation, state).then(() => {
              releaseRecovery(state.resource, state);
              if (xhr.__piliAdaptiveState !== state || state.cancelled) return;
              if (state.pending) {
                // The suppressed attempt's native event sequence already
                // completed, so the replay can go out right here. A
                // setTimeout replay is faked by environment clocks and would
                // not fire until the next manual clock advance — one cooldown
                // late after a switch commit (XHR pause regression).
                fireXhrRetry(xhr, state);
              } else {
                scheduleXhrRetry(xhr, state);
              }
            });
          }
        }
        event.stopImmediatePropagation();
        return;
      }
      if (event.type === "abort") {
        state.cancelled = true;
        activeXhrs.delete(xhr);
        return;
      }
      if (event.type === "readystatechange" && xhr.readyState === 4 && state.playurl) {
        if (state.path === sessionPathKey() && state.sequence === playInfoSequence) {
          try {
            if (xhr.responseType === "json") processPlayInfo(xhr.response);
            else if (!xhr.responseType || xhr.responseType === "text") {
              const data = nativeJsonParse(xhr.responseText);
              if (Core.collectStreams(data).length) {
                processPlayInfo(data);
                const text = JSON.stringify(data);
                Object.defineProperty(xhr, "responseText", { configurable: true, value: text });
                Object.defineProperty(xhr, "response", { configurable: true, value: text });
              }
            }
          } catch (_) {}
        }
      }
      if (!state.resource || state.cancelled || state.finished) return;
      if (event.type === "timeout") state.timedOut = true;
      if (xhr.readyState >= 2 && xhr.status && state.resource &&
          !Core.shouldSwitchForRequestFailure(xhr.status, false)) {
        state.resource.firstByteAt ??= Date.now();
        state.resource.lastFailureReason = null;
      }
      if (xhr.readyState > 1 && xhr.readyState < 4 && xhr.status &&
          Core.shouldSwitchForRequestFailure(xhr.status, false)) {
        event.stopImmediatePropagation();
        return;
      }
      if (event.type === "readystatechange" && xhr.readyState === 4 &&
          Core.shouldSwitchForRequestFailure(xhr.status, false)) {
        if (settings.enabled && !userPaused && resources.has(state.resource) && state.path === sessionPathKey()) {
          // Suppress the player-facing failure; recovery is armed by the
          // terminal event that follows (handled in the pending branch).
          state.pending = true;
          event.stopImmediatePropagation();
          return;
        }
      }
      if (event.type === "loadend") {
        state.finished = true;
        activeXhrs.delete(xhr);
      }
    };
    for (const type of ["readystatechange", "load", "error", "timeout", "loadend", "abort", "progress", "loadstart"]) {
      xhr.addEventListener(type, onEvent, true);
    }
  }

  XMLHttpRequest.prototype.open = function adaptiveOpen(method, url, ...rest) {
    const old = this.__piliAdaptiveState;
    if (old) { old.cancelled = true; clearTimeout(old.timer); releaseRecovery(old.resource, old); }
    activeXhrs.delete(this);
    // Clear only our own response overrides when an XHR is reused.
    if (old?.playurl) { delete this.response; delete this.responseText; }
    const originalUrl = String(url);
    const rewritten = rewriteMediaUrl(originalUrl);
    const resource = String(method).toUpperCase() === "GET" && rest[0] !== false ? rewritten.resource : null;
    const playurl = Core.isPlayUrlApi(originalUrl);
    this.__piliAdaptiveResource = resource;
    this.__piliAdaptiveHost = Core.hostOf(rewritten.url);
    this.__piliAdaptiveState = {
      resource, playurl, path: sessionPathKey(), sequence: playurl ? ++playInfoSequence : 0,
      generation: resource?.generation,
      method, rest, url: resource ? rewritten.url : originalUrl,
      attempted: new Set([rewritten.url]), headers: [], cancelled: false, timedOut: false,
    };
    observeXhr(this);
    return nativeXhrOpen.call(this, method, resource ? rewritten.url : originalUrl, ...rest);
  };

  XMLHttpRequest.prototype.setRequestHeader = function adaptiveHeader(name, value) {
    const result = nativeXhrHeader.call(this, name, value);
    this.__piliAdaptiveState?.headers.push([name, value]);
    return result;
  };

  XMLHttpRequest.prototype.abort = function adaptiveAbort() {
    const state = this.__piliAdaptiveState;
    const waitingDone = state?.pending && this.readyState === 4;
    releaseRecovery(state?.resource, state);
    if (state) { state.cancelled = true; state.pending = false; clearTimeout(state.timer); }
    activeXhrs.delete(this);
    const result = nativeXhrAbort.call(this);
    // Native abort on an already-DONE hidden failure emits no terminal events.
    if (waitingDone) {
      this.dispatchEvent(new Event("abort"));
      this.dispatchEvent(new Event("loadend"));
    }
    return result;
  };

  XMLHttpRequest.prototype.send = function adaptiveSend(body) {
    const state = this.__piliAdaptiveState;
    if (state?.resource) {
      state.body = body;
      // Bound a stuck media request even when the site's XHR timeout is zero.
      // Before the first byte a shorter bound avoids dead first candidates.
      if (!this.timeout) this.timeout = state.resource.firstByteAt ? CANDIDATE_WINDOW_MS : FIRST_BYTE_WINDOW_MS;
      activeXhrs.add(this);
    }
    return nativeXhrSend.call(this, body);
  };

  function bufferedEnd(video) {
    const position = video.currentTime || 0;
    for (let index = 0; index < video.buffered.length; index += 1) {
      if (video.buffered.start(index) <= position && video.buffered.end(index) >= position) {
        return video.buffered.end(index);
      }
    }
    return video.buffered.length ? video.buffered.end(video.buffered.length - 1) : position;
  }

  function trackVideoFrames(video) {
    if (frameVideo === video) return;
    stopFrameTracking();
    frameVideo = video;
    videoHasStartedPlayback = false;
    let stopped = false;
    let callbackId = 0;
    const resetFrameBaseline = () => {
      if (stopped || frameVideo !== video) return;
      videoPlayStartedAt = Date.now();
      lastVideoFrameAt = videoPlayStartedAt;
      lastVideoFramePosition = video.currentTime || 0;
    };
    const markPlaybackStarted = () => {
      if (stopped || frameVideo !== video) return;
      videoHasStartedPlayback = true;
      resetFrameBaseline();
    };
    const resetForNewSource = () => {
      if (stopped || frameVideo !== video) return;
      videoHasStartedPlayback = false;
      videoFrameRecoveryUntil = 0;
      resetFrameBaseline();
      health = Core.createHealthState(Date.now());
    };
    resetFrameBaseline();
    video.addEventListener("playing", markPlaybackStarted);
    video.addEventListener("loadstart", resetForNewSource);
    video.addEventListener("seeking", resetFrameBaseline);
    if (!video.paused && (video.currentTime || 0) > 0) markPlaybackStarted();
    if (video.requestVideoFrameCallback) {
      const next = (_, metadata) => {
        if (stopped || frameVideo !== video) return;
        videoHasStartedPlayback = true;
        lastVideoFrameAt = Date.now();
        lastVideoFramePosition = Number(metadata.mediaTime) || video.currentTime || 0;
        videoFrameRecoveryUntil = 0;
        callbackId = video.requestVideoFrameCallback(next);
      };
      callbackId = video.requestVideoFrameCallback(next);
    }
    stopFrameTracking = () => {
      stopped = true;
      video.removeEventListener("playing", markPlaybackStarted);
      video.removeEventListener("loadstart", resetForNewSource);
      video.removeEventListener("seeking", resetFrameBaseline);
      if (callbackId && video.cancelVideoFrameCallback) {
        video.cancelVideoFrameCallback(callbackId);
      }
      if (frameVideo === video) frameVideo = null;
      stopFrameTracking = () => {};
    };
  }

  function rewardStablePlayback(video, now) {
    if (video.paused || video.ended) return;
    if (
      now - lastRewardAt < settings.stableRewardSec * 1000 ||
      video.currentTime - lastRewardPosition < Math.min(10, settings.stableRewardSec / 2)
    ) {
      return;
    }
    const hosts = new Set(activeResources().map((item) => Core.hostOf(item.currentUrl)).filter(Boolean));
    for (const host of hosts) updateScore(host, 2);
    lastRewardAt = now;
    lastRewardPosition = video.currentTime;
  }

  function monitorVideo() {
    if (sessionPathKey() !== sessionPath) resetVideoSession();
    if (!settings.enabled) return;
    const video = document.querySelector("video");
    if (!video || video.error) return;
    if (document.hidden) return;
    const now = Date.now();
    const end = bufferedEnd(video);
    const forwardBuffer = Math.max(0, end - video.currentTime);
    trackVideoFrames(video);
    if (
      video.requestVideoFrameCallback &&
      Core.shouldPauseForVideoFrameStall(
        {
          playing: !video.paused,
          hasStartedPlayback: videoHasStartedPlayback,
          seeking: video.seeking,
          position: video.currentTime || 0,
          lastFramePosition: lastVideoFramePosition,
          lastFrameAt: lastVideoFrameAt,
          playStartedAt: Math.max(videoPlayStartedAt, pageVisibleAt),
          recoveryUntil: videoFrameRecoveryUntil,
          forwardBuffer,
          minForwardBuffer: settings.lowBufferSec,
        },
        now,
      )
    ) {
      videoFrameRecoveryUntil = now + 12_000;
      lastReason = "画面卡住，正在重新缓冲";
      emitStatus();
      showToast(`Adaptive CDN：${lastReason}`);
      video.currentTime = Math.max(0, Math.min(video.currentTime, lastVideoFramePosition));
      return;
    }
    lastBufferSeconds = forwardBuffer;
    const reason = Core.evaluateHealth(
      health,
      {
        duration: video.duration,
        position: video.currentTime,
        buffered: end,
        playing: !video.paused,
        hasStartedPlayback: videoHasStartedPlayback,
        ended: video.ended,
      },
      settings,
      now,
    );
    if (reason) switchCdn(reason);
    rewardStablePlayback(video, now);
    emitStatus();
  }

  function resetVideoSession() {
    for (const resource of resources) resource.recovery?.controller.abort();
    userPaused = false;
    abortInflightMedia(null, true);
    activeFetches.clear();
    activeXhrs.clear();
    fatalVideos = new WeakSet();
    stopFrameTracking();
    resources.clear();
    aliases.clear();
    failedHosts.clear();
    switchCount = 0;
    lastReason = "等待播放地址";
    lastBufferSeconds = 0;
    lastVideoFrameAt = Date.now();
    lastVideoFramePosition = 0;
    videoPlayStartedAt = Date.now();
    videoHasStartedPlayback = false;
    videoFrameRecoveryUntil = 0;
    networkGuard = Core.createNetworkGuardState();
    sessionPath = sessionPathKey();
    health = Core.createHealthState(Date.now());
    lastRewardAt = Date.now();
    lastRewardPosition = 0;
  }

  function currentStatus() {
    const active = activeResources();
    const currentHosts = [...new Set(active.map((item) => Core.hostOf(item.currentUrl)).filter(Boolean))];
    const candidateHosts = [
      ...new Set([...resources].flatMap((item) => item.urls.map(Core.hostOf)).filter(Boolean)),
    ];
    return {
      enabled: settings.enabled,
      currentHosts,
      candidateHosts,
      failedHosts: [...failedHosts],
      switches: switchCount,
      reason: lastReason,
      forwardBuffer: Math.round(lastBufferSeconds * 10) / 10,
      scores,
      settings,
    };
  }

  let statusTimer = 0;
  function emitStatus() {
    clearTimeout(statusTimer);
    statusTimer = setTimeout(() => {
      const status = currentStatus();
      document.documentElement?.setAttribute(
        "data-pili-adaptive-cdn-candidates",
        String(status.candidateHosts.length),
      );
      post("status", status);
    }, 80);
  }

  function showToast(text, warning = false) {
    if (!document.documentElement) return;
    let host = document.getElementById("pili-adaptive-cdn-toast-host");
    if (!host) {
      host = document.createElement("div");
      host.id = "pili-adaptive-cdn-toast-host";
      host.style.cssText = "position:fixed;left:18px;bottom:72px;z-index:2147483647;pointer-events:none";
      document.documentElement.appendChild(host);
    }
    const toast = document.createElement("div");
    toast.textContent = text;
    toast.style.cssText = [
      "max-width:520px",
      "padding:10px 14px",
      "border-radius:10px",
      `background:${warning ? "rgba(150,45,45,.94)" : "rgba(28,31,38,.94)"}`,
      "color:#fff",
      "font:13px/1.45 system-ui,sans-serif",
      "box-shadow:0 6px 24px rgba(0,0,0,.22)",
      "margin-top:8px",
    ].join(";");
    host.appendChild(toast);
    setTimeout(() => toast.remove(), 3500);
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== BRIDGE_SOURCE) return;
    if (event.data.type === "config") {
      settings = Core.normalizeSettings(event.data.payload?.settings);
      if (!settings.enabled) {
        for (const resource of resources) resource.recovery?.controller.abort();
        abortInflightMedia(null, true);
      }
      scores = { ...(event.data.payload?.scores || {}) };
      cooldowns = { ...(event.data.payload?.cooldowns || {}) };
      emitStatus();
    } else if (event.data.type === "manual-switch") {
      switchCdn("manual", true);
    } else if (event.data.type === "get-status") {
      emitStatus();
    }
  });

  setInterval(() => {
    scanEmbeddedPlayInfo();
    for (const name of ["__playinfo__", "playurlSSRData"]) {
      try {
        processPlayInfo(window[name]);
      } catch (_) {}
    }
  }, 500);
  setInterval(monitorVideo, 1000);
  post("ready", null);
})();
