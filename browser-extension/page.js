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

  let settings = Core.normalizeSettings();
  let scores = {};
  let cooldowns = {};
  let sessionPath = location.pathname;
  let switchCount = 0;
  let lastReason = "等待播放地址";
  let lastBufferSeconds = 0;
  let lastRewardAt = Date.now();
  let lastRewardPosition = 0;
  let health = Core.createHealthState(Date.now());

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

  function canPlayAv1() {
    if (!settings.preferAv1 || !window.MediaSource?.isTypeSupported) return false;
    return window.MediaSource.isTypeSupported('video/mp4; codecs="av01.0.08M.08"');
  }

  function cleanExpiredState(now = Date.now()) {
    for (const [host, until] of Object.entries(cooldowns)) {
      if (Number(until) <= now) delete cooldowns[host];
    }
    for (const [controller, createdAt] of activeFetches) {
      if (now - createdAt > 90_000) activeFetches.delete(controller);
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
      };
      resources.add(resource);
    }
    resource.urls = Core.uniqueUrls([...resource.urls, ...urls]);
    const currentHost = Core.hostOf(resource.currentUrl);
    resource.currentUrl =
      effective.find((url) => Core.hostOf(url) === currentHost) || effective[0];
    for (const url of resource.urls) aliases.set(Core.resourceKey(url), resource);
  }

  function processPlayInfo(value) {
    if (!value || typeof value !== "object" || processedObjects.has(value)) return value;
    const streams = Core.collectStreams(value);
    if (!streams.length) return value;
    processedObjects.add(value);
    Core.reorderVideoArrays(value, canPlayAv1());
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

  function abortInflightMedia() {
    for (const controller of activeFetches.keys()) controller.abort("adaptive-cdn-switch");
    activeFetches.clear();
    for (const xhr of activeXhrs) {
      try {
        xhr.abort();
      } catch (_) {}
    }
    activeXhrs.clear();
  }

  function activeResources() {
    const threshold = Date.now() - 90_000;
    const active = [...resources].filter((item) => item.lastRequestAt >= threshold);
    return active.length ? active : [...resources];
  }

  function switchCdn(reason, manual = false) {
    if (!settings.enabled || !resources.size) return false;
    const maximum = settings.traverseAllCdns ? Infinity : settings.maxSwitches;
    if (!manual && switchCount >= maximum) {
      lastReason = "已达到本视频最大切换次数";
      emitStatus();
      return false;
    }

    const targets = activeResources();
    const currentHosts = new Set(targets.map((item) => Core.hostOf(item.currentUrl)).filter(Boolean));
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
    abortInflightMedia();
    const hosts = [...new Set(targets.map((item) => Core.hostOf(item.currentUrl)).filter(Boolean))];
    lastReason = `${reasonLabel(reason)} → ${hosts.join(" / ")}`;
    emitStatus();
    showToast(`Adaptive CDN：${lastReason}`);
    return true;
  }

  function reasonLabel(reason) {
    return (
      {
        "position-stall": "播放位置停滞",
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
    activeFetches.set(controller, Date.now());
    try {
      const response = await nativeFetch(mediaFetchInput(input, rewritten.url), {
        ...init,
        signal: controller.signal,
      });
      if (!response.ok && response.status >= 500) switchCdn("http-error");
      return response;
    } catch (error) {
      if (!controller.signal.aborted) switchCdn("network-error");
      throw error;
    }
  };

  XMLHttpRequest.prototype.open = function adaptiveOpen(method, url, ...rest) {
    const originalUrl = String(url);
    const rewritten = rewriteMediaUrl(originalUrl);
    this.__piliAdaptiveResource = rewritten.resource;
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
      activeXhrs.add(this);
      this.addEventListener(
        "loadend",
        () => {
          activeXhrs.delete(this);
          if (this.status >= 500) switchCdn("http-error");
        },
        { once: true },
      );
      this.addEventListener("error", () => switchCdn("network-error"), { once: true });
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
    if (location.pathname !== sessionPath) resetVideoSession();
    if (!settings.enabled) return;
    const video = document.querySelector("video");
    if (!video) return;
    const now = Date.now();
    const end = bufferedEnd(video);
    lastBufferSeconds = Math.max(0, end - video.currentTime);
    const reason = Core.evaluateHealth(
      health,
      {
        duration: video.duration,
        position: video.currentTime,
        buffered: end,
        playing: !video.paused,
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
    resources.clear();
    aliases.clear();
    failedHosts.clear();
    switchCount = 0;
    lastReason = "等待播放地址";
    lastBufferSeconds = 0;
    sessionPath = location.pathname;
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
