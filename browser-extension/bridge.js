(function () {
  "use strict";

  const PAGE_SOURCE = "pili-adaptive-cdn-page";
  const BRIDGE_SOURCE = "pili-adaptive-cdn-bridge";
  let latestStatus = null;

  function post(type, payload) {
    window.postMessage({ source: BRIDGE_SOURCE, type, payload }, "*");
  }

  async function sendConfig() {
    const stored = await chrome.storage.local.get(["settings", "scores", "cooldowns"]);
    post("config", stored);
  }

  window.addEventListener("message", (event) => {
    if (event.source !== window || event.data?.source !== PAGE_SOURCE) return;
    if (event.data.type === "ready") {
      sendConfig();
    } else if (event.data.type === "status") {
      latestStatus = event.data.payload;
    } else if (event.data.type === "scores") {
      chrome.storage.local.set({ scores: event.data.payload || {} });
    } else if (event.data.type === "cooldowns") {
      chrome.storage.local.set({ cooldowns: event.data.payload || {} });
    }
  });

  chrome.storage.onChanged.addListener((changes, areaName) => {
    if (areaName !== "local") return;
    if (changes.settings || changes.scores || changes.cooldowns) sendConfig();
  });

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (message?.type === "get-status") {
      post("get-status", null);
      setTimeout(() => sendResponse(latestStatus), 100);
      return true;
    }
    if (message?.type === "manual-switch") {
      post("manual-switch", null);
      sendResponse({ ok: true });
    }
    return false;
  });

  sendConfig();
})();
