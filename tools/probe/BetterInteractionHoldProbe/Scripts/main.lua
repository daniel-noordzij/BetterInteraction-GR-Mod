--[[
    BetterInteractionHoldProbe -- why does a held interact key get eaten?

    READ-ONLY. It reads properties and writes a text file. No writes, no calls,
    no hooks, no save contact. Safe anywhere, including a live lobby.

    THE BUG (Daniel, 29 Aug 2026)
    -----------------------------
    "interacting with an object that requires holding said input requires seeing
    the input icon. If the input is held even a frame before that icon is shown
    the input gets eaten and the player needs to release and re-press E to
    interact with it (fixing a spot in the outpost, opening a casket, sitting on
    a chair). If the player was holding E and the input appears then it should
    start the holding."

    WHAT THE DUMP ALREADY EXPLAINS
    ------------------------------
    IA_Interact carries exactly ONE trigger, a UInputTriggerReleased
    (UE4SS_ObjectDump.txt:126853), and IMC_Default adds no per-mapping triggers.
    With that configuration the action emits Started on press, Ongoing every
    frame while held, Triggered on RELEASE, then Completed.

    That predicts the asymmetry without being told it: a TAP survives being
    pressed before focus because it can still fire on the release edge, while a
    HOLD needs the press edge -- and while the key stays down no second Started
    is ever produced. Hence release-and-re-press.

    FINDING: the trigger configuration.
    HYPOTHESIS: that the game's native handler starts a hold on Started and is
    gated on having a focus target. That handler is unreflected C++ and is NOT
    IN THE DUMP, so the root cause stays a hypothesis. The fix does not depend
    on it -- it does not care WHY the edge was missed.

    WHY THIS IS A TIMELINE AND NOT A SNAPSHOT
    -----------------------------------------
    The bug is entirely about ORDERING: does the key go down before or after the
    object becomes focusable. One F-key snapshot cannot see that. So F11 toggles
    RECORDING, and while recording the pump samples every tick and writes a line
    only when something CHANGES. Walk at a chair holding E, then release and
    re-press, and the file shows both orderings side by side.

    WHAT IT SAMPLES, all by property walk from the local controller

      AHeldenPlayerController.CurrentInteractTarget   Helden.hpp:6618, 0xC00
          a UInteractionComponent* -- a direct focus pointer, far cheaper than
          the InteractionWidgetComponent -> Widget -> InteractState walk.

      that component's bIsHoldInteraction / HoldInteractionDuration
      that component's widget InteractState  (Hidden 0, ProximityRange 1, Focused 2)

      HONESTY NOTE, corrected 29 Aug 2026. An earlier version of this header
      claimed these were "two independent focus signals ... printing BOTH and
      letting them disagree". THEY ARE NOT INDEPENDENT: the widget is reached
      THROUGH CurrentInteractTarget, so when that is empty the widget column is
      empty too, by construction and not by measurement. Making them independent
      needs a walk of HotInteractions, which needs the subsystem, which needs a
      global scan -- and rule E forbids that at this sample rate. So the second
      signal is deliberately NOT here, and the question it would answer -- "was
      the prompt actually on screen?" -- is answered far more cheaply by the
      player looking at the screen.

      AHeldenCharacter.CurrentInteraction, off the pawn: is an interaction
      actually RUNNING. Established empty while merely aimed, so non-empty means
      something really started.

      APlayerController.PlayerInput            Engine.hpp:11084, 0x428
        -> UEnhancedPlayerInput.ActionInstanceData   EnhancedInput.hpp:356, 0x4E8
           TMap<UInputAction*, FInputActionInstance>, and each value carries
           ETriggerEvent TriggerEvent   (None 0, Triggered 1, Started 2,
                                         Ongoing 4, Canceled 8, Completed 16)
           float ElapsedProcessedTime
           float ElapsedTriggeredTime
        -- i.e. "is the interact key down, and for how long", without ever
        constructing an FKey and without caring how it is rebound.

    THE QUESTION THIS PROBE CANNOT ANSWER, and it is the blocking one:
    what Interact_Server(pawn, component) DOES when the component is a hold.
    That needs a CALL, not a read, and the replay probe already has it: aim at a
    chair, F9 to method A, F10. Do that separately.

    KEYS
    ----
      F11   start / stop recording. Read-only either way.
]]

local MOD     = "BetterInteractionHoldProbe"
local VERSION = "hold-3"

-- ==========================================================================
-- Version-fragile names, all verified against the 5.7.4 dump.
-- ==========================================================================

local CLASS = { controller = "HeldenPlayerController" }

