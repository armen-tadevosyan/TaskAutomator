-- Paste into ~/.hammerspoon/init.lua and Reload Config
--
-- Hotkeys:
--  Ctrl+Alt+Cmd+R      -> Toggle recording
--  Ctrl+Alt+Cmd+P      -> Play once
--  Ctrl+Alt+Cmd+Shift+P-> Toggle infinite loop playback
--  Ctrl+Alt+Cmd+0      -> Play 5 loops (example)
--  Ctrl+Alt+Cmd+X      -> Stop playback immediately
--  Ctrl+Alt+Cmd+S      -> Save (compressed) to ~/keystroke_recording.json
--  Ctrl+Alt+Cmd+L      -> Load from ~/keystroke_recording.json
--  Ctrl+Alt+Cmd+C      -> Clear current recording
--  Ctrl+Alt+Cmd+M      -> Toggle mouse-move recording (default OFF)
--  Manually edit/upload/tweak keystrokes by changing the contents of ~/keystroke_recording.json

local json = require("hs.json")
local timer = require("hs.timer")
local eventtap = hs.eventtap
local alert = hs.alert
local hotkey = hs.hotkey
local path = os.getenv("HOME") .. "/keystroke_recording.json"

-- Settings
local RECORD_MOUSE_MOVES = false      -- default; toggle at runtime with Ctrl+Alt+Cmd+M
local AUTO_COMPRESS_ON_SAVE = true

-- State
local recording = false
local startTime = nil
local events = {}  -- recorded events

-- Playback state
local playbackTimers = {}       -- list of hs.timer objects created by doAfter
local playbackRunning = false
local playbackLooping = false
local playbackRunDuration = nil -- duration of a single run (cached)

-- Utility
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
    }
    if includeMouseMoves then table.insert(types, t.mouseMoved) end
    return types
end

-- create/recreate event tap (used when toggling mouse-move recording)
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

        if et == eventtap.event.types.keyDown or et == eventtap.event.types.keyUp then
            local evTypeStr = (et == eventtap.event.types.keyDown) and "down" or "up"
            local chars = e:getCharacters(true)
            local keyCode = e:getKeyCode()
            local flags = flagsToList(e:getFlags())
            -- we record printable characters; non-printables may be nil/empty (skip them for now)
            if not chars or chars == "" then
                print(string.format("[rec] skipped non-printing key code=%s t=%.4f", tostring(keyCode), t))
            else
                table.insert(events, {
                    t = t,
                    kind = "key",
                    subtype = evTypeStr,
                    chars = chars,
                    keyCode = keyCode,
                    flags = flags
                })
            end
            return false
        end

        -- mouse events (clicks, optionally moves)
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

-- initial tap
makeEventTap()

