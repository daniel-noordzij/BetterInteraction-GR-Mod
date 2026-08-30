--[[
    BetterInteraction -- interaction quality of life for Grain Rot.

    PHASE 1. This file changes only LOCAL PRESENTATION: how far off-centre you
    may look before a prompt appears, how close you must be, and how long a hold
    takes. It writes no authoritative state, sends no RPC, touches no save, and
    registers no hook.

    CO-OP BUCKET, declared per feature at the site, per CLAUDE.md:

      prompt_angle      bucket 1  local presentation. One float on one shared
                                  asset. Nothing is replicated, nothing agreed.
      prompt_distance   bucket 1  same asset.
      reach             bucket 1  MaxInteractDistance, per component. Governs
                                  what YOUR machine offers you.
      aim_forgiveness   bucket 1  LineTraceDiscardRadius, per component.
      hold_duration     bucket 3  HoldInteractionDuration MAY be validated by
                                  the host. Not established. OFF by default and
                                  the config says so.

    WHY IT IS A RECONCILER AND NOT A PATCHER
    ----------------------------------------
    The game puts its own values back -- measured on this build, a written
    property reset twice inside a fourteen-minute session. This mod assumes the
    same for everything it writes: a one-shot apply would work until
    the first reset and then quietly stop, which is the worst failure mode
    available. So every value is re-asserted on a timer, every write is read
    back, and a value the game has put back is reported once per object per
    world rather than silently rewritten forever.

    WHAT THE GAME ACTUALLY SHIPS  (measured 29 Aug 2026, 739 components,
    two worlds -- see docs/DESIGN.md)

      InteractProximityAngle     20        one shared asset, whole game
      InteractProximityDistance  300       same asset
      MaxInteractDistance        150 x609, 170 x84, 200 x38, 250 x8
      LineTraceDiscardRadius     5 x589, 1 x84, 15 x28, 2 x27, 40 x8, 25 x2, 10 x1
      HoldInteractionDuration    0.75 x564, 0.8 x167, 1.5 x6, 4 x2
      InteractionCooldown        0.35 on EVERY ONE -- no variance at all
      InputAction                Interact on every one

    That last pair is why this mod does not touch cooldown: there is nothing to
    tune per class, only one number for everything, and changing it is bucket 3.

    HOW IT REACHES THE COMPONENTS
    -----------------------------
    UHeldenInteractionSubsystem.RegisteredInteractionEntries, walked as a
    property off the subsystem. One global object-array walk per pass to find
    the subsystem; everything below it is a property walk (crash rule E).

    SCHEDULING (crash rule K, RE-UE4SS #1180)
    -----------------------------------------
    Exactly one LoopAsync, exactly one ExecuteInGameThread, and no
    ExecuteWithDelay anywhere. Every delayed step goes through the `defer` queue
    below, which the pump drains on the game thread -- scheduling from inside a
    drained entry is safe by construction because it appends to our live table,
    never to the one being walked. Keybind callbacks do NOT run on the game
    thread, so they set a flag and nothing else.

    CONFIG
    ------
    <profile>\shimloader\cfg\BetterInteraction.cfg, read at startup and on F4.
    Every feature independently switchable; 0 means leave the game's value alone.

    KEYS
    ----
      F3   write a diagnostic report and change nothing
      F4   reload the config file
]]

local MOD     = "BetterInteraction"
local VERSION = "0.26.0-hooksize"

-- ==========================================================================
-- Everything version-fragile, in one place. A game patch is an edit here.
-- Every name below was read out of the 5.7.4 CXXHeaderDump and confirmed live.
-- ==========================================================================

local CLASS = {
    dispenser = "HeldenCoinDispenser",             -- AHeldenCoinDispenser
    subsystem  = "HeldenInteractionSubsystem",
    controller = "HeldenPlayerController",
    gameState  = "HeldenGameState",
}

local PROP = {
    registered = "RegisteredInteractionEntries",  -- TArray<FHeldenInteractionEntry>
    entryComp  = "Component",                     -- its only field
    settings   = "InteractSettings",              -- on the subsystem
    angle      = "InteractProximityAngle",        -- UInteractionSettings 0x3C
    distance   = "InteractProximityDistance",     -- UInteractionSettings 0x38
    reach      = "MaxInteractDistance",           -- UInteractionComponent 0x2D8
    discard    = "LineTraceDiscardRadius",        -- UInteractionComponent 0x2E0
    holdOn     = "bIsHoldInteraction",            -- UInteractionComponent 0x318
    holdDur    = "HoldInteractionDuration",       -- UInteractionComponent 0x31C

    -- Features 1 and 2, the deposit-all. Every one verified against the dump.
    hot        = "HotInteractions",                -- UHeldenInteractionSubsystem 0x58
    widgetCmp  = "InteractionWidgetComponent",     -- UInteractionComponent 0x330
    widget     = "Widget",                         -- UWidgetComponent, UMG.hpp:2376
    state      = "InteractState",                  -- UInteractionWidget 0x338
    required   = "RequiredMoney",                  -- AHeldenCoinDepositObject 0x4A8
    targetObj  = "TargetObject",                   -- AHeldenCoinDepositObject 0x488
    coinsLeft  = "CoinsLeftToPay",                 -- gumball 0x4A0 / upgrade 0x630
    remaining  = "RemainingCost",                  -- AHeldenElevatorMachine 0x638
    money      = "Money",                          -- AHeldenCharacter 0x1250
    pawn       = "Pawn",                           -- AController 0x2F0
    players    = "PlayerArray",                    -- AGameStateBase 0x2C8
    stashMoney = "StashMoney",                     -- AHeldenGameState 0x350

    -- Feature 5, the eaten hold input.
    focus      = "CurrentInteractTarget",          -- AHeldenPlayerController 0xC00
    playerIn   = "PlayerInput",                    -- APlayerController 0x428
    actionData = "ActionInstanceData",             -- UEnhancedPlayerInput 0x4E8
    trigger    = "TriggerEvent",                   -- FInputActionInstance 0x13
    elapsed    = "ElapsedProcessedTime",           -- FInputActionInstance 0x58
    holdOn     = "bIsHoldInteraction",             -- UInteractionComponent 0x318
    holdDur    = "HoldInteractionDuration",        -- UInteractionComponent 0x31C
    inProgress = "CurrentInteraction",             -- AHeldenCharacter 0xBB0
    progBar    = "ProgressBarWidget",              -- UInteractionWidget 0x360
    interpSpd  = "InterpSpeed",                    -- UHeldenProgressBar 0x33C
    progress   = "Progress",                       -- UHeldenProgressBar 0x338

    -- Feature 3, one coin instead of a shower of them.
    dispenser  = "CoinDispenser",                  -- AHeldenPackageSpot 0x4C0
    maxGold    = "MaxGoldPerCoins",                -- AHeldenCoinDispenser 0x330
    maxArt     = "MaxArtifactsPerCoin",            -- AHeldenCoinDispenser 0x334
    coinMoney  = "Money",                          -- AHeldenPhysicsCoin 0x938
    coinInter  = "InteractComponent",              -- AHeldenPhysicsCoin 0x6D8
    cooldown   = "DispenseCooldownRange",          -- AHeldenCoinDispenser 0x320
    root       = "RootComponent",                  -- AActor 0x1B8
    relLoc     = "RelativeLocation",               -- USceneComponent 0x148

}

-- ETriggerEvent, EnhancedInput_enums.hpp:116. FLAG values, not a dense
-- sequence. IA_Interact carries exactly one trigger, a UInputTriggerReleased
-- (UE4SS_ObjectDump.txt:126853), so it emits Started on press, Ongoing every
-- frame while the key is down, and Triggered only on RELEASE.
local TRIG_STARTED, TRIG_ONGOING = 2, 4

-- EHeldenInteractState, Helden_enums.hpp:893
local STATE_FOCUSED = 2

--- WHAT EACH DEPOSIT DOES, ONE ENTRY PER MACHINE. Version-fragile data, so it
--- lives here and nowhere else.
---
--- Two things vary per machine and NEITHER is derivable from the property names.
--- Both earlier attempts to derive them were wrong, and the second one destroyed
--- three of Daniel's artifacts:
---
---   * WHICH POOL pays. Not per-resource: the elevator takes GOLD from the
---     carried purse (39 -> 0 measured) while the upgrade machine takes GOLD
---     from the stash (1531 -> 1511 -> 1491 … measured, carried 0 throughout).
---   * WHAT THE MACHINE'S COUNTER IS DENOMINATED IN. Not per-counter-property:
---     the upgrade machine and the gumball BOTH use CoinsLeftToPay, and it
---     means different things in each. Read out of Helden.hpp and confirmed
---     against live logs on 29 Aug 2026:
---
---       "currency"  the counter holds MONEY and drops by whatever was paid.
---                   Elevating RequiredMoney alone is enough, because the
---                   machine subtracts the amount. Elevator RemainingCost and
---                   upgrade CoinsLeftToPay are both this.
---       "presses"   the counter holds a COUNT OF INSERTIONS and drops by
---                   exactly ONE per press, whatever was charged. Elevating
---                   RequiredMoney alone therefore DESTROYS the difference --
---                   that is what cost Daniel three artifacts. The charge and
---                   the counter must move together.
---
--- EVIDENCE, all from real runs on 29 Aug 2026:
---
---   elevator  RemainingCost   perPress 5   pool carried
---             wrote 35, owed 40 -> 5, carried 39 -> 0.  paid 35, credited 35.
---   upgrade   CoinsLeftToPay  perPress 20  pool stash
---             owed 100 -> 80 -> 60 -> 40 -> 20, stash gold -20 each press.
---             paid 20, credited 20. 20 != 1, so this counter is CURRENCY.
---   gumball   CoinsLeftToPay  perPress 1   pool stash
---             wrote 3A: stash 5A -> 2A (three paid), owed 3 -> 2 (ONE
---             credited). Its counter is a COUNT OF COINS.
---
--- A machine that is not in this table is NEVER elevated. Not knowing is the
--- default, and the cost of guessing wrong is the player's resources.
--- WHICH ACTORS ARE GRINDER COINS. Version-fragile data, so it lives here.
---
--- Measured 30 Aug 2026 from the coin report: BP_Coin_Gold_01_C and
--- BP_Coin_Artifact_01_C.
---
--- THESE ARE NOT "GRINDER COINS", and an earlier version of this comment said
--- they were. UHeldenDataSingleton holds ONE GoldCoinActorClass and ONE
--- ArtifactCoinActorClass for the whole game, so every gold coin from every
--- source -- the grinder, an enemy drop, a piggybank -- is the same class.
--- There is no way to tell them apart by class, which is exactly why the merge
--- groups by POSITION instead. Daniel: "coins dropped from enemies and
--- piggybanks are also merged".
---
--- The DungLoot variants (BP_Coin_Gold_DungLoot_02_C,
--- BP_Coin_Artifact_DungLoot_02_C) are a separate class and are left alone.
---
--- WHY A LIST AND NOT "anything with a Money property": 0.10.0 counted anything
--- carrying an FHeldenMoney, and the report duly filled up with
--- BP_HeldenCharacter_01_C, BP_Flamer_Vessel_01_C and BP_BirdGhost_01_C. They
--- all legitimately have purses. Naming the classes is the only honest filter.
local COIN = {
    BP_Coin_Gold_01_C     = true,
    BP_Coin_Artifact_01_C = true,
}

local MACHINE = {
    BP_HeldenElevator_CoinDeposit_C = { pool = "carried", counterIs = "currency" },
    BP_Upgrade_CoinDeposit_C        = { pool = "stash",   counterIs = "currency" },
    BP_Gumball_CoinDeposit_C        = { pool = "stash",   counterIs = "presses"  },
}

--- Classes this session has caught crediting LESS than it charged. Anything in
--- here is never elevated again, whatever the table above says -- the observed
--- behaviour of the running game outranks a value I typed.
local disabled = {}

local CONFIG_FILE = "BetterInteraction.cfg"
local LOG_FILE    = "BetterInteraction.log"
local STATE_FILE  = "BetterInteraction_state.txt"

local KEY_DIAG   = Key.F3
local KEY_RELOAD = Key.F4

-- THE PUMP ASKS FOR EVERY FRAME. IT CANNOT GET MORE THAN ONE.
--
-- The ring only moves when the mod moves it -- measured 30 Aug 2026,
-- UHeldenProgressBar:SetProgress does ONE interpolation step and stores no
-- target -- so the ring's smoothness IS the mod's update rate, and at 30Hz
-- Daniel reads it as "30 to 40fps" against a base game that looks like 100.
--
-- The rate is not really PUMP_MS. LoopAsync runs off the game thread and
-- APPENDS; the engine DRAINS once per tick; and inFlight refuses to append
-- while one is still pending. So the real rate is min(1/PUMP_MS, frame rate)
-- and asking for 8ms means "once per frame", not "125 times a second". On a
-- machine running at 40fps this pump runs 40 times a second, by construction.
--
-- Rule K is untouched and this is why the rate is safe to raise: still exactly
-- one LoopAsync and one ExecuteInGameThread, still appended from the LoopAsync
-- body and never from inside a drained callback -- which is the actual hazard
-- in RE-UE4SS #1180. Nothing about #1180 is rate-dependent.
--
-- The expensive work does NOT follow the pump. It is gated on ELAPSED TIME
-- rather than a tick count, because a tick count now means "frames" and would
-- silently make the deposit pass four times slower on a 60fps machine than the
-- 200ms it was measured and tuned at.
local PUMP_MS       = 8
local DEPOSIT_EVERY = 0.20   -- SECONDS between deposit/hold scans
local APPLY_MIN     = 0.10   -- floor on the reconciler interval, in seconds
local WIDE_EVERY  = 1.0    -- seconds between level-wide sweeps
local MAX_ENTRIES = 6000   -- a length far past the ~400 seen is the RE-UE4SS
                           -- #1328 failure mode, not a big level

-- ==========================================================================
-- Config. Plain `key = number` lines; anything else is ignored. Defaults here
-- are the shipped ones, so a missing or unreadable file still behaves.
-- ==========================================================================

local cfg = {
    -- Features 1 and 2. ON by default: this is what the mod is for.
    deposit_all         = 1,
    -- The gumball half. Separate key because it writes a SECOND value --
    -- the machine's own coin counter -- and someone may reasonably want the
    -- charge collapsed without that. See the header.
    deposit_counter     = 1,
    -- Feature 3. The most gold or artifacts the grinder may put in ONE coin.
    -- These ARE the game's own property values, so 0 means "leave it alone".
    coin_max_gold       = 100000,
    coin_max_artifacts  = 100000,
    coin_merge          = 1,
    coin_merge_radius   = 100,
    coin_merge_max_gold      = 100,
    coin_merge_max_artifacts = 100,
    coin_dispense_delay = 0.05,
    -- Feature 5. ON by default: it only ever acts where the base game has
    -- already dropped the input, so with it on nothing that works today
    -- changes.
    hold_rescue         = 1,
    hold_rescue_bar     = 1,

    -- Phase 1's knobs. OFF by default -- they work and are verified, but the
    -- interaction angle and distance are fine as the game ships them.
    prompt_angle        = 0,
    prompt_distance     = 0,
    reach               = 0,
    reach_ceiling       = 250,
    aim_forgiveness     = 0,
    hold_duration       = 0,
    hold_duration_floor = 0.25,
    apply_interval      = 1.0,
    log_reverts         = 1,
    diagnostic_key      = 1,
}

local cfgPath, cfgLoaded = nil, false

-- ==========================================================================
-- Log. Flushed, because UE4SS's own log is buffered and loses the last seconds
-- before a crash (crash rule J).
-- ==========================================================================

local logHandle = nil

local function openOut(name, mode)
    local handle = io.open(name, mode)
    if handle ~= nil then return handle, name end
    local fallback = (os.getenv("TEMP") or ".") .. "\\" .. name
    handle = io.open(fallback, mode)
    return handle, fallback
end

local function diag(text)
    if logHandle == nil then
        logHandle = openOut(LOG_FILE, "a") or false
    end
    if logHandle == false then return end
    pcall(function()
        logHandle:write(string.format("%s %9.3f  %s\n",
            os.date("%H:%M:%S"), os.clock(), text))
        logHandle:flush()
    end)
end

local function log(text)
    print("[" .. MOD .. "] " .. tostring(text) .. "\n")
    diag(text)
end

--- One line per distinct reason, then silence. A guard that can quietly do
--- nothing has to say so (crash rule H) -- but saying it every pass is its own
--- kind of silence.
local said = {}
local function logOnce(key, text)
    if said[key] then return end
    said[key] = true
    log(text)
end

-- ==========================================================================
-- Null-wrapper primitives (crash rule A).
--
-- A wrapper around null is TRUTHY, and a property read answers with a wrapper
-- whether or not the class has that property. So existence is never tested with
-- `if x`, `not x` or `~= nil`: for an object the test is "can it say its own
-- name", and for a value the test is its TYPE.
--
-- IsValid() is not used anywhere in this file. It DEREFERENCES, so on a freed
-- object it is the crash rather than a test for one (crash rule B).
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

--- A property that must be a NUMBER, or nil. `get(...) ~= nil` is the banned
--- form: it is true for a class that does not have the property at all.
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

local function count(array)
    local n = nil
    local ok = pcall(function() n = array:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    ok = pcall(function() n = #array end)
    if ok and type(n) == "number" then return n end
    return -1
end

--- The object's class name. Used to look a deposit up in the MACHINE table.
---
--- This function was CALLED before it existed: 0.3.2 shipped with
--- className(owner) at the deposit site and no definition anywhere in the file,
--- because the name was carried over from the probes. Lua resolved it as a nil
--- global, the walk raised on the first deposit, and the pcall around the walk
--- swallowed it -- so the whole feature did nothing and said nothing.
--- lua_check gained rule U for exactly this.
local function className(object)
    local name = nil
    pcall(function() name = object:GetClass():GetFName():ToString() end)
    if type(name) ~= "string" or name == "" then return "?" end
    return name
end

local function shortName(name)
    if name == nil or name == "" then return "?" end
    return (name:gsub("^.*[%.:/]", ""))
end

local function near(a, b)
    return type(a) == "number" and type(b) == "number" and math.abs(a - b) < 0.001
end

--- An `FHeldenMoney` read IN PLACE off a persistent object. ALL OR NOTHING: if
--- it is not three numbers it is not an FHeldenMoney we may touch. A partial
--- read that fabricated zeros for the rest would be written back later and
--- would permanently zero whatever did not read.
local function money(object, property)
    local block = get(object, property)
    local a, b, c = nil, nil, nil
    pcall(function() a = block.Scraps end)
    pcall(function() b = block.Gold end)
    pcall(function() c = block.Artifacts end)
    if type(a) ~= "number" or type(b) ~= "number" or type(c) ~= "number" then
        return nil
    end
    return { scraps = a, gold = b, artifacts = c }
end

local function moneyStr(value)
    if value == nil then return "?" end
    return string.format("%dS/%dG/%dA", value.scraps, value.gold, value.artifacts)
end

local function sameMoney(a, b)
    if a == nil or b == nil then return false end
    return a.scraps == b.scraps and a.gold == b.gold and a.artifacts == b.artifacts
end

--- Write an FHeldenMoney in place, field by field. Three plain int32s -- the
--- same in-place struct-member write proven for an FVector2D on this build.
local function writeMoney(object, property, value)
    local block = get(object, property)
    if block == nil then return false end
    local ok = true
    if not pcall(function() block.Scraps = value.scraps end) then ok = false end
    if not pcall(function() block.Gold = value.gold end) then ok = false end
    if not pcall(function() block.Artifacts = value.artifacts end) then ok = false end
    return ok
end

--- Returns owed, WHICH property answered, and the machine itself -- the third
--- because a press-counted machine needs its counter written, and the machine
--- must be re-reached by property walk from the deposit every pass rather than
--- held (crash rule C).
local function owedFor(deposit)
    local machine = get(deposit, PROP.targetObj)
    if not real(machine) then return nil, nil, nil end
    local value = numberProp(machine, PROP.remaining)
    if value ~= nil then return value, PROP.remaining, machine end
    value = numberProp(machine, PROP.coinsLeft)
    if value ~= nil then return value, PROP.coinsLeft, machine end
    return nil, nil, nil
end

--- Which single resource a cost is denominated in. nil when it spans more than
--- one -- that case is refused rather than guessed at.
local function soleResource(value)
    if value == nil then return nil end
    local found, amount = nil, 0
    for _, key in ipairs({ "scraps", "gold", "artifacts" }) do
        if value[key] > 0 then
            if found ~= nil then return nil end
            found, amount = key, value[key]
        end
    end
    if found == nil then return nil end
    return found, amount
end


--- NO UOBJECT IS EVER HELD ACROSS A TICK IN THIS FILE.
---
--- Version 0.2.1 held the subsystem and the controller for up to a second as a
--- crash-rule-E throttle, and it CRASHED THE GAME on starting a new save:
--- EXCEPTION_ACCESS_VIOLATION reading 0x0000000100000025, nine frames deep in
--- ue4ss.dll, 13 seconds after launch.
---
--- The mechanism is crash rule C in its exact documented form. noteWorld()
--- calls fullName() on the held subsystem in order to DETECT a world change --
--- and a name lookup DEREFERENCES. At a world change the object is freed BEFORE
--- the code that would clear the cache runs. Validate-then-forget, which is the
--- order the rule forbids.
---
--- The crash briefing settles the rule-E-versus-rule-C conflict that produced
--- it: "a rescan is exposure to a race; a stale pointer is a certainty. When
--- they conflict, take the race." So both objects are re-resolved every deposit
--- pass, and the pass runs at 200ms rather than 100ms -- half the scan rate,
--- still five times faster than the 1Hz that caused the write/restore flicker.

-- ==========================================================================
--- Find an object again BY PATH rather than holding it (crash rule C).
---
--- StaticFindObject is a name-hash lookup, NOT the global object-array walk
--- that rule E and RE-UE4SS #1328 are about, so this is safe to do at pump
--- rate where FindFirstOf would not be.
---
--- It returns a wrapper around a NULL POINTER when it finds nothing, never nil,
--- so `~= nil` is the banned test here (rule A) and fullName is the real one.
local function byPath(fullname)
    if type(fullname) ~= "string" then return nil end
    -- EVERYTHING AFTER THE CLASS NAME, whatever package it is in.
    --
    -- 0.7.0 matched only "/Game/..." and a fixed spot's component did not
    -- match, so its ring was never drawn -- measured 30 Aug 2026, Daniel: "the
    -- filling animation for specifically fixing spots is gone. it doesnt show
    -- the animation at all and then fixes it eventually anyway". The fallback
    -- worked exactly as designed and said so in the log, which is the only
    -- reason this was a cosmetic bug and not a dead feature.
    --
    -- GetFullName() is "Class Package.Outer:Sub.Name", so the path is simply
    -- everything past the first space -- no assumption about the package.
    local path = fullname:match("^%S+%s+(.+)$")
    if path == nil then return nil end
    local found = nil
    pcall(function() found = StaticFindObject(path) end)
    -- fullName() answers "" for nil AND for a wrapper around null, so this one
    -- test covers both. `found == nil` in front of it would be the banned form.
    if fullName(found) == "" then return nil end
    return found
end

-- FORWARD DECLARED. cachedRoot's body is defined further down, next to the
-- other object helpers, but callers sit between the two. A forward `local` is
-- the honest fix: the name exists from here on, so rules L and S are satisfied
-- and Lua resolves it as an upvalue rather than a nil global -- and the
-- assignment runs at load, long before any pass calls it.
local rootNames = {}
local cachedRoot

-- World epoch (crash rule D). Deferred work must not outlive its world, and
-- the revert bookkeeping is per-world by definition.
-- ==========================================================================

local epoch     = 0
local worldMark = nil
local reverts   = {}    -- fullName .. "|" .. prop -> true, cleared on epoch change

local function noteWorld(subsystem)
    local mark = real(subsystem) and fullName(subsystem) or nil
    if mark == nil or mark == worldMark then return end
    if worldMark ~= nil then
        epoch = epoch + 1
        reverts = {}
        said = {}
        rootNames = {}
        diag("world changed; epoch is now " .. epoch
            .. "; every remembered object name dropped")
    end
    worldMark = mark
end

-- ==========================================================================
-- The defer queue (crash rule K).
--
-- NEVER schedule through UE4SS. RE-UE4SS #1180: process_simple_actions drains
-- the engine-tick action vector with erase_if under a RECURSIVE mutex, so an
-- ExecuteInGameThread or ExecuteWithDelay issued from inside a drained callback
-- appends mid-iteration and corrupts the stored Lua registry refs. Seven of one
-- tester's fifteen crashes in a single session were this, and it works fine on
-- a fast machine, which is why it keeps coming back.
--
-- So every delayed step goes here instead. The queue is swapped before it is
-- walked, so an entry that schedules more work appends to the NEXT table rather
-- than the one being iterated. The epoch is captured centrally at SCHEDULE
-- time and checked centrally before the entry runs -- no hand-rolled second
-- guard, which is its own documented failure.
-- ==========================================================================

local defer = { queue = {}, ticks = 0 }

function defer.at(delayMs, label, fn)
    defer.queue[#defer.queue + 1] = {
        due   = defer.ticks + math.max(0, math.floor(delayMs / PUMP_MS)),
        label = label,
        epoch = epoch,
        fn    = fn,
    }
end

function defer.drain()
    defer.ticks = defer.ticks + 1
    if #defer.queue == 0 then return end
    local pending = defer.queue
    defer.queue = {}
    for _, entry in ipairs(pending) do
        if defer.ticks < entry.due then
            defer.queue[#defer.queue + 1] = entry
        elseif entry.epoch ~= epoch then
            diag("dropping deferred step '" .. tostring(entry.label)
                .. "': scheduled in epoch " .. tostring(entry.epoch)
                .. ", we are now in " .. tostring(epoch))
        else
            local ok, err = pcall(entry.fn)
            if not ok then
                log("deferred step '" .. tostring(entry.label) .. "' failed: "
                    .. tostring(err))
            end
        end
    end
end

-- ==========================================================================
-- Config file
-- ==========================================================================

--- WHERE THE CONFIG LIVES.
---
--- SHIMLOADER_CFG_DIR is the answer, and it is documented: shimloader takes
--- --cfg-dir from the mod manager and "publishes the resolved paths into the
--- process environment ... before ue4ss.dll is loaded" (its own README, 1.1.7).
--- So os.getenv gives the profile's cfg directory exactly, with no guessing.
---
--- Everything else here is a fallback with a reason:
---
---   Helden\Config          shimloader maps --cfg-dir onto GAME/Config, so this
---                          is the same directory by its virtualised name, and
---                          it works even if the env var is ever dropped.
---   the mod's own folder   for a hand-installed copy with no shimloader.
---   the working directory  last resort; cwd is Win64.
---
--- A DERIVED path from debug.getinfo does NOT work here and the first version
--- was wrong to try. Shimloader creates Win64\Mods at launch as a redirect, so
--- the script reports itself at
---     ...\Helden\Binaries\Win64\Mods\BetterInteraction\Scripts\main.lua
--- and walking up from there lands in Win64, not in the profile. Measured
--- 29 Aug 2026: it looked in Win64\cfg\ and found nothing.
local function configCandidates()
    local candidates = {}

    local cfgDir = nil
    pcall(function() cfgDir = os.getenv("SHIMLOADER_CFG_DIR") end)
    if type(cfgDir) == "string" and cfgDir ~= "" then
        cfgDir = cfgDir:gsub("[/\\]+$", "")
        candidates[#candidates + 1] = cfgDir .. "\\" .. CONFIG_FILE
    end

    -- cwd is Helden\Binaries\Win64, so this is Helden\Config.
    candidates[#candidates + 1] = "..\\..\\Config\\" .. CONFIG_FILE

    local source = nil
    pcall(function() source = debug.getinfo(1, "S").source end)
    if type(source) == "string" and source:sub(1, 1) == "@" then
        local scripts = source:sub(2):match("^(.*)[/\\][^/\\]+$")
        if scripts ~= nil then
            local modFolder = scripts:match("^(.*)[/\\][^/\\]+$")
            if modFolder ~= nil then
                candidates[#candidates + 1] = modFolder .. "\\" .. CONFIG_FILE
            end
            candidates[#candidates + 1] = scripts .. "\\" .. CONFIG_FILE
        end
    end

    candidates[#candidates + 1] = CONFIG_FILE
    return candidates
end

--- WRITE THE DEFAULTS OUT WHEN THERE IS NO CONFIG TO READ.
---
--- Packaging rule 5 says the config ships "as a file the user can read and
--- edit, not as constants baked into main.lua". A Thunderstore install cannot
--- rely on one appearing: no Grain Rot package ships a cfg/ folder, and where
--- r2modman would put one if it did is unverified -- it nests a package's
--- overlay/ and mod/ under the package name, so a cfg/ would probably nest too,
--- somewhere the mod is not looking.
---
--- So the mod writes its own on first run, into the first location it can. That
--- makes every setting visible and editable however the mod was installed,
--- which is what the rule is actually for.
---
--- The values come from the SAME cfg table the mod runs on, so the file cannot
--- disagree with the defaults it documents. The fully commented version ships
--- with the mod and is on its page; this one is deliberately terse.
local function writeDefaultConfig(candidates)
    local names = {}
    for key in pairs(cfg) do names[#names + 1] = key end
    table.sort(names)

    local header = {
        "# " .. MOD .. " " .. VERSION .. " -- written by the mod because"
            .. " no config file was found.",
        "#",
        "# Every setting the mod has, at its default. Edit it and press F4 in",
        "# game to reload; no restart is needed. 0 almost always means 'leave",
        "# the game's own value alone'.",
        "#",
        "# The fully commented version, explaining what each setting does and",
        "# what it was measured against, ships with the mod and is on its page.",
        "",
    }

    for _, path in ipairs(candidates) do
        local out = io.open(path, "w")
        if out ~= nil then
            for _, line in ipairs(header) do
                out:write(line)
                out:write("\n")
            end
            for _, key in ipairs(names) do
                local value = cfg[key]
                if value == math.floor(value) then
                    out:write(string.format("%s = %d\n", key, value))
                else
                    out:write(string.format("%s = %s\n", key, tostring(value)))
                end
            end
            out:close()
            return path
        end
    end
    return nil
end

local function loadConfig()
    local candidates = configCandidates()
    local handle, path = nil, nil
    for _, candidate in ipairs(candidates) do
        local attempt = io.open(candidate, "r")
        if attempt ~= nil then
            handle, path = attempt, candidate
            break
        end
    end
    if handle == nil then
        local written = writeDefaultConfig(candidates)
        if written ~= nil then
            log("no " .. CONFIG_FILE .. " found, so one was written with the"
                .. " defaults: " .. written .. " -- edit it and press F4.")
            handle, path = io.open(written, "r"), written
        end
        if handle == nil then
            cfgLoaded = false
            logOnce("nocfg", "no " .. CONFIG_FILE .. " found and none could be"
                .. " written; running on built-in defaults. Looked in: "
                .. table.concat(candidates, "   "))
            return
        end
    end

    local applied, unknown = 0, {}
    for line in handle:lines() do
        local key, value = line:match("^%s*([%w_]+)%s*=%s*([%-%d%.]+)")
        if key ~= nil then
            local number = tonumber(value)
            if number == nil then
                unknown[#unknown + 1] = key .. " (not a number: " .. value .. ")"
            elseif cfg[key] == nil then
                unknown[#unknown + 1] = key .. " (not a setting this mod has)"
            else
                cfg[key] = number
                applied = applied + 1
            end
        end
    end
    handle:close()
    cfgPath, cfgLoaded = path, true

    log(string.format("config loaded from %s -- %d settings", path, applied))
    -- Rule H: a config line that did nothing must say so, or a typo looks
    -- exactly like a feature that does not work.
    for _, item in ipairs(unknown) do
        log("  config line ignored: " .. item)
    end
end

-- ==========================================================================
-- Writes, every one of them read back.
--
-- Returns "already" / "written" / "REFUSED" / "missing". REFUSED means the
-- write did not take -- the accessor handed back a copy, or the game rejected
-- it -- and is the one that has to be visible, because a write that silently
-- does nothing and a feature that is switched off look identical otherwise.
-- ==========================================================================

local applied, refused, reapplied = 0, 0, 0

local function setNumber(object, property, target, label)
    local before = numberProp(object, property)
    if before == nil then return "missing" end
    if near(before, target) then return "already" end

    pcall(function() object[property] = target end)
    local after = numberProp(object, property)
    if not near(after, target) then
        refused = refused + 1
        logOnce("refused:" .. label .. ":" .. property,
            "REFUSED: " .. label .. "." .. property .. " would not take "
            .. tostring(target) .. " (still reads " .. tostring(after) .. ")")
        return "REFUSED"
    end

    applied = applied + 1
    -- The game putting a value back is EXPECTED and is why this is a
    -- reconciler. Say it once per object per world -- rule H without the
    -- 24,000-lines-an-hour failure mode.
    if cfg.log_reverts ~= 0 then
        local key = fullName(object) .. "|" .. property
        if reverts[key] then
            reapplied = reapplied + 1
        else
            reverts[key] = true
        end
    end
    return "written"
end

-- ==========================================================================
-- The features. Each declares its co-op bucket at the site.
-- ==========================================================================

--- BUCKET 1 -- local presentation. One shared asset, one write, whole game.
--- Established 29 Aug 2026: every one of 739 components in two worlds points at
--- /Game/Core/InteractionSettings.InteractionSettings, so this really is one
--- write for everything.
local function applySettings(subsystem)
    local settings = get(subsystem, PROP.settings)
    if not real(settings) then
        logOnce("nosettings", "the shared " .. PROP.settings .. " asset did not"
            .. " resolve; the prompt-cone features are doing nothing this world")
        return
    end
    if cfg.prompt_angle > 0 then
        setNumber(settings, PROP.angle, cfg.prompt_angle, "settings")
    end
    if cfg.prompt_distance > 0 then
        setNumber(settings, PROP.distance, cfg.prompt_distance, "settings")
    end
end

--- BUCKET 1 for reach and forgiveness -- they change what YOUR machine offers.
--- BUCKET 3 for hold duration: whether the host validates HoldInteractionDuration
--- is NOT established, so it is off by default and the config says why.
local function applyComponent(component)
    local label = shortName(fullName(component))

    if cfg.reach > 0 then
        -- The ceiling is where CLAUDE.md's scope line is enforced: "you are
        -- standing at it" is in scope, "you are across the room" is not. The
        -- game's own upper value is 250, so that is the default ceiling.
        local want = math.min(cfg.reach, cfg.reach_ceiling)
        local current = numberProp(component, PROP.reach)
        -- Only ever raise a short reach toward the ceiling. Never shorten
        -- something the game deliberately made long.
        if current ~= nil and current < want then
            setNumber(component, PROP.reach, want, label)
        end
    end

    if cfg.aim_forgiveness > 0 then
        local current = numberProp(component, PROP.discard)
        if current ~= nil and current < cfg.aim_forgiveness then
            setNumber(component, PROP.discard, cfg.aim_forgiveness, label)
        end
    end

    if cfg.hold_duration > 0 then
        -- Only touch components that ARE holds. Setting a duration on a tap
        -- would be meaningless at best.
        if boolProp(component, PROP.holdOn) == true then
            local want = math.max(cfg.hold_duration, cfg.hold_duration_floor)
            local current = numberProp(component, PROP.holdDur)
            if current ~= nil and current > want then
                setNumber(component, PROP.holdDur, want, label)
            end
        end
    end
end

local function findFirst(class)
    local found = nil
    pcall(function() found = FindFirstOf(class) end)
    if not real(found) then return nil end
    -- Every one of these classes has a Default__ twin in the object dump, and a
    -- class default object would answer every read with archetype values rather
    -- than this world's. Cheap to rule out, expensive to misread.
    if fullName(found):find("Default__", 1, true) ~= nil then
        logOnce("cdo:" .. class, "FindFirstOf(\"" .. class .. "\") answered with"
            .. " a class default object; refusing it. REPORT THIS.")
        return nil
    end
    return found
end

--- WHO ELSE IS IN THE SESSION, without a global scan.
---
--- AGameStateBase.PlayerArray is a TArray<APlayerState*> property on the game
--- state the mod already resolves, so counting players is a property walk.
local function playerCount(gs)
    if gs == nil then return 1 end
    local array = get(gs, PROP.players)
    if array == nil then return 1 end
    local total = count(array)
    if total < 1 or total > MAX_ENTRIES then return 1 end
    return total
end

--- EVERY COIN DEPOSIT IN THE LEVEL, not just the ones the host is standing at.
---
--- Measured in the first lobby: a guest only benefited while Daniel stood near
--- the machine, because the mod walks HotInteractions -- which is the LOCAL
--- player's proximity. RegisteredInteractionEntries is every registered
--- component in the world, ~380 of them, and it is a property walk off the
--- subsystem rather than a global object-array scan, so rule E is not in play.
---
--- SPLIT SLOW FROM FAST, which is the whole reason this is affordable. There are
--- only THREE coin deposits in a level against ~380 components, so the
--- expensive part is FINDING them, not acting on them. The 380-entry walk runs
--- every few seconds and only records NAMES; the three names are turned back
--- into objects by hash lookup on the normal 200ms cadence.
---
--- A slower cadence for the ACTING would not have been safe: after a gumball
--- dispenses, its counter resets to 3 while the elevated charge still stands,
--- and a press inside that window pays 3 for a credit of 1 -- the exact robbery
--- that cost Daniel three artifacts. Widening that window fivefold and pointing
--- it at the guest was not a trade worth making.
---
--- SOLO PAYS NOTHING: skipped entirely unless a second player is present.
--- ONE SWEEP, TWO CONSUMERS. The deposits and the loose coins are found in the
--- same pass over the registered array, because walking it twice would double
--- the only cost that matters here.
---
--- Coins are swept too because Daniel saw the same symptom for them -- "it
--- doesnt merge the coins until the host gets closer". Merging is safe at this
--- slower cadence in a way the deposits' charge would not have been: a merge is
--- write-verify-then-empty inside a single pass, with no second value left
--- standing between passes for a press to land on.
local wide = { coins = {}, at = -1, epoch = -1, said = -1 }

local function discoverWide(subsystem, players)
    if wide.epoch ~= epoch then
        wide.epoch, wide.coins = epoch, {}
        wide.at, wide.said = -1, -1
    end
    if players < 2 then
        if #wide.coins > 0 then
            wide.coins = {}
            diag("coop: alone again, so the level-wide sweep is off")
        end
        wide.said = -1
        return wide
    end
    if wide.at >= 0 and os.clock() - wide.at < WIDE_EVERY then return wide end
    wide.at = os.clock()

    local array = get(subsystem, PROP.registered)
    if array == nil then return wide end
    local total = count(array)
    if total < 0 or total > MAX_ENTRIES then return wide end

    local coins = {}
    pcall(function()
        array:ForEach(function(_index, element)
            local entry = nil
            pcall(function() entry = element:get() end)
            local component = nil
            if entry ~= nil then
                pcall(function() component = entry[PROP.entryComp] end)
            end
            if not real(component) then return end
            local owner = nil
            pcall(function() owner = component:GetOwner() end)
            if not real(owner) then return end
            if COIN[className(owner)] then
                coins[#coins + 1] = fullName(component)
            end
        end)
    end)

    wide.coins = coins
    if wide.said ~= #coins then
        wide.said = #coins
        diag(string.format("coop: %d players; swept %d registered components,"
            .. " covering %d loose coin(s) level-wide", players, total, #coins))
    end
    return wide
end

--- True when any per-component feature is on. When they are all off -- which is
--- the shipped default -- the walk is skipped entirely and a pass costs one
--- object-array scan plus one property write.
local function needComponentWalk()
    return cfg.reach > 0 or cfg.aim_forgiveness > 0 or cfg.hold_duration > 0
end

-- ==========================================================================
-- Resolution and the pass
-- ==========================================================================

--- One extra global array walk per pass, on the same once-a-second cadence as
--- the subsystem resolve (crash rule E). Never cached across passes (rule C).
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

local state = { passes = 0, skipped = 0, components = 0, lastSkip = nil }

local function pass()
    -- Rule F: gate on a FACT -- is there a playable world -- not on a timer.
    local subsystem = cachedRoot("subsystem",
        function() return findFirst(CLASS.subsystem) end)
    if subsystem == nil then
        state.skipped = state.skipped + 1
        state.lastSkip = "no " .. CLASS.subsystem .. " (menu, or a level transition)"
        logOnce("noworld", "waiting: " .. state.lastSkip)
        return
    end
    said["noworld"] = nil     -- so the next transition says it again
    noteWorld(subsystem)
    state.passes = state.passes + 1

    applySettings(subsystem)



    if not needComponentWalk() then
        state.components = 0
        return
    end

    local array = get(subsystem, PROP.registered)
    if array == nil then
        logOnce("noarray", PROP.registered .. " did not read; per-component"
            .. " features are doing nothing")
        return
    end
    local total = count(array)
    if total < 0 then
        logOnce("nolength", PROP.registered .. " has no readable length")
        return
    end
    if total > MAX_ENTRIES then
        logOnce("bogus", string.format("%s reports %d entries, past the %d cap"
            .. " -- refusing to walk it (RE-UE4SS #1328 returns garbage lengths"
            .. " off a raced array)", PROP.registered, total, MAX_ENTRIES))
        return
    end

    local seen = 0
    pcall(function()
        array:ForEach(function(_index, element)
            local entry = nil
            pcall(function() entry = element:get() end)
            local component = nil
            if entry ~= nil then
                pcall(function() component = entry[PROP.entryComp] end)
            end
            if real(component) then
                seen = seen + 1
                applyComponent(component)
            end
        end)
    end)
    state.components = seen
end

--- Runs EVERY PUMP TICK, unlike the 1-second reconciler.
---
--- Measured 29 Aug 2026: at 1 Hz the write and the restore alternate as focus
--- flickers on approach, and the player's press lands on whichever the last
--- pass happened to leave -- which is the "took 5, then the rest on the second
--- press" symptom, and on one run it took three presses.
---
--- Both objects are re-resolved EVERY pass. NOTHING IS HELD -- see the note by
--- the epoch declaration for why 0.2.1's throttle crashed the game.
-- ==========================================================================
-- FEATURE 5 -- THE EATEN HOLD INPUT. The mod runs the hold itself.
-- ==========================================================================
--
-- THE BUG, in Daniel's words: "interacting with an object that requires holding
-- said input requires seeing the input icon. If the input is held even a frame
-- before that icon is shown the input gets eaten and the player needs to
-- release and re-press E."
--
-- WHY IT HAPPENS -- finding, from the dump, not a guess. IA_Interact carries
-- exactly ONE trigger, a UInputTriggerReleased (UE4SS_ObjectDump.txt:126853),
-- and IMC_Default adds no per-mapping triggers. That configuration emits
-- Started on press, Ongoing every frame while held, and Triggered on RELEASE.
-- So while the key stays down NO SECOND Started IS EVER PRODUCED. A tap can
-- still fire on the release edge; a hold, which needs the press edge, cannot.
-- That is the asymmetry, and it predicts release-and-re-press exactly.
--
-- (Which native handler consumes that edge is unreflected C++ and is not in the
-- dump. It stays a HYPOTHESIS and this feature does not depend on it: it does
-- not care why the edge was missed, only that it was.)
--
-- WHAT THIS DOES. When a hold prompt is focused and the key is already down and
-- the game is demonstrably not running a hold, the mod runs the hold itself:
-- its own timer against the component's own HoldInteractionDuration, driving
-- the prompt's own progress bar, and completing through the game's own
-- Interact(pawn) -- which is measured to complete a hold interaction outright.
--
-- CO-OP: bucket 2, local input shaping. Every call is one the unmodded game
-- would have accepted at that moment from that player; the mod only supplies
-- the press edge the input system dropped. NOT verified in a lobby.
--
-- IT CANNOT DOUBLE-FIRE, and this is the property that matters most. The
-- decision to take over is gated on the game's OWN hold alpha reading zero --
-- a measurement, not an inference -- so the mod and the game can never both be
-- running a hold on the same press. Once the mod has taken over it stops
-- consulting that alpha, because by then the alpha it reads is its own.
-- Backstops: it fires at most once per key press (firedFor), it never fires
-- while an interaction is already running (CurrentInteraction), and it drops
-- everything the moment the key goes up.

--- Is the interact key down right now. Property walk from the controller:
--- PlayerInput -> ActionInstanceData, a TMap<UInputAction*,
--- FInputActionInstance>. No global scan (rule E), no FKey ever constructed,
--- and it follows a rebind for free because it asks about the ACTION.
--- `wanted` is the lower-cased action asset name, e.g. "ia_interact". Named
--- exactly, never by prefix: SecondaryInteract and TertiaryInteract are separate
--- actions on separate buttons, and IA_UI_Accept is not IA_UI_Puzzl_Accept.
---
--- `roster` is optional; when given, every action currently DOWN is recorded
local function actionDown(controller, wanted, roster)
    local input = get(controller, PROP.playerIn)
    if not real(input) then return nil, nil, "PlayerInput did not resolve" end
    local map = get(input, PROP.actionData)
    if map == nil then return nil, nil, PROP.actionData .. " did not read" end

    local down, elapsed, seen = nil, nil, 0
    local ok = pcall(function()
        map:ForEach(function(key, value)
            seen = seen + 1
            local action = key
            pcall(function() action = key:get() end)
            local name = shortName(fullName(action)):lower()
            local instance = value
            pcall(function() instance = value:get() end)
            local trig = numberProp(instance, PROP.trigger)
            if trig == nil then return end
            local held = (trig == TRIG_STARTED) or (trig == TRIG_ONGOING)
            if roster ~= nil and held then roster[#roster + 1] = name end
            if name == wanted and down == nil then
                down = held
                elapsed = numberProp(instance, PROP.elapsed)
            end
        end)
    end)
    if not ok then return nil, nil, "the " .. PROP.actionData .. " walk raised" end
    if down == nil then
        -- Rule H: "that action is not in the map" and "the map is empty" are
        -- different facts, and only one of them means this name is wrong.
        return nil, nil, string.format("no %s among %d actions", wanted, seen)
    end
    return down, elapsed, nil
end

local function interactDown(controller)
    return actionDown(controller, "ia_interact")
end

--- READING SPACE CRASHED THE GAME. Both routes are DELETED, not disabled.
---
--- 0.15.0 asked APlayerController::GetInputKeyTimeDown(FKey) by handing it a
--- Lua table {KeyName = "SpaceBar"}, and failing that walked
--- UEnhancedPlayerInput.KeysPressedThisTick reading KeyName off each FKey. The
--- first conversation of the session took the process down:
---
---   EXCEPTION_ACCESS_VIOLATION reading address 0x0000000000000070
---   SecondsSinceStart 12
---
--- A near-null dereference. An FKey is not just its name -- it carries an
--- internal cached pointer to its key details -- so a struct built from a table
--- has that pointer as garbage, and the engine dereferences it. The same
--- objection applies to reading a field off an FKey taken out of a TMap.
---
--- THE RULE ALREADY SAID SO. "Fields of a struct returned by value across the
--- Lua/native boundary are not safe -- reading one can hard-crash the process,
--- and pcall CANNOT catch it." 0.15.0 carried a comment arguing that passing a
--- struct IN was different from reading one OUT. That argument was mine, it was
--- wrong, and it is exactly the shape of reasoning the rule exists to stop.
---
--- Space cannot be read this way. It is not an input action either (0.15.0's
--- other finding). What is left untried is a UE4SS keybind on the raw key, which
--- touches no game memory at all -- but it is not attempted here, because the
--- next thing this feature does should be chosen deliberately and not while
--- reacting to a crash.

--- THE ROOT OBJECTS, FOUND ONCE AND THEN REMEMBERED BY NAME.
---
--- Daniel asked the obvious question: why look these up on a cadence at all --
--- why not hardcode them, or find them once per level?
---
--- Hardcoding is out. The same subsystem has had at least seventeen different
--- names across sessions (HeldenInteractionSubsystem_2147479638, _2147480850,
--- _2147480855 ...) because the instance number changes every run and the
--- dungeon is regenerated from a seed.
---
--- Holding the pointer is worse, and it is crash rule C: there is NO safe way
--- to ask whether a UObject pointer is still valid. IsValid() reads THROUGH the
--- pointer, so on freed memory it is the crash rather than a test for it, and
--- pcall cannot catch an access violation. 0.2.1 cached the subsystem and
--- controller for one second as exactly this optimisation and crashed 100% of
--- new-save starts.
---
--- So this caches the NAME. A string cannot dangle. StaticFindObject turns it
--- back into an object with a hash lookup instead of the global object-array
--- walk that rule E and RE-UE4SS #1328 are about -- and when the world changes
--- the name simply stops resolving, which is the re-scan trigger, arriving
--- BEFORE any dereference rather than after one.
---
--- This takes the mod from roughly eleven global walks a second to nearly none.
cachedRoot = function(key, scanner, stillValid)
    local found = byPath(rootNames[key])
    if found ~= nil then
        if stillValid == nil or stillValid(found) then return found end
    end
    rootNames[key] = nil
    found = scanner()
    if found ~= nil then
        rootNames[key] = fullName(found)
        logOnce("root:" .. key .. ":" .. rootNames[key],
            "resolved " .. key .. " by scan: " .. shortName(rootNames[key])
            .. " -- remembered by name, so this should not repeat until the"
            .. " world changes")
    end
    return found
end

--- The prompt widget for a component: InteractionWidgetComponent -> Widget.
local function promptWidget(component)
    local holder = get(component, PROP.widgetCmp)
    if not real(holder) then return nil end
    local widget = get(holder, PROP.widget)
    if not real(widget) then return nil end
    return widget
end

--- THE FOCUSED HOLD PROMPT, and the correction that this whole feature turned
--- on. 0.6.0 asked AHeldenPlayerController.CurrentInteractTarget and did
--- nothing whatsoever, in complete silence.
---
--- MEASURED 30 Aug 2026, from Daniel's F3 taken while holding the key at a
--- chair for two seconds:
---
---     interact key      DOWN, down 2.00s
---     focused           nothing
---
--- CurrentInteractTarget is not "what you are aiming at". It is the interact
--- the game has ACCEPTED -- it fills on the press edge. So in the eaten-input
--- case, which is the entire point of this feature, it is empty by
--- construction and the takeover condition could never be true. The earlier
--- hold probe showed it populated only because every sample it took was after
--- a press that had landed.
---
--- The real signal is the prompt's own UInteractionWidget.InteractState, which
--- is what is actually on screen. Reaching it needs the components in range,
--- which is HotInteractions on the subsystem -- so this walks the SAME array
--- the deposit pass already walks, off the SAME resolve, and adds no global
--- object-array walk at all (rule E).
local function focusedHold(subsystem)
    local array = get(subsystem, PROP.hot)
    if array == nil then return nil, nil end
    local total = count(array)
    if total < 0 or total > MAX_ENTRIES then return nil, nil end

    local found, foundWidget = nil, nil
    pcall(function()
        array:ForEach(function(_index, element)
            if found ~= nil then return end
            local component = nil
            pcall(function() component = element:get() end)
            if not real(component) then return end
            if boolProp(component, PROP.holdOn) ~= true then return end
            local widget = promptWidget(component)
            if not real(widget) then return end
            if numberProp(widget, PROP.state) ~= STATE_FOCUSED then return end
            found, foundWidget = component, widget
        end)
    end)
    return found, foundWidget
end

--- DRIVING THE RING SMOOTHLY AT 200ms.
---
--- Daniel, 30 Aug 2026: "the bar filling is very choppy, it basically fills it
--- in ~25% at a time." Correct, and predicted -- four updates across a 0.8s
--- hold is exactly four steps.
---
--- The game does not draw it smoothly by writing it every frame either.
--- UHeldenProgressBar carries `float InterpSpeed` and `SetProgress(float,
--- bool bInterp)`: told to interp, the bar ANIMATES toward the value on its
--- own. So the fix is not a faster pump -- which would have doubled the mod's
--- global-walk rate for cosmetics -- it is to stop snapping the bar and give
--- it somewhere to travel to.
---
--- It is handed the alpha we will have at the NEXT update, one step ahead, so
--- it spends the whole 200ms animating across exactly the gap our sampling
--- leaves and arrives just as the next update lands. Clamped at 1 so it can
--- never show full before the hold actually completes.
local hold = {
    active   = false,   -- is the mod running a hold right now
    t0       = 0,       -- os.clock at which the mod's hold started
    target   = nil,     -- fullName of the component it started on
    firedFor = nil,     -- fullName already completed on THIS key press
    epoch    = -1,
    barOK    = nil,     -- has SetHoldInteractAlpha ever been seen to take
    sawFocus = nil,     -- last focused hold announced, to log it only on change
    dirty    = {},      -- fullName -> true: rings we wrote and have not cleared
    pawnName = nil,     -- the pawn's path, so the fast tick can complete without
                        -- a controller resolve
    frames   = 0,       -- ring updates drawn in the current hold
    tracked  = false,   -- has this hold reported its achieved rate yet
}

--- ANSWERED 30 Aug 2026, so there is nothing here any more:
--- AHeldenInteractableObject::Interact_Local(pawn) DOES NOTHING on a hold, the
--- same as Interact_Server. All three members of the family are now measured --
--- Interact completes outright, Interact_Server does nothing, Interact_Local
--- does nothing -- and the component carries no hold-start-time field either
--- (its whole reflected surface is bIsHoldInteraction, HoldInteractionDuration,
--- bAutoEndHoldInteract and GetHoldInteractAlpha). The game's hold lives in
--- unreflected C++ and cannot be started, so the mod draws the ring itself and
--- the only lever left is how often it can do that.
---
--- The probe that established this is DELETED rather than left switched off: it
--- also suppressed the ring for the whole of the hold it ran on, so shipping it
--- would have broken the first hold of every session.

--- DRAW THE RING THE WAY THE GAME DOES: write the alpha, every update.
---
--- 0.7.1 raised the bar's InterpSpeed and led the target, on the theory that the
--- bar would animate between updates. It does not -- SetProgress performs ONE
--- step and stores no target, measured -- so all that machinery bought nothing
--- and left a game property to put back. It is gone, and with it the
--- hold_ring_interp knob.
---
--- SetProgress IS THE DRAW. SetHoldInteractAlpha is not, or not on its own:
--- 0.7.1 called it exactly once per hold and the ring still animated for the
--- whole hold, which can only have been the per-frame SetProgress calls. It is
--- still made on the first update, because that combination is the one actually
--- observed to put a ring on screen, and it costs nothing.
---
--- bInterp is FALSE. Interpolation existed to hide a low update rate; at frame
--- rate it would only add lag, and the game's own ring is linear.
local function driveBar(widget, alpha, first)
    if first then pcall(function() widget:SetHoldInteractAlpha(alpha) end) end
    local bar = get(widget, PROP.progBar)
    if not real(bar) then return false end
    pcall(function() bar:SetProgress(alpha, false) end)
    return true
end

local function clearBar(component)
    local widget = promptWidget(component)
    if not real(widget) then return false end
    pcall(function() widget:SetHoldInteractAlpha(0) end)
    local bar = get(widget, PROP.progBar)
    if real(bar) then pcall(function() bar:SetProgress(0, false) end) end
    return true
end


local function resetHold(why)
    if hold.active and why ~= nil then
        diag(string.format("hold: abandoned after %.2fs (%s)",
            os.clock() - hold.t0, why))
    end
    hold.active, hold.target = false, nil
end

--- END A HOLD THE MOD HAS SERVED IN FULL.
---
--- Interact(pawn) on the owning actor is measured to perform a hold interaction
--- outright, which is exactly what is wanted at the END of a hold that has
--- already run its whole duration.
---
--- Reachable from BOTH cadences on purpose. The 30Hz ring tick finds its
--- component by path and is the one that normally fires, on time; the 200ms
--- scan already has the component in hand and fires as a fallback if the path
--- lookup ever fails, so a component whose path will not resolve costs the ring
--- and not the feature. hold.firedFor makes the two safe to have at once: the
--- first to arrive latches it and the other returns.
local function finishHold(component, pawn, duration)
    if pawn == nil then return resetHold("the pawn could not be found again") end

    -- Never while something is already running.
    local running = get(pawn, PROP.inProgress)
    if running ~= nil and real(running) then
        return resetHold("an interaction is already running")
    end

    local owner = nil
    pcall(function() owner = component:GetOwner() end)
    if not real(owner) then return resetHold("no owner") end

    local name = hold.target
    local fired = pcall(function() owner:Interact(pawn) end)
    hold.firedFor = name              -- once per key press, whatever happened
    resetHold(nil)
    -- Immediately, while the component is still in hand. The prompt is about to
    -- hide anyway; what must not survive is the VALUE, which is what was still
    -- sitting on the fixed spot after its interaction had gone.
    if clearBar(component) then hold.dirty[name] = nil end
    diag(string.format("hold: completed %s after %.2fs and called Interact -- %s",
        shortName(name), duration, fired and "call returned" or "the call RAISED"))
end

--- Everything this feature remembers between passes is a SCALAR or a STRING.
--- No UObject is held (crash rule C): the focus target is remembered by NAME
--- and re-resolved from the controller every pass.

--- Put back every ring this mod has written and not yet cleared.
---
--- Most ends have the widget in hand and clear on the spot. The ones that do
--- not -- the key released, focus lost, the object finished and stopped being a
--- focusable hold at all -- reach it here, by NAME, from the same
--- HotInteractions walk, matching whatever state the component is in now. That
--- last case is the fixed spot: it is still in range, it is simply no longer
--- something focusedHold() would ever return, so nothing else would ever find
--- it again.
local function clearDirty(subsystem, keep)
    if next(hold.dirty) == nil then return end
    local array = get(subsystem, PROP.hot)
    if array == nil then return end
    local total = count(array)
    if total < 0 or total > MAX_ENTRIES then return end

    pcall(function()
        array:ForEach(function(_index, element)
            local component = nil
            pcall(function() component = element:get() end)
            if not real(component) then return end
            local name = fullName(component)
            if hold.dirty[name] == nil or name == keep then return end
            if clearBar(component) then
                hold.dirty[name] = nil
                diag("hold: cleared the ring on " .. shortName(name))
            end
        end)
    end)
end

--- Runs on the deposit cadence, off the deposit's own subsystem resolve, so it
--- costs no extra global walk. 200ms to notice a prompt against a 0.75s hold is
--- about 13% longer than pressing normally would be -- which is a far better
--- trade than doubling the mod's largest crash exposure for it.
local function holdScan(subsystem, controller)
    if cfg.hold_rescue == 0 then return end
    if hold.epoch ~= epoch then
        hold.epoch, hold.active, hold.target, hold.firedFor = epoch, false, nil, nil
        -- The old world's widgets are gone with it; carrying their names would
        -- be a list this mod could never satisfy.
        hold.sawFocus, hold.dirty = nil, {}
    end
    if controller == nil then return end

    clearDirty(subsystem, hold.active and hold.target or nil)

    local down, heldFor, why = interactDown(controller)
    if why ~= nil then
        logOnce("holdinput:" .. why,
            "the hold feature cannot read the interact key (" .. why
            .. "), so it is doing nothing at all")
        return
    end

    -- KEY UP CLEARS EVERYTHING, including the once-per-press latch. This is
    -- also what leaves release-and-re-press working exactly as it does today.
    if down ~= true then
        -- Clear on THIS pass, not the next one: the top-of-pass sweep spared
        -- the ring we were still driving, and releasing the key is exactly when
        -- it has to go.
        if hold.active then clearDirty(subsystem, nil) end
        resetHold(nil)
        hold.firedFor = nil
        return
    end

    local focus, widget = focusedHold(subsystem)
    if not real(focus) or not real(widget) then
        return resetHold("no hold prompt focused")
    end

    local name = fullName(focus)
    if hold.sawFocus ~= name then
        hold.sawFocus = name
        diag(string.format("hold: a hold prompt is focused -- %s (%.2fs)",
            shortName(name), numberProp(focus, PROP.holdDur) or -1))
    end
    if hold.firedFor == name then return end      -- done; waiting for release
    if hold.active and hold.target ~= name then
        resetHold("looked at something else")
    end

    if not hold.active then
        -- THE DECISION, and the only place the game's own alpha is consulted.
        -- Non-zero means the game IS running its hold -- the key went down
        -- while this was already focused, the press edge landed, and there is
        -- nothing wrong to fix. Stand down and let it run.
        local gameAlpha = nil
        pcall(function() gameAlpha = widget:GetHoldInteractAlpha() end)
        if type(gameAlpha) == "number" and gameAlpha > 0.001 then
            -- Worth one line, once: this is the reading the whole no-double-fire
            -- property rests on, and it had never been observed NON-zero.
            logOnce("gamehold", string.format("hold: the game's own hold reads"
                .. " alpha %.3f while running, so standing down on a live hold"
                .. " works as designed.", gameAlpha))
            return
        end

        -- Key down, hold prompt focused, and the game is not holding: the press
        -- edge was eaten. Take it over -- starting NOW, not from when the key
        -- went down, so it feels exactly like pressing at this moment.
        hold.active, hold.t0, hold.target = true, os.clock(), name
        hold.pawnName = fullName(get(controller, PROP.pawn))
        hold.frames, hold.tracked = 0, false

        -- Reported HERE, not on some later pass. 0.6.2 put this behind "the
        -- first update where alpha is already moving" and it never printed
        -- once, so the ring's real InterpSpeed went unmeasured for a whole run.
        local bar = get(promptWidget(focus) or focus, PROP.progBar)
        diag(string.format("hold: TAKING OVER %s (key already down %.2fs,"
            .. " game alpha %s) -- running %.2fs myself, ring InterpSpeed %s",
            shortName(name), heldFor or -1, tostring(gameAlpha),
            numberProp(focus, PROP.holdDur) or -1,
            real(bar) and tostring(numberProp(bar, PROP.interpSpd)) or "no ring"))
    end

    -- THE FALLBACK, and the only reason this is here rather than only in the
    -- 30Hz tick: if StaticFindObject cannot resolve the component's path, the
    -- fast tick can neither draw nor finish. Firing from here means that costs
    -- the smooth ring and NOT the feature. Normally the fast tick has already
    -- latched firedFor by now and this never runs.
    local duration = numberProp(focus, PROP.holdDur)
    if duration == nil or duration <= 0 then return resetHold("no duration") end
    if (os.clock() - hold.t0) / duration < 1 then return end
    if byPath(hold.target) == nil then
        logOnce("holdpath:" .. shortName(name), string.format(
            "hold: %s could not be found again by path, so the ring cannot be"
            .. " drawn at 30Hz for it. Completing from the 200ms pass instead --"
            .. " the hold still works, it just will not animate smoothly.",
            shortName(name)))
    end
    finishHold(focus, get(controller, PROP.pawn), duration)
end

--- THE RING, AND THE COMPLETION, at pump rate.
---
--- Split out of holdScan because both are time-critical and holdScan is not:
--- deciding whether to take over needs the subsystem and the controller, which
--- are global walks and stay on the 200ms cadence. Drawing the ring and firing
--- at the right moment need neither -- the component and the pawn are found
--- again BY PATH, which is a hash lookup.
---
--- 0.6.2 did both at 200ms and Daniel got two defects for it: "the filling
--- animation goes too quickly but also still isn't really smooth ... a very
--- fast ease-out to every 25% spot". Four samples cannot be smoothed into a
--- sweep, and leading the bar by a whole 200ms step made it read FULL up to a
--- fifth of a second before the hold actually fired. At 30Hz the lead is one
--- frame and both go away.
local function holdFast()
    if not hold.active or cfg.hold_rescue == 0 then return end

    local component = byPath(hold.target)
    if component == nil then return end        -- the 200ms scan will notice

    local duration = numberProp(component, PROP.holdDur)
    if duration == nil or duration <= 0 then return end
    local alpha = (os.clock() - hold.t0) / duration
    if alpha > 1 then alpha = 1 end

    if cfg.hold_rescue_bar ~= 0 then
        local widget = promptWidget(component)
        if real(widget) then
            hold.frames = hold.frames + 1
            driveBar(widget, alpha, hold.frames == 1)
            hold.dirty[hold.target] = true

            -- Rule J: the ACHIEVED update rate, which is the only number that
            -- decides whether this ring can look like the game's. Reported once
            -- per hold, at the midpoint.
            if not hold.tracked and alpha > 0.5 then
                hold.tracked = true
                diag(string.format("hold: ring is updating at %.0f Hz (%d"
                    .. " updates in %.2fs of a %.2fs hold)",
                    hold.frames / (os.clock() - hold.t0), hold.frames,
                    os.clock() - hold.t0, duration))
            end
        end
    end

    if alpha < 1 then return end
    finishHold(component, byPath(hold.pawnName), duration)
end

-- ==========================================================================
-- FEATURE 3 -- ONE COIN, NOT A SHOWER OF THEM.
-- ==========================================================================
--
-- THE ANNOYANCE: the grinder pays out one coin at a time, roughly every 0.4s,
-- and every coin has to be picked up separately. There can be dozens.
--
-- WHY THE AMOUNTS VARY, which is the whole finding. Daniel: "one may have 3
-- while another may have 10". That is not randomness -- AHeldenCoinDispenser
-- carries `int32 MaxGoldPerCoins` and `int32 MaxArtifactsPerCoin`, so a payout
-- is BUCKETED into coins of at most that much, and the odd small one is the
-- remainder. 10, 10, 10, 3 is a payout of 33 against a cap of 10.
--
-- So the fix is not to sweep the coins up after the fact -- which would have
-- meant re-issuing an interact per coin, the same shape Daniel rejected for the
-- gumball. It is to stop them being split at all: raise the cap and the payout
-- cannot be divided.
--
-- The total is untouched. Same gold, same artifacts, one pickup instead of
-- thirty. Effort changes, result does not -- which is the QoL line exactly.
--
-- CO-OP: bucket 3. Spawning the coins is authoritative, so this is host/solo
-- like the deposits -- but unlike them, when the HOST has it every player in
-- the lobby gets the benefit.
--
-- REACHED WITHOUT A SINGLE NEW GLOBAL WALK. The grinder is an
-- AHeldenPackageSpot, which is an AHeldenInteractableObject, so it is already
-- in HotInteractions whenever the player is near it -- and the dispenser hangs
-- off it as a plain property. You cannot make it dispense without standing at
-- it, so being in range is guaranteed before any coin exists.
local dispensers = {}   -- fullName -> { gold = original, artifacts = original }
local lastCoinReport = nil
local lastSweep = 0

--- WHERE AN ACTOR IS, WITHOUT THE CRASH.
---
--- K2_GetActorLocation() returns an FVector BY VALUE, and reading a field off a
--- struct returned by value across the Lua/native boundary is the documented
--- hard-crash -- pcall cannot catch it, because it is an access violation and
--- not a Lua error. So it is not used.
---
--- RootComponent is a plain pointer (AActor 0x1B8) and RelativeLocation is an
--- FVector PROPERTY on it (USceneComponent 0x148), so this is a field read in
--- place on a persistent object -- the same shape as FHeldenMoney's Gold and
--- FRangedFloat's min, both of which this mod already reads and writes safely.
---
--- CAVEAT, and it is checked rather than assumed: RelativeLocation is relative
--- to the ATTACH PARENT. A coin lying on the ground should have an unparented
--- root, making it the world position -- but "should" is what has cost this
--- project two test rounds already, so the first coins seen in a world have
--- their coordinates logged, and clustering refuses to run at all if positions
--- cannot be read.
--- HOW OLD A COIN IS, so a pile merges into the one that was already there.
---
--- Daniel, 30 Aug 2026: "currently the old coin merges into the new one, make it
--- prioritize the other way around." He is right, and the reason is physical:
--- the newest coin is the one that has just been thrown out of the dispenser and
--- is still moving, while the older one has settled. Merging into the settled
--- coin is what keeps the value where the player can already see it.
---
--- AActor::GetGameTimeSinceCreation() returns a plain float -- a value type, not
--- a struct across the boundary, so it is safe to call -- and it is the game's
--- own answer rather than something this mod infers. Bigger means older.
---
--- It is UNPROVEN on this build, so there is a fallback: the first time the mod
--- ever sees a coin it records the clock, and age is measured from that instead.
--- The fallback is only approximate -- coins already lying there when the player
--- walks up are all first seen at once -- so ties break on name, which is
--- arbitrary but DETERMINISTIC. An inconsistent comparator makes table.sort
--- raise, and that would take the whole pass down.
local coinSeen = {}     -- fullName -> os.clock when first observed
local coinEpoch = -1
local coinAgeSource = nil

local function ageOf(actor, name, now)
    local age = nil
    pcall(function() age = actor:GetGameTimeSinceCreation() end)
    if type(age) == "number" then
        if coinAgeSource == nil then
            coinAgeSource = "the game"
            diag("coins: ages come from GetGameTimeSinceCreation, so the oldest"
                .. " coin in a pile is known exactly")
        end
        return age
    end
    if coinSeen[name] == nil then coinSeen[name] = now end
    if coinAgeSource == nil then
        coinAgeSource = "first sighting"
        log("coins: GetGameTimeSinceCreation did not answer, so coin age is"
            .. " measured from when this mod first saw each one. Coins already"
            .. " lying there when you walk up will all look the same age.")
    end
    return now - coinSeen[name]
end

local function positionOf(actor)
    local root = get(actor, PROP.root)
    if not real(root) then return nil end
    local at = get(root, PROP.relLoc)
    if at == nil then return nil end
    local x, y, z = nil, nil, nil
    pcall(function() x = at.X end)
    pcall(function() y = at.Y end)
    pcall(function() z = at.Z end)
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return { x = x, y = y, z = z }
end

--- Group coins that are near EACH OTHER, not near the player.
---
--- Daniel, 30 Aug 2026: "currently the coins merging is based around *the
--- player*, would it be possible to merge coins based on themselves?" Yes, and
--- it is better: merging everything in the player's range pulls a coin by the
--- grinder together with one dropped across the room, so value moves somewhere
--- the player did not expect. Grouping by distance between coins keeps every
--- merged coin INSIDE the pile it came from, and leaves separate drops separate.
---
--- Single linkage: two coins are in the same pile if they are within the radius
--- of each other, transitively. Each coin is assigned exactly once, so this is
--- O(n^2) over a handful of coins on a 200ms pass.
local function cluster(list, radius)
    local limit, out, taken = radius * radius, {}, {}
    for seed = 1, #list do
        if not taken[seed] then
            taken[seed] = true
            local group, scan = { list[seed] }, 1
            while scan <= #group do
                local here = group[scan]
                for other = 1, #list do
                    if not taken[other] then
                        local dx = here.at.x - list[other].at.x
                        local dy = here.at.y - list[other].at.y
                        local dz = here.at.z - list[other].at.z
                        if dx * dx + dy * dy + dz * dz <= limit then
                            taken[other] = true
                            group[#group + 1] = list[other]
                        end
                    end
                end
                scan = scan + 1
            end
            out[#out + 1] = group
        end
    end
    return out
end

--- How many coins a pile should end up as, and how to divide the total between
--- them. Merging a whole payout into ONE coin concentrates a risk the base game
--- had spread out -- Daniel: "if the person cant find that single coin or it
--- somehow clips through the environment then everything is lost at once" -- so
--- a pile becomes ceil(total / cap) coins, split evenly so there is no
--- near-worthless straggler. A cap of 0 puts it all in one.
local function chunksFor(sum, available)
    local wanted = 1
    if cfg.coin_merge_max_gold > 0 and sum.gold > 0 then
        wanted = math.max(wanted, math.ceil(sum.gold / cfg.coin_merge_max_gold))
    end
    if cfg.coin_merge_max_artifacts > 0 and sum.artifacts > 0 then
        wanted = math.max(wanted,
            math.ceil(sum.artifacts / cfg.coin_merge_max_artifacts))
    end
    if wanted > available then wanted = available end
    return wanted
end

local function share(total, parts)
    local out, base, extra = {}, math.floor(total / parts), total % parts
    for index = 1, parts do
        out[index] = base + (index <= extra and 1 or 0)
    end
    return out
end

--- MERGE ONE PILE.
---
--- ORDER IS THE SAFETY PROPERTY, exactly as it is for the gumball counter. Every
--- keeper is written and READ BACK before a single other coin is emptied, and if
--- any keeper refuses the write the originals go back and nothing is touched.
--- Empty-then-fill would destroy the payout on a refused write.
---
--- Emptied coins are hidden and made non-interactable rather than DESTROYED.
--- K2_DestroyActor exists, but destroying an actor the level purge may already
--- have taken is a crash this project has shipped once (rule D), and nothing
--- here needs it: a coin worth zero cannot pay out twice even if the mod is
--- unloaded with every write it made left standing.
---
--- CO-OP: bucket 3, host/solo, like the rest of the deposit family.
local function mergePile(kind, list)
    -- OLDEST FIRST, so the keepers are the coins that were already settled and
    -- the ones emptied are the ones that just arrived.
    table.sort(list, function(a, b)
        if a.age ~= b.age then return a.age > b.age end
        return a.name < b.name
    end)

    local sum = { scraps = 0, gold = 0, artifacts = 0 }
    for _, coin in ipairs(list) do
        sum.scraps = sum.scraps + coin.held.scraps
        sum.gold = sum.gold + coin.held.gold
        sum.artifacts = sum.artifacts + coin.held.artifacts
    end

    local keep = chunksFor(sum, #list)
    if #list <= keep then return end

    local scraps, gold, arts = share(sum.scraps, keep), share(sum.gold, keep),
        share(sum.artifacts, keep)

    local ok, written = true, 0
    for index = 1, keep do
        local want = { scraps = scraps[index], gold = gold[index],
                       artifacts = arts[index] }
        writeMoney(list[index].actor, PROP.coinMoney, want)
        if sameMoney(money(list[index].actor, PROP.coinMoney), want) then
            written = written + 1
        else
            ok = false
        end
    end

    if not ok then
        for index = 1, written do
            writeMoney(list[index].actor, PROP.coinMoney, list[index].held)
        end
        logOnce("nomerge:" .. kind, string.format("coins: %s would not take a"
            .. " merged value, so every coin is left exactly as the game made"
            .. " it.", kind))
        return
    end

    local emptied = 0
    for index = keep + 1, #list do
        local other = list[index]
        writeMoney(other.actor, PROP.coinMoney,
            { scraps = 0, gold = 0, artifacts = 0 })
        local check = money(other.actor, PROP.coinMoney)
        if check ~= nil and check.scraps == 0 and check.gold == 0
                and check.artifacts == 0 then
            emptied = emptied + 1
            local part = get(other.actor, PROP.coinInter)
            if real(part) then
                pcall(function() part:SetIsInteractable(false) end)
            end
            pcall(function() other.actor:SetActorEnableCollision(false) end)
            pcall(function() other.actor:SetActorHiddenInGame(true) end)
        else
            -- It kept its value, and a keeper already holds a share of it. Take
            -- that much back out of the first keeper or the payout doubles.
            local back = money(list[1].actor, PROP.coinMoney)
            if back ~= nil then
                writeMoney(list[1].actor, PROP.coinMoney, {
                    scraps = back.scraps - other.held.scraps,
                    gold = back.gold - other.held.gold,
                    artifacts = back.artifacts - other.held.artifacts })
            end
            log("coins: one refused to be emptied, so its value was taken back"
                .. " out of the merged coin. Nothing gained, nothing lost.")
        end
    end

    if emptied > 0 then
        log(string.format("coins: merged %d %s in one pile into %d worth %s"
            .. " (%d emptied, total unchanged)", #list, kind, keep,
            moneyStr(sum), emptied))
    end
end

local function mergeCoins(groups)
    for kind, list in pairs(groups) do
        if #list >= 2 then
            for _, pile in ipairs(cluster(list, cfg.coin_merge_radius)) do
                if #pile >= 2 then mergePile(kind, pile) end
            end
        end
    end
end

--- Set one dispenser's caps, capturing the game's own values the first time it
--- is ever seen. Shared by the property-walk route and the fallback below.
local function tuneDispenser(unit)
    if not real(unit) then return false end
    local name = fullName(unit)
    local entry = dispensers[name]
    if entry == nil then
        local wasGold = numberProp(unit, PROP.maxGold)
        local wasArt  = numberProp(unit, PROP.maxArt)
        if wasGold == nil or wasArt == nil then
            logOnce("nodispenser:" .. name, shortName(name) .. " has no "
                .. PROP.maxGold .. "/" .. PROP.maxArt
                .. "; refusing to guess at its coin split")
            return false
        end
        entry = { gold = wasGold, artifacts = wasArt }
        dispensers[name] = entry
        log(string.format("grinder %s: the game splits payouts into coins of at"
            .. " most %d gold and %d artifacts", shortName(name), wasGold, wasArt))
    end

    -- DRIVE TO TARGET, never decline and leave -- the same discipline the
    -- deposits use. A config of 0 drives the game's own value back, so switching
    -- the feature off actually undoes it rather than merely ceasing to re-apply.
    local wantGold = cfg.coin_max_gold > 0 and cfg.coin_max_gold or entry.gold
    local wantArt = cfg.coin_max_artifacts > 0 and cfg.coin_max_artifacts
        or entry.artifacts
    setNumber(unit, PROP.maxGold, wantGold, shortName(name))
    setNumber(unit, PROP.maxArt, wantArt, shortName(name))

    -- The ~0.4s between coins. With the payout coming out per item there can be
    -- dozens of those gaps, and waiting through them is half the annoyance. The
    -- struct is written IN PLACE on the persistent object, never through a
    -- by-value getter (the memory-safety rule).
    if cfg.coin_dispense_delay > 0 then
        local gap = get(unit, PROP.cooldown)
        if gap ~= nil then
            local want = cfg.coin_dispense_delay
            pcall(function() gap.min = want end)
            pcall(function() gap.max = want end)
        end
    end

    return true
end

local function applyDispensers(subsystem, wideCoins)
    -- Local proximity plus whatever the level-wide sweep found, deduped: a coin
    -- handled twice in one pass would have its own first write read back as the
    -- game's value.
    local candidates, already = {}, {}
    local array = get(subsystem, PROP.hot)
    if array ~= nil then
        local total = count(array)
        if total >= 0 and total <= MAX_ENTRIES then
            pcall(function()
                array:ForEach(function(_index, element)
                    local component = nil
                    pcall(function() component = element:get() end)
                    if not real(component) then return end
                    local named = fullName(component)
                    if already[named] then return end
                    already[named] = true
                    candidates[#candidates + 1] = component
                end)
            end)
        end
    end
    for _, named in ipairs(wideCoins or {}) do
        if not already[named] then
            local component = byPath(named)
            if component ~= nil then
                already[named] = true
                candidates[#candidates + 1] = component
            end
        end
    end
    if #candidates == 0 then return end

    -- The first-sighting table is keyed by name, never by object (rule C), and
    -- the old world's coins are gone with it.
    if coinEpoch ~= epoch then
        coinEpoch, coinSeen = epoch, {}
    end
    local now = os.clock()
    local coins, purse = 0, { scraps = 0, gold = 0, artifacts = 0 }
    local kinds, groups, placed = {}, {}, 0

    pcall(function()
        -- Nested, not inlined: every `return` below means "skip this one".
        local function one(component)
            local owner = nil
            pcall(function() owner = component:GetOwner() end)
            if not real(owner) then return end

            -- THE COINS THEMSELVES, counted and summed. This is the instrument
            -- that says whether the change did what it claims: one coin holding
            -- the whole payout, rather than the same payout in thirty pieces or
            -- -- the failure that would matter -- a different total.
            -- ONLY NAMED COIN CLASSES. See the COIN table for why.
            local kind = className(owner)
            if COIN[kind] then
                local held = money(owner, PROP.coinMoney)
                if held ~= nil then
                    coins = coins + 1
                    purse.scraps = purse.scraps + held.scraps
                    purse.gold = purse.gold + held.gold
                    purse.artifacts = purse.artifacts + held.artifacts
                    kinds[kind] = (kinds[kind] or 0) + 1
                    if held.scraps + held.gold + held.artifacts > 0 then
                        -- NO POSITION, NO MERGE. Falling back to merging
                        -- everything in range is precisely the behaviour this
                        -- replaces, so it is not a fallback -- it is the bug.
                        local at = positionOf(owner)
                        if at == nil then
                            logOnce("nocoinpos", "coins: a coin's position could"
                                .. " not be read, so nothing will be merged."
                                .. " Every coin is left exactly as the game"
                                .. " made it.")
                        else
                            groups[kind] = groups[kind] or {}
                            local list = groups[kind]
                            local who = fullName(owner)
                            list[#list + 1] = { actor = owner, held = held,
                                                at = at, name = who,
                                                age = ageOf(owner, who, now) }
                            if placed < 3 then
                                placed = placed + 1
                                logOnce("coinpos:" .. placed, string.format(
                                    "coins: a %s sits at %.0f, %.0f, %.0f --"
                                    .. " these must look like world coordinates"
                                    .. " for the %d-unit grouping to mean"
                                    .. " anything", kind, at.x, at.y, at.z,
                                    cfg.coin_merge_radius))
                            end
                        end
                    end
                end
            end

            tuneDispenser(get(owner, PROP.dispenser))
        end
        for _, component in ipairs(candidates) do one(component) end
    end)

    -- THE FALLBACK, and it only ever runs on EVIDENCE that the free route
    -- failed: no dispenser has been reached by property walk in this world.
    -- FindAllOf is the global object-array walk rule E is about, so it is capped
    -- at once every 10s and stops permanently the moment one is found -- which
    -- on the intended path is before the player has finished walking up to the
    -- grinder. Without this, a CoinDispenser pointer that is only populated at
    -- dispense time would make the whole feature quietly do nothing.
    if next(dispensers) == nil and os.clock() - lastSweep >= 10 then
        lastSweep = os.clock()
        local found = 0
        pcall(function()
            for _, unit in ipairs(FindAllOf(CLASS.dispenser) or {}) do
                if tuneDispenser(unit) then found = found + 1 end
            end
        end)
        if found == 0 then
            logOnce("nogrinder", "no " .. CLASS.dispenser .. " reachable yet;"
                .. " the one-coin feature is doing nothing so far. That is"
                .. " expected outside a dungeon.")
        end
    end

    if cfg.coin_merge ~= 0 then mergeCoins(groups) end

    if coins > 0 then
        local names = {}
        for kind, many in pairs(kinds) do
            names[#names + 1] = string.format("%s x%d", kind, many)
        end
        table.sort(names)
        local line = string.format("%d coin%s on the ground worth %s  [%s]",
            coins, coins == 1 and "" or "s", moneyStr(purse),
            table.concat(names, ", "))
        if lastCoinReport ~= line then
            lastCoinReport = line
            diag("grinder: " .. line)
        end
    end
end

--- ONE findFirst for the whole mod, feeding both features. FindFirstOf is a
--- global object-array walk and the mod's largest crash exposure (rule E,
--- RE-UE4SS #1328), so it is resolved once here rather than once per feature.
local function interactionTick()
    if cfg.deposit_all == 0 and cfg.hold_rescue == 0
            and cfg.coin_max_gold == 0 and cfg.coin_max_artifacts == 0 then
        return
    end

    local subsystem = cachedRoot("subsystem",
        function() return findFirst(CLASS.subsystem) end)
    if subsystem == nil then return end
    noteWorld(subsystem)

    -- Re-validated as well as re-resolved: a name could in principle come back
    -- as a controller that is no longer the local one, and acting on someone
    -- else's controller would be a real bug rather than a slow one.
    local controller = cachedRoot("controller", localController, function(found)
        local isLocal = nil
        pcall(function() isLocal = found:IsLocalController() end)
        return isLocal == true
    end)

    -- ============================================================
    -- BUCKET 2 RUNS EVERYWHERE. BUCKET 3 RUNS ONLY ON THE AUTHORITY.
    -- ============================================================
    --
    -- Measured in the first real lobby, 30 Aug 2026. A guest running the deposit
    -- features writes RequiredMoney and CoinsLeftToPay locally, the server
    -- replicates its own values back, and the two fight: Daniel watched a gumball
    -- counter go 3 -> 2 -> 2 -> 0 instead of 3 -> 2 -> 1 -> 0. Those writes never
    -- changed what was actually charged. They only corrupted what the guest saw.
    --
    -- The brief already called these bucket 3, host and solo only. This is what
    -- makes that true rather than merely written down.
    --
    -- A guest KEEPS feature 5, which is bucket 2: it re-sends an input the player
    -- could have sent themselves, changes no shared state, and is confirmed
    -- working in a lobby.
    --
    -- A guest loses nothing that ever worked. When the HOST runs the mod and is
    -- near the machine, the guest still gets the benefit, because the host's
    -- write is the authoritative one.
    --
    -- UNKNOWN DEFAULTS TO ACTING. A failed read answers nil, not false, and nil
    -- must not disable the mod in single player -- that would trade a cosmetic
    -- bug on guests for a dead mod for everyone. Only a definite false stands
    -- down, and the answer is logged once either way.
    local authority = nil
    local gs = cachedRoot("gameState",
        function() return findFirst(CLASS.gameState) end)
    if gs ~= nil then
        pcall(function() authority = gs:HasAuthority() end)
    end
    logOnce("authority:" .. tostring(authority), string.format(
        "this instance reports HasAuthority = %s, so the deposit and coin"
        .. " features are %s", tostring(authority),
        authority == false and "STANDING DOWN (they are the host's to make)"
            or "active"))

    local okH, errH = pcall(function() holdScan(subsystem, controller) end)
    if not okH then
        logOnce("holdscan:" .. tostring(errH), "hold pass failed: " .. tostring(errH))
    end

    -- Bucket 3 from here down: nothing below this line may run on a guest.
    if authority == false then return end

    local players = playerCount(gs)
    local reach = discoverWide(subsystem, players)

    if cfg.coin_max_gold > 0 or cfg.coin_max_artifacts > 0 then
        local okD, errD = pcall(function()
            applyDispensers(subsystem, reach.coins)
        end)
        if not okD then
            logOnce("dispenser:" .. tostring(errD),
                "the grinder pass failed: " .. tostring(errD))
        end
    end
end

-- ==========================================================================
-- FEATURES 1 AND 2 -- pay a whole deposit in one press, sized AT the press.
-- ==========================================================================
--
-- CO-OP BUCKET 3. This writes AHeldenCoinDepositObject.RequiredMoney, which only
-- the server may meaningfully do -- but it now runs from an interact hook that
-- fires on the SERVER for every player, so a guest gets the benefit without
-- their own machine writing anything.
--
-- WHY A HOOK AND NOT A STANDING WRITE. Until 0.26.0 the mod pre-positioned each
-- machine on a timer, sizing the deposit to whichever wallet it could see. Three
-- things were wrong with that, all found in the first real lobby:
--
--   * IT USED THE WRONG WALLET. The elevator charges the INTERACTING player's
--     carried purse. The mod sized it from the host's purse, which was empty
--     while the guest holding 58 gold got nothing. Measured, in one log line:
--     `HOOK Interact pawn=...(REMOTE) purse=0S/58G/3A` beside the mod's own
--     `carried=0S/0G/0A`.
--   * IT LIED TO THE PLAYER. Pre-compensating a press-counted machine leaves its
--     meter showing the remaining COST as one coin when the press will take
--     three. Daniel: "it should still show the proper amount of 3."
--   * IT LEFT A MACHINE STANDING CHEAP between passes, which is a leak if the
--     mod stops at the wrong moment.
--
-- Sizing at the press cures all three: nothing is written until someone presses,
-- it is written against THAT person's wallet, and it is put back immediately
-- afterwards.
--
-- WHY `Interact` AND NOT `Interact_Server`. Measured 30 Aug 2026 over one lobby:
-- the host's own press fires ONLY Interact (5 of 5), while a guest's fires
-- Interact_Server first and then Interact. Crucially only 13 of the guest's 25
-- Interact_Server calls reached Interact -- so Interact_Server firing does NOT
-- mean the interaction happened, and sizing there would leave a machine written
-- after every refused attempt. Interact fires for both players and only when the
-- press proceeds.
--
-- THE PRE-HOOK IS EARLY ENOUGH: the counter moved between pre and post in the
-- same measurement (`owed 1 -> 0`), so the charge happens inside the call.
--
-- THE SAFETY PROPERTY, and it is what makes the ordering not matter: the deposit
-- is NEVER sized above what the interacting player is holding. If the game's
-- affordability check reads the old, smaller value it passes trivially; the
-- charge then reads ours and is affordable by construction. A player who cannot
-- cover even one of the game's own presses is left entirely alone.
local sized = { count = 0, last = nil, everSized = false }
local pendingSize = nil

--- Which wallet this machine actually charges, and how much is in it.
local function walletFor(spec, pawn)
    if spec.pool == "stash" then
        local gs = cachedRoot("gameState",
            function() return findFirst(CLASS.gameState) end)
        if gs == nil then return nil, "stash" end
        return money(gs, PROP.stashMoney), "stash"
    end
    return money(pawn, PROP.money), "carried"
end

local function sizeDeposit(owner, pawn)
    if cfg.deposit_all == 0 then return end
    if not real(owner) or not real(pawn) then return end

    local original = money(owner, PROP.required)
    if original == nil then return end                  -- not a coin deposit

    local machineClass = className(owner)
    local spec = MACHINE[machineClass]
    if spec == nil or disabled[machineClass] then
        logOnce("nosize:" .. machineClass, string.format(
            "deposit %s: NOT sizing -- %s. It will behave exactly as the game"
            .. " makes it.", machineClass,
            spec == nil and "this machine has never been measured"
                or "it was caught crediting less than it charged"))
        return
    end

    local resource, perPress = soleResource(original)
    if resource == nil or perPress == nil or perPress <= 0 then return end

    local owed, _prop, _machine = owedFor(owner)
    if owed == nil or owed <= 0 then return end

    local purse, where = walletFor(spec, pawn)
    if purse == nil then return end
    local affordable = purse[resource] or 0

    -- The counter's units differ per machine: a currency counter holds money, a
    -- press counter holds insertions. Both are converted to PRESSES here so the
    -- rest of this reads the same either way.
    local owedPresses = owed
    if spec.counterIs == "currency" then
        owedPresses = math.floor(owed / perPress)
    end
    local canAfford = math.floor(affordable / perPress)
    local n = owedPresses
    if canAfford < n then n = canAfford end
    if n < 2 then return end                            -- nothing to collapse

    local want = { scraps = original.scraps, gold = original.gold,
                   artifacts = original.artifacts }
    want[resource] = perPress * n
    writeMoney(owner, PROP.required, want)
    if not sameMoney(money(owner, PROP.required), want) then
        writeMoney(owner, PROP.required, original)
        logOnce("noreq:" .. machineClass, "deposit " .. machineClass
            .. ": RequiredMoney would not take a write; left alone")
        return
    end

    -- A press counter only ever moves by one, so it has to be pre-positioned in
    -- the same breath -- and because this happens inside the press, it is never
    -- left standing where a player could see it or a stopped mod could strand it.
    if spec.counterIs == "presses" and cfg.deposit_counter ~= 0 then
        local _o, counterProp, machine = owedFor(owner)
        if real(machine) and counterProp ~= nil then
            setNumber(machine, counterProp, owed - n + 1, shortName(fullName(owner)))
        end
    end

    pendingSize = { owner = owner, pawn = pawn, original = original, n = n,
                    perPress = perPress, resource = resource, spec = spec,
                    owed = owed, purse = purse, where = where,
                    machineClass = machineClass }

    sized.count = sized.count + 1
    sized.last = string.format("%s x%d %s from %s", machineClass, n, resource, where)
    if not sized.everSized then
        sized.everSized = true
        log(string.format("deposit sizing is live: %s takes %d %s in one press"
            .. " instead of %d, from the %s of whoever pressed it.",
            machineClass, perPress * n, resource, n, where))
    end
end

--- Put RequiredMoney back, and check the machine credited what it charged.
local function settleDeposit()
    local before = pendingSize
    pendingSize = nil
    if before == nil then return end

    writeMoney(before.owner, PROP.required, before.original)

    local purse = select(1, walletFor(before.spec, before.pawn))
    local owedAfter = select(1, owedFor(before.owner))
    if purse == nil or owedAfter == nil then return end

    local charged = (before.purse[before.resource] or 0) - (purse[before.resource] or 0)
    local credited = before.owed - owedAfter
    if credited < 0 then return end          -- the machine completed and reset
    local worth = credited
    if before.spec.counterIs == "presses" then worth = credited * before.perPress end

    if charged > 0 and worth < charged then
        if not disabled[before.machineClass] then
            disabled[before.machineClass] = true
            log(string.format("DISABLING %s: one press charged %d %s and"
                .. " credited only %d (worth %d). The difference would be"
                .. " destroyed, so this mod will leave that machine alone.",
                before.machineClass, charged, before.resource, credited, worth))
        end
    else
        diag(string.format("deposit %s: charged %d %s, credited %d (worth %d)"
            .. " -- balanced; %s restored to %s", before.machineClass, charged,
            before.resource, credited, worth, PROP.required,
            moneyStr(before.original)))
    end
end

local hooksOn = false
local function installHooks()
    if cfg.deposit_all == 0 then return end
    hooksOn = pcall(function()
        RegisterHook("/Script/Helden.HeldenInteractableObject:Interact",
            function(self, pawn)
                pcall(function() sizeDeposit(self:get(), pawn:get()) end)
            end,
            function() pcall(settleDeposit) end)
    end)
    -- Rule H, and the one failure this design cannot otherwise report: if the
    -- hook stops firing after a game patch the deposits simply behave as the
    -- base game, silently. patch_check.py compares NAMES and would not catch it,
    -- so the absence of this line in a log is the tell.
    log(hooksOn
        and "deposit sizing hook registered on HeldenInteractableObject:Interact"
        or "THE INTERACT HOOK WOULD NOT REGISTER -- deposits will behave exactly"
           .. " as the base game does. Nothing is broken; nothing is helped.")
end

-- ==========================================================================
-- F3 -- the diagnostic report. Changes nothing. It is the only instrument a
-- bug reporter has (CLAUDE.md, packaging rule 3).
-- ==========================================================================

local function dumpState()
    local out = {}
    local function say(text) out[#out + 1] = text end

    say("")
    say("================================================================")
    say(string.format(" %s %s   %s", MOD, VERSION, os.date("%Y-%m-%d %H:%M:%S")))
    say("================================================================")
    say(string.format("  config            %s", cfgLoaded and cfgPath
        or "NOT LOADED -- running on built-in defaults"))
    say(string.format("  passes            %d", state.passes))
    say(string.format("  passes with no world %d", state.skipped))
    if state.lastSkip then say("  last skip         " .. state.lastSkip) end
    say(string.format("  world epoch       %d", epoch))
    say(string.format("  values written    %d", applied))
    say(string.format("  values REFUSED    %d", refused))
    say(string.format("  values the game put back %d", reapplied))
    say(string.format("  components walked last pass %d", state.components))

    -- FEATURE 5. What a bug reporter needs is the LIVE input and focus state at
    -- the moment they hit F3 -- "it did nothing" and "it never saw the key" are
    -- different reports and only one of them is a bug in this mod.
    say("")
    say("  hold rescue")
    say(string.format("    enabled           %s", cfg.hold_rescue ~= 0))
    say(string.format("    running one now   %s%s", hold.active,
        hold.active and string.format(" (%.2fs into %s)",
            os.clock() - hold.t0, shortName(hold.target or "?")) or ""))
    say(string.format("    progress bar      %s", hold.barOK == nil
        and "not exercised yet" or (hold.barOK and "takes writes"
        or "WILL NOT take writes -- no visible feedback, still completes")))
    local who = localController()
    if who == nil then
        say("    controller        no local controller right now")
    else
        local down, heldFor, why = interactDown(who)
        say(string.format("    interact key      %s", why ~= nil and why
            or string.format("%s, down %.2fs", down and "DOWN" or "up",
                heldFor or 0)))
        -- BOTH signals, labelled, because confusing them is what made 0.6.0 do
        -- nothing. CurrentInteractTarget fills when the game ACCEPTS a press;
        -- the widget's InteractState is what is actually on your screen.
        local accepted = get(who, PROP.focus)
        say(string.format("    accepted interact %s", real(accepted)
            and shortName(fullName(accepted)) or "nothing"))

        local subsystem = findFirst(CLASS.subsystem)
        if subsystem == nil then
            say("    prompts in range  no subsystem")
        else
            local focus, widget = focusedHold(subsystem)
            if real(focus) and real(widget) then
                local alpha = nil
                pcall(function() alpha = widget:GetHoldInteractAlpha() end)
                say(string.format("    focused HOLD      %s, %.2fs, game alpha %s",
                    shortName(fullName(focus)),
                    numberProp(focus, PROP.holdDur) or -1, tostring(alpha)))
            else
                say("    focused HOLD      none")
            end

            -- THE INVENTORY. If InteractState turns out not to be the on-screen
            -- signal either, this is what says so without another test round:
            -- every hold component in range and the state its widget reports.
            local array = get(subsystem, PROP.hot)
            local shown, holds = 0, 0
            if array ~= nil then
                pcall(function()
                    array:ForEach(function(_i, element)
                        local component = nil
                        pcall(function() component = element:get() end)
                        if not real(component) then return end
                        if boolProp(component, PROP.holdOn) ~= true then return end
                        holds = holds + 1
                        if shown >= 8 then return end
                        shown = shown + 1
                        local w = promptWidget(component)
                        say(string.format("      hold in range   %-34s state %s",
                            shortName(fullName(component)),
                            real(w) and tostring(numberProp(w, PROP.state))
                                or "no widget"))
                    end)
                end)
            end
            say(string.format("    hold components in range %d (Hidden 0,"
                .. " ProximityRange 1, Focused 2)", holds))
        end
    end
    say(string.format("  deposit presses sized  %d", sized.count))
    say(string.format("  last sized             %s", sized.last or "none yet"))

    say("")
    say("  -- settings, in the order this file lists them --")
    for _, key in ipairs({ "prompt_angle", "prompt_distance", "reach",
                           "reach_ceiling", "aim_forgiveness", "hold_duration",
                           "hold_duration_floor", "apply_interval",
                           "log_reverts", "diagnostic_key" }) do
        say(string.format("  %-22s %s", key, tostring(cfg[key])))
    end

    -- Live readback, straight off the objects, so the file shows the game's
    -- current truth and not only what the mod believes it did.
    say("")
    say("  -- live readback --")
    local subsystem = findFirst(CLASS.subsystem)
    if subsystem == nil then
        say("  no " .. CLASS.subsystem .. " right now (menu, or a transition)")
    else
        say("  subsystem         " .. fullName(subsystem))
        local settings = get(subsystem, PROP.settings)
        if not real(settings) then
            say("  settings asset    did not resolve")
        else
            say("  settings asset    " .. fullName(settings))
            say(string.format("  %-22s %s", PROP.angle,
                tostring(numberProp(settings, PROP.angle))))
            say(string.format("  %-22s %s", PROP.distance,
                tostring(numberProp(settings, PROP.distance))))
        end
        local array = get(subsystem, PROP.registered)
        say(string.format("  %-22s %d entries", PROP.registered,
            array ~= nil and count(array) or -1))
    end

    say("================ end of " .. MOD .. " state ================")

    local handle, path = openOut(STATE_FILE, "a")
    if handle == nil then
        log("could not open " .. STATE_FILE .. "; writing state to the log instead")
        for _, line in ipairs(out) do print(line .. "\n") end
        return
    end
    handle:write(table.concat(out, "\n") .. "\n")
    handle:close()
    log("state written to " .. path)
end

-- ==========================================================================
-- The pump (crash rule K). One LoopAsync, one ExecuteInGameThread, no
-- ExecuteWithDelay. Keybinds do no work -- they set a flag and the pump does
-- everything, because keybind callbacks are not on the game thread.
-- ==========================================================================

local pending  = { diag = false, reload = false }
local inFlight = false
local ticks    = 0
local lastScan, lastApply = 0, 0

local pumpStarted = pcall(function()
    LoopAsync(PUMP_MS, function()
        if inFlight then return false end
        inFlight = true
        ExecuteInGameThread(function()
            ticks = ticks + 1
            defer.drain()

            if pending.reload then
                pending.reload = false
                local ok, err = pcall(loadConfig)
                if not ok then log("config reload failed: " .. tostring(err)) end
            end
            if pending.diag then
                pending.diag = false
                local ok, err = pcall(dumpState)
                if not ok then log("diagnostic failed: " .. tostring(err)) end
            end

            -- EVERY TICK, and cheap: no global walk, only a path lookup while
            -- a hold is actually running.
            local okF, errF = pcall(holdFast)
            if not okF then
                logOnce("holdfast:" .. tostring(errF),
                    "hold ring tick failed: " .. tostring(errF))
            end

            -- Both features, one subsystem resolve, one controller resolve.
            -- ELAPSED TIME, not a tick count: ticks are frames now.
            local now = os.clock()
            local ok2, err2 = true, nil
            if now - lastScan >= DEPOSIT_EVERY then
                lastScan = now
                ok2, err2 = pcall(interactionTick)
            end
            if not ok2 then
                logOnce("tick:" .. tostring(err2),
                    "interaction tick failed: " .. tostring(err2))
            end

            if now - lastApply >= math.max(APPLY_MIN, cfg.apply_interval) then
                lastApply = now
                local ok, err = pcall(pass)
                if not ok then
                    logOnce("pass:" .. tostring(err), "apply pass failed: " .. tostring(err))
                end
            end

            inFlight = false
        end)
        return false
    end)
end)

loadConfig()

local boundDiag = false
if cfg.diagnostic_key ~= 0 then
    boundDiag = pcall(function()
        RegisterKeyBind(KEY_DIAG, function() pending.diag = true end)
    end)
end
local boundReload = pcall(function()
    RegisterKeyBind(KEY_RELOAD, function() pending.reload = true end)
end)

pcall(installHooks)

diag("---- " .. MOD .. " " .. VERSION .. " loaded ----")
log("loaded.")
if not pumpStarted then
    log("FATAL: LoopAsync did not start. NOTHING WILL EVER RUN -- report this")
    log("rather than waiting for the mod to take effect.")
end
log(string.format("prompt_angle=%s  prompt_distance=%s  reach=%s"
    .. "  aim_forgiveness=%s  hold_duration=%s", tostring(cfg.prompt_angle),
    tostring(cfg.prompt_distance), tostring(cfg.reach),
    tostring(cfg.aim_forgiveness), tostring(cfg.hold_duration)))
if cfg.aim_forgiveness > 0 then
    log("NOTE: aim_forgiveness is ON. What LineTraceDiscardRadius actually does"
        .. " is NOT established -- you are experimenting. Please report what you see.")
end
if cfg.hold_duration > 0 then
    log("NOTE: hold_duration is ON. Whether the host validates it is NOT"
        .. " established, so treat it as untested in a lobby.")
end
log(boundDiag and "F3  writes a diagnostic report and changes nothing"
    or "F3 not bound (diagnostic_key = 0, or registration failed)")
log(boundReload and "F4  reloads " .. CONFIG_FILE
    or "F4 could not be registered -- edit the config and restart instead")
