--[[
    BetterInteraction -- interaction quality of life for Grain Rot.

    WHAT IT DOES, and the co-op bucket of each, per CLAUDE.md:

      deposit_all / deposit_counter   bucket 3  pay a whole deposit in one
                                                press; sized at the press, on
                                                the host, for whoever pressed.
      coin_*                          bucket 3  the grinder pays out in one
                                                coin; piles merge; host/solo.
      attack_hold / attack_rate       bucket 2  hold to keep swinging or
                                                punching, at each weapon's own
                                                measured click cadence; runs on
                                                the machine whose key is down.

    The prompt-cone / reach / aim / hold-duration knobs that this file carried
    from Phase 1 were removed on 5 Sep 2026 at Daniel's request: built,
    verified, never wanted (CLAUDE.md, "What we are actually building").

    WHY EVERY WRITE IS READ BACK AND RE-ASSERTED
    ---------------------------------------------
    The game puts its own values back -- measured on this build, a written
    property reset twice inside a fourteen-minute session. So the coin caps
    are re-asserted on every interaction tick, every write is read back, and
    a value the game has put back is reported once per object per world
    rather than silently rewritten forever. The deposit writes are the other
    way round on purpose: made at the press and put back straight after.

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

    SCHEDULING (the heartbeat -- see the pump section)
    --------------------------------------------------
    NO LoopAsync, NO ExecuteInGameThread, NO ExecuteWithDelay anywhere. The
    game's own timer manager calls a harmless native controller function 40
    times a second and our hook on it is the pump, so every line of this file
    runs on the game thread. Every delayed step goes through the `defer`
    queue, drained once per beat.

    CONFIG
    ------
    <profile>\shimloader\cfg\BetterInteraction.cfg, read at startup. Every
    feature independently switchable; 0 means leave the game's value alone.

    KEYS
    ----
    None. The mod binds no keys (packaging rule 2); edit the config and
    restart the game. Hold-to-attack reads the game's own attack action
    state; it binds nothing of its own.
]]

local MOD     = "BetterInteraction"
local VERSION = "1.0.1"

-- ==========================================================================
-- Everything version-fragile, in one place. A game patch is an edit here.
-- Every name below was read out of the 5.7.4 CXXHeaderDump and confirmed live.
-- ==========================================================================

local CLASS = {
    dispenser = "HeldenCoinDispenser",             -- AHeldenCoinDispenser
    subsystem  = "HeldenInteractionSubsystem",
    gameState  = "HeldenGameState",
    controller = "HeldenPlayerController",         -- hold-to-attack
}

--- Functions called by name, so a rename is one edit here.
local FUNC = {
    attack     = "Attack_Server",                  -- AHeldenWeapon(int32 InCombo), Helden.hpp:7490
    animInst   = "GetAnimInstance",                -- USkeletalMeshComponent, Engine.hpp:24686
    playMont   = "Montage_Play",                   -- UAnimInstance, Engine.hpp:12542
    jumpSect   = "Montage_JumpToSection",          -- UAnimInstance, Engine.hpp:12545
    setTimer   = "K2_SetTimer",                    -- UKismetSystemLibrary, Engine.hpp:17811
    punchMulti = "PlayMontage_Multicast",          -- AHeldenCharacter(UAnimMontage*, uint8), Helden.hpp:4251
    punchServer= "PlayMontageIgnoreLocal_Server",  -- AHeldenCharacter, Helden.hpp:4248 (guest: everyone else)
    sectionName= "GetSectionName",                 -- UAnimMontage(int32) -> FName
    sectionIdx = "GetSectionIndex",                -- UAnimMontage(FName) -> int32, Engine.hpp:12646
    activeMont = "GetCurrentActiveMontage",        -- UAnimInstance() -> UAnimMontage*, Engine.hpp:12596
    curSection = "Montage_GetCurrentSection",      -- UAnimInstance(UAnimMontage*) -> FName, Engine.hpp:12552
}

--- Hooked function paths (rule H: registration is logged either way).
local HOOK = {
    interact   = "/Script/Helden.HeldenInteractableObject:Interact",
    swing      = "/Script/Helden.HeldenWeapon:Attack_Multicast",
    punch      = "/Script/Helden.HeldenCharacter:PlayMontage_Multicast",         -- bare hands, the host's own punch
    punchGuest = "/Script/Helden.HeldenCharacter:PlayMontageIgnoreLocal_Server",  -- bare hands, a guest's own punch (best candidate)
    beat       = "/Script/Engine.PlayerController:ResetControllerLightColor",  -- the heartbeat
    restart    = "/Script/Engine.PlayerController:ClientRestart",              -- arms it, per world
}
local BEAT_FUNC    = "ResetControllerLightColor"     -- what K2_SetTimer calls by name
local STATICS_PATH = "/Script/Engine.Default__KismetSystemLibrary"

--- The attack input action's own name, lower-cased; a rebind does not change it.
local ATTACK_ACTION = "ia_attack"

