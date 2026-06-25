function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const total = Math.floor(seconds);
  const h = Math.floor(total / 3600);
  const m = Math.floor((total % 3600) / 60);
  const s = total % 60;
  return h ? `${h}:${String(m).padStart(2, "0")}:${String(s).padStart(2, "0")}` : `${m}:${String(s).padStart(2, "0")}`;
}

function setConnection(text, isError = false) {
  const element = document.getElementById("connection");
  element.textContent = text;
  element.classList.toggle("error", isError);
}

function render(html) {
  document.getElementById("content").innerHTML = html;
}

async function activeTab() {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  return tab;
}

async function getContext(tab) {
  try {
    return await chrome.tabs.sendMessage(tab.id, { type: "GET_YOUTUBE_CONTEXT" });
  } catch {
    return { isVideo: false };
  }
}

async function healthCheck() {
  return chrome.runtime.sendMessage({ type: "HEALTH_CHECK" });
}

async function submitSummary(context) {
  return chrome.runtime.sendMessage({
    type: "SUBMIT_SUMMARY",
    payload: {
      videoId: context.videoId,
      url: context.canonicalURL,
      title: context.title,
      channelName: context.channelName,
      durationSeconds: context.durationSeconds,
      currentTimeSeconds: context.currentTimeSeconds,
      thumbnailURL: context.thumbnailURL
    }
  });
}

function renderNotVideo() {
  setConnection("");
  render(`<p class="muted">Open a YouTube video to create a summary.</p>`);
}

function renderMacAppClosed(context) {
  setConnection("Mac app is not running.", true);
  render(`
    <p class="muted">Start the local YouTube Brain app, then try again.</p>
    <div class="actions">
      <button id="openApp" class="primary">Open Mac App</button>
      <button id="retry">Try Again</button>
    </div>
  `);
  document.getElementById("openApp").addEventListener("click", () => {
    chrome.runtime.sendMessage({ type: "OPEN_MAC_APP", url: context?.canonicalURL || "" });
  });
  document.getElementById("retry").addEventListener("click", init);
}

function renderVideo(context) {
  setConnection("Mac app connected");
  render(`
    ${context.thumbnailURL ? `<img class="thumbnail" src="${context.thumbnailURL}" alt="">` : ""}
    <p class="title"></p>
    <p class="meta"></p>
    <div class="actions">
      <button id="create" class="primary">Create Summary</button>
    </div>
  `);
  document.querySelector(".title").textContent = context.title || context.videoId;
  document.querySelector(".meta").textContent = [context.channelName, formatDuration(context.durationSeconds)].filter(Boolean).join(" · ");
  document.getElementById("create").addEventListener("click", async () => {
    const button = document.getElementById("create");
    button.disabled = true;
    button.textContent = "Sending...";
    const response = await submitSummary(context);
    if (!response?.ok) {
      renderError(response?.error || "Could not send the video.", context);
      return;
    }
    const status = response.body?.status;
    if (status === "already_exists") {
      renderAlreadyExists(response.body.videoId);
    } else if (status === "already_processing") {
      renderSent("This video is already being processed.");
    } else {
      renderSent("The summary is being generated in the Mac app.");
    }
  });
}

function renderSent(message) {
  setConnection("Sent to YouTube Brain");
  render(`<p class="muted">${message}</p>`);
}

function renderAlreadyExists(videoId) {
  setConnection("Already in library");
  render(`
    <p class="muted">This video is already in your library.</p>
    <div class="actions">
      <button id="openApp" class="primary">Open in Mac App</button>
    </div>
  `);
  document.getElementById("openApp").addEventListener("click", () => {
    chrome.runtime.sendMessage({ type: "OPEN_MAC_APP", url: `youtubebrain://video/${videoId}` });
  });
}

function renderError(message, context) {
  setConnection("Could not send the video.", true);
  render(`
    <p class="error">${message}</p>
    <div class="actions">
      <button id="retry" class="primary">Try Again</button>
    </div>
  `);
  document.getElementById("retry").addEventListener("click", () => renderVideo(context));
}

async function init() {
  const tab = await activeTab();
  const context = await getContext(tab);
  if (!context?.isVideo) {
    renderNotVideo();
    return;
  }
  const health = await healthCheck();
  if (!health?.ok) {
    renderMacAppClosed(context);
    return;
  }
  renderVideo(context);
}

init().catch((error) => renderError(error.message || String(error), null));
