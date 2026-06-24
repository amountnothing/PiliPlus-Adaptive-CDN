(async function () {
  "use strict";

  const enabled = document.getElementById("enabled");
  const stored = await chrome.storage.local.get("settings");
  enabled.checked = stored.settings?.enabled !== false;

  enabled.addEventListener("change", async () => {
    const current = (await chrome.storage.local.get("settings")).settings || {};
    await chrome.storage.local.set({ settings: { ...current, enabled: enabled.checked } });
  });

  document.getElementById("open-options").addEventListener("click", () => {
    chrome.runtime.openOptionsPage();
  });

  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  const supported = /^https:\/\/www\.bilibili\.com\/(video|bangumi\/play)\//.test(tab?.url || "");
  if (!supported) {
    document.getElementById("summary").textContent = "请在哔哩哔哩视频页使用";
    document.getElementById("manual-switch").disabled = true;
    return;
  }

  async function send(message) {
    try {
      return await chrome.tabs.sendMessage(tab.id, message);
    } catch (_) {
      return null;
    }
  }

  function render(status) {
    if (!status) {
      document.getElementById("summary").textContent = "刷新视频页面后开始监控";
      return;
    }
    enabled.checked = status.enabled;
    document.getElementById("summary").textContent = status.enabled ? "监控中" : "已关闭";
    document.getElementById("current-host").textContent = status.currentHosts?.join(" / ") || "—";
    document.getElementById("buffer").textContent = `${status.forwardBuffer ?? 0}s`;
    document.getElementById("switches").textContent = String(status.switches ?? 0);
    document.getElementById("candidate-count").textContent = String(status.candidateHosts?.length ?? 0);
    document.getElementById("reason").textContent = status.reason || "等待播放地址";
  }

  render(await send({ type: "get-status" }));
  document.getElementById("manual-switch").addEventListener("click", async () => {
    await send({ type: "manual-switch" });
    setTimeout(async () => render(await send({ type: "get-status" })), 180);
  });
})();