--- HOW FAST EACH MELEE WEAPON CAN BE SWUNG BY CLICKING, in seconds per swing.
--- Version-fragile data, so it lives here.
---
--- Measured 2 Sep 2026 (probe attack-4): the smallest gap between the game's
--- own Attack_Multicast calls under Daniel's fastest clicking, per weapon.
--- The gaps cluster within 20-30 ms per weapon, so this is the GAME's limit
--- for that weapon, not a finger's. It has to be a table because the server
--- does NOT rate-limit Attack_Server: probe attack-10 showed a spike club
--- accepting calls at 0.40 s that clicking could only make at 0.68 s. A
--- repeat faster than the click is the cheat this mod promises not to be.
---
--- BARE HANDS. A punch swings no weapon actor: the game multicasts a punch
--- montage on the character instead (probe attack-16/17: every punch is
--- HeldenCharacter:PlayMontage_Multicast(AM_PunchAttacks, section 0 or 1,
--- alternating). Calling that same multicast from Lua on the host punches
--- "like it would normally" (attack-17, F1). Keyed on the montage's name;
--- the value is the fastest measured click, 0.507-0.717 s.
local UNARMED = {
    AM_PunchAttacks = 0.51,
}

--- A class not in this table is NOT repeated, and the log says so once.
--- The saw is absent on purpose: it ships with the game's own auto-fire on,
--- and a repeat on top of it double-swings (attack-10 log, 21:46).
local CADENCE = {
    BP_Malet_01_C           = 0.40,
    BP_Malet_02_C           = 0.41,
    BP_Malet_Golden_01_C    = 0.40,
    BP_Knife_01_C           = 0.41,
    BP_Machete_01_C         = 0.42,
    BP_Spear_01_C           = 0.44,
    BP_Umbrella_01_C        = 0.43,
    BP_Battery_01_C         = 0.39,
    BP_Broom_01_C           = 0.82,
    BP_SpikeClub_01_C       = 0.68,
    BP_SpikeClub_Elite_01_C = 0.68,
    BP_Shield_01_C          = 0.98,
}

local PROP = {
    registered = "RegisteredInteractionEntries",  -- TArray<FHeldenInteractionEntry>
    entryComp  = "Component",                     -- its only field

    -- Features 1 and 2, the deposit-all. Every one verified against the dump.
    hot        = "HotInteractions",                -- UHeldenInteractionSubsystem 0x58
    required   = "RequiredMoney",                  -- AHeldenCoinDepositObject 0x4A8
    targetObj  = "TargetObject",                   -- AHeldenCoinDepositObject 0x488
    coinsLeft  = "CoinsLeftToPay",                 -- gumball 0x4A0 / upgrade 0x630
    remaining  = "RemainingCost",                  -- AHeldenElevatorMachine 0x638
    money      = "Money",                          -- AHeldenCharacter 0x1250
    players    = "PlayerArray",                    -- AGameStateBase 0x2C8
    stashMoney = "StashMoney",                     -- AHeldenGameState 0x350

    -- Feature 3, one coin instead of a shower of them.
    dispenser  = "CoinDispenser",                  -- AHeldenPackageSpot 0x4C0
    maxGold    = "MaxGoldPerCoins",                -- AHeldenCoinDispenser 0x330
    maxArt     = "MaxArtifactsPerCoin",            -- AHeldenCoinDispenser 0x334
    coinMoney  = "Money",                          -- AHeldenPhysicsCoin 0x938
    coinInter  = "InteractComponent",              -- AHeldenPhysicsCoin 0x6D8
    cooldown   = "DispenseCooldownRange",          -- AHeldenCoinDispenser 0x320
    root       = "RootComponent",                  -- AActor 0x1B8
    relLoc     = "RelativeLocation",               -- USceneComponent 0x148

    -- Hold to attack. All verified against the dump on 2 Sep 2026.
    pawn       = "Pawn",                           -- AController 0x2F0
    equipped   = "EquipedItems",                   -- AHeldenCharacter 0x1270 [sic]
    holster    = "HolsterState",                   -- AHeldenEquipableItem 0x4D9: None 0, Equipped 1, Holsterd 2
    playerIn   = "PlayerInput",                    -- APlayerController 0x428
    actionData = "ActionInstanceData",             -- UEnhancedPlayerInput 0x4E8
    trigger    = "TriggerEvent",                   -- FInputActionInstance 0x13
    canAuto    = "bCanAutoFire",                   -- AHeldenMeleeWeapon 0xC72: the game's own loop
    -- the guest's local swing animation (see playSwingLocally)
    mesh       = "Mesh",                           -- ACharacter 0x330, USkeletalMeshComponent*
    animChain  = "AttackAnimChain",                -- AHeldenWeapon 0xC18, FHeldenAttackAnimChain
    attacks    = "Attacks",                        -- FHeldenAttackAnimChain: TArray<FHeldenMontage>
    montage    = "Montage",                        -- FHeldenMontage: UAnimMontage*
    sections   = "Sections",                       -- FHeldenMontage: TArray<FName>
    lastMont   = "LastAttackMontage",              -- AHeldenWeapon 0xC40, FHeldenMontage
}

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
-- THE SETTLE GAP (5 Sep 2026). #1180 is not the only race in this pump. Read
-- out of RE-UE4SS LuaMod.cpp at the shipped SHA e31aaaa6: the LoopAsync
-- thread runs its Lua WITHOUT m_thread_actions_mutex, ExecuteInGameThread
-- takes its luaL_ref on the hook state's registry BEFORE taking that mutex,
-- and the game thread luaL_unref's the previous callback's ref right after
-- that callback returns. Our callback's last statement is `inFlight = false`,
-- so the LoopAsync thread could call ExecuteInGameThread -- a registry write
-- on another thread -- in the microseconds between our return and UE4SS's
-- unref of the ref it was still holding. And get_function_ref in
-- process_simple_actions sits OUTSIDE its try, so a ref that comes back
-- garbage throws through the engine tick, uncaught: "Abort signal received",
-- with "[Lua::Registry::get_function_ref] Ref was not function" in the
-- minidump. That is the 4 Sep 2026 crash, 64 minutes in (docs/DESIGN.md).
--
-- So the LoopAsync body waits one FULL extra pass after it sees inFlight
-- clear before it appends again. The unref follows our return by
-- microseconds on the same thread; a whole PUMP_MS interval on top of that
-- closes the window in practice without removing the per-frame rate (the
-- drain is once per frame anyway). The LoopAsync body must stay
-- allocation-free -- booleans and integers only -- because it too runs
-- concurrently with game-thread Lua in the same state.
--
-- The expensive work does NOT follow the pump. It is gated on ELAPSED TIME
-- rather than a tick count, because a tick count now means "frames" and would
-- silently make the deposit pass four times slower on a 60fps machine than the
-- 200ms it was measured and tuned at.
-- The beat length, in ms: what K2_SetTimer is asked for, and what defer.at
-- converts delays with. 25 ms = 40 beats a second, measured exact. Nothing
-- in the mod needs more (the attack repeat tolerates it; the deposit hooks
-- do not use the beat at all).
local PUMP_MS       = 25
local DEPOSIT_EVERY = 0.20   -- SECONDS between deposit scans
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

    -- Housekeeping. Write a line whenever the game reverts a value the mod
    -- set, once per object per world.
    log_reverts         = 1,

    -- Hold to attack. ON by default. attack_rate 0 = each weapon's own
    -- measured click cadence (the CADENCE table); a positive number overrides
    -- it for every weapon, and is floored at the weapon's own cadence.
    attack_hold         = 1,
    attack_rate         = 0,
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
---
--- It used to take a third argument, a predicate to re-validate the cached
--- object. Only one caller ever passed one -- the local-controller resolve,
--- which existed for the hold feature -- so it went with it. Every surviving
--- root is identified by its own name and needs no second opinion.
local rootNames = {}

local function cachedRoot(key, scanner)
    local found = byPath(rootNames[key])
    if found ~= nil then return found end
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
        "# Every setting the mod has, at its default. Edit it and restart the",
        "# game. 0 almost always means 'leave the game's own value alone'.",
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
                .. " defaults: " .. written .. " -- edit it and restart.")
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
--- Runs every DEPOSIT_EVERY seconds from the heartbeat.
---
--- Measured 29 Aug 2026: at 1 Hz the write and the restore alternate as focus
--- flickers on approach, and the player's press lands on whichever the last
--- pass happened to leave -- which is the "took 5, then the rest on the second
--- press" symptom, and on one run it took three presses.
---
--- Both objects are re-resolved EVERY pass. NOTHING IS HELD -- see the note by
--- the epoch declaration for why 0.2.1's throttle crashed the game.
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
--- The game's own per-coin split, learned from the first grinder seen this
--- session; until then the measured shipped values. Plain numbers.
local GAME_COIN_MEASURED = { gold = 5, artifacts = 1 }   -- measured 30 Aug 2026
local gameCoin = { gold = GAME_COIN_MEASURED.gold, artifacts = GAME_COIN_MEASURED.artifacts }

