function parseYouTubeURL(input) {
  let url;
  try {
    url = new URL(input);
  } catch {
    return null;
  }
  const host = url.hostname.replace(/^www\./, "");
  let videoId = "";
  if (host === "youtu.be") {
    videoId = url.pathname.split("/").filter(Boolean)[0] || "";
  } else if (host === "youtube.com" || host === "m.youtube.com") {
    if (url.pathname === "/watch") {
      videoId = url.searchParams.get("v") || "";
    } else {
      const parts = url.pathname.split("/").filter(Boolean);
      if ((parts[0] === "shorts" || parts[0] === "embed") && parts[1]) {
        videoId = parts[1];
      }
    }
  }
  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) return null;
  return { videoId, canonicalURL: `https://www.youtube.com/watch?v=${videoId}` };
}

function textFromSelectors(selectors) {
  for (const selector of selectors) {
    const element = document.querySelector(selector);
    const text = element?.textContent?.trim();
    if (text) return text;
  }
  return undefined;
}

function extractVideoContext() {
  const parsed = parseYouTubeURL(window.location.href);
  if (!parsed) return { isVideo: false };

  const video = document.querySelector("video");
  const title =
    textFromSelectors(["h1.ytd-watch-metadata", "h1.title", "meta[property='og:title']"]) ||
    document.title.replace(/\s+-\s+YouTube$/, "");
  const channelName = textFromSelectors([
    "#owner #channel-name a",
    "ytd-video-owner-renderer #channel-name a",
    "meta[itemprop='author']"
  ]);

  return {
    isVideo: true,
    videoId: parsed.videoId,
    canonicalURL: parsed.canonicalURL,
    title,
    channelName,
    durationSeconds: Number.isFinite(video?.duration) ? Math.floor(video.duration) : undefined,
    currentTimeSeconds: Number.isFinite(video?.currentTime) ? Math.floor(video.currentTime) : undefined,
    thumbnailURL: `https://i.ytimg.com/vi/${parsed.videoId}/hqdefault.jpg`
  };
}

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type === "GET_YOUTUBE_CONTEXT") {
    sendResponse(extractVideoContext());
  }
  return true;
});

// Report the currently opened watch page to the Mac app so it can surface a
// "recently watched" suggestion. YouTube is a single-page app, so we report on
// initial load and again whenever it navigates between videos, debounced so the
// title/channel DOM has time to settle.
let reportTimer;
function reportWatch() {
  clearTimeout(reportTimer);
  reportTimer = setTimeout(() => {
    const context = extractVideoContext();
    if (!context.isVideo) return;
    try {
      chrome.runtime.sendMessage({ type: "REPORT_WATCH", payload: context });
    } catch {
      // Extension context can be invalidated on reload; ignore.
    }
  }, 1500);
}

// Print the running version so you can confirm at a glance (YouTube page console)
// that the newest content script is actually injected into this tab.
console.info(`[TubeFold] content script v${chrome.runtime.getManifest().version} loaded`);

reportWatch();
document.addEventListener("yt-navigate-finish", reportWatch);
