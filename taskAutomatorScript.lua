-- Paste into ~/.hammerspoon/init.lua and Reload Config
-- Hotkeys:
--  Ctrl+Alt+Cmd+R      -> Toggle recording
--  Ctrl+Alt+Cmd+P      -> Play once
--  Ctrl+Alt+Cmd+Shift+P-> Toggle infinite loop playback
--  Ctrl+Alt+Cmd+1-9    -> Play N times (1-9)
--  Ctrl+Alt+Cmd+X      -> Stop playback immediately
--  Ctrl+Alt+Cmd+S      -> Save to ~/keystroke_recording.json
--  Ctrl+Alt+Cmd+Shift+S-> Save As (prompts for name)
--  Ctrl+Alt+Cmd+L      -> Load from ~/keystroke_recording.json
--  Ctrl+Alt+Cmd+Shift+L-> Load From (choose file)
--  Ctrl+Alt+Cmd+C      -> Clear current recording
--  Ctrl+Alt+Cmd+M      -> Toggle mouse-move recording
--  Ctrl+Alt+Cmd+I      -> Show info about current recording
--  Ctrl+Alt+Cmd+H      -> Show help

local json = require("hs.json")
local timer = require("hs.timer")
local eventtap = hs.eventtap
local alert = hs.alert
local hotkey = hs.hotkey
local keycodes = hs.keycodes
local fs = hs.fs
local dialog = hs.dialog

local defaultPath = os.getenv("HOME") .. "/keystroke_recording.json"
local currentPath = defaultPath

-- Settings
local RECORD_MOUSE_MOVES = false
local AUTO_COMPRESS_ON_SAVE = true
local SHOW_ALERTS = true
local PLAYBACK_SPEED = 1.0  -- 1.0 = normal, 2.0 = double speed, 0.5 = half speed

-- State
local recording = false
local startTime = nil
local events = {}
local recordingName = "Untitled"

-- Playback state
local playbackTimers = {}
local playbackRunning = false
local playbackLooping = false
local playbackRunDuration = nil
local playbackCount = 0

-- Special key mapping for non-printable keys
local specialKeys = {
    [51] = "delete",      -- backspace
    [117] = "forwarddelete",
    [36] = "return",
    [76] = "return",      -- numpad enter
    [48] = "tab",
    [53] = "escape",
    [123] = "left",
    [124] = "right",
    [125] = "down",
    [126] = "up",
    [115] = "home",
    [119] = "end",
    [116] = "pageup",
    [121] = "pagedown",
    [49] = "space",
}

-- Utility functions
local function showAlert(msg)
    if SHOW_ALERTS then
        alert.show(msg, 2)
    end
    print("[Recorder] " .. msg)
end

local function flagsToList(flags)
    local out = {}
    if flags.cmd then table.insert(out, "cmd") end
    if flags.alt then table.insert(out, "alt") end
    if flags.ctrl then table.insert(out, "ctrl") end
    if flags.shift then table.insert(out, "shift") end
    if flags.fn then table.insert(out, "fn") end
    return out
end

local function buildWatchTypes(includeMouseMoves)
    local t = eventtap.event.types
    local types = {
        t.keyDown,
        t.keyUp,
        t.leftMouseDown,
        t.leftMouseUp,
        t.rightMouseDown,
        t.rightMouseUp,
        t.otherMouseDown,
        t.otherMouseUp,
        t.scrollWheel,
    }
    if includeMouseMoves then 
        table.insert(types, t.mouseMoved)
    end
    return types
end

-- Enhanced key code to string conversion
local function keyCodeToString(keyCode, chars)
    if chars and chars ~= "" then
        return chars
    end
    
    if specialKeys[keyCode] then
        return specialKeys[keyCode]
    end
    
    local mapped
    local success = pcall(function()
        mapped = keycodes.map[keyCode]
    end)
    
    if success and mapped and type(mapped) == "string" then
        return mapped
    end
    
    return "key" .. tostring(keyCode)
end

