--[[
    BetterInteractionReplay -- can Lua re-issue an interact, and can one press
    pay a whole deposit at once?

    ###################################################################
    #  THIS IS THE FIRST THING IN THIS PROJECT THAT IS NOT READ-ONLY. #
    #  F10 PERFORMS A REAL INTERACTION. It spends real money and      #
    #  moves real machines, in whatever save you are in.              #
    #  SOLO ONLY. It refuses to fire if anyone else is in the lobby.  #
    ###################################################################

    WHY IT EXISTS
    -------------
    Phase 0 established the target: deposit loops cost more than one press for
    something you can already afford. The upgrade machine is 100 gold at 20 a
    press, so five. The elevator takes 5 a press against a price that varies by
    destination -- 40, 60 or 100 -- so eight, twelve or twenty presses. (An
    earlier draft said 50, having read AHeldenElevatorMachine.ReturnCost, which
    is the RETURN trip and never varies. The live descent price is
    RemainingCost, 0x638.)

    ESTABLISHED 29 Aug 2026, and the reason method C exists: the game takes a
    FIXED amount per press. Wallet 36 gold against 40 owed took exactly 5, twice.
    It does not pay as much as it can.

    THE THREE METHODS
    -----------------
    Every signature read out of the 5.7.4 dump; none is guessed.

      A  HeldenPlayerController:Interact_Server(APawn*, UInteractionComponent*)
         Helden.hpp:6700. The game's OWN client-to-server interact RPC -- the
         literal call a real keypress makes. PROVEN 29 Aug: -5 gold, machine
         counter 40 -> 35. Co-op bucket 2, local input shaping.

      B  HeldenInteractableObject:Interact(APawn*)
         Helden.hpp:5823. The shared entry point. PROVEN 29 Aug: -5 gold,
         counter 35 -> 30. Also bucket 2.

      C  Pay as much as you can afford in ONE press.
         Writes AHeldenCoinDepositObject.RequiredMoney (0x4A8) to
         min(owed, wallet), fires A, then restores the original value.

         *** CO-OP BUCKET 3. *** Unlike A and B this WRITES a property on a game
         actor. On host/solo that write is authoritative and works. On a GUEST it
         would be local-only -- the server would still take the original amount
         while your prompt showed the new one, which is the "reads as the mod
         being broken" failure CLAUDE.md's co-op section describes. That is why
         this probe is solo-only, and why bucket is the open question for the
         real feature rather than whether the write lands.

         NOT A CHEAT, by CLAUDE.md's own test: the TOTAL paid is unchanged --
         still 40 gold for a 40 gold elevator. Only the chunk size moves. That is
         effort, not result. The prohibited InteractCost change alters the PRICE;
         this does not.

         The restore is DEFERRED by RESTORE_TICKS rather than immediate, because
         the deduction arrives through the server path between +300ms and +1s,
         and putting the value back in the same tick could undo it before
         anything reads it. It is serviced by the pump unconditionally, so a
         failure anywhere else still puts the value back, and it re-finds the
         deposit BY NAME rather than holding a pointer across ticks.

    DELIBERATELY NOT TESTED: HeldenCharacter:InteractObjectEvent_Server(uint8).
    The signature is known but the ENUM IS NOT -- nothing in the dump says what
    the byte means, and firing a server RPC with a guessed value is not something
    this probe should do.

    HOW IT MEASURES SUCCESS
    -----------------------
    "The call did not raise" is not evidence that anything happened. So each
    fire brackets an OBSERVABLE and reports the delta:

      AHeldenCharacter.Money        (FHeldenMoney, 0x1250) -- your wallet
      <machine>.CoinsLeftToPay      gumball / upgrade machine
      <machine>.RemainingCost       elevator machine

    Money is the decisive one -- it is on YOUR pawn, so it moves whatever the
    target turns out to be. Fire once at the elevator deposit and gold should
    drop by exactly 5. The after-readings are taken on LATER PUMP TICKS (+~300ms
    and +~1s) because even solo the change goes through the server path and is
    not visible in the same frame.

    HOW IT KNOWS WHAT YOU ARE LOOKING AT
    ------------------------------------
    Corrected 29 Aug 2026. The first version used
    AHeldenCharacter.CurrentInteraction, and it is ALWAYS EMPTY when you are
    merely aimed at something -- four status reports in a row, no fire. It is
    replicated and has an OnRep_, so it is almost certainly the interaction IN
    PROGRESS rather than the one under the crosshair.

    The real focus signal is the per-interactable prompt widget:

        UInteractionComponent.InteractionWidgetComponent   (UWidgetComponent)
          -> .Widget                                       (UMG.hpp:2376)
            -> .InteractState                              (Focused = 2)

    reached by walking the subsystem's HotInteractions. All property walks off
    objects already in hand. CurrentInteraction is still tried first, because
    during a hold it is the most direct answer there is, and the report always
    says WHICH source answered.

    SAFETY GATES. Every one must pass or it refuses and says which failed.
      1. SOLO. GameState.PlayerArray must hold exactly one player, and the local
         controller must have authority. Anything else refuses.
      2. A local controller and a possessed pawn must exist.
      3. Something must actually be focused. It never picks a target for you.
      4. MAX_FIRES per session, then it refuses for the rest of the session.
      5. ONE call per keypress. No loop, no auto-repeat, no hold -- method C
         gets its effect from the amount, not from repeating.
      6. Method C additionally refuses unless there is a PLAN: a deposit with a
         single-resource RequiredMoney, a readable owed amount, and more owed
         than one press covers. F9 prints the plan in full before you can fire
         it, and it never writes more than min(owed, wallet).
      7. Method C refuses while a restore is still pending, so a second fire
         cannot capture the MODIFIED value as the original.

    KEYS
    ----
      F9    READ-ONLY. Cycle the armed method, report every gate, and SURVEY
            every interactable the game says is in range with its
            InteractState. Press this first, and as often as you like.
      F10   FIRE ONE CALL of the armed method. This is the one that acts.

    THE REPORT FILE IS THE INSTRUMENT, NOT THE CONSOLE. Every F9 appends the
    full status -- READY or BLOCKED, and why -- to BetterInteraction_replay.txt.
    You do not need a UE4SS console to run this; you need that file.

    SCHEDULING (crash rule K, RE-UE4SS #1180)
    -----------------------------------------
    One LoopAsync, one ExecuteInGameThread, no ExecuteWithDelay. The delayed
    after-readings are counted in PUMP TICKS through our own queue, never
    scheduled through UE4SS. Keybinds set a flag and do nothing else.

    OUTPUT   BetterInteraction_replay.txt   the report, appended
             BetterInteraction_replay.log   flushed forensics
]]

local MOD     = "BetterInteractionReplay"
local VERSION = "replay-10"

-- ==========================================================================
-- Version-fragile names, in one place. All read out of the 5.7.4 dump.
-- ==========================================================================

local CLASS = {
    controller = "HeldenPlayerController",
    gameState  = "HeldenGameState",
    subsystem  = "HeldenInteractionSubsystem",
}

local PROP = {
    pawn        = "Pawn",                  -- AController 0x2F0
    current     = "CurrentInteraction",    -- AHeldenCharacter 0xBB0, TWeakObjectPtr<AActor>
    interactCmp = "InteractComponent",     -- AHeldenInteractableObject 0x420
    money       = "Money",                 -- AHeldenCharacter 0x1250, FHeldenMoney
    coinsLeft   = "CoinsLeftToPay",        -- AHeldenGumballMachine 0x4A0 / AHeldenUpgradeMachine 0x630
    remaining   = "RemainingCost",         -- AHeldenElevatorMachine 0x638 -- the LIVE price
    targetObj   = "TargetObject",          -- AHeldenCoinDepositObject 0x488
    required    = "RequiredMoney",         -- AHeldenCoinDepositObject 0x4A8, FHeldenMoney
                                           -- the amount taken PER PRESS
    players     = "PlayerArray",           -- AGameStateBase 0x2C8
    focusTarget = "CurrentInteractTarget", -- AHeldenPlayerController 0xC00.
                                           -- MEASURED 29 Aug 2026: this is NOT
                                           -- "what you are aimed at" -- it is
                                           -- "the interact the game has
                                           -- ACCEPTED". It appears on the
                                           -- accepted press and clears on
                                           -- completion, so non-empty means a
                                           -- hold is RUNNING.
    holdOn      = "bIsHoldInteraction",    -- UInteractionComponent 0x318
    running     = "CurrentInteraction",    -- AHeldenCharacter 0xBB0. Non-empty
                                           -- means an interaction actually
                                           -- STARTED. Empty while merely aimed.
    hot         = "HotInteractions",       -- UHeldenInteractionSubsystem 0x58
    widgetCmp   = "InteractionWidgetComponent", -- UInteractionComponent 0x330, UWidgetComponent
    widget      = "Widget",                -- UWidgetComponent 0x6A8 (UMG.hpp:2376)
    state       = "InteractState",         -- UInteractionWidget 0x338, EHeldenInteractState
}

-- EHeldenInteractState, Helden_enums.hpp:893
local STATE = { [0] = "Hidden", [1] = "ProximityRange", [2] = "Focused" }
local STATE_FOCUSED = 2

-- ==========================================================================
-- Tunables
-- ==========================================================================

local PUMP_MS    = 100
local MAX_FIRES  = 20    -- per session. Then it refuses, loudly.
local CHECK_TICKS = { 3, 10 }   -- after-readings, in pump ticks (~300ms, ~1s)
local RESTORE_RETRY_TICKS  = 5  -- ~0.5s between restore attempts
local RESTORE_MAX_ATTEMPTS = 20 -- ~10s of trying before giving up loudly
local RESTORE_TICKS = 15        -- ~1.5s: after both readings, so the restore
                                -- cannot undo the write before the server has
                                -- read it, and before the next press can use it

local REPORT_FILE = "BetterInteraction_replay.txt"
local DIAG_FILE   = "BetterInteraction_replay.log"

local KEY_CYCLE = Key.F9     -- F9  read-only
local KEY_FIRE  = Key.F10    -- F10 acts
-- Bare function keys, no modifier: a standing preference for every probe in
-- this project. NOTE that this makes F10 -- the key that performs a real
-- interaction -- easier to hit by accident than it was as ALT+F10. The gates
-- are what stop that mattering: it cannot fire unless you are solo, something
-- is genuinely focused, and the session cap is not spent. It also never
-- repeats: one press is one call.

-- ==========================================================================
-- Output
-- ==========================================================================

local diagHandle = nil
local outputDir  = "Helden\\Binaries\\Win64"

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
        diagHandle = openOut(DIAG_FILE, "a") or false
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

local lines = {}
local function say(text) lines[#lines + 1] = text end

local function writeReport()
    if #lines == 0 then return end
    local handle, path = openOut(REPORT_FILE, "a")
    if handle == nil then
        for _, line in ipairs(lines) do print(line .. "\n") end
        lines = {}
        return
    end
    pcall(function()
        handle:write(table.concat(lines, "\n") .. "\n")
        handle:close()
    end)
    diag("report appended to " .. path)
    lines = {}
end

-- ==========================================================================
-- Null-wrapper primitives (crash rule A). IsValid() is never used: it
-- dereferences, so on a freed object it is the crash rather than a test (B).
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

local function count(array)
    local n = nil
    local ok = pcall(function() n = array:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    ok = pcall(function() n = #array end)
    if ok and type(n) == "number" then return n end
    return -1
end

--- FHeldenMoney is three plain int32s (Helden.hpp:2366) -- no pointer, no
--- TArray, no FString. Read IN PLACE off the persistent object, field by field.
--- Never through a by-value getter, which is the documented hard crash here.
local function money(object, property)
    -- ALL OR NOTHING, deliberately. Two things were wrong before:
    --   * `if block == nil` is the banned null-wrapper test one level down --
    --     get() answers with a wrapper for a property the class lacks, so that
    --     guard never fired and the field reads below carried the function.
    --   * returning a table when only SOME fields read fabricated zeros for the
    --     rest. That value becomes plan.old, becomes pendingRestore.old, and is
    --     written back field-by-field -- permanently zeroing whatever did not
    --     read, on a live game actor, while the report said "(verified)".
    -- If it is not three numbers it is not an FHeldenMoney we may touch.
    local block = get(object, property)
    local s, g, a = nil, nil, nil
    pcall(function() s = block.Scraps end)
    pcall(function() g = block.Gold end)
    pcall(function() a = block.Artifacts end)
    if type(s) ~= "number" or type(g) ~= "number" or type(a) ~= "number" then
        return nil
    end
    return { scraps = s, gold = g, artifacts = a }
end

local function moneyStr(value)
    if value == nil then return "unreadable" end
    return string.format("%dS/%dG/%dA", value.scraps, value.gold, value.artifacts)
end

--- Write an `FHeldenMoney` IN PLACE, field by field, off the persistent object.
--- Three plain int32s -- the same in-place struct-member write LetMeLook proves
--- for an FVector2D. Never through a by-value getter.
local function writeMoney(object, property, value)
    local block = get(object, property)
    if block == nil then return false end
    local ok = true
    if not pcall(function() block.Scraps = value.scraps end) then ok = false end
    if not pcall(function() block.Gold = value.gold end) then ok = false end
    if not pcall(function() block.Artifacts = value.artifacts end) then ok = false end
    return ok
end

--- A property read that must be a NUMBER, or nil. Never `get(...) ~= nil`.
---
--- Crash rule A applied to property reads, which is where it bit: `get()`
--- answers with a WRAPPER for a property the class does not have, and a wrapper
--- is not nil. So `get(o, "CoinsLeftToPay") ~= nil` was true for a mallet, a
--- soul pawn and a roof hatch, the focused deposit won the counter search on
--- that false positive, and method C then refused with "nothing in range
--- reports how much is still owed" while the elevator machine stood next to it
--- holding RemainingCost. The type IS the test.
local function boolProp(object, property)
    local value = get(object, property)
    if type(value) ~= "boolean" then return nil end
    return value
end

local function numberProp(object, property)
    local value = get(object, property)
    if type(value) ~= "number" then return nil end
    return value
end

local function sameMoney(a, b)
    if a == nil or b == nil then return false end
    return a.scraps == b.scraps and a.gold == b.gold and a.artifacts == b.artifacts
end

--- Which single resource a cost is denominated in. Returns the key and the
--- amount, or nil when the cost spans more than one -- that case is refused
--- rather than guessed at.
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

local function moneyDelta(before, after)
    if before == nil or after == nil then return "unreadable" end
    local ds = after.scraps - before.scraps
    local dg = after.gold - before.gold
    local da = after.artifacts - before.artifacts
    if ds == 0 and dg == 0 and da == 0 then return "NO CHANGE" end
    return string.format("%+dS/%+dG/%+dA", ds, dg, da)
end

-- ==========================================================================
-- Resolution. Two global array walks per keypress, never on a timer (rule E).
-- ==========================================================================

local function findFirst(class)
    local found = nil
    pcall(function() found = FindFirstOf(class) end)
    if not real(found) then return nil end
    if fullName(found):find("Default__", 1, true) ~= nil then return nil end
    return found
end

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

--- What the game itself thinks you are looking at.
---
--- `AHeldenCharacter.CurrentInteraction` was the first attempt and it is ALWAYS
--- EMPTY when you are merely aimed at something -- measured 29 Aug 2026, four
--- status reports in a row. It is replicated and has an `OnRep_`, so it is
--- almost certainly the interaction IN PROGRESS (a hold in flight) rather than
--- the one under the crosshair. Kept as the first choice anyway, because during
--- a hold it is the most direct answer available.
---
--- The real focus signal is the per-interactable prompt widget:
---     UInteractionComponent.InteractionWidgetComponent  (UWidgetComponent)
---       -> .Widget                                      (UMG.hpp:2376)
---         -> .InteractState                             (Focused = 2)
--- reached by walking the subsystem's HotInteractions -- all property walks off
--- objects already in hand, no extra global scan beyond the subsystem itself.
---
--- Returns the focused component, plus the full survey so F9 can SHOW every
--- hot interactable and its state. Without that survey a refusal reads as "the
--- probe is broken"; with it, you can see the game reporting Hidden or
--- ProximityRange for the thing you thought you were aimed at.
local function surveyHot(subsystem)
    local rows, focused = {}, nil
    if subsystem == nil then return rows, nil end
    local array = get(subsystem, PROP.hot)
    -- `array == nil` would be the banned null-wrapper test. If the property
    -- moves in a game patch, ForEach raises inside the pcall and the caller
    -- must be able to tell that from "nothing is in range" (crash rule H).
    local walked = pcall(function()
        array:ForEach(function(_index, element)
            local component = nil
            local ok = pcall(function() component = element:get() end)
            if not ok or not real(component) then return end

            local state = nil
            local widgetComponent = get(component, PROP.widgetCmp)
            if real(widgetComponent) then
                local widget = get(widgetComponent, PROP.widget)
                if real(widget) then state = get(widget, PROP.state) end
            end

            local owner = nil
            pcall(function() owner = component:GetOwner() end)
            local row = {
                component = component,
                owner = real(owner) and owner or nil,
                ownerClass = real(owner) and className(owner) or "?",
                ownerName = real(owner) and shortName(fullName(owner))
                    or shortName(fullName(component)),
                state = state,
                stateName = (type(state) == "number" and STATE[state])
                    or (state == nil and "no widget" or "?"),
            }
            rows[#rows + 1] = row
            if state == STATE_FOCUSED and focused == nil then focused = row end
        end)
    end)
    return rows, focused, walked
end

--- Actors whose restore never verified. Method C refuses to plan against these:
--- their RequiredMoney is modified, so a fresh plan would capture the MODIFIED
--- value as plan.old and "restore" the wrong number permanently.
---
--- DECLARED HERE, ABOVE resolve(), because resolve() reads it. Declared with the
--- other state below, it was a nil global at the point of use and would have
--- raised on the first method-C plan -- the same ordering trap that forced the
--- METHODS table down the file, in a second place.
local restoreFailed = {}

--- Resolve everything, and report WHY if anything is missing. Returns a context
--- table plus a list of gate failures -- never a half-built context with a
--- silent hole in it (crash rule H).
---
--- `needFocus = false` skips the focus gate and everything downstream of it.
--- The after-the-fire readings use that form, because a successful interact
--- DROPS focus for a moment: on 29 Aug 2026 fire 1's +300ms reading was lost to
--- "nothing is focused", which is a true statement about a question the watch
--- was not asking. The watch needs the pawn and the counters, not a target.
---
--- It still re-resolves from scratch every call rather than holding pointers
--- across ticks (crash rule C) -- a rescan is a race, a stale pointer is a
--- certainty.
local function resolve(needFocus)
    if needFocus == nil then needFocus = true end
    local ctx, blocked = {}, {}

    ctx.controller = localController()
    if ctx.controller == nil then
        blocked[#blocked + 1] = "no local " .. CLASS.controller
            .. " (menu, or a level transition)"
        return ctx, blocked
    end

    -- GATE 1: SOLO. Two independent conditions, both required.
    local authority = nil
    pcall(function() authority = ctx.controller:HasAuthority() end)
    ctx.authority = authority
    if authority ~= true then
        blocked[#blocked + 1] = "this machine is NOT the authority"
            .. " (HasAuthority=" .. tostring(authority) .. ") -- you are a guest"
    end

    local gameState = findFirst(CLASS.gameState)
    if gameState == nil then
        blocked[#blocked + 1] = CLASS.gameState .. " did not resolve, so the"
            .. " player count cannot be checked. Refusing rather than guessing."
    else
        local players = get(gameState, PROP.players)
        ctx.playerCount = (players ~= nil) and count(players) or -1
        if ctx.playerCount ~= 1 then
            blocked[#blocked + 1] = string.format(
                "%s holds %s players -- SOLO ONLY", PROP.players,
                ctx.playerCount >= 0 and tostring(ctx.playerCount) or "an unreadable number")
        end
    end

    -- GATE 2: a possessed pawn.
    ctx.pawn = get(ctx.controller, PROP.pawn)
    if not real(ctx.pawn) then
        blocked[#blocked + 1] = "no possessed pawn on the local controller"
        return ctx, blocked
    end
    ctx.pawnClass = className(ctx.pawn)

    -- GATE 3: something is actually focused. The probe never picks for you.
    -- Two sources, tried in order, and the report always says which one answered.
    local current = get(ctx.pawn, PROP.current)
    -- A TWeakObjectPtr may arrive already dereferenced or as a wrapper needing
    -- :Get(); try the direct form first and fall back rather than assuming.
    if not real(current) then
        local inner = nil
        pcall(function() inner = current:Get() end)
        if real(inner) then current = inner end
    end

    ctx.subsystem = findFirst(CLASS.subsystem)
    ctx.hotRows, ctx.focusedRow, ctx.hotWalked = surveyHot(ctx.subsystem)

    if real(current) then
        ctx.via = PROP.current .. " (an interaction in progress)"
        ctx.target = current
        ctx.component = get(current, PROP.interactCmp)
    elseif ctx.focusedRow ~= nil then
        ctx.via = "the prompt widget reporting InteractState=Focused"
        ctx.target = ctx.focusedRow.owner
        ctx.component = ctx.focusedRow.component
    elseif needFocus then
        blocked[#blocked + 1] = string.format(
            "nothing is focused. %s is empty and none of the %d hot"
            .. " interactables reports InteractState=Focused. Stand closer and"
            .. " look straight at it -- the survey below shows what the game"
            .. " thinks is in range.", PROP.current, #ctx.hotRows)
        return ctx, blocked
    end

    if not real(ctx.component) then ctx.component = nil end
    if not real(ctx.target) then
        -- Method B needs the actor; method A only needs the component, so this
        -- is not fatal on its own and is reported rather than assumed away.
        ctx.target = nil
        ctx.targetClass = "<no owning actor>"
        ctx.targetName = ctx.component ~= nil and fullName(ctx.component) or ""
    else
        ctx.targetClass = className(ctx.target)
        ctx.targetName = fullName(ctx.target)
    end

    -- WHICH OBJECT CARRIES THE COUNTER.
    --
    -- Measured 29 Aug 2026: aiming at BP_HeldenElevator_CoinDeposit_C reported
    -- CoinsLeftToPay = n/a and RemainingCost = n/a, because the deposit object
    -- carries neither -- the machine does -- and the TargetObject hop did not
    -- reach it. So the probe fired twice while watching nothing that could
    -- move, which is worse than not firing.
    --
    -- Three sources now, in order, and the report says which one answered:
    --   1. the focused actor itself
    --   2. its TargetObject
    --   3. ANY actor in range that has one -- the elevator machine sits in the
    --      hot list at ProximityRange while you aim at its deposit
    --- Does this actor actually hold a readable counter? The type is the test:
    --- `get(...) ~= nil` was true for everything in range (see numberProp).
    local function carriesCounter(object)
        if not real(object) then return false end
        return numberProp(object, PROP.coinsLeft) ~= nil
            or numberProp(object, PROP.remaining) ~= nil
    end

    ctx.counterHolder, ctx.counterVia = nil, nil
    if carriesCounter(ctx.target) then
        ctx.counterHolder, ctx.counterVia = ctx.target, "the focused actor"
    elseif real(ctx.target) and carriesCounter(get(ctx.target, PROP.targetObj)) then
        ctx.counterHolder = get(ctx.target, PROP.targetObj)
        ctx.counterVia = "the focused actor's " .. PROP.targetObj
    else
        for _, row in ipairs(ctx.hotRows) do
            if carriesCounter(row.owner) then
                ctx.counterHolder = row.owner
                ctx.counterVia = "a counter-carrying actor in range (" .. row.ownerClass .. ")"
                break
            end
        end
    end

    -- Every counter in range, not just one. If the guess about which object
    -- matters is wrong again, a delta anywhere still shows up.
    ctx.counters = {}
    for _, row in ipairs(ctx.hotRows) do
        if carriesCounter(row.owner) then
            ctx.counters[#ctx.counters + 1] = {
                label = row.ownerClass .. " " .. row.ownerName,
                owner = row.owner,
            }
        end
    end

    -- CAN ANYTHING MOVE? A fire whose observables are all zero or unreadable
    -- proves nothing either way, and a NO CHANGE result would read in the
    -- report as "the call failed" when it means "nothing was watched".
    local wallet = money(ctx.pawn, PROP.money)
    local broke = (wallet == nil)
        or (wallet.scraps == 0 and wallet.gold == 0 and wallet.artifacts == 0)
    -- A fire is only uninformative if NOTHING can move. The interaction
    -- pointers move for any interaction, deposit or not, so they count.
    ctx.uninformative = broke and #ctx.counters == 0
        and not (real(ctx.component) or real(ctx.target))
    ctx.broke = broke
    ctx.wallet = wallet

    -- ---------------------------------------------------------------------
    -- THE PLAN for method C: pay as much as possible in ONE press.
    --
    -- The game takes a FIXED amount per press -- measured 29 Aug 2026, wallet
    -- 36 gold against 40 owed took exactly 5, not 36. So "one press pays what
    -- you can afford" means changing RequiredMoney to min(owed, wallet) for the
    -- duration of a single interact, then putting it back.
    --
    -- The TOTAL paid is unchanged; only the chunk size moves. That is the
    -- CLAUDE.md test for QoL-versus-cheat -- effort, not result -- and it is
    -- why this is not the prohibited InteractCost change.
    -- ---------------------------------------------------------------------
    ctx.plan, ctx.planWhy = nil, nil
    local deposit = nil
    local required = real(ctx.target) and money(ctx.target, PROP.required) or nil
    if required ~= nil then deposit = ctx.target end

    if deposit ~= nil and restoreFailed[fullName(deposit)] ~= nil then
        ctx.planWhy = "this deposit's " .. PROP.required .. " could not be"
            .. " restored earlier and is still modified (original was "
            .. restoreFailed[fullName(deposit)] .. "). Refusing rather than"
            .. " capturing that as a new original. Restart the game to clear it."
        deposit = nil
    elseif deposit == nil then
        ctx.planWhy = "the focused actor carries no readable " .. PROP.required
            .. " -- aim at a coin deposit"
    else
        local resource, perPress = soleResource(required)

        -- THE OWED AMOUNT MUST COME FROM *THIS DEPOSIT'S* MACHINE.
        --
        -- ctx.counterHolder has a third fallback -- "any counter-carrying actor
        -- in range" -- which is fine for the passive ledger and catastrophic
        -- here: with two machines in range it would write one machine's balance
        -- as the other machine's per-press cost, and that is a real money write.
        -- The dump gives the actual association: AHeldenCoinDepositObject
        -- .TargetObject (0x488) is the object this deposit feeds. Nothing else
        -- is allowed to answer.
        local machine = get(deposit, PROP.targetObj)
        local owed = nil
        if real(machine) then
            owed = numberProp(machine, PROP.remaining)
                or numberProp(machine, PROP.coinsLeft)
        end
        ctx.planMachine = real(machine) and machine or nil

        if resource == nil then
            ctx.planWhy = PROP.required .. " is " .. moneyStr(required)
                .. " -- not a single resource, refusing to guess which to scale"
        elseif owed == nil then
            ctx.planWhy = "this deposit's " .. PROP.targetObj .. " does not report"
                .. " a counter, so how much is still owed is unknown. Refusing"
                .. " rather than borrowing a number from another actor in range."
        elseif wallet == nil then
            ctx.planWhy = "your money did not read"
        else
            local affordable = wallet[resource]
            local amount = (owed < affordable) and owed or affordable
            if amount <= 0 then
                ctx.planWhy = string.format(
                    "nothing to pay: owed=%d, you have %d %s", owed, affordable, resource)
            elseif amount <= perPress then
                ctx.planWhy = string.format(
                    "one press already covers it: %d owed / %d affordable is not"
                    .. " more than the %d it takes per press", owed, affordable, perPress)
            else
                local new = { scraps = required.scraps, gold = required.gold,
                              artifacts = required.artifacts }
                new[resource] = amount
                ctx.deposit = deposit
                ctx.depositName = fullName(deposit)
                ctx.plan = {
                    old = required, new = new, resource = resource,
                    perPress = perPress, owed = owed, affordable = affordable,
                    amount = amount,
                    -- floor, not ceil: a press costs the FULL perPress or does
                    -- not happen, so a final partial press is not one the
                    -- unmodded game could have made and must not be counted.
                    savedPresses = math.floor(amount / perPress) - 1,
                }
            end
        end
    end

    return ctx, blocked
end

--- The observables. Money is the decisive one -- it is on YOUR pawn, so it
--- moves whatever the target turns out to be. The counters are a cross-check.
local function snapshot(ctx)
    local counters = {}
    for _, entry in ipairs(ctx.counters or {}) do
        counters[#counters + 1] = {
            label = entry.label,
            coins = numberProp(entry.owner, PROP.coinsLeft),
            remaining = numberProp(entry.owner, PROP.remaining),
        }
    end
    -- The two interaction pointers. Money and counters are the right
    -- observables for a DEPOSIT and the wrong ones for a chair -- which is why
    -- firing at a chair came back VERDICT: NONE and taught us nothing. These
    -- two move for any interaction, so a hold is now self-observing and the
    -- experiment no longer has to be coordinated across two probes.
    local focusName, runningName = "-", "-"
    if ctx.controller ~= nil then
        local target = get(ctx.controller, PROP.focusTarget)
        if real(target) then focusName = shortName(fullName(target)) end
    end
    if ctx.pawn ~= nil then
        local current = get(ctx.pawn, PROP.running)
        if not real(current) then
            local inner = nil
            pcall(function() inner = current:Get() end)
            if real(inner) then current = inner end
        end
        if real(current) then runningName = shortName(fullName(current)) end
    end

    return {
        money = money(ctx.pawn, PROP.money),
        coins = ctx.counterHolder and numberProp(ctx.counterHolder, PROP.coinsLeft) or nil,
        remaining = ctx.counterHolder and numberProp(ctx.counterHolder, PROP.remaining) or nil,
        counters = counters,
        focusName = focusName,
        runningName = runningName,
    }
end

local function coinsStr(value)
    if type(value) ~= "number" then return "n/a" end
    return tostring(value)
end

-- ==========================================================================
-- State
-- ==========================================================================

local methodIndex = 1
local fires       = 0
local pending     = { cycle = false, fire = false, busy = false }
local watch       = nil    -- { ticksLeft = {...}, before = {...}, ... }
local ticks       = 0

--- WORLD EPOCH (crash rule D). Deferred work must not outlive its world, and
--- this file defers a WRITE. `ticks` is monotonic and says nothing about which
--- world you are in, so a restore scheduled before a level change was still due
--- after it. The epoch is bumped whenever the identity of the world changes,
--- and every deferred job carries the epoch it was scheduled in.
local epoch       = 0
local worldMark   = nil
local everPlayable = false   -- rule F: a FACT, not a timer

--- Called once per pass with the resolved context. Cheap: two strings.
local function trackWorld(ctx)
    local mark = nil
    if ctx ~= nil and ctx.subsystem ~= nil then mark = fullName(ctx.subsystem) end
    if mark ~= nil and mark ~= "" and mark ~= worldMark then
        if worldMark ~= nil then
            epoch = epoch + 1
            diag("world changed (" .. tostring(worldMark) .. " -> " .. mark
                .. "); epoch is now " .. epoch)
        end
        worldMark = mark
    end
    if ctx ~= nil and ctx.pawn ~= nil and ctx.controller ~= nil then
        everPlayable = true
    end
end

--- Set by method C before it fires and serviced by the pump: the value to
--- put back, and when. Held as a NAME plus a value, never as a UObject
--- pointer, so the restore re-resolves rather than dereferencing something
--- that may have gone away (crash rule C).
local pendingRestore = nil

-- ==========================================================================
-- The two calls we are testing, plus the one that pays it all at once.
--
-- DECLARED HERE, BELOW THE HELPERS, ON PURPOSE. These closures call diag(),
-- money(), writeMoney(), sameMoney() and read `ticks` and `pendingRestore`.
-- A Lua closure that names a local declared LATER in the file resolves it as
-- a global -- that is, nil -- and the failure is silent. Moving this table
-- above any of them would break method C without a syntax error.
-- ==========================================================================
--- The candidates, in the order F9 cycles them. `call` receives the
--- resolved context and performs EXACTLY ONE invocation.
local METHODS = {
    {
        name = "A  PlayerController:Interact_Server(pawn, component)",
        note = "the game's own client-to-server interact RPC (Helden.hpp:6700)",
        needsComponent = true,
        call = function(ctx)
            ctx.controller:Interact_Server(ctx.pawn, ctx.component)
        end,
    },
    {
        name = "B  InteractableObject:Interact(pawn)",
        note = "the shared entry point, proven hookable (Helden.hpp:5823)",
        needsComponent = false,
        needsTarget = true,
        call = function(ctx)
            ctx.target:Interact(ctx.pawn)
        end,
    },
    {
        name = "C  pay as much as you can afford in ONE press",
        note = "WRITES RequiredMoney, fires Interact_Server, then restores it."
            .. " CO-OP BUCKET 3 -- unlike A and B this changes a property on a"
            .. " game actor, so it is host/solo only by nature.",
        needsComponent = true,
        needsPlan = true,
        call = function(ctx)
            local plan = ctx.plan

            -- Flushed BEFORE the write, so if the process dies here the log
            -- carries the original value to put back by hand (crash rule J).
            diag(string.format("WRITING %s on %s: %s -> %s (restoring in %d ticks)",
                PROP.required, ctx.depositName, moneyStr(plan.old),
                moneyStr(plan.new), RESTORE_TICKS))

            -- ARM THE RESTORE BEFORE THE FIRST FIELD IS TOUCHED.
            --
            -- writeMoney assigns three int32s under three separate pcalls, so
            -- "it returned false" and "it wrote nothing" are different
            -- statements. Arming afterwards left a window in which a partial
            -- write had landed with no rollback and nothing scheduled to undo
            -- it -- and because the next-fire gate keys off pendingRestore,
            -- that fire would then have captured the MODIFIED value as the
            -- original. Arming first is idempotent (the restore writes plan.old,
            -- which equals the current value if nothing changed) and closes
            -- every failure path between here and the RPC in one move.
            pendingRestore = {
                name = ctx.depositName,
                old = plan.old,
                due = ticks + RESTORE_TICKS,
                label = moneyStr(plan.old),
                epoch = epoch,
                touched = false,
            }

            local wrote = writeMoney(ctx.deposit, PROP.required, plan.new)
            pendingRestore.touched = true
            if not wrote then
                error({ stage = "write",
                        message = "the " .. PROP.required .. " write raised"
                            .. " part-way; the restore is armed and will run" })
            end
            local readback = money(ctx.deposit, PROP.required)
            if not sameMoney(readback, plan.new) then
                -- The write did not take. Do NOT fire -- firing now would just
                -- be method A with extra steps and would look like a success.
                -- The armed restore puts the value back; no inline rollback,
                -- because an unverified inline rollback was its own silent hole.
                error({ stage = "write",
                        message = string.format(
                            "the write did not take: readback %s, wanted %s."
                            .. " The interact was NOT fired; the restore is armed",
                            moneyStr(readback), moneyStr(plan.new)) })
            end

            ctx.controller:Interact_Server(ctx.pawn, ctx.component)
        end,
    },
}

-- ==========================================================================
-- F9 -- read-only status
-- ==========================================================================

local function status()
    local ctx, blocked = resolve()
    local method = METHODS[methodIndex]

    say("")
    say("================================================================")
    say(string.format(" %s %s   ARMED: %s   %s", MOD, VERSION, method.name,
        os.date("%Y-%m-%d %H:%M:%S")))
    say("================================================================")
    say("  " .. method.note)
    say(string.format("  fires used                 %d of %d", fires, MAX_FIRES))
    say(string.format("  authority                  %s", tostring(ctx.authority)))
    say(string.format("  players in lobby           %s",
        ctx.playerCount and tostring(ctx.playerCount) or "?"))
    if ctx.pawn ~= nil then
        say("  your pawn                  " .. tostring(ctx.pawnClass))
        say("  your money                 " .. moneyStr(money(ctx.pawn, PROP.money)))
    end
    if ctx.via ~= nil then
        say("  focus found via            " .. ctx.via)
        say("  focused target             " .. tostring(ctx.targetClass)
            .. "  " .. shortName(ctx.targetName))
        say("  its InteractComponent      "
            .. (ctx.component ~= nil and "present" or "MISSING -- method A cannot run"))
        if ctx.counterHolder ~= nil then
            say("  counter found via          " .. tostring(ctx.counterVia))
            say("  counter holder             " .. shortName(fullName(ctx.counterHolder)))
            say("  CoinsLeftToPay             " .. coinsStr(numberProp(ctx.counterHolder, PROP.coinsLeft)))
            say("  RemainingCost              " .. coinsStr(numberProp(ctx.counterHolder, PROP.remaining)))
        else
            say("  counter holder             none in range carries CoinsLeftToPay")
            say("                             or RemainingCost")
        end
        say(string.format("  counters watched           %d", #(ctx.counters or {})))
    end

    -- What method C would do, spelled out in full BEFORE you can fire it.
    if method.needsPlan then
        say("")
        if ctx.plan == nil then
            say("  PLAN: none -- " .. tostring(ctx.planWhy))
        else
            local plan = ctx.plan
            say(string.format("  PLAN: pay %d %s in ONE press instead of %d",
                plan.amount, plan.resource, plan.perPress))
            say(string.format("        owed %d, you can afford %d, so it takes %d",
                plan.owed, plan.affordable, plan.amount))
            say(string.format("        %s  %s -> %s, then restored after %.1fs",
                PROP.required, moneyStr(plan.old), moneyStr(plan.new),
                RESTORE_TICKS * PUMP_MS / 1000))
            say(string.format("        saves %d press%s", plan.savedPresses,
                plan.savedPresses == 1 and "" or "es"))
            say("        INTENDED: the total paid is unchanged, only the chunk")
            say("        size moves. UNVERIFIED until this fire measures it --")
            say("        whether the machine credits what the deposit charges is")
            say("        exactly what the verdict below settles.")
        end
    end

    -- The READY line must account for the ARMED method's own requirements, not
    -- just the shared gates. It said READY beside "PLAN: none" on 29 Aug, so the
    -- refusal that followed looked like a malfunction rather than the same
    -- reason stated twice.
    local methodBlocked = nil
    if fires >= MAX_FIRES then
        methodBlocked = string.format("the session cap of %d fires is spent"
            .. " -- restart the game to reset", MAX_FIRES)
    elseif method.needsPlan and ctx.plan == nil then
        methodBlocked = "this method needs a plan: " .. tostring(ctx.planWhy)
    elseif method.needsComponent and ctx.component == nil then
        methodBlocked = "this method needs the focused " .. PROP.interactCmp
    elseif method.needsTarget and ctx.target == nil then
        methodBlocked = "this method needs the owning actor"
    elseif pendingRestore ~= nil then
        methodBlocked = "a " .. PROP.required .. " restore is still pending"
    end

    if #blocked == 0 and methodBlocked == nil then
        say("  >>> READY. F10 will fire ONE call and this WILL change the game.")
    else
        say("  >>> BLOCKED -- F10 would refuse:")
        for _, reason in ipairs(blocked) do say("      * " .. reason) end
        if methodBlocked ~= nil then say("      * " .. methodBlocked) end
    end

    -- The lesson from 29 Aug 2026: it fired twice with an empty wallet and no
    -- readable counter, so both NO CHANGE results were meaningless. Say that
    -- BEFORE the fire, not after.
    if ctx.uninformative then
        say("  !!! WARNING: a fire right now would be UNINFORMATIVE.")
        say("      Your money reads all zero and nothing in range carries a")
        say("      counter, so there is no observable that CAN move. A NO CHANGE")
        say("      result would mean 'nothing was watched', not 'the call")
        say("      failed'. Get some coins first, or aim at a machine.")
    elseif ctx.broke then
        say("  !!! NOTE: your money reads all zero, so a deposit would have")
        say("      nothing to spend. The counters below are still watched, so a")
        say("      fire is not wasted -- but money will not move.")
    end

    -- The survey. Without a console this file is the only instrument, so it
    -- always shows what the game thinks is in range and what state each one is
    -- in -- otherwise "nothing is focused" is indistinguishable from a probe
    -- that cannot see anything at all (crash rule H).
    if ctx.hotRows ~= nil then
        say("")
        say(string.format("  -- what the game says is in range: %d interactables --",
            #ctx.hotRows))
        if ctx.subsystem == nil then
            say("     the interaction subsystem did not resolve, so this is empty")
            say("     for a reason that has nothing to do with where you are aimed")
        elseif #ctx.hotRows == 0 then
            say("     nothing at all. Walk closer to something.")
        else
            say(string.format("     %-16s %-40s %s", "state", "owning class", "name"))
            for _, row in ipairs(ctx.hotRows) do
                say(string.format("     %-16s %-40s %s",
                    row.stateName, row.ownerClass, row.ownerName))
            end
            say("     (Focused is the one F10 would act on. If nothing is")
            say("      Focused, the game is not offering you a prompt right now.)")
        end
    end
    writeReport()
    -- One condition, computed once: the console line said READY while the file
    -- said BLOCKED, because this ignored methodBlocked.
    local ready = (#blocked == 0 and methodBlocked == nil)
    log("armed: " .. method.name .. (ready and "  READY" or "  BLOCKED"))
end

-- ==========================================================================
-- F10 -- fire exactly one call
-- ==========================================================================

local function fire()
    local method = METHODS[methodIndex]

    if fires >= MAX_FIRES then
        log("REFUSED: " .. MAX_FIRES .. " fires used this session. Restart the"
            .. " game to reset. This cap exists so a stuck key cannot empty"
            .. " your wallet.")
        say("")
        say(string.format(" REFUSED at %s -- session cap of %d fires reached.",
            os.date("%H:%M:%S"), MAX_FIRES))
        writeReport()
        return
    end

    local ctx, blocked = resolve()
    if #blocked > 0 then
        say("")
        say(string.format(" REFUSED at %s -- %s", os.date("%H:%M:%S"), method.name))
        for _, reason in ipairs(blocked) do say("      * " .. reason) end
        writeReport()
        log("REFUSED: " .. blocked[1])
        return
    end
    if method.needsComponent and ctx.component == nil then
        say("")
        say(" REFUSED -- " .. method.name .. " needs the focused "
            .. PROP.interactCmp .. " and it did not resolve.")
        writeReport()
        log("REFUSED: no " .. PROP.interactCmp .. " for method " .. method.name)
        return
    end
    if method.needsPlan and ctx.plan == nil then
        say("")
        say(" REFUSED -- " .. method.name)
        say("      * " .. tostring(ctx.planWhy))
        writeReport()
        log("REFUSED: no plan -- " .. tostring(ctx.planWhy))
        return
    end
    if pendingRestore ~= nil then
        say("")
        say(" REFUSED -- a " .. PROP.required .. " restore is still pending on "
            .. shortName(pendingRestore.name) .. ". Wait a second and retry;")
        say(" firing now would capture the MODIFIED value as the original.")
        writeReport()
        log("REFUSED: restore still pending")
        return
    end
    if method.needsTarget and ctx.target == nil then
        say("")
        say(" REFUSED -- " .. method.name .. " needs the owning ACTOR and the")
        say(" focused component did not report one. Try method A, which needs")
        say(" only the component.")
        writeReport()
        log("REFUSED: no owning actor for method " .. method.name)
        return
    end

    local before = snapshot(ctx)
    fires = fires + 1

    say("")
    say("================================================================")
    say(string.format(" FIRE %d/%d   %s   %s", fires, MAX_FIRES, method.name,
        os.date("%Y-%m-%d %H:%M:%S")))
    say("================================================================")
    say("  target                     " .. tostring(ctx.targetClass)
        .. "  " .. shortName(ctx.targetName))
    say("  focus found via            " .. tostring(ctx.via))
    say("  money before               " .. moneyStr(before.money))
    say(string.format("  accepted / running before  %s / %s",
        before.focusName, before.runningName))
    if method.needsPlan and ctx.plan ~= nil then
        say(string.format("  PLAN                       pay %d %s in one press"
            .. " instead of %d (%s -> %s)", ctx.plan.amount, ctx.plan.resource,
            ctx.plan.perPress, moneyStr(ctx.plan.old), moneyStr(ctx.plan.new)))
        say(string.format("  EXPECT                     money -%d %s, owed %d -> %d",
            ctx.plan.amount, ctx.plan.resource, ctx.plan.owed,
            ctx.plan.owed - ctx.plan.amount))
    end
    say(string.format("  counters watched           %d", #before.counters))
    for _, entry in ipairs(before.counters) do
        say(string.format("    %-44s coins=%s remaining=%s", entry.label,
            coinsStr(entry.coins), coinsStr(entry.remaining)))
    end
    if ctx.uninformative then
        say("  !!! THIS FIRE IS UNINFORMATIVE: no observable can move. Whatever")
        say("      the deltas below say, they say nothing about the call.")
    end

    -- The call. Flushed on both sides, so if it takes the process down the log
    -- says which method did it (crash rule J).
    diag("ABOUT TO INVOKE " .. method.name .. " on " .. ctx.targetName)
    local ok, err = pcall(function() method.call(ctx) end)
    diag("RETURNED from " .. method.name .. "  ok=" .. tostring(ok))

    if not ok then
        -- Method C raises from its OWN property write, before the RPC is ever
        -- reached. Reporting that as "not invocable from Lua" would retire a
        -- mechanism that is already Established to work (-5 gold, twice) --
        -- exactly the hard-rule-5 failure this file has already made once.
        local stage, message = nil, err
        if type(err) == "table" then stage, message = err.stage, err.message end
        say("  RESULT                     the call RAISED: " .. tostring(message))
        if stage == "write" then
            say("  -> the " .. PROP.required .. " WRITE failed. Interact_Server was")
            say("     never called, so this says NOTHING about whether the call")
            say("     works -- it is Established that it does.")
        else
            say("  -> this method is not invocable from Lua in this form.")
        end
        writeReport()
        log("fire " .. fires .. ": " .. method.name .. " RAISED -- " .. tostring(err))
        return
    end
    say("  RESULT                     the call returned without raising")
    say("  (that alone is NOT evidence anything happened -- the deltas below are)")
    writeReport()
    log("fire " .. fires .. ": " .. method.name .. " returned; watching for a delta")

    -- After-readings on later pump ticks. Counted in OUR ticks, never scheduled
    -- through UE4SS (crash rule K).
    watch = { before = before, method = method, at = {}, fired = fires,
              uninformative = ctx.uninformative, plan = ctx.plan,
              isHoldTarget = (ctx.component ~= nil
                  and boolProp(ctx.component, PROP.holdOn) == true),
              targetName = ctx.targetName }
    for _, tick in ipairs(CHECK_TICKS) do
        watch.at[#watch.at + 1] = { due = ticks + tick, done = false, tick = tick }
    end
end

--- Put RequiredMoney back after method C. Re-finds the deposit BY NAME through
--- a fresh resolve rather than holding the pointer across ticks (crash rule C).
---
--- If it cannot be found -- you walked away, the level changed -- it says so and
--- prints the original value, because the alternative is a game actor left with
--- a modified cost and nothing on record saying what it was. The value is not
--- saved anywhere, so a restart also clears it.
local function serviceRestore()
    if pendingRestore == nil or ticks < pendingRestore.due then return end
    local job = pendingRestore
    -- NOT cleared yet. The first version cleared it before attempting anything,
    -- so a single unlucky tick -- a menu, a loading beat, one step too far --
    -- abandoned the restore permanently and left a live actor mis-costed. It is
    -- cleared only on a VERIFIED restore, on giving up, or on a world change.

    -- Crash rule D: a write scheduled in the previous world must not land in
    -- this one. The object is gone with the world; nothing to put back.
    if job.epoch ~= epoch then
        pendingRestore = nil
        log("dropping the " .. PROP.required .. " restore for "
            .. shortName(job.name) .. ": scheduled in epoch " .. tostring(job.epoch)
            .. ", we are now in " .. tostring(epoch)
            .. ". The object went away with its world.")
        return
    end
    -- Crash rule F: never write into a world that is not playable yet.
    if not everPlayable then
        job.due = ticks + RESTORE_RETRY_TICKS
        return
    end

    local ctx = resolve(false)
    local found = nil
    if real(ctx.target) and fullName(ctx.target) == job.name then
        found = ctx.target
    else
        for _, row in ipairs(ctx.hotRows or {}) do
            if row.owner ~= nil and fullName(row.owner) == job.name then
                found = row.owner
                break
            end
        end
    end

    if found ~= nil then
        writeMoney(found, PROP.required, job.old)
        local readback = money(found, PROP.required)
        if sameMoney(readback, job.old) then
            pendingRestore = nil
            say(string.format("  restored %s to %s   (verified after %d attempt%s)",
                PROP.required, job.label, (job.attempts or 0) + 1,
                (job.attempts or 0) == 0 and "" or "s"))
            log("restored " .. PROP.required .. " on " .. shortName(job.name))
            writeReport()
            return
        end
    end

    -- Missed, or written but not verified. Retry rather than give up.
    job.attempts = (job.attempts or 0) + 1
    if job.attempts < RESTORE_MAX_ATTEMPTS then
        job.due = ticks + RESTORE_RETRY_TICKS
        diag(string.format("restore attempt %d for %s did not take (%s); retrying",
            job.attempts, shortName(job.name),
            found == nil and "not in range" or "readback disagreed"))
        return
    end

    pendingRestore = nil
    restoreFailed[job.name] = job.label
    say("  RESTORE FAILED after " .. job.attempts .. " attempts -- "
        .. shortName(job.name) .. " could not be put back.")
    say("  " .. PROP.required .. " is still modified. It was " .. job.label
        .. ". It is not saved anywhere, so restarting the game clears it.")
    say("  Method C will refuse to plan against that actor from now on, so it")
    say("  cannot capture the modified value as an original.")
    log("RESTORE FAILED: " .. job.name .. "; " .. PROP.required
        .. " left modified, original was " .. job.label)
    writeReport()
end

--- Re-resolves from scratch every time rather than holding the context across
--- ticks: a held pointer across a world change is a certainty, a rescan is only
--- a race (crash rule C).
local function serviceWatch()
    if watch == nil then return end
    local remaining = false
    for _, check in ipairs(watch.at) do
        if not check.done then
            if ticks >= check.due then
                check.done = true
                -- resolve(false): the watch does not need a focused target, and
                -- a successful interact drops focus for a moment. Requiring it
                -- cost fire 1's +300ms reading on 29 Aug.
                local ctx, blocked = resolve(false)
                if #blocked > 0 or ctx.pawn == nil then
                    say(string.format("  +%dms                     could not re-read"
                        .. " (%s)", check.tick * PUMP_MS,
                        blocked[1] or "no pawn"))
                else
                    local after = snapshot(ctx)
                    watch.lastMoney = after.money
                    watch.lastFocus, watch.lastRunning = after.focusName, after.runningName
                    if after.focusName ~= watch.before.focusName
                            or after.runningName ~= watch.before.runningName then
                        say(string.format("         accepted %s -> %s   running %s -> %s   <-- MOVED",
                            watch.before.focusName, after.focusName,
                            watch.before.runningName, after.runningName))
                    end
                    say(string.format("  +%dms  money %s -> %s   delta %s",
                        check.tick * PUMP_MS, moneyStr(watch.before.money),
                        moneyStr(after.money), moneyDelta(watch.before.money, after.money)))
                    for index, entry in ipairs(after.counters) do
                        local was = watch.before.counters[index]
                        if was ~= nil and was.label == entry.label then
                            -- Compare the FORMATTED values, not the raw ones.
                            -- A property that is absent on a class comes back as
                            -- a fresh wrapper each read, so `was.coins ~= entry.coins`
                            -- was true for every row including "n/a -> n/a" --
                            -- which marked all eight counters MOVED on 29 Aug
                            -- and buried the one that actually did.
                            -- Safe to compare directly now: numberProp
                            -- answers a number or nil, not a fresh wrapper each
                            -- read, which is what made every row read MOVED.
                            local moved = (was.coins ~= entry.coins)
                                or (was.remaining ~= entry.remaining)
                            say(string.format("         %-40s coins %s -> %s  remaining %s -> %s%s",
                                entry.label, coinsStr(was.coins), coinsStr(entry.coins),
                                coinsStr(was.remaining), coinsStr(entry.remaining),
                                moved and "   <-- MOVED" or ""))
                        end
                    end
                end
            else
                remaining = true
            end
        end
    end
    if not remaining then
        if watch.uninformative then
            say("  VERDICT: NONE. This fire had no observable that could move, so")
            say("  it says nothing about " .. watch.method.name .. " either way.")
            say("  Re-run it with coins in hand and a machine in range.")
        elseif watch.plan == nil and watch.isHoldTarget
                and watch.lastFocus == watch.before.focusName
                and watch.lastRunning == watch.before.runningName then
            -- MEASURED 29 Aug 2026 on Chair_01_C: this is what actually
            -- happened. Named explicitly because the generic verdict below is
            -- true but does not say what it means for feature 5.
            say("")
            say("  VERDICT: NOTHING MOVED on a HOLD target. Neither")
            say("  CurrentInteractTarget nor CurrentInteraction changed, so this")
            say("  call does not drive holds at all -- it is the tap path.")
            say("  Feature 5 cannot be built on it.")
        elseif watch.plan == nil and watch.before.focusName ~= nil
                and (watch.lastFocus ~= watch.before.focusName
                     or watch.lastRunning ~= watch.before.runningName) then
            -- A HOLD verdict. MEASURED 29 Aug 2026 on a chair, unmodded:
            --   press accepted  -> CurrentInteractTarget = the actor, at once
            --   0.80s later     -> CurrentInteraction = the actor, target clears
            -- So which pointer moved says exactly what the call did, and this is
            -- the blocking question for feature 5.
            say("")
            if watch.lastRunning ~= watch.before.runningName
                    and watch.lastRunning ~= "-" then
                say("  VERDICT: the call COMPLETED the interaction outright --")
                say("  CurrentInteraction became " .. tostring(watch.lastRunning) .. ".")
                say("  For a HOLD that means Interact_Server does not start a hold,")
                say("  it finishes it. Feature 5 would skip the hold entirely,")
                say("  which is a different feature and needs a decision.")
            elseif watch.lastFocus ~= watch.before.focusName
                    and watch.lastFocus ~= "-" then
                say("  VERDICT: the call STARTED a hold -- CurrentInteractTarget")
                say("  became " .. tostring(watch.lastFocus) .. " and no interaction")
                say("  has completed yet. That is exactly what feature 5 needs:")
                say("  one RPC, and the game runs its own hold from there.")
            else
                say("  VERDICT: a pointer CLEARED rather than being set. Report the")
                say("  before/after line above -- this is not one of the two")
                say("  outcomes the design anticipated.")
            end
        elseif watch.plan ~= nil then
            -- Method C has an EXPECTED number, so "something moved" is not the
            -- test -- the game may simply have clamped the take back to the
            -- per-press amount, which would make C method A with extra steps
            -- and would otherwise read as a success.
            local plan = watch.plan
            local moved = nil
            local last = watch.lastMoney
            if last ~= nil and watch.before.money ~= nil then
                moved = watch.before.money[plan.resource] - last[plan.resource]
            end
            say("")
            if moved == nil then
                say("  VERDICT: could not re-read your money, so nothing is settled.")
            elseif moved == plan.amount then
                say(string.format("  VERDICT: MATCHED the plan -- %d %s in ONE press.",
                    moved, plan.resource))
                say("  The RequiredMoney write took effect and one press paid what")
                say("  would have taken " .. (plan.savedPresses + 1) .. ".")
            elseif moved == plan.perPress then
                say(string.format("  VERDICT: CLAMPED -- the game took %d %s, the"
                    .. " per-press amount, not the %d written.",
                    moved, plan.resource, plan.amount))
                say("  So the write landed but the game does not honour it, and")
                say("  method C is method A with extra steps. That is a real answer.")
            elseif moved == 0 then
                say("  VERDICT: NOTHING MOVED. The write verified but no money was")
                say("  taken -- the interact did not complete.")
            else
                say(string.format("  VERDICT: UNEXPECTED -- took %d %s, planned %d,"
                    .. " per press %d. Report this.",
                    moved, plan.resource, plan.amount, plan.perPress))
            end
        else
            say("  VERDICT: a non-zero delta above means " .. watch.method.name)
            say("  actually performed the interaction. NO CHANGE on every reading")
            say("  means the call was accepted by Lua but did nothing.")
        end
        writeReport()
        log("fire " .. watch.fired .. " watch complete")
        watch = nil
    end
end

-- ==========================================================================
-- The pump (crash rule K, RE-UE4SS #1180). One LoopAsync, one
-- ExecuteInGameThread, no ExecuteWithDelay. Keybinds set a flag only.
-- ==========================================================================

local pumpStarted = pcall(function()
    LoopAsync(PUMP_MS, function()
        if pending.busy then return false end
        pending.busy = true
        ExecuteInGameThread(function()
            ticks = ticks + 1

            local wantCycle, wantFire = pending.cycle, pending.fire
            pending.cycle, pending.fire = false, false

            if wantCycle then
                methodIndex = methodIndex + 1
                if methodIndex > #METHODS then methodIndex = 1 end
                local ok, err = pcall(status)
                if not ok then log("status error: " .. tostring(err)) end
            end
            if wantFire then
                local ok, err = pcall(fire)
                if not ok then log("fire error: " .. tostring(err)) end
            end
            local ok, err = pcall(function() trackWorld(resolve(false)) end)
            if not ok then log("world-track error: " .. tostring(err)) end

            ok, err = pcall(serviceWatch)
            if not ok then log("watch error: " .. tostring(err)) end
            -- The restore runs LAST and unconditionally, so a failure anywhere
            -- above still puts RequiredMoney back.
            ok, err = pcall(serviceRestore)
            if not ok then log("restore error: " .. tostring(err)) end

            -- Anything pressed while that ran is dropped, not queued.
            pending.cycle, pending.fire = false, false
            pending.busy = false
        end)
        return false
    end)
end)

local boundCycle = pcall(function()
    RegisterKeyBind(KEY_CYCLE, function() pending.cycle = true end)
end)
local boundFire = pcall(function()
    RegisterKeyBind(KEY_FIRE, function() pending.fire = true end)
end)

diag("---- " .. MOD .. " " .. VERSION .. " loaded ----")
log("loaded. THIS PROBE CAN CHANGE THE GAME. Solo only, " .. MAX_FIRES
    .. " fires per session, one call per press.")
if not pumpStarted then
    log("FATAL: LoopAsync did not start -- the keys are registered but nothing"
        .. " will ever run.")
end
log(boundCycle and "F9   read-only: cycle the armed method and show every gate"
                or "F9 could not be registered")
log(boundFire and "F10  FIRES ONE REAL INTERACTION. Press F9 first."
               or "F10 could not be registered")
-- Start with the status on screen so the first thing anyone sees is what is
-- armed and whether the gates pass, rather than an unlabelled ready-to-fire key.
pending.cycle = true
methodIndex = #METHODS       -- so the first cycle lands on method 1