--- A configured cap, never below what the game itself puts in one coin.
local function mergeCap(kind)
    local want = (kind == "gold") and cfg.coin_merge_max_gold or cfg.coin_merge_max_artifacts
    if want <= 0 then return 0 end
    return math.max(want, gameCoin[kind] or 1)
end

local function chunksFor(sum, available)
    local wanted = 1
    local capGold, capArt = mergeCap("gold"), mergeCap("artifacts")
    if capGold > 0 and sum.gold > 0 then
        wanted = math.max(wanted, math.ceil(sum.gold / capGold))
    end
    if capArt > 0 and sum.artifacts > 0 then
        wanted = math.max(wanted, math.ceil(sum.artifacts / capArt))
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
        -- The game's own coin size is the FLOOR for every cap in the config
        -- (5 Sep 2026, Daniel): a cap below it would split payouts finer
        -- than the game does, which nobody wants. Plain numbers, never the
        -- object (rule C).
        if wasGold > 0 then gameCoin.gold = wasGold end
        if wasArt > 0 then gameCoin.artifacts = wasArt end
        log(string.format("grinder %s: the game splits payouts into coins of at"
            .. " most %d gold and %d artifacts", shortName(name), wasGold, wasArt))
    end

    -- DRIVE TO TARGET, never decline and leave -- the same discipline the
    -- deposits use. A config of 0 drives the game's own value back, so switching
    -- the feature off actually undoes it rather than merely ceasing to re-apply.
    local wantGold = cfg.coin_max_gold > 0 and math.max(cfg.coin_max_gold, entry.gold) or entry.gold
    local wantArt = cfg.coin_max_artifacts > 0 and math.max(cfg.coin_max_artifacts, entry.artifacts)
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
    if cfg.deposit_all == 0
            and cfg.coin_max_gold == 0 and cfg.coin_max_artifacts == 0 then
        return
    end

    local subsystem = cachedRoot("subsystem",
        function() return findFirst(CLASS.subsystem) end)
    if subsystem == nil then return end
    noteWorld(subsystem)

    -- ============================================================
    -- EVERY FEATURE IS BUCKET 3, SO ALL OF IT RUNS ONLY ON THE AUTHORITY.
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
    -- NOTHING IS LEFT FOR A GUEST TO RUN. Every feature the mod still has is
    -- bucket 3, so a guest's copy stands down completely -- and loses nothing,
    -- because the host's writes are the authoritative ones and the guest gets
    -- the benefit of them either way. This is what makes the mod host-only
    -- rather than merely host-recommended.
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