local PROP = {
    focus      = "CurrentInteractTarget",   -- AHeldenPlayerController 0xC00
    playerIn   = "PlayerInput",             -- APlayerController 0x428
    actionData = "ActionInstanceData",      -- UEnhancedPlayerInput 0x4E8
    trigger    = "TriggerEvent",            -- FInputActionInstance 0x13
    elapsed    = "ElapsedProcessedTime",    -- FInputActionInstance 0x58
    elapsedTrig = "ElapsedTriggeredTime",   -- FInputActionInstance 0x5C
    holdOn     = "bIsHoldInteraction",      -- UInteractionComponent 0x318
    holdDur    = "HoldInteractionDuration", -- UInteractionComponent 0x31C
    widgetCmp  = "InteractionWidgetComponent",
    widget     = "Widget",
    state      = "InteractState",
    pawn       = "Pawn",                    -- AController 0x2F0
    inProgress = "CurrentInteraction",      -- AHeldenCharacter 0xBB0, the
                                            -- interaction actually RUNNING.
                                            -- Established empty while merely
                                            -- aimed, so a non-empty value means
                                            -- something really started -- which
                                            -- is the observable a chair moves
                                            -- and money does not.
}

-- ETriggerEvent, EnhancedInput_enums.hpp:116. Note these are FLAG values, not
-- a dense sequence: Ongoing is 4, Canceled 8, Completed 16.
local TRIGGER = {
    [0] = "None", [1] = "Triggered", [2] = "Started",
    [4] = "Ongoing", [8] = "Canceled", [16] = "Completed",
}

-- EHeldenInteractState, Helden_enums.hpp:893
local STATE = { [0] = "Hidden", [1] = "ProximityRange", [2] = "Focused" }

local OUT_FILE = "BetterInteraction_hold.txt"
local KEY_TOGGLE = Key.F11
local PUMP_MS = 100
local SAMPLE_EVERY = 2  -- sample every N pump ticks: 200ms, halving the scan rate

-- Only these actions are worth a line. Everything else in the map is movement
-- and camera noise that would bury the signal. Matched case-insensitively on
-- the UInputAction's own name, so a rebind does not affect it.
local WATCH = { "interact", "use" }

-- ==========================================================================
-- Output
-- ==========================================================================

local handle, outPath = nil, OUT_FILE

local function openOut()
    if handle ~= nil then return end
    handle = io.open(OUT_FILE, "a")
    if handle == nil then
        outPath = (os.getenv("TEMP") or ".") .. "\\" .. OUT_FILE
        handle = io.open(outPath, "a")
    end
    if handle == nil then handle = false end
end

--- Flushed per line. The whole point is the last few hundred milliseconds
--- before something goes wrong, and UE4SS's own log is buffered (crash rule J).
local function emit(text)
    openOut()
    if handle == false then
        print("[" .. MOD .. "] " .. text .. "\n")
        return
    end
    pcall(function()
        handle:write(text, "\n")
        handle:flush()
    end)
end

local function log(text)
    print("[" .. MOD .. "] " .. tostring(text) .. "\n")
end

-- ==========================================================================
-- Null-wrapper primitives (crash rule A). A property read answers with a
-- WRAPPER whether or not the class has that property, so existence is tested
-- by TYPE and objects by "can it say its own name". IsValid() is never used --
-- it dereferences, so on a freed object it is the crash, not a test (rule B).
-- ==========================================================================

local function fullName(object)
    local name = nil
    pcall(function() name = object:GetFullName() end)
    if type(name) ~= "string" then return "" end
    return name
end

local function real(object)
    return object ~= nil and fullName(object) ~= ""
end

local function get(object, property)
    local value = nil
    pcall(function() value = object[property] end)
    return value
end

local function numberProp(object, property)
    local value = get(object, property)
    if type(value) ~= "number" then return nil end
    return value
end

local function boolProp(object, property)
    local value = get(object, property)
    if type(value) ~= "boolean" then return nil end
    return value
end

local function shortName(name)
    if name == nil or name == "" then return "-" end
    return (name:gsub("^.*[%.:/]", ""))
end

local function className(object)
    local name = nil
    pcall(function() name = object:GetClass():GetFName():ToString() end)
    if type(name) ~= "string" or name == "" then return "?" end
    return name
end

local function enumStr(value, names)
    if type(value) ~= "number" then return "?" end
    local name = names[value]
    if name == nil then return "?(" .. tostring(value) .. ")" end
    return name
end

-- ==========================================================================
-- Sampling
-- ==========================================================================

