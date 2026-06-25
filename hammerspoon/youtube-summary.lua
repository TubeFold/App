local M = {}

M.hotkeyModifiers = { "cmd", "alt" }
M.hotkeyKey = "Y"
M.cliPath = os.getenv("YOUTUBE_SUMMARY_CLI") or os.getenv("HOME") .. "/.local/bin/youtube-summary"
M.shellPath = "/bin/zsh"
M.path = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

local currentTask = nil

local browserScripts = {
  ["Safari"] = 'tell application "Safari" to return URL of current tab of front window',
  ["Google Chrome"] = 'tell application "Google Chrome" to return URL of active tab of front window',
  ["Arc"] = 'tell application "Arc" to return URL of active tab of front window',
  ["Brave Browser"] = 'tell application "Brave Browser" to return URL of active tab of front window',
  ["Microsoft Edge"] = 'tell application "Microsoft Edge" to return URL of active tab of front window',
}

local function notify(title, text)
  hs.notify.new({ title = title, informativeText = text or "" }):send()
end

local function shellQuote(value)
  return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function isYouTubeVideoUrl(url)
  if not url then return false end
  return url:match("^https://www%.youtube%.com/watch%?") or
    url:match("^https://youtube%.com/watch%?") or
    url:match("^https://www%.youtube%.com/shorts/") or
    url:match("^https://youtube%.com/shorts/") or
    url:match("^https://www%.youtube%.com/embed/") or
    url:match("^https://youtube%.com/embed/") or
    url:match("^https://youtu%.be/")
end

local function currentBrowserUrl()
  local app = hs.application.frontmostApplication()
  if not app then return nil, "No active application" end

  local appName = app:name()
  local script = browserScripts[appName]
  if not script then
    return nil, "Unsupported browser: " .. appName
  end

  local ok, result = hs.osascript.applescript(script)
  if not ok or not result or result == "" then
    return nil, "Could not read active tab URL"
  end
  return result, nil
end

function M.run()
  if currentTask then
    notify("YouTube Summary", "Summary is already running")
    return
  end

  local url, errorMessage = currentBrowserUrl()
  if not url then
    notify("YouTube Summary", errorMessage)
    return
  end

  if not isYouTubeVideoUrl(url) then
    notify("YouTube Summary", "Active tab is not a YouTube video")
    return
  end

  notify("YouTube Summary", "Processing started")

  local command = "export PATH=" .. shellQuote(M.path) .. "; " .. shellQuote(M.cliPath) .. " " .. shellQuote(url)
  currentTask = hs.task.new(M.shellPath, function(exitCode, stdOut, stdErr)
    currentTask = nil
    if exitCode == 0 then
      local path = (stdOut or ""):match("^%s*(.-)%s*$")
      notify("YouTube Summary", path ~= "" and path or "Summary is ready")
    else
      local message = (stdErr or stdOut or ""):match("[^\r\n]+") or "Command failed"
      notify("YouTube Summary Error", message)
    end
  end, { "-lc", command })

  if not currentTask:start() then
    currentTask = nil
    notify("YouTube Summary Error", "Could not start CLI task")
  end
end

function M.bindHotkey()
  hs.hotkey.bind(M.hotkeyModifiers, M.hotkeyKey, M.run)
end

M.bindHotkey()

return M