-- ==========================================================================
-- HOLD TO ATTACK -- the mod repeats a swing the game started.
-- ==========================================================================
--
-- THE ANNOYANCE: every melee swing is a click. Holding the button swings once.
--
-- CO-OP BUCKET 2, PER MACHINE. Every call this makes is one the player could
-- have made by clicking, and it is made on the machine whose key is down. A
-- guest needs the mod for it; the host validates each swing as it does today.
-- The host's copy does nothing for a guest's key, because it cannot see it.
--
-- WHY NOT THE GAME'S OWN AUTO-FIRE. AHeldenMeleeWeapon ships bCanAutoFire,
-- AutoFireRate and a working loop (the saw uses it). Eight probe versions on
-- 2 Sep 2026 established that flipping the flag works -- and that a TAP on a
-- flipped weapon starts a loop the release does not end: 170+ swings that no
-- reflected write or call could stop (flag off, effect off, Blueprint toggle
-- off -- all measured, all failed), and starving its rate stops it but jams
-- the weapon until a holster. docs/DESIGN.md, attack-5 .. attack-9.
--
-- WHAT WORKS INSTEAD, measured in attack-9 and attack-10: calling
-- AHeldenWeapon:Attack_Server(combo) from Lua swings the weapon "as if
-- normally pressing LMB, both functionally and the animation". So:
--
--   1. THE GAME STARTS EVERY CHAIN. A real press produces a real swing, the
--      Attack_Multicast hook sees it, and a chain opens. The mod never makes
--      the first swing, so every lock the game puts on it (dialogue, menus,
--      holstering, stamina) is respected for free.
--   2. The weapon's own click cadence after the last swing (CADENCE, per
--      class, measured), while the attack action still reads Started/Ongoing
--      and the weapon that swung is still carried, call Attack_Server with
--      the next combo index. The server does not rate-limit that call
--      (attack-10: a spike club took 0.40 s calls against a 0.68 s click), so
--      the cadence is the mod's responsibility, not the game's.
--   3. No swing follows our call: the game refused it; the chain closes and
--      waits for a fresh real press. Key up: the chain closes. Nothing runs,
--      resolves or scans while no chain is live.
--
-- The controller is re-found at every step (crash rule C) -- a FindAllOf at
-- most 1/attack_rate times a second, only while the key is held, against the
-- 5 Hz the removed feature 5 ran in a lobby without incident.
--
-- ON A GUEST THE SWING IS SILENT WITHOUT ONE MORE STEP. Measured 5 Sep 2026,
-- two machines: a guest's repeats did damage but played no animation. The
-- game's click path plays the montage on the owning client itself and the
-- server's Attack_Multicast skips the owner; a call that came from the mod
-- never ran that client-side half. So on an instance where the weapon
-- reports HasAuthority() == false, each repeat also plays the swing montage
-- on the local mesh: bucket 1, presentation only, the server still decides
-- the hit. The montage is picked from the weapon's AttackAnimChain by combo
-- index, and the game's own choice (LastAttackMontage after a real swing) is
-- logged beside it once per class so a wrong mapping shows in the file.
-- ==========================================================================

--- The live chain: plain values only, never a UObject (rule C).
local chain = nil
local attackStats = { chains = 0, calls = 0, refused = 0 }

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

--- Is the attack action down? Walks UEnhancedPlayerInput.ActionInstanceData,
--- the proven idiom; matches the action by its own name so a rebind is
--- irrelevant. Started (2) and Ongoing (4) are "down" for a Pressed+Released
--- trigger pair. Returns nil when the map cannot be read at all.
local function attackHeld(controller)
    local input = get(controller, PROP.playerIn)
    if not real(input) then return nil end
    local map = get(input, PROP.actionData)
    if map == nil then return nil end
    local held, seen = false, false
    pcall(function()
        map:ForEach(function(key, value)
            local action = key
            pcall(function() action = key:get() end)
            if shortName(fullName(action)):lower() ~= ATTACK_ACTION then return end
            seen = true
            local instance = value
            pcall(function() instance = value:get() end)
            local trig = numberProp(instance, PROP.trigger)
            if trig == 2 or trig == 4 then held = true end
        end)
    end)
    if not seen then return nil end
    return held
end

--- The carried item of the class that swung. The swing itself proved it was
--- in hand; HolsterState is NOT consulted, because an item handed over by
--- the game's own equip path can read None until it is holstered and redrawn
--- (attack-10 / first shipped run: "carried but not drawn" on every fresh
--- weapon), and a swung weapon that is still carried is still the one in hand.
--- Returns the item, a reason, and the class of whatever reads Equipped
--- (HolsterState 1) right now -- nil when nothing does. SWITCHING MID-HOLD
--- (5 Sep 2026): a chain is keyed to the item that started it, and the game
--- never starts a new chain while the key stays down, so a chain that only
--- checks "still carried" keeps driving the OLD item after a switch -- the
--- old animation and cadence with the new item's damage. The caller closes
--- the chain when the drawn item is no longer the chain's.
local function weaponInHand(controller, wantedClass)
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return nil, "no pawn", nil end
    local items = get(pawn, PROP.equipped)
    if items == nil then return nil, PROP.equipped .. " did not read", nil end
    local match, matchHolster, drawnClass = nil, nil, nil
    pcall(function()
        items:ForEach(function(_, element)
            local item = element
            pcall(function() item = element:get() end)
            if not real(item) then return end
            local holster = numberProp(item, PROP.holster)
            local cls = className(item)
            if holster == 1 and drawnClass == nil then drawnClass = cls end
            if match == nil and cls == wantedClass then match, matchHolster = item, holster end
        end)
    end)
    if match == nil then return nil, "not carried", drawnClass end
    if matchHolster == 2 then return nil, "holstered", drawnClass end
    if drawnClass ~= nil and drawnClass ~= wantedClass then
        return nil, "no longer in hand (" .. drawnClass .. " is)", drawnClass
    end
    return match, "carried", drawnClass
end

--- The class of the item drawn right now, or nil for empty hands.
local function drawnItem(controller)
    local _, _, drawn = weaponInHand(controller, "")
    return drawn
end

