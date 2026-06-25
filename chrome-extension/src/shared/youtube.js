export function parseYouTubeURL(input) {
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

  if (!/^[A-Za-z0-9_-]{11}$/.test(videoId)) {
    return null;
  }

  return {
    videoId,
    canonicalURL: `https://www.youtube.com/watch?v=${videoId}`
  };
}

export function thumbnailURL(videoId) {
  return `https://i.ytimg.com/vi/${videoId}/hqdefault.jpg`;
}
