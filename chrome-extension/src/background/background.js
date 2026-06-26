const API_BASE_URL = "http://127.0.0.1:43821";
const API_TOKEN_STORAGE_KEY = "tubefoldApiToken";

async function storedToken() {
  const data = await chrome.storage.local.get(API_TOKEN_STORAGE_KEY);
  return data[API_TOKEN_STORAGE_KEY] || "";
}

async function apiFetch(path, options = {}) {
  const token = await storedToken();
  const headers = {
    ...(options.headers || {})
  };
  if (token) headers.Authorization = `Bearer ${token}`;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeout || 2000);
  try {
    const response = await fetch(`${API_BASE_URL}${path}`, {
      ...options,
      headers,
      signal: controller.signal
    });
    const text = await response.text();
    const body = text ? JSON.parse(text) : {};
    if (!response.ok) {
      throw new Error(body?.error?.message || `HTTP ${response.status}`);
    }
    return body;
  } finally {
    clearTimeout(timer);
  }
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  (async () => {
    if (message?.type === "HEALTH_CHECK") {
      sendResponse({ ok: true, body: await apiFetch("/health", { timeout: 1500 }) });
      return;
    }
    if (message?.type === "SUBMIT_SUMMARY") {
      const body = await apiFetch("/api/v1/summaries", {
        method: "POST",
        timeout: 5000,
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ ...message.payload, source: "chrome-extension" })
      });
      sendResponse({ ok: true, body });
      return;
    }
    if (message?.type === "REPORT_WATCH") {
      // Fire-and-forget: the Mac app is often closed, so swallow any failure.
      try {
        await apiFetch("/api/v1/watch-activity", {
          method: "POST",
          timeout: 2000,
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ ...message.payload, source: "chrome-extension" })
        });
        sendResponse({ ok: true });
      } catch (error) {
        sendResponse({ ok: false, error: error.message || String(error) });
      }
      return;
    }
    if (message?.type === "LOOKUP_VIDEO") {
      const youtubeId = encodeURIComponent(message.youtubeId || "");
      const body = await apiFetch(`/api/v1/videos/by-youtube-id/${youtubeId}`, { timeout: 2500 });
      sendResponse({ ok: true, body });
      return;
    }
    if (message?.type === "PUBLISH_TELEGRAPH") {
      const videoId = encodeURIComponent(message.videoId || "");
      const body = await apiFetch(`/api/v1/videos/${videoId}/publish-telegraph`, {
        method: "POST",
        timeout: 30000
      });
      if (body?.url) {
        await chrome.tabs.create({ url: body.url });
      }
      sendResponse({ ok: true, body });
      return;
    }
    if (message?.type === "OPEN_MAC_APP") {
      const rawURL = message.url || "";
      const targetURL = rawURL.startsWith("tubefold://")
        ? rawURL
        : `tubefold://summarize?url=${encodeURIComponent(rawURL)}`;
      await chrome.tabs.create({ url: targetURL });
      sendResponse({ ok: true });
      return;
    }
    sendResponse({ ok: false, error: "Unknown message" });
  })().catch((error) => {
    sendResponse({ ok: false, error: error.message || String(error) });
  });
  return true;
});