--- Seconds between repeats for this weapon class, or nil for "do not repeat".
local function cadenceFor(class)
    local own = CADENCE[class]
    if own == nil then return nil end
    if cfg.attack_rate > 0 then return math.max(cfg.attack_rate, own) end
    return own
end

--- Fed by the Attack_Multicast hook: a weapon swung somewhere. Only a swing
--- by the LOCAL pawn opens a chain; a guest's swing replicated to this
--- machine must not make this machine call anything.
local function noteSwing(weapon, combo)
    if cfg.attack_hold == 0 then return end
    local owner = nil
    pcall(function() owner = weapon:GetOwner() end)
    local isLocal, why = nil, "owner unreadable, IsLocallyControlled not called"
    if real(owner) then
        local ok, err = pcall(function() isLocal = owner:IsLocallyControlled() end)
        if not ok then
            why = "IsLocallyControlled threw: " .. tostring(err)
        elseif type(isLocal) ~= "boolean" then
            why = "IsLocallyControlled returned " .. tostring(isLocal)
            isLocal = nil
        end
    end
    if isLocal == false then return end
    if isLocal == nil then
        -- Cannot tell whose swing this is. Acting would be wrong in a lobby;
        -- say so once rather than silently doing nothing (rule H), and say
        -- WHY (rule J): the 4 Sep 2026 crash was preceded by this line with
        -- the error swallowed, 109 ms before UE4SS aborted on a corrupted
        -- registry ref. The text is the only thing that can tell "the game
        -- refused the call" from "our Lua state is already broken".
        logOnce("attack:owner", "hold-to-attack: cannot tell whose weapon swung"
            .. " (owner " .. (real(owner) and className(owner) or "unreadable")
            .. "; " .. why .. "); the swing is ignored. REPORT THIS.")
        return
    end
    local class = className(weapon)
    if boolProp(weapon, PROP.canAuto) == true then
        logOnce("attack:auto:" .. class, "hold-to-attack: " .. class
            .. " already repeats on its own (the game's auto-fire); left to the game")
        return
    end
    local rate = cadenceFor(class)
    if rate == nil then
        logOnce("attack:unknown:" .. class, "hold-to-attack: no measured click"
            .. " cadence for " .. class .. "; holding it will not repeat. REPORT THIS"
            .. " with the weapon's name and it can be added.")
        return
    end
    -- Rule J: which montage did the GAME use for this combo? Read in place off
    -- the weapon, logged once per class and index, so the guest-side pick can
    -- be checked against it in the file.
    if chain == nil or chain.calledAt == nil then
        local last = get(get(weapon, PROP.lastMont), PROP.montage)
        pcall(function() last = last:get() end)
        if real(last) then
            logOnce("attack:game:" .. class .. ":" .. tostring(combo),
                string.format("hold-to-attack: the game played %s for combo %d on %s",
                    shortName(fullName(last)), combo, class))
        end
    end

    local now = os.clock()
    if chain ~= nil and chain.kind == "unarmed" then chain = nil end
    if chain == nil then
        chain = { kind = "weapon", class = class, combo = combo, rate = rate, nextAt = now + rate,
                  calledAt = nil, calls = 0, epoch = epoch }
        attackStats.chains = attackStats.chains + 1
    else
        chain.combo = combo
        chain.nextAt = now + chain.rate
    end
    chain.lastSwing = now
end