-- toggle recording
local function toggleRecording()
    if not recording then
        events = {}
        startTime = timer.secondsSinceEpoch()
        recording = true
        if evtTap then evtTap:start() end
        alert.show("Recording: ON")
        print("[recorder] started")
    else
        recording = false
        if evtTap then evtTap:stop() end
        alert.show("Recording: OFF — " .. tostring(#events) .. " events")
        print("[recorder] stopped, events:", #events)
        -- refresh cached run duration
        playbackRunDuration = nil
    end
end

-- compute total duration of events (handles mouse_hold entries)
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

-- perform one event immediately (used by scheduled timers)
local function performEventAction(ev)
    if ev.kind == "key" then
        local isDown = (ev.subtype == "down")
        local mods = ev.flags or {}
        local key = ev.chars
        if not key or key == "" then
            -- fallback mapping (best effort)
            local mapped
            pcall(function() mapped = hs.keycodes.map[ev.keyCode] end)
            if mapped and type(mapped) == "string" then key = mapped else key = tostring(ev.keyCode) end
        end
        local evt = eventtap.event.newKeyEvent(mods, key, isDown)
        if evt then evt:post() end

    elseif ev.kind == "mouse" then
        local pt = ev.point or { x = 0, y = 0 }
        -- move cursor then post the specific mouse event (down/up)
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
        -- move + down, then schedule up after duration
        local moveEvt = eventtap.event.newMouseEvent(eventtap.event.types.mouseMoved, {x=pt.x, y=pt.y})
        if moveEvt then moveEvt:post() end
        local downEvt = eventtap.event.newMouseEvent(downType, {x=pt.x, y=pt.y})
        if downEvt then downEvt:post() end
        if ev.duration and ev.duration > 0 then
            local upTimer = timer.doAfter(ev.duration, function()
                local upEvt = eventtap.event.newMouseEvent(upType, {x=pt.x, y=pt.y})
                if upEvt then upEvt:post() end
            end)
            table.insert(playbackTimers, upTimer)
        end
    end
end

-- cancel all scheduled playback timers
local function cancelPlaybackTimers()
    for _, t in ipairs(playbackTimers) do
        if t and t.stop then pcall(function() t:stop() end) end
    end
    playbackTimers = {}
    playbackRunning = false
    playbackLooping = false
end

-- schedule a single run of events with baseDelay seconds from now (baseDelay >= 0)
local function schedulePlaybackRun(evts, baseDelay)
    baseDelay = baseDelay or 0
    for _, ev in ipairs(evts) do
        local delay = (ev.t or 0) + baseDelay
        local tim = timer.doAfter(delay, function() performEventAction(ev) end)
        table.insert(playbackTimers, tim)
    end
    local runDur = computeTotalDuration(evts)
    -- also put a "run-end" timer we can use for chaining cleanup if desired
    local endTimer = timer.doAfter(baseDelay + runDur, function() end)
    table.insert(playbackTimers, endTimer)
    return runDur
end

-- start playback:
--  loopCount: nil or 1 = play once
--             N (>1) = play N times
--             0 or math.huge = infinite loop (reschedules run-by-run)
--  gapSeconds: delay between runs
local function startPlaybackWithLoops(loopCount, gapSeconds)
    if recording then alert.show("Stop recording before playback"); return end
    if not events or #events == 0 then alert.show("No events recorded"); return end
    if playbackRunning then alert.show("Playback already running"); return end

    playbackRunning = true
    playbackLooping = (loopCount == 0 or loopCount == math.huge)
    playbackTimers = {}

    -- If cached duration not present, compute it
    playbackRunDuration = playbackRunDuration or computeTotalDuration(events)
    local runDur = playbackRunDuration
    local gap = gapSeconds or 0

    -- Infinity case: schedule one run now (relative scheduling) and then reschedule next run after runDur+gap
    if loopCount == 0 or loopCount == math.huge then
        playbackLooping = true
        alert.show("Playback (infinite) starting")
        -- schedule the first run immediately with baseDelay = 0
        schedulePlaybackRun(events, 0)
        -- schedule the loop timer that fires after runDur+gap and schedules the next single run (keeps going until stopped)
        local function scheduleNextRun()
            if not playbackRunning then return end
            -- schedule run events relative to NOW (baseDelay=0)
            schedulePlaybackRun(events, 0)
            -- schedule the next invocation after runDur+gap
            local loopTimer = timer.doAfter(runDur + gap, scheduleNextRun)
            table.insert(playbackTimers, loopTimer)
        end
        -- start the recurring scheduler after runDur+gap so runs don't overlap
        local starter = timer.doAfter(runDur + gap, scheduleNextRun)
        table.insert(playbackTimers, starter)
        return
    end

    -- Finite case: schedule all runs up-front
    local maxRuns = (loopCount == nil) and 1 or loopCount
    if maxRuns <= 0 then maxRuns = 1 end
    alert.show("Playback starting (" .. tostring(maxRuns) .. " runs)")
    for i = 0, maxRuns - 1 do
        local base = i * (runDur + gap)
        schedulePlaybackRun(events, base)
    end
    -- schedule cleanup timer at end of last run
    local totalTime = maxRuns * runDur + (maxRuns - 1) * gap
    local cleanup = timer.doAfter(totalTime + 0.01, function()
        playbackRunning = false
        playbackLooping = false
        alert.show("Playback finished")
    end)
    table.insert(playbackTimers, cleanup)
end

local function stopPlayback()
    if not playbackRunning and not playbackLooping then
        alert.show("No playback running")
        return
    end
    cancelPlaybackTimers()
    alert.show("Playback stopped")
end

-- convenience wrappers
local function playOnce() startPlaybackWithLoops(1, 0) end
local function toggleInfiniteLoop()
    if playbackRunning and playbackLooping then
        stopPlayback()
    else
        startPlaybackWithLoops(0, 0.25) -- infinite with 0.25s gap
    end
end
local function playFiveTimes() startPlaybackWithLoops(5, 0.2) end

-- compress down+up into mouse_hold
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
                if matches then
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

-- save/load/clear
local function saveToFile()
    local toSave = events
    if AUTO_COMPRESS_ON_SAVE then toSave = compressMouseHolds(events) end
    local f = io.open(path, "w")
    if not f then alert.show("Save failed"); return end
    f:write(json.encode(toSave))
    f:close()
    alert.show("Saved to " .. path)
end

local function loadFromFile()
    local f = io.open(path, "r")
    if not f then alert.show("No file to load"); return end
    local s = f:read("*a"); f:close()
    local ok, tbl = pcall(function() return json.decode(s) end)
    if ok and type(tbl) == "table" then
        events = tbl
        playbackRunDuration = nil
        alert.show("Loaded " .. tostring(#events) .. " events")
    else
        alert.show("Failed to parse file")
    end
end

local function clearRecording()
    if recording then alert.show("Stop recording first"); return end
    events = {}
    playbackRunDuration = nil
    alert.show("Recording cleared")
end

-- toggle mouse moves at runtime (recreate eventtap)
local function toggleMouseMoves()
    if recording then alert.show("Stop recording to change mouse-move setting"); return end
    RECORD_MOUSE_MOVES = not RECORD_MOUSE_MOVES
    makeEventTap()
    alert.show("Mouse move recording: " .. (RECORD_MOUSE_MOVES and "ON" or "OFF"))
end

-- hotkeys
hotkey.bind({"ctrl","alt","cmd"}, "R", toggleRecording)
hotkey.bind({"ctrl","alt","cmd"}, "P", playOnce)
hotkey.bind({"ctrl","alt","cmd","shift"}, "P", toggleInfiniteLoop)
hotkey.bind({"ctrl","alt","cmd"}, "0", playFiveTimes)
hotkey.bind({"ctrl","alt","cmd"}, "X", stopPlayback)
hotkey.bind({"ctrl","alt","cmd"}, "S", saveToFile)
hotkey.bind({"ctrl","alt","cmd"}, "L", loadFromFile)
hotkey.bind({"ctrl","alt","cmd"}, "C", clearRecording)
hotkey.bind({"ctrl","alt","cmd"}, "M", toggleMouseMoves)

-- startup
print("Recorder loaded. Ctrl+Alt+Cmd+R to toggle recording.")
alert.show("Recorder loaded. Ctrl+Alt+Cmd+R to toggle recording.")