--- NO UOBJECT IS HELD ACROSS A SAMPLE.
---
--- This probe previously held the controller for up to a second as a rule-E
--- throttle. The SHIPPING MOD did the same thing and it crashed the game on
--- starting a new save -- an access violation reading a garbage address, nine
--- frames deep in ue4ss, at a world change. A name lookup on the held object is
--- what does it, and the object is freed before anything can clear the cache.
---
--- The crash briefing settles the conflict with rule E directly: "a rescan is
--- exposure to a race; a stale pointer is a certainty. When they conflict, take
--- the race." So the scan is back, and the sample rate is halved instead --
--- SAMPLE_EVERY now means "sample every N pump ticks", not "reuse for N ticks".
local function localController()
    local found = nil
    pcall(function()
        for _, controller in ipairs(FindAllOf(CLASS.controller) or {}) do
            if found == nil and real(controller) then
                local isLocal = nil
                pcall(function() isLocal = controller:IsLocalController() end)
                if isLocal == true then found = controller end
            end
        end
    end)
    return found
end

--- The interact action's live trigger state. Walks
--- UEnhancedPlayerInput.ActionInstanceData, a TMap<UInputAction*,
--- FInputActionInstance>. TMap:ForEach(key, value) is the proven idiom.
---
--- Returns a compact string, plus the raw trigger number so the caller can
--- detect a change without parsing the string back.
local function inputState(controller)
    local input = get(controller, PROP.playerIn)
    if not real(input) then return "PlayerInput did not resolve", nil end
    local map = get(input, PROP.actionData)
    if map == nil then return PROP.actionData .. " did not read", nil end

    local parts, primary, seen = {}, nil, 0
    local ok = pcall(function()
        map:ForEach(function(key, value)
            seen = seen + 1
            local action = key
            pcall(function() action = key:get() end)
            local name = shortName(fullName(action)):lower()

            local wanted = false
            for _, want in ipairs(WATCH) do
                if name:find(want, 1, true) ~= nil then wanted = true end
            end
            if not wanted then return end

            local instance = value
            pcall(function() instance = value:get() end)
            local trig = numberProp(instance, PROP.trigger)
            local elapsed = numberProp(instance, PROP.elapsed)
            local elapsedTrig = numberProp(instance, PROP.elapsedTrig)

            parts[#parts + 1] = string.format("%s=%s held=%s trig=%s",
                shortName(fullName(action)), enumStr(trig, TRIGGER),
                elapsed and string.format("%.2f", elapsed) or "?",
                elapsedTrig and string.format("%.2f", elapsedTrig) or "?")
            if primary == nil then primary = trig end
        end)
    end)
    if not ok then return "the " .. PROP.actionData .. " walk raised", nil end
    if #parts == 0 then
        -- Rule H: "no interact action in the map" and "the map is empty" are
        -- different facts and only one of them means the WATCH list is wrong.
        return string.format("no action matching %s among %d in the map",
            table.concat(WATCH, "/"), seen), nil
    end
    return table.concat(parts, "  |  "), primary
end

--- What the game thinks you are focused on, by TWO routes, so they can disagree
--- in the file rather than silently agreeing in my head.
local function focusState(controller)
    local component = get(controller, PROP.focus)
    if not real(component) then
        return "-", "-", nil, nil
    end

    local owner = nil
    pcall(function() owner = component:GetOwner() end)
    local label = real(owner)
        and (className(owner) .. " " .. shortName(fullName(owner)))
        or shortName(fullName(component))

    local hold = boolProp(component, PROP.holdOn)
    local dur = numberProp(component, PROP.holdDur)
    local kind = (hold == true)
        and ("HOLD " .. (dur and string.format("%.2fs", dur) or "?"))
        or ((hold == false) and "tap" or "?")

    -- Cross-check against the widget path the replay probe proved.
    local widgetState = nil
    local widgetComponent = get(component, PROP.widgetCmp)
    if real(widgetComponent) then
        local widget = get(widgetComponent, PROP.widget)
        if real(widget) then widgetState = numberProp(widget, PROP.state) end
    end

    return label, kind, widgetState, fullName(component)
end

-- ==========================================================================
-- The recorder
-- ==========================================================================

local recording = false
local samples, changes = 0, 0
local last = { focus = nil, trigger = nil, widgetState = nil, input = nil }

local ticksSeen = 0