-- Event tap creation
local evtTap = nil
local function makeEventTap()
    if evtTap then
        pcall(function() evtTap:stop() end)
        evtTap = nil
    end
    
    local types = buildWatchTypes(RECORD_MOUSE_MOVES)
    evtTap = eventtap.new(types, function(e)
        if not recording then return false end
        
        local now = timer.secondsSinceEpoch()
        local t = now - startTime
        local et = e:getType()

        -- Handle keyboard events
        if et == eventtap.event.types.keyDown or et == eventtap.event.types.keyUp then
            local evTypeStr = (et == eventtap.event.types.keyDown) and "down" or "up"
            local chars = e:getCharacters(true)
            local keyCode = e:getKeyCode()
            local flags = flagsToList(e:getFlags())
            local keyStr = keyCodeToString(keyCode, chars)
            
            table.insert(events, {
                t = t,
                kind = "key",
                subtype = evTypeStr,
                chars = chars,
                key = keyStr,
                keyCode = keyCode,
                flags = flags
            })
            return false
        end

        -- Handle scroll wheel
        if et == eventtap.event.types.scrollWheel then
            local dx = e:getProperty(eventtap.event.properties.scrollWheelEventDeltaAxis1)
            local dy = e:getProperty(eventtap.event.properties.scrollWheelEventDeltaAxis2)
            local pt = e:location()
            
            table.insert(events, {
                t = t,
                kind = "scroll",
                point = { x = pt.x, y = pt.y },
                delta = { x = dx, y = dy }
            })
            return false
        end

        -- Handle mouse events
        if et == eventtap.event.types.leftMouseDown
            or et == eventtap.event.types.leftMouseUp
            or et == eventtap.event.types.rightMouseDown
            or et == eventtap.event.types.rightMouseUp
            or et == eventtap.event.types.otherMouseDown
            or et == eventtap.event.types.otherMouseUp
            or (RECORD_MOUSE_MOVES and et == eventtap.event.types.mouseMoved) then

            local pt = e:location()
            local flags = flagsToList(e:getFlags())
            table.insert(events, {
                t = t,
                kind = "mouse",
                subtype = et,
                point = { x = pt.x, y = pt.y },
                flags = flags
            })
            return false
        end

        return false
    end)
end

makeEventTap()

