--[[
    BetterInteractionProbe -- Phase 0 recon for the BetterInteraction mod.

    READ-ONLY. It reads properties and writes text files. It writes no game
    state, touches no save, registers no hook, and the only game function it
    calls is GetOwner(), a pure getter.

    IT IS A PROBE, NOT PART OF THE MOD. It lives in tools/probe/ and never ships
    in a package (packaging rule 4).

    WHAT IT IS FOR
    --------------
    CLAUDE.md documents what interaction properties EXIST. It cannot say what
    they are SET TO, or which interactions are the ones that actually make you
    hammer a key. Both are questions about a running game. So this dumps the real
    numbers and we tune against numbers instead of guesses.

    Alongside that it moves three of the open questions:

      * Is UInteractionSettings one shared asset at runtime?  It counts the
        DISTINCT InteractionSettings pointers across every registered component.
        One means one write covers the whole game.
      * Which interactions are repeat-fire?  It gives the DEPOSIT LOOPS table --
        amount owed, amount taken per press, and the division. The first version
        printed the total alone, which was a numerator with no denominator:
        measured 29 Aug 2026, the upgrade machine takes 20 per press, not 1, so
        CoinsLeftToPay = 100 is five presses rather than a hundred. The per-press
        figure is AHeldenCoinDepositObject.RequiredMoney, reached through the
        machine's CoinDeposit pointer. Alongside it, tap interactions sorted by
        cooldown -- a hypothesis list, since cooldown turned out to be 0.35
        everywhere with no variance at all.
      * Which holds are long?  Sorted, so "shorter holds" has a target list.
        UnlockCost is read for the "Repair" walls, which are the largest single
        population of holds in a run.

    HOW IT REACHES THE COMPONENTS
    -----------------------------
    UHeldenInteractionSubsystem.RegisteredInteractionEntries, walked as a
    property off the subsystem -- crash rule E's cheapest tier. The subsystem
    itself must come from FindFirstOf: nothing in the 954-header dump holds a
    pointer to it, so there is no object to walk down from.

    GLOBAL ARRAY WALKS PER KEYPRESS (crash rule E, RE-UE4SS #1328):
        F7  three -- local controller, subsystem, data singleton
        F8  two   -- local controller, subsystem
    Never on a timer. Everything else is a property walk from an object in hand.

    WHAT IS PROVEN HERE AND WHAT IS NOT
    -----------------------------------
    Corrected 29 Aug 2026 after checking rather than assuming. An earlier draft
    of this header had the risk ladder upside down.

    PROVEN on this exact build, in shipped mods:
      * TArray-of-STRUCTS walked by ForEach + element:get() + field read.
        GrainRotAP main.lua:1565 does exactly this over
        UHeldenSaveGame.Quests, a TArray<FHeldenQuest> whose element is 0x28
        with an FName, a nested TArray and an enum in it. FHeldenInteractionEntry
        is 0x10 and holds one pointer -- strictly simpler. This step is fine.
      * TArray-of-pointers, GetFullName, GetClass():GetFName():ToString(),
        GetArrayNum, FindFirstOf, FindAllOf, IsLocalController, LoopAsync,
        one ExecuteInGameThread, and RegisterKeyBind(Key, fn) -- the bare
        two-argument form, which GrainRotAPCoopProbe main.lua:527 uses.

    NOT proven here, and therefore exercised on the SMALLEST sample first:
      * reading an FText PROPERTY and calling :ToString() on it. The shipped
        mods construct FText and pass it to SetText; they do not read one back
        out of a property. PromptInteractionText is the only FText we read.
      * component:GetOwner(). A UFunction call on a component appears in none of
        the three proven mods. It returns a POINTER, which is the safe shape --
        unlike a by-value struct return, which is the documented hard crash --
        but it is still dispatched through the engine.

    That is why the HOT section runs first even in the full pass: it performs
    both unproven reads on the one to three components you are standing next to.
    If they are going to take the process down they do it there, cheaply, and
    the forensics log names which one. The full walk only ever runs after that
    same code has already survived on a small sample in the same session. (Both
    reads have since run clean over 739 components; the ordering stays because
    it costs nothing and a game patch can un-prove either of them.)

    Both keybinds ran fine as ALT+F7 / ALT+F8 on 29 Aug 2026, so two keybinds in
    one mod is settled either way. They are now bare F7 / F8 by preference, which
    is also the better-proven form. If only one of the two banner lines appears
    in the UE4SS log at load, that is the thing to report -- not "the probe does
    nothing".

    ORDER IS A SAFETY PROPERTY, AND IT IS FLUSHED
    ---------------------------------------------
    The report is written in this order and flushed to disk after every step, so
    whatever kills the process cannot take the earlier steps with it:

      1. header, role, population counts
      2. HOT components          <- both unproven reads, smallest sample
      3. the three global settings floats  <- the cheapest, highest-value data
      4. RegisteredInteractionEntries, and the raw per-component file
      5. the distinct-settings tally, the candidate lists, the totals

    SCHEDULING (crash rule K, RE-UE4SS #1180)
    -----------------------------------------
    Exactly one LoopAsync, exactly one ExecuteInGameThread, and no
    ExecuteWithDelay anywhere. Keybinds do NOT run on the game thread, so they
    set a flag and nothing else. tools/lua_check.py fails the build if that ever
    stops being true. Nothing is cached between presses (crash rule C).

    F7 costs one game-thread tick. MEASURED 29 Aug 2026 over 336 and 403
    registered components: ~40 ms. That is a frame, not the freeze an earlier
    draft of this header predicted, so both keys are lobby-safe in practice. The
    report still prints the elapsed time every run, because that measurement is
    the only thing the claim rests on and a bigger world could change it.

    KEYS
    ----
      F7   full report
      F8   hot only -- stand at a thing, press it, see how THAT thing is
               configured. Also the smoke test for the two unproven reads.

    OUTPUT   (in Helden\Binaries\Win64\, beside UE4SS.log; %TEMP% as a fallback)
      BetterInteraction_probe.txt       the report. APPENDS, so the outpost run
                                        and the in-run run land in one file.
      BetterInteraction_probe_raw.txt   every component, one block each.
      BetterInteraction_probe.log       flushed forensics. If the game dies, the
                                        last line here says where it was.
]]

local MOD     = "BetterInteractionProbe"
local VERSION = "phase0-6"

-- ==========================================================================
-- Everything version-fragile, in one place. A game patch is an edit here.
-- Every name below was read out of the 5.7.4 CXXHeaderDump on 29 Aug 2026,
-- individually, and none of it is guessed.
-- ==========================================================================

local CLASS = {
    subsystem  = "HeldenInteractionSubsystem",   -- UTickableWorldSubsystem
    singleton  = "HeldenDataSingleton",          -- carries InteractionSettings
    controller = "HeldenPlayerController",       -- the world gate
}

local PROP = {
    registered  = "RegisteredInteractionEntries",  -- TArray<FHeldenInteractionEntry>
    hot         = "HotInteractions",               -- TArray<UInteractionComponent*>
    settings    = "InteractSettings",              -- on the subsystem
    settingsAlt = "InteractionSettings",           -- on the singleton AND on each component
    entryComp   = "Component",                     -- the one field of FHeldenInteractionEntry
}

-- UInteractionComponent, in report order. `kind` drives the formatter.
-- All eighteen scalar knobs; nothing on this class is left unread.
local COMPONENT_FIELDS = {
    { key = "hold",         prop = "bIsHoldInteraction",         kind = "bool"     },
    { key = "holdDur",      prop = "HoldInteractionDuration",    kind = "number"   },
    { key = "autoEndHold",  prop = "bAutoEndHoldInteract",       kind = "bool"     },
    { key = "holster",      prop = "bHolsterDuringHoldInteract", kind = "bool"     },
    { key = "soulHold",     prop = "bAllowSoulHoldInteract",     kind = "bool"     },
    { key = "cooldown",     prop = "InteractionCooldown",        kind = "number"   },
    { key = "maxDist",      prop = "MaxInteractDistance",        kind = "number"   },
    { key = "lineTrace",    prop = "bLineTraceValidate",         kind = "bool"     },
    { key = "discard",      prop = "LineTraceDiscardRadius",     kind = "number"   },
    { key = "action",       prop = "InputAction",                kind = "action"   },
    { key = "interactable", prop = "bIsInteractable",            kind = "bool"     },
    { key = "locked",       prop = "bLockInteraction",           kind = "bool"     },
    { key = "cost",         prop = "InteractCost",               kind = "number"   },
    { key = "costRes",      prop = "InteractCostResource",       kind = "resource" },
    { key = "autoRegister", prop = "bAutoRegisterInteraction",   kind = "bool"     },
    { key = "noDialogue",   prop = "bDisableDuringDialogue",     kind = "bool"     },
    { key = "useVolume",    prop = "bUseInteractVolume",         kind = "bool"     },
    { key = "customLoc",    prop = "bUseCustomInteractLocation", kind = "bool"     },
}

--- Scalars on the OWNING ACTOR, read off the owner wrapper we already hold. A
--- name that is absent on a given class simply reads nil and formats as "?", so
--- no class dispatch is needed and nothing is called.
---
--- These are the shape of a repeat-fire loop: a counter that goes down one
--- press at a time, and the cooldowns around it. CoinsLeftToPay lives on TWO
--- classes -- AHeldenGumballMachine (0x4A0) and AHeldenUpgradeMachine (0x630).
--- Kept OUT of the grouping signature: they are live state, not configuration,
--- so grouping on them would shatter every bucket.
local OWNER_FIELDS = {
    { key = "actorLocked",  prop = "bInteractionLocked",          kind = "bool"   },
    -- LIVE REMAINING -- what is still owed right now. These drive the press
    -- arithmetic.
    { key = "coinsLeft",    prop = "CoinsLeftToPay",              kind = "number" },
    { key = "remainingCost", prop = "RemainingCost",              kind = "number" },
    -- STATIC CONFIG -- the designer's price on a fresh machine.
    { key = "upgradeCost",  prop = "UpgradeCost",                 kind = "number" },
    -- NEITHER. AHeldenElevatorMachine.ReturnCost (0x590) sits in the config
    -- block beside the animation timings and reads 50 while the price the game
    -- actually shows is 40, 60 or 100. It is the RETURN trip, a different
    -- journey, and it is deliberately kept out of the press arithmetic. The
    -- live descent price is RemainingCost (0x638), beside FuseStates.
    { key = "returnCost",   prop = "ReturnCost",                  kind = "number" },
    { key = "pickUpCd",     prop = "PickUpItemCooldown",          kind = "number" },
    { key = "postDestroyCd", prop = "PostDestroyInteractCooldown", kind = "number" },
    { key = "rewardDelay",  prop = "GiveRewardDelay",             kind = "number" },
    { key = "hudDelay",     prop = "ShowHudRewardDelay",          kind = "number" },
    { key = "leverPause",   prop = "LeverPauseDuration",          kind = "number" },
    { key = "leverAnim",    prop = "LeverAnimDuration",           kind = "number" },
}

--- `FHeldenMoney` members on the owning actor. THE MISSING DENOMINATOR.
---
--- Measured 29 Aug 2026: the upgrade machine's CoinsLeftToPay went 100 -> 40
--- over three presses, i.e. 20 per press, not one. So a total on its own says
--- nothing about how many presses it costs -- `presses = total / per-press` --
--- and the per-press amount is `AHeldenCoinDepositObject.RequiredMoney`, which
--- the first version of this probe never read. A numerator with no denominator.
---
--- `FHeldenMoney` (Helden.hpp:2366) is 0xC of three plain int32s: no pointer,
--- no TArray, no FString. It is the safest struct shape there is. Read IN PLACE
--- off the persistent object and then field by field -- never through a
--- by-value getter, which is the documented hard crash on this build.
local OWNER_MONEY = {
    { key = "perPress",   prop = "RequiredMoney" },  -- AHeldenCoinDepositObject
    { key = "unlockCost", prop = "UnlockCost"    },  -- AHeldenUnlockableObject (the "Repair" walls)
    { key = "rerollCost", prop = "RerollCost"    },  -- AHeldenTipJar
    { key = "perCoin",    prop = "MoneyPerCoin"  },  -- AHeldenPiggyConstruct
    { key = "pickupWorth", prop = "PickupMoney"  },  -- AHeldenPickupActor (the loose coins)
}

--- A machine points at its deposit object; the deposit object carries the
--- per-press amount. Following that pointer is a property walk from an object
--- already in hand, so the machine's own row can show both numbers.
local DEPOSIT_POINTER = "CoinDeposit"          -- AHeldenUpgradeMachine, AHeldenElevatorMachine, AHeldenGumballMachine

--- Text-shaped extras. THESE ARE THE UNPROVEN READS -- see the header. They are
--- deliberately read LAST in readComponent, so every numeric field is already in
--- the record if one of them takes the process down.
local COMPONENT_TEXT = {
    { key = "prompt",    prop = "PromptInteractionText"      },  -- FText
    { key = "volumeTag", prop = "InteractVolumeComponentTag" },  -- FName
}

-- EHeldenActionLock, Helden_enums.hpp:135. Machine-compared against the header:
-- 49 of 49 values match. UInteractionComponent.InputAction is one of these.
local ACTION_LOCK = {
    [0] = "Jump", [1] = "Interact", [2] = "Move", [3] = "Look", [4] = "Sprint",
    [5] = "FlashLight", [6] = "Crouch", [7] = "Dodge", [8] = "UI_Accept",
    [9] = "UI_Back", [10] = "UI_Up", [11] = "UI_Right", [12] = "UI_Left",
    [13] = "UI_Down", [14] = "PauseMenu", [15] = "Attack",
    [16] = "SecondaryInteract", [17] = "TertiaryInteract",
    [18] = "UI_PuzzleAccept", [19] = "UI_PuzzleExit", [20] = "UI_PuzzleUp",
    [21] = "UI_PuzzleRight", [22] = "UI_PuzzleLeft", [23] = "UI_PuzzleDown",
    [24] = "StartConstruct", [25] = "ExitConstruct", [26] = "AcceptConstruct",
    [27] = "RotateLeftConstruct", [28] = "RotateRightConstruct",
    [29] = "InventoryAction01", [30] = "InventoryAction02",
    [31] = "InventoryAction03", [32] = "InventoryAction04",
    [33] = "InventroyAction", [34] = "PushToTalk", [35] = "EjectSpiritAction",
    [36] = "DropItemAction", [37] = "AltAttack", [38] = "PhysZoom",
    [39] = "PhysRotate", [40] = "SkipCinematic", [41] = "Emote",
    [42] = "PhysRotateLeft", [43] = "PhysRotateRight", [44] = "ToggleSprint",
    [45] = "UI_TabLeft", [46] = "UI_TabRight", [47] = "Introspect",
    [48] = "ToggleCrouch",
}

-- EHeldenResource, Helden_enums.hpp:1086. Machine-compared: 3 of 3 match.
local RESOURCE = { [0] = "Scraps", [1] = "Gold", [2] = "Artifacts" }

-- ==========================================================================
-- Tunables
-- ==========================================================================

local PUMP_MS        = 100    -- the single-append pump
local MAX_ENTRIES    = 6000   -- 1519 exist. A count far past that is the #1328
                              -- failure mode -- a garbage length off a raced
                              -- array -- so stop rather than walk into it.
local FLUSH_EVERY    = 20     -- raw-file flush interval; crash granularity
local PROGRESS_EVERY = 100    -- forensics-log progress interval
local MAX_EXAMPLES   = 3      -- example instance names per configuration group
local MAX_CLASSES    = 50     -- classes printed in detail; the index lists all
local MAX_CONFIGS    = 8      -- configuration groups printed per class

local REPORT_FILE = "BetterInteraction_probe.txt"
local RAW_FILE    = "BetterInteraction_probe_raw.txt"
local DIAG_FILE   = "BetterInteraction_probe.log"

local KEY_FULL = Key.F7      -- F7  full report
local KEY_HOT  = Key.F8      -- F8  hot only
-- Bare function keys, no modifier: a standing preference for every probe in
-- this project. Both of these are read-only, so an accidental press costs a
-- file append and nothing else.

-- ==========================================================================
-- Forensics log. Flushed on every line, because UE4SS's own log is buffered and
-- loses the last seconds before a crash -- and the last seconds are the whole
-- point of having one (crash rule J).
-- ==========================================================================

local diagHandle = nil
local diagPath   = DIAG_FILE
local outputDir  = "Helden\\Binaries\\Win64"

--- Open a file beside UE4SS.log, falling back to %TEMP% if that directory is
--- not writable. Returns handle (may be nil) and the path actually used.
local function openOut(name, mode)
    local handle = io.open(name, mode)
    if handle ~= nil then return handle, name end
    local fallback = (os.getenv("TEMP") or ".") .. "\\" .. name
    handle = io.open(fallback, mode)
    if handle ~= nil then outputDir = "%TEMP%" end
    return handle, fallback
end

local function diag(text)
    if diagHandle == nil then
        diagHandle, diagPath = openOut(DIAG_FILE, "a")
        if diagHandle == nil then diagHandle = false end
    end
    if diagHandle == false then return end
    pcall(function()
        diagHandle:write(string.format("%s %9.3f  %s\n",
            os.date("%H:%M:%S"), os.clock(), text))
        diagHandle:flush()
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
-- A wrapper around null is TRUTHY. FindFirstOf and property reads answer with a
-- wrapper whether or not the object is there, so `if x`, `if not x` and
-- `x ~= nil` all wave nothing straight through. "Can this object say its own
-- name" is the test that works: GetFullName answers Lua nil for a null wrapper.
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

--- A TArray element arrives wrapped; :get() unwraps it. Proven idiom.
local function deref(value)
    local inner = nil
    local ok = pcall(function() inner = value:get() end)
    if ok and inner ~= nil then return inner end
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

--- Anything -> a plain string, never nil. Handles FText and FName via ToString.
--- This is one of the two unproven accesses; see the header.
local function flat(value)
    if value == nil then return "" end
    local kind = type(value)
    if kind == "string" or kind == "number" or kind == "boolean" then
        return tostring(value)
    end
    local text = nil
    local ok = pcall(function() text = value:ToString() end)
    if ok and type(text) == "string" then return text end
    return ""
end

local function className(object)
    local name = nil
    pcall(function() name = object:GetClass():GetFName():ToString() end)
    if type(name) ~= "string" or name == "" then return "?" end
    return name
end

--- The tail of a full name: "...PersistentLevel.BP_Chest_C_2147480123" -> the
--- last dotted segment.
local function shortName(name)
    if name == nil or name == "" then return "?" end
    return (name:gsub("^.*[%.:/]", ""))
end

--- The owning ACTOR's segment of a component's full name. A component's own
--- tail is "InteractComponent" on every AHeldenInteractableObject, which is not
--- identifying -- the segment before it is.
local function ownerSegment(componentFullName)
    if componentFullName == nil or componentFullName == "" then return "?" end
    local trimmed = componentFullName:gsub("%.[^%.]*$", "")
    return shortName(trimmed)
end

-- ==========================================================================
-- Formatting. Every reader answers "?" rather than guessing, so a property that
-- did not read as its expected type is VISIBLE instead of silently defaulting.
-- ==========================================================================

local function numStr(value)
    if type(value) ~= "number" then return "?" end
    return string.format("%.6g", value)
end

local function boolStr(value)
    if type(value) ~= "boolean" then return "?" end
    return value and "true" or "false"
end

local function enumStr(value, names)
    if type(value) == "number" then
        local name = names[value]
        if name == nil then return "?(" .. tostring(value) .. ")" end
        return name .. "(" .. tostring(value) .. ")"
    end
    local text = flat(value)
    if text ~= "" then return text end
    return "?"
end

local function fieldStr(kind, value)
    if kind == "bool" then return boolStr(value) end
    if kind == "number" then return numStr(value) end
    if kind == "action" then return enumStr(value, ACTION_LOCK) end
    if kind == "resource" then return enumStr(value, RESOURCE) end
    return flat(value)
end

--- An `FHeldenMoney` read IN PLACE off a persistent object: take the struct
--- view, then read its three int32 fields. Never a by-value getter.
---
--- Returns nil when the property is absent (most classes have none of them) or
--- when every field is zero, so an absent name costs a row rather than filling
--- the report with "0/0/0". Returns the total as a second value, so the caller
--- can do arithmetic without parsing the string back.
local function moneyStr(object, property)
    local money = get(object, property)
    if money == nil then return nil end
    local scraps, gold, artifacts = nil, nil, nil
    pcall(function() scraps = money.Scraps end)
    pcall(function() gold = money.Gold end)
    pcall(function() artifacts = money.Artifacts end)
    if type(scraps) ~= "number" and type(gold) ~= "number"
            and type(artifacts) ~= "number" then
        return nil
    end
    local s = (type(scraps) == "number") and scraps or 0
    local g = (type(gold) == "number") and gold or 0
    local a = (type(artifacts) == "number") and artifacts or 0
    if s == 0 and g == 0 and a == 0 then return nil end
    return string.format("%dS/%dG/%dA", s, g, a), s + g + a
end

-- ==========================================================================
-- Reading one component
-- ==========================================================================

local firstOwnerRead, firstTextRead = false, false
local ownerlessCount = 0

--- Every value comes back as a STRING, because every value is going into a
--- report and a string is the one form that cannot surprise us later. The two
--- numeric fields the candidate lists sort on are kept as numbers alongside.
local function readComponent(component)
    local record = {
        component   = fullName(component),
        fields      = {},
        ownerFields = {},
        text        = {},
    }

    -- 1. The scalars. Plain property reads on a persistent UObject: the safest
    --    thing in this file, and the data Phase 1 actually needs.
    for _, field in ipairs(COMPONENT_FIELDS) do
        local raw = get(component, field.prop)
        record.fields[field.key] = fieldStr(field.kind, raw)
        if field.key == "cooldown" then
            record.cooldownNum = (type(raw) == "number") and raw or nil
        elseif field.key == "holdDur" then
            record.holdDurNum = (type(raw) == "number") and raw or nil
        elseif field.key == "hold" then
            -- TRI-STATE, deliberately. "false" and "did not read" are different
            -- answers, and collapsing them would quietly file an unreadable
            -- component into the tap candidate list that Phase 2 is tuned from.
            record.holdRead = (type(raw) == "boolean")
            record.isHold   = (raw == true)
        end
    end

    -- 2. The back-pointer to the shared settings asset. Counting the DISTINCT
    --    values of this across every component answers the open question.
    record.settings = fullName(get(component, PROP.settingsAlt))

    -- 3. The owning actor. UNPROVEN ACCESS -- GetOwner is a UFunction call on a
    --    component, which appears in none of the three proven mods. It returns a
    --    POINTER, the safe shape, but it is dispatched through the engine.
    if not firstOwnerRead then
        firstOwnerRead = true
        diag("first component:GetOwner() call -- unproven access, about to run")
    end
    local owner = nil
    pcall(function() owner = component:GetOwner() end)

    if real(owner) then
        record.owner      = fullName(owner)
        record.ownerClass = className(owner)
        for _, field in ipairs(OWNER_FIELDS) do
            local value = fieldStr(field.kind, get(owner, field.prop))
            if value ~= "?" then
                record.ownerFields[field.key] = value
                -- THREE CATEGORIES, kept apart on purpose. This exact conflation
                -- has now produced a wrong number twice: `UpgradeCost` (100)
                -- clobbering `CoinsLeftToPay` (40), and `ReturnCost` (50, the
                -- return trip) standing in for a descent price that is really
                -- 40, 60 or 100. A machine has a config price, a live balance,
                -- and sometimes an unrelated third price, and only the live
                -- balance answers "how many presses from here".
                if field.key == "coinsLeft" or field.key == "remainingCost" then
                    record.owedNow = tonumber(value)
                elseif field.key == "upgradeCost" then
                    record.owedFull = tonumber(value)
                end
            end
        end
        for _, field in ipairs(OWNER_MONEY) do
            local value, total = moneyStr(owner, field.prop)
            if value ~= nil then
                record.ownerFields[field.key] = value
                if field.key == "perPress" then record.perPress = total end
            end
        end
        -- A machine carries the total; its deposit object carries the per-press
        -- amount. One pointer hop, off an object already in hand, so the
        -- machine's own row can show both and the division is possible.
        local deposit = get(owner, DEPOSIT_POINTER)
        if real(deposit) then
            local value, total = moneyStr(deposit, "RequiredMoney")
            if value ~= nil then
                record.ownerFields["depositPerPress"] = value
                record.perPress = total
            end
        end
    else
        -- A CONSTANT class key, so ownerless rows collapse into one bucket
        -- rather than each becoming its own. Identity is preserved in `owner`,
        -- which the examples and the raw file both print.
        ownerlessCount = ownerlessCount + 1
        record.owner      = record.component
        record.ownerClass = "<no owner>"
        logOnce("noowner", "GetOwner() did not answer for at least one component;"
            .. " those rows are grouped under <no owner> and identified by the"
            .. " owner segment of the component's own outer chain")
    end

    -- 4. Text LAST. UNPROVEN ACCESS -- reading an FText property and calling
    --    :ToString() on it has no precedent in the proven mods. Everything above
    --    is already in `record` if this is the step that dies.
    if not firstTextRead then
        firstTextRead = true
        diag("first FText/FName :ToString() read -- unproven access, about to run")
    end
    for _, field in ipairs(COMPONENT_TEXT) do
        record.text[field.key] = flat(get(component, field.prop))
    end

    return record
end

--- The grouping key: every CONFIGURED value, and nothing identifying and
--- nothing live. Two components with the same signature are the same
--- knob-setting, so the report can collapse the population into the handful of
--- distinct configurations that actually exist -- which is the list we tune.
--- OWNER_FIELDS are excluded on purpose: they are live state (CoinsLeftToPay
--- changes as you play) and grouping on them would shatter every bucket.
local function signature(record)
    local parts = {}
    for _, field in ipairs(COMPONENT_FIELDS) do
        parts[#parts + 1] = field.key .. "=" .. record.fields[field.key]
    end
    return table.concat(parts, "  ")
end

-- ==========================================================================
-- Resolution. Global object-array walks, on a keypress, never on a timer
-- (crash rule E).
-- ==========================================================================

local function findFirst(class)
    local found = nil
    pcall(function() found = FindFirstOf(class) end)
    if not real(found) then return nil end
    -- FindFirstOf is understood to skip class default objects, but the object
    -- dump shows a Default__ twin for every one of these classes, and a CDO
    -- would answer every read with the archetype's values rather than this
    -- world's. Cheap to rule out; expensive to misread.
    if fullName(found):find("Default__", 1, true) ~= nil then
        logOnce("cdo:" .. class, "FindFirstOf(\"" .. class .. "\") answered with a"
            .. " class default object; refusing it. REPORT THIS -- it means the"
            .. " probe cannot see this world's live instance.")
        return nil
    end
    return found
end

--- The world gate (crash rule F): a LOCAL player controller, which is a fact
--- about a playable world rather than a timer. A bare "some controller object
--- exists" is true during a level load too. This is LetMeLook's proven test.
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

-- ==========================================================================
-- Walks. Both return total / seen / empty and the pcall error text, because
-- "the array was empty" and "the array had entries and none resolved" are
-- different answers and only one of them is worth re-running (crash rule H).
-- ==========================================================================

--- HotInteractions: a TArray of raw pointers, so no struct crosses the
--- boundary here at all.
local function walkHot(subsystem, visit)
    local array = get(subsystem, PROP.hot)
    if array == nil then return nil, PROP.hot .. " did not read at all" end
    local total = count(array)
    if total < 0 then return nil, PROP.hot .. " has no readable length" end
    if total > MAX_ENTRIES then
        return nil, string.format("%s reports %d entries, past the %d sanity cap"
            .. " -- refusing to walk it", PROP.hot, total, MAX_ENTRIES)
    end

    local seen, empty = 0, 0
    local ok, err = pcall(function()
        array:ForEach(function(_index, element)
            local component = deref(element)
            if real(component) then
                seen = seen + 1
                visit(component)
            else
                empty = empty + 1
            end
        end)
    end)
    local stats = { total = total, seen = seen, empty = empty }
    if not ok then
        diag("hot walk raised: " .. tostring(err))
        return stats, "the walk raised part-way through: " .. tostring(err)
    end
    return stats, nil
end

--- FHeldenInteractionEntry has exactly one field, Component. Two access forms
--- are tried. Form 1 is the one GrainRotAP main.lua:1565 proves in production
--- over a strictly more complex struct array; form 2 is the fallback. Which one
--- worked is recorded, and the probe separates "the form did not work" from
--- "the Component pointer was genuinely null" -- real() alone cannot.
local reportedForm  = nil
local formGetWorked = nil

local function entryComponent(element)
    local inner = nil
    pcall(function() inner = element:get() end)
    if formGetWorked == nil then formGetWorked = (inner ~= nil) end
    if inner ~= nil then
        local component = nil
        pcall(function() component = inner[PROP.entryComp] end)
        if real(component) then return component, "element:get()." .. PROP.entryComp end
    end
    local component = nil
    pcall(function() component = element[PROP.entryComp] end)
    if real(component) then return component, "element." .. PROP.entryComp end
    return nil, nil
end

local function walkRegistered(subsystem, visit)
    reportedForm, formGetWorked = nil, nil

    local array = get(subsystem, PROP.registered)
    if array == nil then return nil, PROP.registered .. " did not read at all" end
    local total = count(array)
    if total < 0 then return nil, PROP.registered .. " has no readable length" end
    if total > MAX_ENTRIES then
        return nil, string.format("%s reports %d entries, past the %d sanity cap"
            .. " -- refusing to walk it (RE-UE4SS #1328 returns garbage lengths"
            .. " off a raced array)", PROP.registered, total, MAX_ENTRIES)
    end

    diag(string.format("REGISTERED WALK BEGINS -- %d entries. If the log stops"
        .. " inside this, the last index below is where it died.", total))

    local seen, empty = 0, 0
    local ok, err = pcall(function()
        array:ForEach(function(index, element)
            if type(index) == "number" and index % PROGRESS_EVERY == 0 then
                diag("  registered index " .. tostring(index) .. " of " .. total)
            end
            local component, form = entryComponent(element)
            if component == nil then
                empty = empty + 1
            else
                if reportedForm == nil then
                    reportedForm = form
                    diag("  struct element access form that worked: " .. form)
                end
                seen = seen + 1
                visit(component, index)
            end
        end)
    end)
    diag(string.format("REGISTERED WALK ENDS -- %d of %d live, %d empty",
        seen, total, empty))

    local stats = { total = total, seen = seen, empty = empty }
    if not ok then
        diag("registered walk raised: " .. tostring(err))
        return stats, string.format("the walk raised after %d of %d entries: %s",
            seen, total, tostring(err))
    end
    return stats, nil
end

-- ==========================================================================
-- Report building
-- ==========================================================================

local function blockFor(record, indent)
    local out = {}
    local pad = indent or "    "
    local f = record.fields
    out[#out + 1] = pad .. string.format(
        "hold=%s  holdDur=%s  autoEndHold=%s  holster=%s  soulHold=%s",
        f.hold, f.holdDur, f.autoEndHold, f.holster, f.soulHold)
    out[#out + 1] = pad .. string.format(
        "cooldown=%s  maxDist=%s  lineTrace=%s  discardRadius=%s",
        f.cooldown, f.maxDist, f.lineTrace, f.discard)
    out[#out + 1] = pad .. string.format(
        "action=%s  interactable=%s  lockInteraction=%s  cost=%s %s",
        f.action, f.interactable, f.locked, f.cost, f.costRes)
    out[#out + 1] = pad .. string.format(
        "autoRegister=%s  disableInDialogue=%s  useVolume=%s  customLoc=%s",
        f.autoRegister, f.noDialogue, f.useVolume, f.customLoc)

    -- Owner-side scalars, only the ones this class actually has. An absent name
    -- is normal -- most classes have none of them -- so an empty line here is
    -- information, not a failure.
    local owned = {}
    local function add(key)
        local value = record.ownerFields[key]
        if value ~= nil then owned[#owned + 1] = key .. "=" .. value end
    end
    for _, field in ipairs(OWNER_FIELDS) do add(field.key) end
    for _, field in ipairs(OWNER_MONEY) do add(field.key) end
    add("depositPerPress")
    if record.perPress ~= nil and record.perPress > 0 then
        if record.owedFull ~= nil then
            owned[#owned + 1] = string.format("PRESSES_FULL=%.4g",
                record.owedFull / record.perPress)
        end
        if record.owedNow ~= nil then
            owned[#owned + 1] = string.format("PRESSES_LEFT=%.4g",
                record.owedNow / record.perPress)
        end
    end
    if #owned > 0 then
        out[#out + 1] = pad .. "actor: " .. table.concat(owned, "  ")
    end
    return out
end

--- Group by owning actor class, then by identical configuration. Classes are
--- ordered by population, so the ones worth tuning are at the top of the report
--- rather than wherever the alphabet puts them.
local function group(records)
    local classes, order = {}, {}
    for _, record in ipairs(records) do
        local bucket = classes[record.ownerClass]
        if bucket == nil then
            bucket = { name = record.ownerClass, total = 0, configs = {}, order = {} }
            classes[record.ownerClass] = bucket
            order[#order + 1] = bucket
        end
        bucket.total = bucket.total + 1

        local key = signature(record)
        local config = bucket.configs[key]
        if config == nil then
            config = { record = record, count = 0, examples = {} }
            bucket.configs[key] = config
            bucket.order[#bucket.order + 1] = config
        end
        config.count = config.count + 1
        if #config.examples < MAX_EXAMPLES then
            local label = shortName(record.owner)
            if record.ownerClass == "<no owner>" then
                label = ownerSegment(record.component)
            end
            config.examples[#config.examples + 1] = label
        end
    end
    table.sort(order, function(a, b)
        if a.total == b.total then return a.name < b.name end
        return a.total > b.total
    end)
    for _, bucket in ipairs(order) do
        table.sort(bucket.order, function(a, b) return a.count > b.count end)
    end
    return order
end

--- Tap interactions with the shortest cooldown, longest holds. Both are
--- CANDIDATE LISTS, not findings: a short cooldown is the shape a spam-click
--- has, it is not evidence that anyone spams that particular thing.
---
--- Components whose bIsHoldInteraction did not read go in NEITHER list and are
--- counted, so the tap list cannot quietly absorb rows the probe could not
--- classify (crash rule H).
local function candidates(records)
    local taps, holds = {}, {}
    local unclassified, noCooldown, noDuration = 0, 0, 0
    for _, record in ipairs(records) do
        if not record.holdRead then
            unclassified = unclassified + 1
        elseif record.isHold then
            if record.holdDurNum ~= nil and record.holdDurNum > 0 then
                holds[#holds + 1] = record
            else
                noDuration = noDuration + 1
            end
        elseif record.cooldownNum ~= nil then
            taps[#taps + 1] = record
        else
            noCooldown = noCooldown + 1
        end
    end
    table.sort(taps, function(a, b)
        if a.cooldownNum == b.cooldownNum then return a.ownerClass < b.ownerClass end
        return a.cooldownNum < b.cooldownNum
    end)
    table.sort(holds, function(a, b)
        if a.holdDurNum == b.holdDurNum then return a.ownerClass < b.ownerClass end
        return a.holdDurNum > b.holdDurNum
    end)
    return taps, holds, {
        unclassified = unclassified,
        noCooldown = noCooldown,
        noDuration = noDuration,
    }
end

--- Collapse a candidate list to one row per (class, value) pair with a count.
local function collapse(records, valueKey)
    local rows, index = {}, {}
    for _, record in ipairs(records) do
        local key = record.ownerClass .. "|" .. numStr(record[valueKey])
        local row = index[key]
        if row == nil then
            row = { class = record.ownerClass, value = record[valueKey],
                    count = 0, example = shortName(record.owner) }
            index[key] = row
            rows[#rows + 1] = row
        end
        row.count = row.count + 1
    end
    return rows
end

-- ==========================================================================
-- The sections
-- ==========================================================================

local runCounter = 0

local function populationLine(stats, what)
    if stats == nil then return "  " .. what .. ": could not be read at all" end
    return string.format("  %s: %d entries in the array, %d held a live"
        .. " component, %d empty or unreadable",
        what, stats.total, stats.seen, stats.empty)
end

local function hotSection(say, subsystem)
    say("")
    say("---- HOT interactions: what is live where you are standing ----")
    say("  (this section also exercises both unproven reads -- GetOwner and the")
    say("   FText prompt -- on the smallest possible sample, before the big walk)")
    local records = {}
    local stats, problem = walkHot(subsystem, function(component)
        records[#records + 1] = readComponent(component)
    end)
    say(populationLine(stats, PROP.hot))
    if problem ~= nil then say("  NOTE: " .. problem) end

    if stats ~= nil and stats.total == 0 then
        say("  the array is empty -- nothing is in interaction range. Walk up to")
        say("  a thing and press the key again.")
    elseif #records == 0 and stats ~= nil and stats.total > 0 then
        say("  the array reports entries but NONE of them resolved. REPORT THIS:")
        say("  it means the entry point this mod is built on is handing back")
        say("  pointers that cannot be read.")
    end

    for _, record in ipairs(records) do
        say("")
        say("  " .. record.ownerClass .. "   " .. shortName(record.owner))
        say("    owner   " .. record.owner)
        local prompt = record.text.prompt
        if prompt ~= "" then say("    prompt  \"" .. prompt .. "\"") end
        for _, line in ipairs(blockFor(record, "    ")) do say(line) end
    end
    return records
end

--- The three global floats and the asset identity. Needs only the subsystem, so
--- it runs BEFORE the registered walk and is flushed with everything else that
--- cannot be recovered if the walk goes wrong.
local function settingsAssetSection(say, subsystem, deep)
    say("")
    say("---- UInteractionSettings: the three global floats ----")

    local settings = get(subsystem, PROP.settings)
    if not real(settings) then
        say("  " .. PROP.settings .. " on the subsystem did not resolve.")
        return nil
    end
    say("  asset                      " .. fullName(settings))
    say("  OutlineTag                 " .. flat(get(settings, "OutlineTag")))
    say("  InteractProximityDistance  " .. numStr(get(settings, "InteractProximityDistance")))
    say("  InteractProximityAngle     " .. numStr(get(settings, "InteractProximityAngle")))
    say("  reached via                subsystem." .. PROP.settings)

    if not deep then
        say("  (the " .. CLASS.singleton .. " cross-check is F7 only -- it")
        say("   costs a global array walk and F8 does not pay for one)")
        return settings
    end

    local singleton = findFirst(CLASS.singleton)
    if singleton == nil then
        say("  cross-check                " .. CLASS.singleton .. " did not resolve")
        return settings
    end
    local otherName = fullName(get(singleton, PROP.settingsAlt))
    if otherName == "" then
        say("  cross-check                " .. CLASS.singleton .. "."
            .. PROP.settingsAlt .. " is null")
    elseif otherName == fullName(settings) then
        say("  cross-check                " .. CLASS.singleton .. "."
            .. PROP.settingsAlt .. " is the SAME asset")
    else
        say("  cross-check                " .. CLASS.singleton .. "."
            .. PROP.settingsAlt .. " is a DIFFERENT asset: " .. otherName)
    end
    return settings
end

--- How many distinct settings assets do the components between them point at?
--- This is the part that needs `records`, so it runs after the walk -- and the
--- conclusion is gated on the sample being the WHOLE registered population.
--- A hot-only sample of one component would otherwise "answer" an open question
--- from a sample that cannot support it.
local function settingsTallySection(say, records, complete)
    say("")
    say("---- how many InteractionSettings assets are actually in use ----")
    local distinct, order = {}, {}
    for _, record in ipairs(records) do
        local name = record.settings
        if name == "" then name = "<null>" end
        if distinct[name] == nil then
            distinct[name] = 0
            order[#order + 1] = name
        end
        distinct[name] = distinct[name] + 1
    end
    table.sort(order)
    say(string.format("  sample                     %d components (%s)",
        #records, complete and "every registered component"
                            or "the HOT set only"))
    say(string.format("  distinct assets in sample  %d", #order))
    for _, name in ipairs(order) do
        say(string.format("      x%-6d %s", distinct[name], name))
    end

    if not complete then
        say("  -> this is the hot sample, not the population. It settles nothing")
        say("     about the shared-asset open question. Press F7 for that.")
    elseif #order == 1 and order[1] ~= "<null>" then
        say("  -> one shared asset across every registered component in THIS")
        say("     world, so one write to those two floats would cover all of")
        say("     them here. Confirm again inside a run before Phase 1 leans on")
        say("     it -- one world is not every world.")
    elseif #order > 1 then
        say("  -> MORE THAN ONE asset. Phase 1 cannot be a single write.")
    end
end

local function registeredSection(say, rawSay, subsystem)
    say("")
    say("---- every registered component, grouped by owning actor class ----")

    local records = {}
    local written = 0
    local started = os.clock()
    local stats, problem = walkRegistered(subsystem, function(component, index)
        local record = readComponent(component)
        records[#records + 1] = record

        rawSay(string.format("[%s] %s   %s", tostring(index), record.ownerClass,
            shortName(record.owner)))
        rawSay("    owner      " .. record.owner)
        rawSay("    component  " .. record.component)
        rawSay("    settings   " .. record.settings)
        if record.text.prompt ~= "" then
            rawSay("    prompt     \"" .. record.text.prompt .. "\"")
        end
        if record.text.volumeTag ~= "" then
            rawSay("    volumeTag  " .. record.text.volumeTag)
        end
        for _, line in ipairs(blockFor(record, "    ")) do rawSay(line) end
        rawSay("")

        written = written + 1
        if written % FLUSH_EVERY == 0 then rawSay(nil) end   -- nil == flush
    end)
    local elapsed = os.clock() - started

    say(populationLine(stats, PROP.registered))
    say(string.format("  walk cost                  %.2f cpu seconds", elapsed))
    if problem ~= nil then say("  NOTE: " .. problem) end
    if reportedForm ~= nil then
        say("  struct element read via    " .. reportedForm)
    elseif stats ~= nil and stats.total > 0 then
        say("  struct element read via    NOTHING WORKED. element:get() "
            .. (formGetWorked == true and "did return a value, so the struct"
                .. " unwrapped and the Component field is what failed"
                or "returned nothing, so the struct did not unwrap at all")
            .. ". REPORT THIS.")
    end
    if ownerlessCount > 0 then
        say(string.format("  components with no owner   %d (grouped under <no owner>)",
            ownerlessCount))
    end
    if #records == 0 then return records end

    local buckets = group(records)
    say("")
    say(string.format("  %d owning classes, %d components", #buckets, #records))
    say("")
    say("  -- class index, most components first --")
    say(string.format("  %-46s %6s %8s", "owning class", "n", "configs"))
    for _, bucket in ipairs(buckets) do
        say(string.format("  %-46s %6d %8d", bucket.name, bucket.total, #bucket.order))
    end

    say("")
    say("  -- configurations. n = how many components share that exact setting --")
    local shownClasses = 0
    for _, bucket in ipairs(buckets) do
        shownClasses = shownClasses + 1
        if shownClasses > MAX_CLASSES then
            say("")
            say(string.format("  ... %d further classes not detailed here (the"
                .. " index above lists them all, and %s has every component)",
                #buckets - MAX_CLASSES, RAW_FILE))
            break
        end
        say("")
        say(string.format("=== %s ===   %d component%s, %d configuration%s",
            bucket.name, bucket.total, bucket.total == 1 and "" or "s",
            #bucket.order, #bucket.order == 1 and "" or "s"))
        for number, config in ipairs(bucket.order) do
            if number > MAX_CONFIGS then
                say(string.format("  ... %d further configurations for this class"
                    .. " not shown -- see %s", #bucket.order - MAX_CONFIGS, RAW_FILE))
                break
            end
            say(string.format("  [config %d]  n=%d  (showing up to %d of %d names)",
                number, config.count, MAX_EXAMPLES, config.count))
            for _, line in ipairs(blockFor(config.record, "      ")) do say(line) end
            local prompt = config.record.text.prompt
            if prompt ~= "" then say("      prompt=\"" .. prompt .. "\"") end
            say("      e.g. " .. table.concat(config.examples, ", "))
        end
    end
    return records
end

local function candidateSection(say, records)
    local taps, holds, skipped = candidates(records)

    say("")
    say("---- CANDIDATES: tap interactions, shortest cooldown first ----")
    say("  A HYPOTHESIS LIST, NOT A FINDING. A tap interaction with a short")
    say("  cooldown is the SHAPE a spam-click has. Whether anyone actually")
    say("  hammers it is a question only playing can answer.")
    say(string.format("  excluded: %d whose hold flag did not read, %d taps with"
        .. " no numeric cooldown", skipped.unclassified, skipped.noCooldown))
    say("")
    if #taps == 0 then
        say("  none.")
    else
        say(string.format("  %-10s %-42s %6s   %s", "cooldown", "owning class", "n", "example"))
        for _, row in ipairs(collapse(taps, "cooldownNum")) do
            say(string.format("  %-10s %-42s %6d   %s",
                numStr(row.value), row.class, row.count, row.example))
        end
    end

    say("")
    say("---- CANDIDATES: hold interactions, longest hold first ----")
    say(string.format("  excluded: %d holds with no positive duration", skipped.noDuration))
    say("")
    if #holds == 0 then
        say("  none.")
    else
        say(string.format("  %-10s %-42s %6s   %s", "seconds", "owning class", "n", "example"))
        for _, row in ipairs(collapse(holds, "holdDurNum")) do
            say(string.format("  %-10s %-42s %6d   %s",
                numStr(row.value), row.class, row.count, row.example))
        end
    end

    -- THE DEPOSIT LOOPS, in presses. This is the table the spam question
    -- actually turns on, and the first version of this probe could not build it
    -- because it read the total without the per-press amount.
    say("")
    say("---- DEPOSIT LOOPS: how many presses each one costs ----")
    say("  presses = amount owed / amount taken per press. Measured 29 Aug 2026:")
    say("  the upgrade machine takes 20 per press, not 1, so a total on its own")
    say("  says nothing. The per-press figure is the deposit object's")
    say("  RequiredMoney, followed through the machine's CoinDeposit pointer.")
    say("  ARITHMETIC, not observation: it assumes a constant amount per press,")
    say("  which is measured for the upgrade machine and assumed elsewhere.")
    say("")
    local loops = {}
    for _, record in ipairs(records) do
        if record.perPress ~= nil and record.perPress > 0
                and (record.owedFull ~= nil or record.owedNow ~= nil) then
            loops[#loops + 1] = {
                class = record.ownerClass,
                full = record.owedFull,
                left = record.owedNow,
                per = record.perPress,
                pressesFull = record.owedFull and (record.owedFull / record.perPress),
                pressesLeft = record.owedNow and (record.owedNow / record.perPress),
                example = shortName(record.owner),
            }
        end
    end
    table.sort(loops, function(a, b)
        return (a.pressesFull or a.pressesLeft or 0) > (b.pressesFull or b.pressesLeft or 0)
    end)
    if #loops == 0 then
        say("  none -- no actor had both a cost and a per-press amount. If you")
        say("  expected one here, it means the machine and its deposit object did")
        say("  not link up; check the raw file for the two rows separately.")
    else
        say("  full  = the config price of a fresh machine (UpgradeCost)")
        say("  left  = what is still owed RIGHT NOW (CoinsLeftToPay / RemainingCost)")
        say("  PRESS_L is the one that matters. These are kept apart because")
        say("  collapsing them has produced a wrong answer twice: UpgradeCost 100")
        say("  hid a balance of 40, and ReturnCost 50 -- which is the RETURN trip")
        say("  and never varies -- stood in for a descent price of 40/60/100.")
        say("  ReturnCost is reported in the counters table below and is kept out")
        say("  of this arithmetic entirely.")
        say("")
        say(string.format("  %-38s %6s %6s %6s %8s %8s   %s", "owning class",
            "full", "left", "/press", "PRESS_F", "PRESS_L", "example"))
        local function cell(value, fmt)
            if value == nil then return "-" end
            return string.format(fmt, value)
        end
        for _, row in ipairs(loops) do
            say(string.format("  %-38s %6s %6s %6d %8s %8s   %s",
                row.class, cell(row.full, "%d"), cell(row.left, "%d"), row.per,
                cell(row.pressesFull, "%.4g"), cell(row.pressesLeft, "%.4g"),
                row.example))
        end
    end

    -- The other shape a repeat-fire loop has: a counter that goes down one press
    -- at a time. Read straight off the owning actor.
    say("")
    say("---- CANDIDATES: per-actor counters, costs and delays that were present ----")
    say("  These are LIVE STATE, not configuration. Money reads as Scraps/Gold/")
    say("  Artifacts, in place off the actor -- FHeldenMoney is three plain")
    say("  int32s, the safest struct shape there is.")
    say("")
    local reportedKeys = {}
    for _, field in ipairs(OWNER_FIELDS) do
        if field.key ~= "actorLocked" then reportedKeys[#reportedKeys + 1] = field.key end
    end
    for _, field in ipairs(OWNER_MONEY) do reportedKeys[#reportedKeys + 1] = field.key end
    reportedKeys[#reportedKeys + 1] = "depositPerPress"

    local rows = {}
    for _, record in ipairs(records) do
        for _, key in ipairs(reportedKeys) do
            local value = record.ownerFields[key]
            if value ~= nil then
                local id = record.ownerClass .. "|" .. key .. "|" .. value
                if rows[id] == nil then
                    rows[id] = { class = record.ownerClass, field = key,
                                 value = value, count = 0,
                                 example = shortName(record.owner) }
                end
                rows[id].count = rows[id].count + 1
            end
        end
    end
    local ordered = {}
    for _, row in pairs(rows) do ordered[#ordered + 1] = row end
    table.sort(ordered, function(a, b)
        if a.class ~= b.class then return a.class < b.class end
        if a.field ~= b.field then return a.field < b.field end
        return a.value < b.value
    end)
    if #ordered == 0 then
        say("  none present on any owning actor in this world.")
    else
        say(string.format("  %-42s %-16s %-14s %6s   %s",
            "owning class", "field", "value", "n", "example"))
        for _, row in ipairs(ordered) do
            say(string.format("  %-42s %-16s %-14s %6d   %s",
                row.class, row.field, row.value, row.count, row.example))
        end
    end
end

local function totalsSection(say, records)
    local hold, tap, unreadable, zeroCooldown, noTrace = 0, 0, 0, 0, 0
    local minDist, maxDist = nil, nil
    for _, record in ipairs(records) do
        if not record.holdRead then unreadable = unreadable + 1
        elseif record.isHold then hold = hold + 1
        else tap = tap + 1 end
        if record.cooldownNum ~= nil and record.cooldownNum <= 0 then
            zeroCooldown = zeroCooldown + 1
        end
        if record.fields.lineTrace == "false" then noTrace = noTrace + 1 end
        local distance = tonumber(record.fields.maxDist)
        if distance ~= nil then
            if minDist == nil or distance < minDist then minDist = distance end
            if maxDist == nil or distance > maxDist then maxDist = distance end
        end
    end
    say("")
    say("---- totals ----")
    say(string.format("  components read            %d", #records))
    say(string.format("  hold interactions          %d", hold))
    say(string.format("  tap interactions           %d", tap))
    say(string.format("  bIsHoldInteraction unread  %d", unreadable))
    say(string.format("  cooldown <= 0              %d", zeroCooldown))
    say(string.format("  bLineTraceValidate false   %d", noTrace))
    say(string.format("  MaxInteractDistance range  %s .. %s",
        numStr(minDist), numStr(maxDist)))
end

-- ==========================================================================
-- The report
-- ==========================================================================

--- hotOnly = true is the F8 pass.
local function report(hotOnly)
    runCounter = runCounter + 1
    firstOwnerRead, firstTextRead = false, false
    ownerlessCount = 0

    local mode = hotOnly and "HOT ONLY" or "FULL"
    diag(string.format("---- run %d (%s) begins ----", runCounter, mode))

    local reportHandle, reportPath = openOut(REPORT_FILE, "a")
    local lines = {}
    local bytes = 0
    local function say(text) lines[#lines + 1] = text end

    --- Write what we have and start a fresh buffer. Called after every section,
    --- so no single failure can take more than one section's output with it.
    --- A no-op when the file could not be opened, which leaves `lines` intact
    --- for the print-to-log fallback at the end.
    local function flush()
        if reportHandle == nil or #lines == 0 then return end
        local blob = table.concat(lines, "\n") .. "\n"
        pcall(function()
            reportHandle:write(blob)
            reportHandle:flush()
        end)
        bytes = bytes + #blob
        lines = {}
    end

    --- The one exit. Prints the size, closes the file, and -- if the file could
    --- never be opened -- puts the whole report in the UE4SS log instead, which
    --- is the only remaining place a tester could read it from. Every return
    --- path goes through here, including the two SKIP paths: a skip that left no
    --- trace anywhere is exactly the ambiguity crash rule H exists to prevent.
    local function finish()
        flush()
        say("")
        say(string.format(" this run added roughly %d KB to %s",
            math.floor(bytes / 1024 + 0.5), REPORT_FILE))
        say("================ end of run " .. runCounter .. " ================")
        if reportHandle == nil then
            log("could not open " .. REPORT_FILE
                .. " in either location; writing the report to the UE4SS log instead")
            for _, line in ipairs(lines) do print(line .. "\n") end
            return
        end
        flush()
        pcall(function() reportHandle:close() end)
        log(string.format("run %d (%s) written to %s", runCounter, mode, reportPath))
        diag(string.format("---- run %d (%s) ends ----", runCounter, mode))
    end

    say("")
    say("================================================================")
    say(string.format(" BetterInteraction probe %s   run %d   %s   %s",
        VERSION, runCounter, mode, os.date("%Y-%m-%d %H:%M:%S")))
    say("================================================================")

    -- Rule F: gate on a FACT -- is there a playable world -- not on a timer.
    local controller = localController()
    if controller == nil then
        say(" SKIPPED: no LOCAL " .. CLASS.controller .. " resolved, so this is")
        say(" the main menu or a level transition. Nothing was read. Get into")
        say(" the world and press the key again.")
        log("skipped: no local " .. CLASS.controller .. " (menu, or a transition)")
        finish()
        return
    end

    local subsystem = findFirst(CLASS.subsystem)
    if subsystem == nil then
        say(" SKIPPED: a local " .. CLASS.controller .. " is here but "
            .. CLASS.subsystem)
        say(" did not resolve. REPORT THIS -- it means the entry point this")
        say(" whole mod is built on is not present in this world.")
        log("skipped: " .. CLASS.subsystem .. " did not resolve although a local "
            .. CLASS.controller .. " did -- REPORT THIS")
        finish()
        return
    end

    -- Authority, reported as the raw signal rather than as a verdict. The
    -- sibling project recorded its own single-signal host test answering WRONG
    -- on a guest, so this says what it measured and lets the reader judge.
    local authority = nil
    pcall(function() authority = controller:HasAuthority() end)
    say(" controller          " .. fullName(controller))
    say(" HasAuthority        " .. boolStr(authority)
        .. "  (true = host or solo, false = guest; ONE signal, not a verdict)")
    say(" subsystem           " .. fullName(subsystem))
    say(" output dir          " .. outputDir)
    say(" global array walks  " .. (hotOnly and "2 (controller, subsystem)"
        or "3 (controller, subsystem, data singleton)"))
    flush()

    -- Step 2: the unproven reads, on the smallest sample.
    local hotRecords = hotSection(say, subsystem)
    flush()

    -- Step 3: the cheapest, highest-value data, safely on disk before the walk.
    settingsAssetSection(say, subsystem, not hotOnly)
    flush()

    if hotOnly then
        settingsTallySection(say, hotRecords, false)
        say("")
        say(" (F8 -- hot only. F7 dumps every registered component.)")
    else
        local rawHandle, rawPath = openOut(RAW_FILE, "a")
        if rawHandle == nil then
            -- Said BEFORE the walk and flushed, so it survives whatever the
            -- walk does. "the raw dump ran" and "the raw dump never ran" must
            -- not look identical (crash rule H).
            say("")
            say(" WARNING: " .. RAW_FILE .. " could not be opened in either")
            say(" location. NO per-component detail will be written this run --")
            say(" the grouped view below is all there is, and it shows at most "
                .. MAX_EXAMPLES .. " names per configuration.")
            log("WARNING: could not open " .. RAW_FILE .. "; no per-component detail")
        end
        local function rawSay(text)
            if rawHandle == nil then return end
            if text == nil then
                pcall(function() rawHandle:flush() end)
                return
            end
            pcall(function() rawHandle:write(text, "\n") end)
        end
        rawSay(string.format("\n======== run %d   %s   %s ========",
            runCounter, VERSION, os.date("%Y-%m-%d %H:%M:%S")))

        local total = count(get(subsystem, PROP.registered))
        log("reading " .. (total >= 0 and tostring(total) or "an unknown number of")
            .. " registered entries (~40ms measured; the report prints the"
            .. " real figure for this run)")
        flush()

        -- Step 4: the big walk.
        local records = registeredSection(say, rawSay, subsystem)
        flush()

        if rawHandle ~= nil then
            pcall(function() rawHandle:close() end)
            say(" per-component detail written to " .. rawPath)
        end

        -- Step 5: everything that needs the whole population.
        settingsTallySection(say, records, true)
        flush()
        candidateSection(say, records)
        flush()
        totalsSection(say, records)
    end

    finish()
end

-- ==========================================================================
-- The pump (crash rule K, RE-UE4SS #1180).
--
-- process_simple_actions drains the engine-tick action vector with erase_if
-- under a RECURSIVE mutex, so an ExecuteInGameThread or ExecuteWithDelay issued
-- from inside a drained callback appends mid-iteration and corrupts the stored
-- Lua registry refs -- "Abort signal received", or "Ref was not function", at
-- random, worst on a slow or unfocused machine.
--
-- So: exactly one ExecuteInGameThread in the whole file, made from a LoopAsync
-- thread. No ExecuteWithDelay anywhere.
--
-- `inFlight` is cleared at the END of the callback, not the start. The full
-- pass is seconds of game-thread work, and clearing it early would let the
-- LoopAsync thread keep appending to the action vector for the whole of that --
-- a concurrent append while the drain is in progress, which is #1180 arriving
-- from the other side.
--
-- Presses that land DURING a run are dropped rather than queued: the flags are
-- cleared again after report() returns, so mashing the key cannot stack a
-- second multi-second stall behind the first.
--
-- Keybind callbacks do not run on the game thread either, so they do no work at
-- all -- they set a flag and the pump does every read.
-- ==========================================================================

local pendingFull = false
local pendingHot  = false
local inFlight    = false
local pumpAlive   = false

local pumpStarted = pcall(function()
    LoopAsync(PUMP_MS, function()
        if inFlight then return false end
        inFlight = true
        ExecuteInGameThread(function()
            if not pumpAlive then
                pumpAlive = true
                diag("pump alive -- the game thread is reaching us")
            end

            local wantFull, wantHot = pendingFull, pendingHot
            pendingFull, pendingHot = false, false

            if wantFull or wantHot then
                local ok, err = pcall(function() report(not wantFull) end)
                if not ok then log("report error: " .. tostring(err)) end
                -- Anything pressed while that ran is dropped, not queued.
                pendingFull, pendingHot = false, false
            end

            inFlight = false
        end)
        return false
    end)
end)

local boundFull = pcall(function()
    RegisterKeyBind(KEY_FULL, function() pendingFull = true end)
end)
local boundHot = pcall(function()
    RegisterKeyBind(KEY_HOT, function() pendingHot = true end)
end)

diag("---- " .. MOD .. " " .. VERSION .. " loaded ----")
log("loaded. Read-only: it writes text files and changes nothing in the game.")
if not pumpStarted then
    log("FATAL: LoopAsync did not start. The keys are registered but NOTHING")
    log("WILL EVER RUN. Report this -- do not wait for a report file.")
end
if boundFull then
    log("F7  full report -> " .. REPORT_FILE .. " (+ " .. RAW_FILE .. ")."
        .. " Costs about one frame (~40ms measured).")
else
    log("F7 could not be registered -- no full report available")
end
if boundHot then
    log("F8  hot only, safe any time including in a lobby")
else
    log("F8 could not be registered -- no hot-only report available")
end
log("if only ONE of those two key lines appeared, the other RegisterKeyBind"
    .. " was rejected -- report that rather than 'the probe does nothing'.")
