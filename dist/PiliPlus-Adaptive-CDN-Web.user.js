// ==UserScript==
// @name         PiliPlus Adaptive CDN for Web
// @namespace    https://github.com/amountnothing/PiliPlus-Adaptive-CDN
// @version      0.2.16
// @description  Adaptive CDN optimization for bilibili web video playback.
// @match        *://www.bilibili.com/video/*
// @match        *://www.bilibili.com/bangumi/play/*
// @run-at       document-start
// @inject-into  page
// @grant        none
// ==/UserScript==
(function (root, factory) {
  const api = factory();
  root.PiliPlusAdaptiveCdnCore = api;
  if (typeof module === "object" && module.exports) module.exports = api;
})(typeof globalThis === "object" ? globalThis : this, function () {
  "use strict";

  const DEFAULT_SETTINGS = Object.freeze({
    enabled: true,
    preferredCodec: "hevc",
    expandKnownUpos: true,
    targetBufferSec: 30,
    segmentToleranceSec: 10,
    lowBufferSec: 10,
    bufferStallSec: 5,
    endToleranceSec: 5,
    cooldownSec: 60,
    traverseAllCdns: true,
    maxSwitches: 3,
    stableRewardSec: 30,
  });

  // These hosts accept the same signed /upgcxcode/ path. Keep this bounded to
  // nodes verified with HTTP 206 + Bilibili CORS instead of guessing domains.
  const KNOWN_UPOS_HOSTS = Object.freeze([
    "upos-sz-mirrorali.bilivideo.com",
    "upos-sz-mirroralib.bilivideo.com",
    "upos-sz-mirroralio1.bilivideo.com",
    "upos-sz-mirrorcos.bilivideo.com",
    "upos-sz-mirrorcosb.bilivideo.com",
    "upos-sz-mirrorcoso1.bilivideo.com",
    "upos-sz-mirrorhw.bilivideo.com",
    "upos-sz-mirrorhwb.bilivideo.com",
    "upos-sz-mirrorhwo1.bilivideo.com",
    "upos-sz-mirroraliov.bilivideo.com",
    "upos-sz-mirrorcosov.bilivideo.com",
    "upos-hz-mirrorakam.akamaized.net",
  ]);

  const NUMBER_RANGES = Object.freeze({
    targetBufferSec: [5, 120],
    segmentToleranceSec: [0, 30],
    lowBufferSec: [2, 30],
    bufferStallSec: [2, 60],
    endToleranceSec: [0, 10],
    cooldownSec: [0, 600],
    maxSwitches: [1, 50],
    stableRewardSec: [10, 300],
  });
  const MIN_BUFFER_GROWTH_SEC = 1;

  function clamp(value, min, max) {
    return Math.min(max, Math.max(min, value));
  }

  function normalizeSettings(input) {
    const source = input && typeof input === "object" ? input : {};
    const output = { ...DEFAULT_SETTINGS };
    for (const key of ["enabled", "preferAv1", "expandKnownUpos", "traverseAllCdns"]) {
      if (typeof source[key] === "boolean") output[key] = source[key];
    }
    if (["av1", "hevc", "avc", "default"].includes(source.preferredCodec)) {
      output.preferredCodec = source.preferredCodec;
    } else if (source.preferAv1 === false) {
      output.preferredCodec = "default";
    }
    for (const [key, [min, max]] of Object.entries(NUMBER_RANGES)) {
      const value = Number(source[key]);
      if (Number.isFinite(value)) output[key] = clamp(value, min, max);
    }
    return output;
  }

  function hostOf(value) {
    try {
      return new URL(String(value), "https://www.bilibili.com").hostname;
    } catch (_) {
      return "";
    }
  }

  function resourceKey(value) {
    try {
      const url = new URL(String(value), "https://www.bilibili.com");
      return url.pathname;
    } catch (_) {
      return "";
    }
  }

  function isMediaUrl(value) {
    const host = hostOf(value);
    if (!host) return false;
    return (
      host.endsWith(".bilivideo.com") ||
      host.endsWith(".bilivideo.cn") ||
      host.endsWith(".akamaized.net")
    );
  }

  function isPlayUrlApi(value) {
    try {
      const url = new URL(String(value), "https://www.bilibili.com");
      return (
        /(^|\/)playurl(?:v2)?(?:\/|$)/i.test(url.pathname) ||
        /\/player\/(?:wbi\/)?playurl/i.test(url.pathname)
      );
    } catch (_) {
      return false;
    }
  }

  function uniqueUrls(values) {
    const result = [];
    const seen = new Set();
    for (const value of values || []) {
      if (typeof value !== "string" || !isMediaUrl(value) || seen.has(value)) {
        continue;
      }
      seen.add(value);
      result.push(value);
    }
    return result;
  }

  function expandUposCandidates(values, enabled = true) {
    const source = uniqueUrls(values);
    if (!enabled) return source;
    const template = source.find((value) => {
      try {
        return new URL(value).pathname.startsWith("/upgcxcode/");
      } catch (_) {
        return false;
      }
    });
    if (!template) return source;
    const expanded = [...source];
    for (const host of KNOWN_UPOS_HOSTS) {
      const url = new URL(template);
      url.hostname = host;
      url.port = "";
      url.protocol = "https:";
      expanded.push(url.toString());
    }
    return uniqueUrls(expanded);
  }

  function scoreOf(scores, urlOrHost) {
    const host = urlOrHost.includes?.("://") ? hostOf(urlOrHost) : urlOrHost;
    const value = Number(scores?.[host]);
    return Number.isFinite(value) ? value : 50;
  }

  function rankCandidates(values, scores, cooldowns, failedHosts, now = Date.now()) {
    return uniqueUrls(values)
      .map((url, index) => ({ url, index, host: hostOf(url) }))
      .filter(({ host }) => {
        if (!host || failedHosts?.has(host)) return false;
        return Number(cooldowns?.[host] || 0) <= now;
      })
      .sort((a, b) => scoreOf(scores, b.host) - scoreOf(scores, a.host) || a.index - b.index)
      .map(({ url }) => url);
  }

  function streamUrls(stream) {
    if (!stream || typeof stream !== "object") return [];
    const base = stream.baseUrl || stream.base_url;
    const backup = stream.backupUrl || stream.backup_url || [];
    return uniqueUrls([base, ...(Array.isArray(backup) ? backup : [backup])]);
  }

  function streamKind(stream) {
    const mime = String(stream?.mimeType || stream?.mime_type || "").toLowerCase();
    const codec = String(stream?.codecs || "").toLowerCase();
    if (mime.startsWith("audio/")) return "audio";
    if (mime.startsWith("video/")) return "video";
    if (/^(mp4a|ec-3|ac-3|opus)/.test(codec)) return "audio";
    return codecFamily(stream?.codecs) ? "video" : "";
  }

  function selectSwitchTargets(resources, failedResource) {
    if (failedResource) return [failedResource];
    const video = resources.filter((resource) => resource.kind === "video");
    return video.length ? video : resources;
  }

  function collectStreams(rootValue) {
    const streams = [];
    const visited = new Set();
    function walk(value, depth) {
      if (!value || typeof value !== "object" || depth > 9 || visited.has(value)) return;
      visited.add(value);
      if (streamUrls(value).length) streams.push(value);
      if (Array.isArray(value)) {
        for (const item of value) walk(item, depth + 1);
      } else {
        for (const child of Object.values(value)) walk(child, depth + 1);
      }
    }
    walk(rootValue, 0);
    return streams;
  }

  function isAv1Codec(codec) {
    return /^av01/i.test(String(codec || ""));
  }

  function codecFamily(codec) {
    const value = String(codec || "").toLowerCase();
    if (value.startsWith("av01")) return "av1";
    if (value.startsWith("hev1") || value.startsWith("hvc1")) return "hevc";
    if (value.startsWith("avc1")) return "avc";
    return "";
  }

  function reorderVideoArrays(rootValue, preferredCodec, canPlayCodec) {
    if (preferredCodec === true) preferredCodec = "av1";
    if (!preferredCodec || preferredCodec === "default" || !rootValue || typeof rootValue !== "object") return;
    const visited = new Set();
    function walk(value, depth) {
      if (!value || typeof value !== "object" || depth > 8 || visited.has(value)) return;
      visited.add(value);
      if (Array.isArray(value.video) && value.video.some((item) => codecFamily(item?.codecs) === preferredCodec)) {
        value.video.sort((a, b) => {
          if (a?.id !== b?.id) return Number(b?.id || 0) - Number(a?.id || 0);
          return (
            Number(canPlayCodec?.(b?.codecs) && codecFamily(b?.codecs) === preferredCodec) -
            Number(canPlayCodec?.(a?.codecs) && codecFamily(a?.codecs) === preferredCodec)
          );
        });
      }
      for (const child of Object.values(value)) walk(child, depth + 1);
    }
    walk(rootValue, 0);
  }

  function createHealthState(now = 0) {
    return {
      lastBuffered: 0,
      lastBufferProgressAt: now,
      refillStartForward: 0,
      bufferBelowTarget: false,
      lastPosition: 0,
      lastPositionProgressAt: now,
      lastSwitchAt: -Infinity,
      wasTrying: false,
    };
  }

  function resetAtMediaTail(state, sample, now) {
    state.lastBuffered = sample.buffered;
    state.lastBufferProgressAt = now;
    state.refillStartForward = 0;
    state.bufferBelowTarget = false;
    state.lastPosition = sample.position;
    state.lastPositionProgressAt = now;
  }

  function evaluateHealth(state, sample, rawSettings, now) {
    const settings = normalizeSettings(rawSettings);
    const duration = Number(sample.duration) || 0;
    const position = Number(sample.position) || 0;
    const buffered = Math.max(position, Number(sample.buffered) || 0);
    // `video.paused === false` becomes true as soon as play() is accepted,
    // which can be several seconds before the first frame is actually ready.
    // Do not start the CDN-stall clock during that normal startup window.
    const trying =
      Boolean(sample.playing) && sample.hasStartedPlayback !== false && !sample.ended;
    const atTail =
      duration > 0 &&
      position + settings.endToleranceSec >= duration &&
      buffered + Math.min(2, settings.endToleranceSec) >= duration;

    if (atTail) {
      resetAtMediaTail(state, { position, buffered }, now);
      return null;
    }

    const positionDelta = Math.abs(position - state.lastPosition);
    const forward = Math.max(0, buffered - position);
    const startedTrying = trying && !state.wasTrying;
    state.wasTrying = trying;
    if (startedTrying) {
      // Starting or resuming playback begins a new observation window. Time
      // spent loading or explicitly paused must not count toward a CDN stall.
      state.lastBufferProgressAt = now;
      state.refillStartForward = forward;
      state.bufferBelowTarget = false;
    }
    if (positionDelta >= 2 && (buffered < state.lastBuffered || forward <= 1)) {
      state.lastBuffered = buffered;
      state.lastBufferProgressAt = now;
      state.refillStartForward = forward;
      state.bufferBelowTarget = false;
      state.lastPosition = position;
      state.lastPositionProgressAt = now;
      state.lastSwitchAt = now;
      return null;
    }
    if (positionDelta >= 0.25 || !trying) {
      state.lastPosition = position;
      state.lastPositionProgressAt = now;
    }


    state.lastBuffered = buffered;

    const targetFloor = Math.min(
      settings.targetBufferSec,
      Math.max(
        settings.lowBufferSec + settings.segmentToleranceSec,
        settings.targetBufferSec - settings.segmentToleranceSec,
      ),
    );
    if (forward >= targetFloor) {
      state.bufferBelowTarget = false;
      return null;
    }
    if (!state.bufferBelowTarget) {
      state.bufferBelowTarget = true;
      state.lastBufferProgressAt = now;
      state.refillStartForward = forward;
      return null;
    }
    if (trying && now - state.lastBufferProgressAt >= settings.bufferStallSec * 1000) {
      const growth = forward - state.refillStartForward;
      state.lastBufferProgressAt = now;
      state.refillStartForward = forward;
      if (growth >= MIN_BUFFER_GROWTH_SEC) return null;
      state.bufferBelowTarget = false;
      state.lastSwitchAt = now;
      return "buffer-stall";
    }
    return null;
  }

  function shouldPauseForVideoFrameStall(sample, now) {
    const frameGraceAt = Math.max(
      Number(sample.lastFrameAt) || 0,
      Number(sample.playStartedAt) || 0,
    );
    return (
      sample.playing &&
      sample.hasStartedPlayback !== false &&
      !sample.seeking &&
      now >= (Number(sample.recoveryUntil) || 0) &&
      (Number(sample.forwardBuffer) || 0) >= (Number(sample.minForwardBuffer) || 0) &&
      sample.position - sample.lastFramePosition >= 0.5 &&
      now - frameGraceAt >= 8000
    );
  }

  function shouldSwitchForRequestFailure(status, aborted) {
    return !aborted && (status == null || (status !== 200 && status !== 206));
  }

  function isCurrentResourceFailure(currentUrl, failedHost) {
    return !failedHost || hostOf(currentUrl) === failedHost;
  }

  function createNetworkGuardState() {
    return { samples: [], pauseUntil: 0 };
  }

  function shouldPauseNetworkSwitch(state, sample, now) {
    if (now < state.pauseUntil) return true;
    state.samples = state.samples.filter((item) => now - item.at <= 15_000);
    state.samples.push({ at: now, host: sample.host, kind: sample.kind });
    const hosts = new Set(state.samples.map((item) => item.host).filter(Boolean));
    const kinds = new Set(state.samples.map((item) => item.kind).filter(Boolean));
    const looksGlobal =
      state.samples.length >= 3 &&
      (state.samples.length >= 4 || hosts.size >= 2 || kinds.size >= 2);
    if (!looksGlobal) return false;
    state.samples = [];
    state.pauseUntil = now + 20_000;
    return true;
  }

  return Object.freeze({
    DEFAULT_SETTINGS,
    KNOWN_UPOS_HOSTS,
    normalizeSettings,
    hostOf,
    resourceKey,
    isMediaUrl,
    isPlayUrlApi,
    uniqueUrls,
    expandUposCandidates,
    scoreOf,
    rankCandidates,
    streamUrls,
    streamKind,
    selectSwitchTargets,
    collectStreams,
    isAv1Codec,
    codecFamily,
    reorderVideoArrays,
    createHealthState,
    evaluateHealth,
    shouldPauseForVideoFrameStall,
    shouldSwitchForRequestFailure,
    isCurrentResourceFailure,
    createNetworkGuardState,
    shouldPauseNetworkSwitch,
  });
});

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
  const nativeJsonParse = JSON.parse.bind(JSON);

  const sessionPathKey = () => location.pathname.replace(/\/+$/, "");

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
    for (const [controller, request] of activeFetches) {
      if (now - request.createdAt > 90_000) activeFetches.delete(controller);
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
      cooldowns,
      excludeFailed ? failedHosts : null,
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
    const urls = Core.expandUposCandidates(
      Core.streamUrls(stream),
      settings.expandKnownUpos,
    );
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
        kind,
      };
      resources.add(resource);
    }
    if (!resource.kind) resource.kind = kind;
    resource.urls = Core.uniqueUrls([...resource.urls, ...urls]);
    const currentHost = Core.hostOf(resource.currentUrl);
    resource.currentUrl =
      effective.find((url) => Core.hostOf(url) === currentHost) || effective[0];
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
    return { url: resource.currentUrl || url, resource };
  }

  function abortInflightMedia(targets = null) {
    const targetSet = targets ? new Set(targets) : null;
    for (const [controller, request] of activeFetches) {
      if (targetSet && !targetSet.has(request.resource)) continue;
      controller.abort("adaptive-cdn-switch");
      activeFetches.delete(controller);
    }
    for (const xhr of activeXhrs) {
      if (targetSet && !targetSet.has(xhr.__piliAdaptiveResource)) continue;
      try {
        xhr.__piliAdaptiveAborted = true;
        xhr.abort();
      } catch (_) {}
      activeXhrs.delete(xhr);
    }
  }

  function activeResources() {
    const threshold = Date.now() - 90_000;
    const active = [...resources].filter((item) => item.lastRequestAt >= threshold);
    return active.length ? active : [...resources];
  }

  function switchCdn(reason, manual = false, failedHost = null, failedResource = null) {
    if (!settings.enabled || !resources.size) return false;
    const maximum = settings.traverseAllCdns ? Infinity : settings.maxSwitches;
    if (!manual && switchCount >= maximum) {
      lastReason = "已达到本视频最大切换次数";
      emitStatus();
      return false;
    }

    const targets = Core.selectSwitchTargets(activeResources(), failedResource);
    const currentHosts = new Set(
      (failedHost ? [failedHost] : targets.map((item) => Core.hostOf(item.currentUrl))).filter(Boolean),
    );
    for (const host of currentHosts) markFailed(host);

    let changed = 0;
    for (const resource of targets) {
      const previous = resource.currentUrl;
      const ranked = candidatesFor(resource);
      const next = ranked.find((url) => Core.hostOf(url) !== Core.hostOf(previous));
      if (!next) continue;
      resource.currentUrl = next;
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
    if (reason === "buffer-stall") abortInflightMedia(targets);
    const hosts = [...new Set(targets.map((item) => Core.hostOf(item.currentUrl)).filter(Boolean))];
    lastReason = `${reasonLabel(reason)} → ${hosts.join(" / ")}`;
    emitStatus();
    showToast(`Adaptive CDN：${lastReason}`);
    return true;
  }

  function switchAfterRequestFailure(reason, resource, failedHost) {
    // Parallel requests from an old host can finish after another request has
    // already switched this resource. Such stale failures must not advance the
    // resource through several more CDNs.
    if (resource && !Core.isCurrentResourceFailure(resource.currentUrl, failedHost)) {
      return false;
    }
    if (
      Core.shouldPauseNetworkSwitch(
        networkGuard,
        { host: failedHost, kind: resource?.kind },
        Date.now(),
      )
    ) {
      lastReason = "检测到整体网络异常，暂停 CDN 切换 20 秒";
      emitStatus();
      return false;
    }
    return switchCdn(reason, false, failedHost, resource);
  }

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
    if (signal) {
      if (signal.aborted) controller.abort(signal.reason);
      else signal.addEventListener("abort", () => controller.abort(signal.reason), { once: true });
    }
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

  async function patchPlayUrlResponse(response) {
    try {
      const data = await response.clone().json();
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
      return patchPlayUrlResponse(await nativeFetch(input, init));
    }

    const rewritten = rewriteMediaUrl(originalUrl);
    if (!rewritten.resource) return nativeFetch(input, init);

    const controller = new AbortController();
    combineSignal(controller, input, init);
    activeFetches.set(controller, { createdAt: Date.now(), resource: rewritten.resource });
    try {
      const response = await nativeFetch(mediaFetchInput(input, rewritten.url), {
        ...init,
        signal: controller.signal,
      });
      if (Core.shouldSwitchForRequestFailure(response.status, controller.signal.aborted)) {
        switchAfterRequestFailure("http-error", rewritten.resource, Core.hostOf(rewritten.url));
      }
      return response;
    } catch (error) {
      if (Core.shouldSwitchForRequestFailure(null, controller.signal.aborted)) {
        switchAfterRequestFailure("network-error", rewritten.resource, Core.hostOf(rewritten.url));
      }
      throw error;
    } finally {
      activeFetches.delete(controller);
    }
  };

  XMLHttpRequest.prototype.open = function adaptiveOpen(method, url, ...rest) {
    const originalUrl = String(url);
    const rewritten = rewriteMediaUrl(originalUrl);
    this.__piliAdaptiveResource = rewritten.resource;
    this.__piliAdaptiveHost = Core.hostOf(rewritten.url);
    this.__piliAdaptivePlayUrl = Core.isPlayUrlApi(originalUrl);
    if (this.__piliAdaptivePlayUrl) {
      this.addEventListener(
        "readystatechange",
        () => {
          if (this.readyState !== 4) return;
          try {
            if (this.responseType === "json") processPlayInfo(this.response);
          } catch (_) {}
        },
        true,
      );
    }
    return nativeXhrOpen.call(this, method, rewritten.url, ...rest);
  };

  XMLHttpRequest.prototype.send = function adaptiveSend(body) {
    if (this.__piliAdaptiveResource) {
      this.__piliAdaptiveAborted = false;
      this.__piliAdaptiveHandledFailure = false;
      activeXhrs.add(this);
      this.addEventListener(
        "abort",
        () => {
          // The player routinely cancels obsolete range requests while
          // seeking, changing quality, or replacing a MediaSource. This is
          // not a CDN failure and must never advance the candidate list.
          this.__piliAdaptiveAborted = true;
          this.__piliAdaptiveHandledFailure = true;
          activeXhrs.delete(this);
        },
        { once: true },
      );
      this.addEventListener(
        "loadend",
        () => {
          activeXhrs.delete(this);
          if (
            !this.__piliAdaptiveHandledFailure &&
            Core.shouldSwitchForRequestFailure(this.status, this.__piliAdaptiveAborted)
          ) {
            this.__piliAdaptiveHandledFailure = true;
            switchAfterRequestFailure(
              "http-error",
              this.__piliAdaptiveResource,
              this.__piliAdaptiveHost,
            );
          }
        },
        { once: true },
      );
      this.addEventListener(
        "error",
        () => {
          if (Core.shouldSwitchForRequestFailure(null, this.__piliAdaptiveAborted)) {
            this.__piliAdaptiveHandledFailure = true;
            switchAfterRequestFailure(
              "network-error",
              this.__piliAdaptiveResource,
              this.__piliAdaptiveHost,
            );
          }
        },
        { once: true },
      );
    }
    return nativeXhrSend.call(this, body);
  };

  JSON.parse = function adaptiveJsonParse(text, reviver) {
    const value = nativeJsonParse(text, reviver);
    if (
      settings.enabled &&
      typeof text === "string" &&
      (text.includes('"baseUrl"') || text.includes('"base_url"'))
    ) {
      processPlayInfo(value);
    }
    return value;
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
    if (!video) return;
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
    abortInflightMedia();
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

(function () {
  "use strict";
  const BRIDGE_SOURCE = "pili-adaptive-cdn-bridge";
  const PAGE_SOURCE = "pili-adaptive-cdn-page";
  const KEY_PREFIX = "piliPlusAdaptiveCdn:";
  function readJson(key, fallback) {
    try {
      const raw = localStorage.getItem(KEY_PREFIX + key);
      return raw ? JSON.parse(raw) : fallback;
    } catch (_) {
      return fallback;
    }
  }
  function writeJson(key, value) {
    try {
      localStorage.setItem(KEY_PREFIX + key, JSON.stringify(value || {}));
    } catch (_) {}
  }
  function post(type, payload) {
    window.postMessage({ source: BRIDGE_SOURCE, type, payload }, "*");
  }
  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== PAGE_SOURCE) return;
    if (event.data.type === "ready") {
      post("config", {
        settings: readJson("settings", {}),
        scores: readJson("scores", {}),
        cooldowns: readJson("cooldowns", {}),
      });
    } else if (event.data.type === "scores") {
      writeJson("scores", event.data.payload);
    } else if (event.data.type === "cooldowns") {
      writeJson("cooldowns", event.data.payload);
    }
  });
})();
