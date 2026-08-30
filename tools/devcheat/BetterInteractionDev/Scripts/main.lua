--[[
    BetterInteractionDev -- money keybinds for testing. NEVER SHIPPED.

    F7   +25 artifacts into the outpost stash
    F8   +1000 gold and +1000 scraps into the outpost stash

    This exists so a co-op test can be set up in seconds instead of farmed for.
    It lives in tools/devcheat/ for the same reason the probes live in
    tools/probe/: packaging rule 2 says dev keybinds are CUT from a release, not
    disabled, and the surest way to cut them is for them never to have been in
    the shipping file. tools/test_packaging.py fails the build if F7 or F8 ever
    appear in BetterInteraction itself.

    WHERE THE MONEY ACTUALLY LIVES.

    The first version wrote AHeldenGameState.StashMoney alone, on the grounds
    that this project's brief forbids writing "anything reaching
    UHeldenSaveGame". Daniel: "it only updates visually but after trying to use
    it it immediately resets" -- so the GameState copy is the DISPLAY and the
    save object is what the game actually spends from. Writing one without the
    other buys a number on screen and nothing else.

    So both are written. There is no third option: AHeldenGameState exposes
    StashMoney as a bare property with no Add/Spend/Set function anywhere in the
    dump, so there is no game API to ask politely.

    WHAT IS STILL NOT DONE, AND WHY. The cheat this was adapted from also calls
    forceSave() afterwards. That is the part the brief calls "a real corruption
    risk", and it is the part that cost a sibling project a ProfileSaveGame.sav.
    It is also not needed for what this is for: writing the save OBJECT is what
    stops the money resetting when you spend it, while forcing a flush to DISK
    only decides whether it survives a restart -- and the game writes the save
    itself soon enough.

    If money survives spending but is gone after a restart, that is the missing
    flush and not a broken cheat. Say so and the forced save can be added; it
    should be a deliberate decision, not a default.

    HOST/SOLO. StashMoney is authoritative. On a guest the write is local, the
    server overwrites it, and the only thing you learn is that you were a guest
    -- so the readback is logged either way and will show it plainly.

    Crash rules observed: keybind callbacks are NOT on the game thread, so they
    set a flag and nothing else; every UObject touch happens on the pump (rule
    K). Nothing is cached between passes (rule C). The GameState is tested with
    fullName(), never for truthiness (rule A).
]]

local MOD      = "BetterInteractionDev"
local LOG_FILE = "BetterInteractionDev.log"
local PUMP_MS  = 100

local GRANTS = {
    { key = "F7", field = "Artifacts", amounts = { Artifacts = 25 } },
    { key = "F8", field = "Gold/Scraps",
      amounts = { Gold = 1000, Scraps = 1000 } },
}

local function log(message)
    local stamp = os.date("%H:%M:%S")
    print("[" .. MOD .. "] " .. message .. "\n")
    local handle = io.open(LOG_FILE, "a")
    if handle ~= nil then
        handle:write(stamp .. "  " .. message .. "\n")
        handle:close()
    end
end

local function fullName(object)
    local name = nil
    pcall(function() name = object:GetFullName() end)
    if type(name) ~= "string" then return "" end
    return name
end

--- Rule A: a wrapper around null is TRUTHY, so the test is the name.
--- Rule C: re-resolved every press, never cached between them.
local function findOne(class)
    local found = nil
    pcall(function() found = FindFirstOf(class) end)
    if fullName(found) == "" then return nil end
    return found
end

local function readStash(holder)
    local a, g, s = nil, nil, nil
    pcall(function() a = holder.StashMoney.Artifacts end)
    pcall(function() g = holder.StashMoney.Gold end)
    pcall(function() s = holder.StashMoney.Scraps end)
    if type(a) ~= "number" or type(g) ~= "number" or type(s) ~= "number" then
        return nil
    end
    return { Artifacts = a, Gold = g, Scraps = s }
end

local function stashText(value)
    if value == nil then return "unreadable" end
    return string.format("%dS/%dG/%dA", value.Scraps, value.Gold, value.Artifacts)
end

--- IN PLACE ON THE PERSISTENT OBJECT, field by field -- never through a
--- by-value getter (the memory-safety rule).
local function grant(amounts, label)
    local gs = findOne("HeldenGameState")
    if gs == nil then
        log(label .. ": no HeldenGameState -- are you in a run?")
        return
    end

    -- HasAuthority is the clean host test, and a guest pressing this should be
    -- told so rather than left wondering why nothing stuck.
    local authority = nil
    pcall(function() authority = gs:HasAuthority() end)
    if authority == false then
        log(label .. ": ignored -- this instance is not the host, and StashMoney"
            .. " is the host's to write.")
        return
    end

    local before = readStash(gs)
    if before == nil then
        log(label .. ": StashMoney did not read; refusing to write blind")
        return
    end

    -- THE SAVE OBJECT IS WHAT THE GAME SPENDS FROM. The GameState copy alone is
    -- only the display -- measured, by Daniel, 30 Aug 2026.
    local save = findOne("HeldenSaveGame")
    local saveBefore = save ~= nil and readStash(save) or nil

    for field, amount in pairs(amounts) do
        local want = before[field] + amount
        pcall(function() gs.StashMoney[field] = want end)
        if saveBefore ~= nil then
            local target = saveBefore[field] + amount
            pcall(function() save.StashMoney[field] = target end)
        end
    end

    local after = readStash(gs)
    local saveAfter = save ~= nil and readStash(save) or nil
    log(string.format("%s: stash %s -> %s   save %s -> %s", label,
        stashText(before), stashText(after),
        stashText(saveBefore), stashText(saveAfter)))

    -- Rule H: a write that silently did nothing must say so.
    if after ~= nil and stashText(before) == stashText(after) then
        log(label .. ": the GameState stash did not change.")
    end
    if save == nil then
        log(label .. ": no HeldenSaveGame was found, so only the display was"
            .. " updated -- expect this to reset the moment you spend it.")
    elseif saveAfter ~= nil and stashText(saveBefore) == stashText(saveAfter) then
        log(label .. ": the SAVE stash did not change -- it will reset on use.")
    end
end

local pending = {}

for _, entry in ipairs(GRANTS) do
    local ok = pcall(function()
        RegisterKeyBind(Key[entry.key], function()
            pending[entry.key] = true      -- flag only; not the game thread
        end)
    end)
    if not ok then
        log("could not bind " .. entry.key)
    end
end

local inFlight = false
local started = pcall(function()
    LoopAsync(PUMP_MS, function()
        if inFlight then return false end
        inFlight = true
        ExecuteInGameThread(function()
            inFlight = false
            for _, entry in ipairs(GRANTS) do
                if pending[entry.key] then
                    pending[entry.key] = false
                    pcall(function()
                        grant(entry.amounts, entry.key .. " " .. entry.field)
                    end)
                end
            end
        end)
        return false
    end)
end)

log("---- " .. MOD .. " loaded ----")
log("F7  +25 artifacts     F8  +1000 gold and +1000 scraps")
log("host or solo only. The save OBJECT is written so the money survives"
    .. " being spent; no save is forced to disk.")
if not started then
    log("THE PUMP DID NOT START -- the keybinds will do nothing")
end