-- Recording controls
local function toggleRecording()
    if not recording then
        events = {}
        startTime = timer.secondsSinceEpoch()
        recording = true
        if evtTap then evtTap:start() end
        showAlert("🔴 Recording started")
    else
        recording = false
        if evtTap then evtTap:stop() end
        showAlert("⏹️ Recording stopped — " .. tostring(#events) .. " events")
        playbackRunDuration = nil
    end
end

-- Duration computation
local function computeTotalDuration(evts)
    local maxT = 0
    for _, ev in ipairs(evts) do
        if ev.kind == "mouse_hold" then
            local endT = (ev.t or 0) + (ev.duration or 0)
            if endT > maxT then maxT = endT end
        else
            local et = ev.t or 0
            if et > maxT then maxT = et end
        end
    end
    return maxT
end

-- Event playback
local function performEventAction(ev)
    if ev.kind == "key" then
        local isDown = (ev.subtype == "down")
        local mods = ev.flags or {}
        local key = ev.key or ev.chars
        
        if not key or key == "" then
            key = keyCodeToString(ev.keyCode, ev.chars)
        end
        
        local success, evt = pcall(function()
            return eventtap.event.newKeyEvent(mods, key, isDown)
        end)
        
        if success and evt then
            evt:post()
        else
            print("[Recorder] Failed to post key event: " .. tostring(key))
        end

    elseif ev.kind == "scroll" then
        local pt = ev.point or { x = 0, y = 0 }
        local delta = ev.delta or { x = 0, y = 0 }
        
        local moveEvt = eventtap.event.newMouseEvent(eventtap.event.types.mouseMoved, {x=pt.x, y=pt.y})
        if moveEvt then moveEvt:post() end
        
        local scrollEvt = eventtap.event.newScrollEvent({delta.x, delta.y}, {}, "pixel")
        if scrollEvt then scrollEvt:post() end

    elseif ev.kind == "mouse" then
        local pt = ev.point or { x = 0, y = 0 }
        local moveEvt = eventtap.event.newMouseEvent(eventtap.event.types.mouseMoved, {x=pt.x, y=pt.y})
        if moveEvt then moveEvt:post() end
        
        local subtype = ev.subtype
        if subtype == eventtap.event.types.leftMouseDown
            or subtype == eventtap.event.types.leftMouseUp
            or subtype == eventtap.event.types.rightMouseDown
            or subtype == eventtap.event.types.rightMouseUp
            or subtype == eventtap.event.types.otherMouseDown
            or subtype == eventtap.event.types.otherMouseUp then
            local mEvt = eventtap.event.newMouseEvent(subtype, {x=pt.x, y=pt.y})
            if mEvt then mEvt:post() end
        end

    elseif ev.kind == "mouse_hold" then
        local pt = ev.point or { x = 0, y = 0 }
        local button = ev.button or "left"
        local downType = (button == "left") and eventtap.event.types.leftMouseDown
                       or (button == "right") and eventtap.event.types.rightMouseDown
                       or eventtap.event.types.otherMouseDown
        local upType = (button == "left") and eventtap.event.types.leftMouseUp
                     or (button == "right") and eventtap.event.types.rightMouseUp
                     or eventtap.event.types.otherMouseUp
        
        local moveEvt = eventtap.event.newMouseEvent(eventtap.event.types.mouseMoved, {x=pt.x, y=pt.y})
        if moveEvt then moveEvt:post() end
        local downEvt = eventtap.event.newMouseEvent(downType, {x=pt.x, y=pt.y})
        if downEvt then downEvt:post() end
        
        if ev.duration and ev.duration > 0 then
            local adjustedDuration = ev.duration / PLAYBACK_SPEED
            local upTimer = timer.doAfter(adjustedDuration, function()
                local upEvt = eventtap.event.newMouseEvent(upType, {x=pt.x, y=pt.y})
                if upEvt then upEvt:post() end
            end)
            table.insert(playbackTimers, upTimer)
        end
    end
end

-- Timer management
local function cancelPlaybackTimers()
    for _, t in ipairs(playbackTimers) do
        if t and t.stop then pcall(function() t:stop() end) end
    end
    playbackTimers = {}
    playbackRunning = false
    playbackLooping = false
    playbackCount = 0
end

local function schedulePlaybackRun(evts, baseDelay)
    baseDelay = baseDelay or 0
    for _, ev in ipairs(evts) do
        local adjustedTime = (ev.t or 0) / PLAYBACK_SPEED
        local delay = adjustedTime + baseDelay
        local tim = timer.doAfter(delay, function() performEventAction(ev) end)
        table.insert(playbackTimers, tim)
    end
    local runDur = computeTotalDuration(evts) / PLAYBACK_SPEED
    local endTimer = timer.doAfter(baseDelay + runDur, function() end)
    table.insert(playbackTimers, endTimer)
    return runDur
end

-- Playback control
local function startPlaybackWithLoops(loopCount, gapSeconds)
    if recording then showAlert("⚠️ Stop recording before playback"); return end
    if not events or #events == 0 then showAlert("⚠️ No events recorded"); return end
    if playbackRunning then showAlert("⚠️ Playback already running"); return end

    playbackRunning = true
    playbackLooping = (loopCount == 0 or loopCount == math.huge)
    playbackTimers = {}
    playbackCount = 0

    playbackRunDuration = playbackRunDuration or computeTotalDuration(events)
    local runDur = playbackRunDuration / PLAYBACK_SPEED
    local gap = (gapSeconds or 0) / PLAYBACK_SPEED

    if loopCount == 0 or loopCount == math.huge then
        playbackLooping = true
        showAlert("▶️ Playing (infinite loop)")
        schedulePlaybackRun(events, 0)
        playbackCount = 1
        
        local function scheduleNextRun()
            if not playbackRunning then return end
            playbackCount = playbackCount + 1
            schedulePlaybackRun(events, 0)
            local loopTimer = timer.doAfter(runDur + gap, scheduleNextRun)
            table.insert(playbackTimers, loopTimer)
        end
        
        local starter = timer.doAfter(runDur + gap, scheduleNextRun)
        table.insert(playbackTimers, starter)
        return
    end

    local maxRuns = (loopCount == nil) and 1 or loopCount
    if maxRuns <= 0 then maxRuns = 1 end
    showAlert("▶️ Playing " .. tostring(maxRuns) .. " time" .. (maxRuns > 1 and "s" or ""))
    
    for i = 0, maxRuns - 1 do
        local base = i * (runDur + gap)
        schedulePlaybackRun(events, base)
    end
    
    local totalTime = maxRuns * runDur + (maxRuns - 1) * gap
    local cleanup = timer.doAfter(totalTime + 0.1, function()
        playbackRunning = false
        playbackLooping = false
        showAlert("✅ Playback finished (" .. maxRuns .. " runs)")
    end)
    table.insert(playbackTimers, cleanup)
end

local function stopPlayback()
    if not playbackRunning and not playbackLooping then
        showAlert("⚠️ No playback running")
        return
    end
    local count = playbackCount
    cancelPlaybackTimers()
    showAlert("⏹️ Playback stopped" .. (count > 0 and " (completed " .. count .. " runs)" or ""))
end

-- Convenience wrappers
local function playOnce() startPlaybackWithLoops(1, 0) end
local function toggleInfiniteLoop()
    if playbackRunning and playbackLooping then
        stopPlayback()
    else
        startPlaybackWithLoops(0, 0.25)
    end
end

-- Compression
local function compressMouseHolds(evts)
    local out = {}
    local i = 1
    local n = #evts
    
    while i <= n do
        local e = evts[i]
        if e.kind == "mouse" and (e.subtype == eventtap.event.types.leftMouseDown
                or e.subtype == eventtap.event.types.rightMouseDown
                or e.subtype == eventtap.event.types.otherMouseDown) then
            local j = i + 1
            if j <= n then
                local e2 = evts[j]
                local matches =
                    (e.subtype == eventtap.event.types.leftMouseDown and e2.subtype == eventtap.event.types.leftMouseUp) or
                    (e.subtype == eventtap.event.types.rightMouseDown and e2.subtype == eventtap.event.types.rightMouseUp) or
                    (e.subtype == eventtap.event.types.otherMouseDown and e2.subtype == eventtap.event.types.otherMouseUp)
                    
                if matches and e2.kind == "mouse" then
                    local button = (e.subtype == eventtap.event.types.leftMouseDown and "left")
                                 or (e.subtype == eventtap.event.types.rightMouseDown and "right")
                                 or "other"
                    table.insert(out, {
                        t = e.t,
                        kind = "mouse_hold",
                        button = button,
                        point = e.point,
                        duration = (e2.t - e.t),
                        flags = e.flags
                    })
                    i = i + 2
                else
                    table.insert(out, e)
                    i = i + 1
                end
            else
                table.insert(out, e)
                i = i + 1
            end
        else
            table.insert(out, e)
            i = i + 1
        end
    end
    return out
end

-- File operations
local function saveToFile(path)
    path = path or currentPath
    local toSave = events
    if AUTO_COMPRESS_ON_SAVE then toSave = compressMouseHolds(events) end
    
    local metadata = {
        version = "2.0",
        name = recordingName,
        eventCount = #toSave,
        duration = computeTotalDuration(events),
        recordedAt = os.date("%Y-%m-%d %H:%M:%S"),
        mouseMovesIncluded = RECORD_MOUSE_MOVES
    }
    
    local data = {
        metadata = metadata,
        events = toSave
    }
    
    local success, jsonStr = pcall(function() return json.encode(data, true) end)
    if not success then
        showAlert("❌ Failed to encode JSON")
        return false
    end
    
    local f = io.open(path, "w")
    if not f then
        showAlert("❌ Save failed")
        return false
    end
    
    f:write(jsonStr)
    f:close()
    currentPath = path
    showAlert("💾 Saved to " .. fs.displayName(path))
    return true
end

local function loadFromFile(path)
    path = path or currentPath
    local f = io.open(path, "r")
    if not f then
        showAlert("❌ No file to load")
        return false
    end
    
    local s = f:read("*a")
    f:close()
    
    local ok, data = pcall(function() return json.decode(s) end)
    if not ok or type(data) ~= "table" then
        showAlert("❌ Failed to parse file")
        return false
    end
    
    -- Handle both new format (with metadata) and old format (just events array)
    if data.events and type(data.events) == "table" then
        events = data.events
        if data.metadata then
            recordingName = data.metadata.name or "Loaded Recording"
        end
    elseif type(data) == "table" and #data > 0 then
        events = data
        recordingName = "Loaded Recording"
    else
        showAlert("❌ Invalid file format")
        return false
    end
    
    playbackRunDuration = nil
    currentPath = path
    showAlert("📂 Loaded " .. tostring(#events) .. " events")
    return true
end

local function saveAs()
    local button, name = dialog.textPrompt("Save Recording As", "Enter a name for this recording:", recordingName or "My Recording", "Save", "Cancel")
    if button == "Save" and name and name ~= "" then
        recordingName = name
        local filename = name:gsub("[^%w%s%-_]", "_") .. ".json"
        local path = os.getenv("HOME") .. "/" .. filename
        saveToFile(path)
    end
end

local function loadFrom()
    local path = dialog.chooseFileOrFolder("Load Recording", os.getenv("HOME"), false, false, false, {"json"})
    if path then
        loadFromFile(path)
    end
end

local function clearRecording()
    if recording then showAlert("⚠️ Stop recording first"); return end
    events = {}
    playbackRunDuration = nil
    recordingName = "Untitled"
    showAlert("🗑️ Recording cleared")
end

-- Info display
local function showInfo()
    if #events == 0 then
        showAlert("ℹ️ No recording")
        return
    end
    
    local duration = computeTotalDuration(events)
    local keyCount = 0
    local mouseCount = 0
    local scrollCount = 0
    
    for _, ev in ipairs(events) do
        if ev.kind == "key" then keyCount = keyCount + 1
        elseif ev.kind == "mouse" or ev.kind == "mouse_hold" then mouseCount = mouseCount + 1
        elseif ev.kind == "scroll" then scrollCount = scrollCount + 1
        end
    end
    
    local info = string.format(
        "📊 Recording: %s\n" ..
        "Total events: %d\n" ..
        "Duration: %.2fs\n" ..
        "Keys: %d | Mouse: %d | Scroll: %d\n" ..
        "Speed: %.1fx",
        recordingName, #events, duration, keyCount, mouseCount, scrollCount, PLAYBACK_SPEED
    )
    
    alert.show(info, 5)
end

-- Help display
local function showHelp()
    local help = [[
🎮 Macro Recorder Help

Recording:
  ⌃⌥⌘R - Toggle recording

Playback:
  ⌃⌥⌘P - Play once
  ⌃⌥⌘⇧P - Toggle infinite loop
  ⌃⌥⌘1-9 - Play N times
  ⌃⌥⌘X - Stop playback

Files:
  ⌃⌥⌘S - Save
  ⌃⌥⌘⇧S - Save As
  ⌃⌥⌘L - Load
  ⌃⌥⌘⇧L - Load From

Other:
  ⌃⌥⌘C - Clear recording
  ⌃⌥⌘M - Toggle mouse moves
  ⌃⌥⌘I - Show info
  ⌃⌥⌘H - Show this help
]]
    alert.show(help, 10)
end

-- Toggle features
local function toggleMouseMoves()
    if recording then showAlert("⚠️ Stop recording to change mouse-move setting"); return end
    RECORD_MOUSE_MOVES = not RECORD_MOUSE_MOVES
    makeEventTap()
    showAlert("🖱️ Mouse moves: " .. (RECORD_MOUSE_MOVES and "ON" or "OFF"))
end

-- Hotkey bindings
hotkey.bind({"ctrl","alt","cmd"}, "R", toggleRecording)
hotkey.bind({"ctrl","alt","cmd"}, "P", playOnce)
hotkey.bind({"ctrl","alt","cmd","shift"}, "P", toggleInfiniteLoop)
hotkey.bind({"ctrl","alt","cmd"}, "X", stopPlayback)
hotkey.bind({"ctrl","alt","cmd"}, "S", saveToFile)
hotkey.bind({"ctrl","alt","cmd","shift"}, "S", saveAs)
hotkey.bind({"ctrl","alt","cmd"}, "L", loadFromFile)
hotkey.bind({"ctrl","alt","cmd","shift"}, "L", loadFrom)
hotkey.bind({"ctrl","alt","cmd"}, "C", clearRecording)
hotkey.bind({"ctrl","alt","cmd"}, "M", toggleMouseMoves)
hotkey.bind({"ctrl","alt","cmd"}, "I", showInfo)
hotkey.bind({"ctrl","alt","cmd"}, "H", showHelp)

-- Number key bindings for N loops
for i = 1, 9 do
    hotkey.bind({"ctrl","alt","cmd"}, tostring(i), function()
        startPlaybackWithLoops(i, 0.2)
    end)
end

-- Startup
print("✅ Enhanced Macro Recorder loaded")
showAlert("✅ Recorder ready! Press ⌃⌥⌘H for help")