--- The weapon's swing montages, in chain order, as { montage, section }.
local function swingMontages(weapon)
    local list = {}
    local attacks = get(get(weapon, PROP.animChain), PROP.attacks)
    pcall(function()
        attacks:ForEach(function(_, element)
            local entry = element
            pcall(function() entry = element:get() end)
            local montage = get(entry, PROP.montage)
            pcall(function() montage = montage:get() end)
            local section = nil
            local sections = get(entry, PROP.sections)
            pcall(function()
                sections:ForEach(function(_, name)
                    if section ~= nil then return end
                    local inner = name
                    pcall(function() inner = name:get() end)
                    pcall(function() section = inner:ToString() end)
                end)
            end)
            if real(montage) then list[#list + 1] = { montage = montage, section = section } end
        end)
    end)
    return list
end

--- GUEST ONLY. Play the swing the server is about to confirm, on our own mesh,
--- because the game's owner-side animation only runs from its own input path.
local function playSwingLocally(controller, weapon, combo)
    local list = swingMontages(weapon)
    if #list == 0 then
        logOnce("attack:nomontage:" .. className(weapon), "hold-to-attack: "
            .. className(weapon) .. " has no readable swing montage; guest repeats"
            .. " will hit without an animation. REPORT THIS.")
        return
    end
    local pick = list[(combo % #list) + 1]
    local pawn = get(controller, PROP.pawn)
    local mesh = get(pawn, PROP.mesh)
    local anim = nil
    pcall(function() anim = mesh[FUNC.animInst](mesh) end)
    if not real(anim) then
        logOnce("attack:noanim", "hold-to-attack: the pawn's mesh has no AnimInstance;"
            .. " guest repeats will hit without an animation. REPORT THIS.")
        return
    end
    local played = nil
    local ok = pcall(function()
        played = anim[FUNC.playMont](anim, pick.montage, 1.0, 0, 0.0, true)
    end)
    if ok and pick.section ~= nil and pick.section ~= "" and pick.section ~= "None" then
        pcall(function() anim[FUNC.jumpSect](anim, FName(pick.section), pick.montage) end)
    end
    logOnce("attack:played:" .. className(weapon) .. ":" .. ((combo % #list) + 1),
        string.format("hold-to-attack (guest): combo %d plays %s%s locally -> %s",
            combo, shortName(fullName(pick.montage)),
            pick.section and (" [" .. pick.section .. "]") or "",
            ok and (type(played) == "number" and string.format("%.2f", played) or "returned")
               or "THREW"))
end

--- Fed by the PlayMontage_Multicast hook: the local character played a
--- montage. Only a punch montage on the LOCAL pawn opens a chain, and never
--- while a weapon chain is live.
local function notePunch(pawn, montage, section, via)
    if cfg.attack_hold == 0 then return end
    if not real(montage) then return end
    local montPath = fullName(montage)
    local short = shortName(montPath)
    local rate = UNARMED[short]
    if rate == nil then return end
    local isLocal = nil
    pcall(function() isLocal = pawn:IsLocallyControlled() end)
    if isLocal ~= true then return end
    -- Rule J: a guest's own punch never showed on PlayMontage_Multicast (5 Sep,
    -- Copy B as guest: weapons repeated, punches never opened a chain). Which
    -- RPC carries it is measured here, once per session.
    logOnce("punch:via:" .. tostring(via), "hold-to-attack (bare hands): the local punch"
        .. " was seen via " .. tostring(via))
    if cfg.attack_rate > 0 then rate = math.max(cfg.attack_rate, rate) end
    local now = os.clock()
    if chain ~= nil and chain.kind ~= "unarmed" then return end
    if chain == nil then
        chain = { kind = "unarmed", class = short, rate = rate, nextAt = now + rate,
                  montage = (montPath:gsub("^%S+%s+", "")), section = section,
                  calledAt = nil, calls = 0, epoch = epoch }
        attackStats.chains = attackStats.chains + 1
    else
        chain.section = section
        chain.nextAt = now + chain.rate
    end
    chain.lastSwing = now
end

--- One repeat of a punch. Host: the multicast itself IS the punch (measured).
--- Guest: the server form reaches everyone else, and the montage is played
--- on our own mesh, as for weapons. Whether a guest's punch also HITS is not
--- yet measured.
local function repeatPunch(controller)
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return false, "no pawn" end
    local montage = nil
    pcall(function() montage = StaticFindObject(chain.montage) end)
    if not real(montage) then pcall(function() montage = LoadAsset(chain.montage) end) end
    if not real(montage) then return false, "punch montage did not resolve" end
    local section = 1 - (chain.section or 0)   -- the game alternates 0, 1, 0, 1
    local authority = nil
    pcall(function() authority = pawn:HasAuthority() end)
    local ok, err
    if authority == false then
        -- MEASURED ON THE HOST, 5 Sep 2026 (probe attack-18, vanilla guest):
        -- every guest punch arrives as PlayMontageIgnoreLocal_Server(
        -- AM_PunchAttacks, section) and the server multicasts it on. That is
        -- what credits the hit -- a local Montage_Play alone animated and
        -- landed nothing (Daniel, same day). The guest's sending side is not
        -- hookable (both hooks silent on Copy B), which is why the chain is
        -- opened by looking at the anim instance instead. So the repeat is
        -- both halves of a real guest punch: the server RPC, and the montage
        -- on our own mesh, which the RPC by name skips.
        logOnce("punch:guest", "hold-to-attack (bare hands, guest): repeating by"
            .. " PlayMontageIgnoreLocal_Server plus a local Montage_Play")
        ok, err = pcall(function() pawn[FUNC.punchServer](pawn, montage, section) end)
        pcall(function()
            local mesh = get(pawn, PROP.mesh)
            local anim = mesh[FUNC.animInst](mesh)
            anim[FUNC.playMont](anim, montage, 1.0, 0, 0.0, true)
            local name = montage[FUNC.sectionName](montage, section)
            local text = nil
            pcall(function() text = name:ToString() end)
            if type(text) == "string" and text ~= "" and text ~= "None" then
                anim[FUNC.jumpSect](anim, FName(text), montage)
            end
        end)
    else
        ok, err = pcall(function() pawn[FUNC.punchMulti](pawn, montage, section) end)
    end
    if not ok then return false, "punch call threw: " .. tostring(err) end
    chain.section = section
    return true
end

--- BARE HANDS ON A GUEST. Neither montage RPC fires on a guest for its own
--- punch (5 Sep, Copy B as guest: weapons repeated, both punch hooks silent).
--- The engine replicates the guest's montage natively, with nothing
--- reflected in between. So the guest's punch is detected by LOOKING: while
--- the attack key is down and no chain is live, ask the local mesh's anim
--- instance which montage is active; a punch montage opens the chain. Ten
--- times a second, off the controller the heartbeat already holds -- no scan.
local lastPunchLook = 0
local PUNCH_LOOK_EVERY = 0.10

local function lookForPunch(controller, now)
    if now - lastPunchLook < PUNCH_LOOK_EVERY then return end
    lastPunchLook = now
    if attackHeld(controller) ~= true then return end
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return end
    if drawnItem(controller) ~= nil then return end
    local mesh = get(pawn, PROP.mesh)
    local anim, montage = nil, nil
    pcall(function() anim = mesh[FUNC.animInst](mesh) end)
    if not real(anim) then return end
    pcall(function() montage = anim[FUNC.activeMont](anim) end)
    if not real(montage) then return end
    local short = shortName(fullName(montage))
    if UNARMED[short] == nil then return end
    local section = 0
    pcall(function()
        local name = anim[FUNC.curSection](anim, montage)
        local index = montage[FUNC.sectionIdx](montage, name)
        if type(index) == "number" and index >= 0 then section = index end
    end)
    logOnce("punch:via:anim", "hold-to-attack (bare hands): the local punch was seen"
        .. " on the anim instance (" .. short .. ")")
    notePunch(pawn, montage, section, "anim instance")
end

--- Every pump tick, with the controller the heartbeat was called on.
--- Returns immediately unless a chain is live and due.
local function attackTick(beatController)
    local now = os.clock()
    if chain == nil then
        if cfg.attack_hold ~= 0 and real(beatController) then
            pcall(lookForPunch, beatController, now)
        end
        return
    end
    if now < chain.nextAt then return end
    if chain.epoch ~= epoch then chain = nil return end

    if chain.kind ~= "unarmed" and chain.calledAt ~= nil and chain.lastSwing < chain.calledAt then
        attackStats.refused = attackStats.refused + 1
        diag(string.format("hold-to-attack: no swing followed Attack_Server(%d) on %s"
            .. " -- refused by the game; chain closed after %d call(s)",
            chain.combo + 1, chain.class, chain.calls))
        chain = nil
        return
    end

    local controller = real(beatController) and beatController or localController()
    if controller == nil then chain = nil return end
    local held = attackHeld(controller)
    if held == nil then
        logOnce("attack:input", "hold-to-attack: the attack action could not be read"
            .. " from ActionInstanceData; holding will not repeat. REPORT THIS.")
        chain = nil
        return
    end
    if not held then
        if chain.calls > 0 then
            diag(string.format("hold-to-attack: released; %d repeat(s) on %s",
                chain.calls, chain.class))
        end
        chain = nil
        return
    end
    if chain.kind == "unarmed" then
        local drawn = drawnItem(controller)
        if drawn ~= nil then
            diag("hold-to-attack (bare hands): " .. drawn .. " was drawn; punch chain closed")
            chain = nil
            return
        end
        local okP, whyP = repeatPunch(controller)
        if not okP then
            logOnce("punch:" .. tostring(whyP), "hold-to-attack (bare hands): " .. tostring(whyP)
                .. "; chain closed. REPORT THIS.")
            chain = nil
            return
        end
        chain.calls = chain.calls + 1
        chain.calledAt = now
        chain.nextAt = now + chain.rate
        attackStats.calls = attackStats.calls + 1
        return
    end

    local weapon, why = weaponInHand(controller, chain.class)
    if weapon == nil then
        diag("hold-to-attack: " .. chain.class .. " " .. why .. "; chain closed")
        chain = nil
        return
    end

    local combo = (chain.combo or 0) + 1
    local ok, err = pcall(function() weapon[FUNC.attack](weapon, combo) end)
    if not ok then
        logOnce("attack:call", "hold-to-attack: " .. FUNC.attack .. " threw: "
            .. tostring(err) .. " -- holding will not repeat. REPORT THIS.")
        chain = nil
        return
    end
    chain.calls = chain.calls + 1
    chain.calledAt = now
    chain.nextAt = now + chain.rate
    attackStats.calls = attackStats.calls + 1

    -- Guest: the server will confirm the hit; the animation is ours to play.
    local authority = nil
    pcall(function() authority = weapon:HasAuthority() end)
    if authority == false then
        pcall(playSwingLocally, controller, weapon, combo)
    end
end

local armIfNeeded   -- the heartbeat's fallback arming; defined with the pump below

local function installHooks()
    if cfg.attack_hold ~= 0 then
        local swingOn = pcall(function()
            RegisterHook(HOOK.swing, function(self, combo)
                pcall(armIfNeeded)
                pcall(function()
                    local index = combo
                    pcall(function() index = combo:get() end)
                    if type(index) ~= "number" then index = tonumber(tostring(index)) or 0 end
                    noteSwing(self:get(), index)
                end)
            end)
        end)
        local function punchHook(path, via)
            return pcall(function()
                RegisterHook(path, function(self, montage, section)
                    pcall(armIfNeeded)
                    pcall(function()
                        local index = section
                        pcall(function() index = section:get() end)
                        if type(index) ~= "number" then index = tonumber(tostring(index)) or 0 end
                        local mont = montage
                        pcall(function() mont = montage:get() end)
                        notePunch(self:get(), mont, index, via)
                    end)
                end)
            end)
        end
        local punchOn = punchHook(HOOK.punch, "PlayMontage_Multicast")
        local punchGuestOn = punchHook(HOOK.punchGuest, "PlayMontageIgnoreLocal_Server")
        log((punchOn and punchGuestOn)
            and ("hold-to-attack (bare hands) hooks registered on " .. HOOK.punch .. " and " .. HOOK.punchGuest)
            or ("A PUNCH HOOK WOULD NOT REGISTER (multicast " .. tostring(punchOn) .. ", server "
                .. tostring(punchGuestOn) .. ") -- holding with empty hands may punch once."))
        log(swingOn
            and ("hold-to-attack hook registered on " .. HOOK.swing
                .. (cfg.attack_rate > 0
                    and string.format("; attack_rate override %.2fs (floored per weapon)", cfg.attack_rate)
                    or "; per-weapon measured cadence"))
            or "THE ATTACK HOOK WOULD NOT REGISTER -- holding the attack key will"
               .. " swing once, exactly as the base game does.")
    end

    if cfg.deposit_all == 0 then return end
    hooksOn = pcall(function()
        RegisterHook(HOOK.interact,
            function(self, pawn)
                pcall(armIfNeeded)
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
-- THE HEARTBEAT. The game is our clock; there is no second thread.
--
-- Until 5 Sep 2026 this was a LoopAsync thread appending one
-- ExecuteInGameThread per pass -- rule K's shape. Three "Abort signal
-- received" crashes with one stack hash (4 Sep, 5 Sep 13:22, 5 Sep 14:53),
-- the second of them with UE4SS's own log naming OUR hook's registry slot as
-- the thing that had been overwritten, established what rule K missed: on
-- this build the LoopAsync thread writes the Lua registry (luaL_ref, for the
-- hand-off) with no lock while the game thread is writing it too (every hook
-- call allocates refs). A settle gap only narrows that; it cannot close it.
-- docs/DESIGN.md, 5 Sep 2026, all three entries.
--
-- So the beat comes from the game. UKismetSystemLibrary:K2_SetTimer asks the
-- world's timer manager to call, by name and looping, a NATIVE parameterless
-- APlayerController function that does nothing useful on a PC --
-- ResetControllerLightColor (Engine.hpp:11181, a gamepad light) -- and our
-- RegisterHook on that function IS the pump. Measured (probe attack-15):
-- exactly 40/s at 0.025, across a world change, for the whole session.
--
-- No LoopAsync, no ExecuteInGameThread, no ExecuteWithDelay anywhere in this
-- file, and packaging asserts it. Every callback in the file runs on the game
-- thread. Keybinds do not exist. `defer` still drains here, once per beat.
--
-- ARMING. A timer dies with its world, so it is armed per world, on the game
-- thread, from callbacks the game gives us: PlayerController:ClientRestart on
-- the local controller (fires when it takes a pawn, every world; proven on
-- this build), a new GameState (RegisterInitGameStatePostHook clears the
-- mark), and -- the fallback that cannot fail to happen in play -- the first
-- Interact or swing hook. Arming is logged and the beat count once a minute.
-- ==========================================================================

local ticks    = 0
local lastScan = 0
local beatArmedFor = nil          -- fullName of the controller the timer is on
local beatsThisMinute, beatMinuteAt = 0, 0
local lastBeatAt = nil

local function heartbeat(beatController)
    ticks = ticks + 1
    local now = os.clock()
    lastBeatAt = now
    beatsThisMinute = beatsThisMinute + 1
    if now - beatMinuteAt >= 60 then
        if beatMinuteAt > 0 then
            diag(string.format("heartbeat: %d beats in the last %.0f s", beatsThisMinute, now - beatMinuteAt))
        end
        beatMinuteAt, beatsThisMinute = now, 0
    end

    defer.drain()

    do
        local okA, errA = pcall(attackTick, beatController)
        if not okA then
            logOnce("attack:" .. tostring(errA), "hold-to-attack tick failed: " .. tostring(errA))
        end
    end

    -- Both features, one subsystem resolve, gated on ELAPSED TIME.
    local ok2, err2 = true, nil
    if now - lastScan >= DEPOSIT_EVERY then
        lastScan = now
        ok2, err2 = pcall(interactionTick)
    end
    if not ok2 then
        logOnce("tick:" .. tostring(err2), "interaction tick failed: " .. tostring(err2))
    end

end

--- Arm the beat on this controller, once per controller. Game thread only.
local function armHeartbeat(controller)
    if not real(controller) then return false end
    local name = fullName(controller)
    if name == beatArmedFor then return true end
    local statics = nil
    pcall(function() statics = StaticFindObject(STATICS_PATH) end)
    if not real(statics) then
        logOnce("beat:nostatics", "HEARTBEAT: KismetSystemLibrary did not resolve; the mod"
            .. " cannot tick. REPORT THIS.")
        return false
    end
    local ok, err = pcall(function()
        statics[FUNC.setTimer](statics, controller, BEAT_FUNC, PUMP_MS / 1000, true, false, 0.0, 0.0)
    end)
    if not ok then
        logOnce("beat:settimer:" .. tostring(err), "HEARTBEAT: K2_SetTimer threw: "
            .. tostring(err) .. " -- the mod cannot tick. REPORT THIS.")
        return false
    end
    beatArmedFor = name
    lastBeatAt = nil
    diag(string.format("heartbeat armed on %s: %s every %d ms", shortName(name), BEAT_FUNC, PUMP_MS))
    return true
end

--- Fallback arming from any game-thread callback: find the local controller
--- (one scan, and only while unarmed) and arm it.
armIfNeeded = function()
    if beatArmedFor ~= nil then return end
    local controller = localController()
    if controller ~= nil then armHeartbeat(controller) end
end

local beatHooked = pcall(function()
    RegisterHook(HOOK.beat, function(self)
        -- `self` is the controller the timer fired on: our own, the one the
        -- timer was armed on. Handed down so the attack tick needs no scan.
        local controller = nil
        pcall(function() controller = self:get() end)
        local ok, err = pcall(heartbeat, controller)
        if not ok then logOnce("beat:" .. tostring(err), "heartbeat failed: " .. tostring(err)) end
    end)
end)

pcall(function()
    RegisterInitGameStatePostHook(function()
        -- A new world: the old timer died with it. Clear the mark so the next
        -- game-thread callback re-arms; say so if nothing beats within 10 s.
        beatArmedFor = nil
        lastBeatAt = nil
        diag("heartbeat: new GameState; will re-arm on the local controller")
    end)
end)

-- PlayerController:ClientRestart fires on the local controller each time it
-- takes a pawn -- every world, early. Proven on this build: the profile's
-- CheatManagerEnablerMod hooks exactly this and logs once per world.
local restartHooked = pcall(function()
    RegisterHook(HOOK.restart, function(self)
        pcall(function()
            local controller = self:get()
            local isLocal = nil
            pcall(function() isLocal = controller:IsLocalController() end)
            if isLocal == true then armHeartbeat(controller) end
        end)
    end)
end)

loadConfig()


pcall(installHooks)

diag("---- " .. MOD .. " " .. VERSION .. " loaded ----")
log("loaded.")
log(beatHooked
    and ("heartbeat hook registered on " .. HOOK.beat .. "; armed per world from "
        .. (restartHooked and "ClientRestart" or "the feature hooks only (ClientRestart would not hook)"))
    or "FATAL: the heartbeat hook would not register. NOTHING WILL EVER RUN -- report this")