local function sample()
    ticksSeen = ticksSeen + 1
    if ticksSeen % SAMPLE_EVERY ~= 0 then return end
    local controller = localController()
    if controller == nil then
        if last.focus ~= "<no controller>" then
            last.focus = "<no controller>"
            emit(string.format("%8.3f  no local %s (menu, or a transition)",
                os.clock(), CLASS.controller))
        end
        return
    end

    samples = samples + 1
    local label, kind, widgetState, focusName = focusState(controller)
    local inputText, trigger = inputState(controller)

    -- Is an interaction actually RUNNING? This is the observable a chair moves
    -- and money does not -- the gap that made the method-A fire at a chair come
    -- back VERDICT: NONE. Read off the pawn, no scan.
    local running = "-"
    local pawn = get(controller, PROP.pawn)
    if real(pawn) then
        local current = get(pawn, PROP.inProgress)
        if not real(current) then
            local inner = nil
            pcall(function() inner = current:Get() end)
            if real(inner) then current = inner end
        end
        if real(current) then running = shortName(fullName(current)) end
    end

    -- Only write when something MOVED. At 10 samples a second a line per sample
    -- would be 600 lines a minute of identical rows, which is its own kind of
    -- silence (crash rule H).
    local moved = (focusName ~= last.focus)
        or (trigger ~= last.trigger)
        or (widgetState ~= last.widgetState)
        or (inputText ~= last.input)
        or (running ~= last.running)
    if not moved then return end

    last.focus, last.trigger = focusName, trigger
    last.widgetState, last.input = widgetState, inputText
    last.running = running
    changes = changes + 1

    emit(string.format("%8.3f  focus=%-40s %-12s widget=%-14s running=%-26s %s",
        os.clock(), label, kind,
        widgetState ~= nil and enumStr(widgetState, STATE) or "-",
        running, inputText))
end

local function toggle()
    recording = not recording
    if recording then
        samples, changes = 0, 0
        last = { focus = nil, trigger = nil, widgetState = nil,
                 input = nil, running = nil }
        ticksSeen = 0
        emit("")
        emit("================================================================")
        emit(string.format(" %s %s   RECORDING from %s", MOD, VERSION,
            os.date("%Y-%m-%d %H:%M:%S")))
        emit("================================================================")
        emit(" One line per CHANGE. Columns:")
        emit("   time      os.clock seconds")
        emit("   focus     AHeldenPlayerController.CurrentInteractTarget's owner")
        emit("   HOLD/tap  that component's bIsHoldInteraction, and its duration")
        emit("   widget    its prompt widget's InteractState -- the second,")
        emit("             independent focus signal. If these two ever disagree,")
        emit("             that disagreement is the finding.")
        emit("   the rest  the interact action's live ETriggerEvent, how long the")
        emit("             key has been down, and how long it has been triggered")
        emit("")
        emit(" WHAT TO DO: hold E, THEN walk into range of a chair or casket --")
        emit(" that is the bug. Then release and re-press without moving -- that")
        emit(" is the workaround. The two orderings will be side by side.")
        emit("")
        log("RECORDING. Press F11 again to stop. Output: " .. outPath)
    else
        emit("")
        emit(string.format(" stopped. %d samples, %d changes recorded.",
            samples, changes))
        emit("================================================================")
        log(string.format("stopped -- %d samples, %d changes -> %s",
            samples, changes, outPath))
    end
end

-- ==========================================================================
-- The pump (crash rule K, RE-UE4SS #1180). One LoopAsync, one
-- ExecuteInGameThread, no ExecuteWithDelay. The keybind sets a flag and does
-- nothing else, because keybind callbacks are not on the game thread.
-- ==========================================================================

local pendingToggle = false
local inFlight = false

local pumpStarted = pcall(function()
    LoopAsync(PUMP_MS, function()
        if inFlight then return false end
        inFlight = true
        ExecuteInGameThread(function()
            if pendingToggle then
                pendingToggle = false
                local ok, err = pcall(toggle)
                if not ok then log("toggle error: " .. tostring(err)) end
            end
            if recording then
                local ok, err = pcall(sample)
                if not ok then log("sample error: " .. tostring(err)) end
            end
            inFlight = false
        end)
        return false
    end)
end)

local bound = pcall(function()
    RegisterKeyBind(KEY_TOGGLE, function() pendingToggle = true end)
end)

log("loaded " .. VERSION .. ". Read-only: it writes a text file and nothing else.")
if not pumpStarted then
    log("FATAL: LoopAsync did not start -- nothing will ever run.")
end
log(bound and "F11  start / stop recording -> " .. OUT_FILE
    or "F11 could not be registered")
log("the blocking question -- what Interact_Server does to a HOLD -- needs the")
log("replay probe, not this one: aim at a chair, F9 to method A, F10.")
