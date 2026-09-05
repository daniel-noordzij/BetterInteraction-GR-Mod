--[[
    BetterInteractionAttackProbe -- what does holding the attack key do today?

    READ-ONLY. It reads properties, hooks two RPCs to LOG them, and writes a
    text file. No writes, no calls, no save contact. Safe anywhere, including a
    live lobby. Two-machine use is not needed for what it measures.

    THE FEATURE IT SERVES (Daniel, 2 Sep 2026)
    ------------------------------------------
    Hold-to-attack: holding the attack key should keep swinging at the game's
    own cadence. On some weapons holding already works, on others every swing
    is a click. Route A is to flip the game's OWN switch for that.

    WHAT THE DUMP ALREADY SAYS
    --------------------------
    AHeldenMeleeWeapon (Helden.hpp:6188) carries a complete auto-repeat block:
        bool  bCanAutoFire      0x0C72
        float AutoFireRate      0x0C74
        bool  bUseAutoFireLoop  0x0C78
        bool  bAutoFireEffect   0x0C88
    and BP_HandSaw_01 is the one shipped weapon whose Blueprint overrides
    OnToggleAutoFireEffect -- direct evidence the path is live. Whether the flag
    is TRUE on any other weapon is in neither dump; it is a CDO value. That is
    the missing fact and this probe's first job.

    The attack itself is AHeldenWeapon:Attack_Server(int32 InCombo) and its
    _Multicast twin (Helden.hpp:7490-7491). Both are reflection-dispatched RPCs,
    the family CLAUDE.md lists as hookable. Hooking them gives the game's true
    per-weapon cadence and what the combo index means, without guessing.

    IA_Attack carries BOTH a Pressed and a Released trigger
    (UE4SS_ObjectDump.txt:122380-122381), unlike IA_Interact, so its
    ActionInstanceData entry should report Started/Ongoing while held. That is
    the same proven walk feature 5 used.

    WHAT IT SAMPLES, all by property walk from the local controller

      AController.Pawn -> AHeldenCharacter.EquipedItems     Helden.hpp:4187, 0x1270
          TArray<AHeldenEquipableItem*>; each has
          EHeldenItemHolsterState HolsterState              Helden.hpp, 0x4D9
              None 0, Equipped 1, Holsterd 2 [sic]
          and, if it is a melee weapon, the four auto-fire fields above.
          A ranged weapon's bCanAutoFire / FireRate are read too, for contrast.

      APlayerController.PlayerInput -> UEnhancedPlayerInput.ActionInstanceData
          the attack action's TriggerEvent and ElapsedProcessedTime.

    WHAT IT HOOKS, log only
      /Script/Helden.HeldenWeapon:Attack_Server        combo, weapon, gap
      /Script/Helden.HeldenWeapon:Attack_Multicast     combo, weapon, gap
      /Script/Helden.HeldenMeleeWeapon:SetAutoFireEffect_Server   the bool

    Every hook logs its own registration either way (crash rule H): a hook that
    silently failed to register looks exactly like a game that never attacks.

    F10 -- EQUIP THE NEXT WEAPON. THIS ONE IS NOT READ-ONLY.
    ----------------------------------------------------------
    Cycles through every item with an attack (ITEMS below, shield included so
    it can be tested). Two routes, tried in order, and the file says which one
    answered:

      1. UHeldenCheatManager:DebugEquipItem(FName)   Helden.hpp:8153
         The shipping build creates no cheat manager, so the probe constructs
         one exactly as CheatManagerEnablerMod does: StaticConstructObject of
         the controller's CheatClass, outer = the controller, assigned to
         APlayerController.CheatManager. The FName it expects is not in the
         dump. attack-2 tried the asset's file name ("Malet_01"): twelve items
         equipped, eight did not. attack-3 reads UHeldenItemDataAsset.UniqueName
         off every asset live, logs the whole table once, and equips by that.
         The result is still VERIFIED half a second later by re-walking
         EquipedItems rather than trusted.
      2. If nothing matching arrived, a real actor is spawned two metres in
         front of the camera from the weapon's Blueprint class, by the icon
         probe's proven BeginDeferredActorSpawnFromClass + FinishSpawningActor
         path. You then pick it up like any dropped item.

    SOLO ONLY for F10: it puts items into the world. Nothing it does touches a
    save, but a lobby is not the place to find out what a spawned weapon does
    to a guest.

    F9 -- FLIP bCanAutoFire ON THE WEAPON IN HAND. NOT READ-ONLY.
    -----------------------------------------------------------
    attack-4 measured: every melee weapon but the saw ships bCanAutoFire=false
    with AutoFireRate=0.5 and bUseAutoFireLoop=true; the saw ships true and
    repeats at exactly 0.50 s under a plain hold, combo staying 0, with
    bAutoFireEffect toggling true for the duration. A 3.1 s hold on the mallet
    produced ZERO swings; fast clicking produced one every 0.40-0.42 s with
    the combo index climbing 1..6. So route A's question is now one write
    away: does flipping the flag make the mallet behave like the saw?

    F9 toggles the flag on whatever is Equipped, reads it straight back, and
    logs both. Press it again to put it back. It writes nothing else.

    F8 / F5 -- RATE, AND THE RUNAWAY
    --------------------------------
    attack-6: AutoFireRate is the ONLY limiter. Written 0.40 the loop ran at
    0.40, written 0.30 it ran at 0.30; no animation clamp down to 0.3. So the
    feature must pick a number, and 0.40 is the measured fastest human click.

    attack-6 also found the RUNAWAY: a mallet whose flag was flipped WHILE IN
    HAND kept swinging after release -- 6 extra swings at 0.5, then 170+ at
    0.3 that no press or release would stop. The saw, flagged at the factory,
    stops on release every time. Best candidate, not established: the stop
    path is wired when the weapon is drawn from the flag's value at that
    moment. F5 flags EVERY melee weapon in the world (what the shipped
    reconciler would do) so a weapon holstered and re-drawn afterwards is
    drawn with the flag already true. If that one stops on release, the
    feature is "write before draw" and the runaway is a probe artefact.

    F4 -- THE RUNAWAY GUARD
    -----------------------
    attack-7: a mallet flagged BEFORE draw stopped cleanly on release after a
    real hold, twice. The runaway came from a TAP shorter than one sample:
    the press started the loop, the release was lost, and no later tap ended
    it. So the feature needs its own off switch. F4 cycles a guard that runs
    while recording: attack action None for two samples + bAutoFireEffect
    still true = runaway, and it fires method A (flag off, then back on), B
    (SetAutoFireEffect_Server(false)) or C (OnToggleAutoFireEffect(false)).
    "off" only logs. The Attack_Multicast lines after each kill are the verdict.

    attack-8: A, B and C all FAILED -- the swings continued through every
    one, and B blinded the guard by clearing the flag it keys on. The loop
    is a native timer. A holster or drop ends it every time; so does the
    release after a REAL hold. attack-9 keeps one guard, D: starve the
    timer by writing AutoFireRate huge on a runaway, restore on the next
    press. And it adds route B's primitive on F3 / F2: call Attack_Server(0)
    / Attack_Multicast(0) ourselves and see whether the weapon swings.

    attack-9: guard D stopped the runaway in one swing and then JAMMED the
    weapon until a holster. F3 (Attack_Server) swung the mallet for real; F2
    did nothing. So attack-10 abandons the game's loop: F4 now toggles the
    REPEATER, which calls Attack_Server itself at 0.40 s while the key is
    held, only ever continuing a chain the game's own press started. Do NOT
    press F5 for this test: the game's flag must stay false.

    KEYS
    ----
      F2    call Attack_Multicast(0) on the weapon in hand (one swing?)
      F3    call Attack_Server(0) on the weapon in hand (one swing?)
      F4    toggle the runaway guard: off <-> D (starve the rate)
      F5    flag every melee weapon in the world, rate 0.40 (writes many bools)
      F8    cycle AutoFireRate on the weapon in hand
      F9    flip bCanAutoFire on the weapon in hand (writes one bool)
      F10   equip / spawn the next weapon in the list (writes to the world)
      F11   start / stop recording. Read-only either way. Hooks log whether or
            not recording is on, so a swing before F11 still leaves a line.
]]

local MOD     = "BetterInteractionAttackProbe"
local VERSION = "attack-11"

-- ==========================================================================
-- Version-fragile names, all verified against the 5.7.4 dump on 2 Sep 2026.
-- ==========================================================================

local CLASS = {
    controller = "HeldenPlayerController",
    itemAsset  = "HeldenItemDataAsset",     -- UHeldenItemDataAsset, Helden.hpp:9308
    melee      = "HeldenMeleeWeapon",       -- AHeldenMeleeWeapon, Helden.hpp:6188
}

local PROP = {
    pawn        = "Pawn",                   -- AController 0x2F0
    equipped    = "EquipedItems",           -- AHeldenCharacter 0x1270 [sic]
    holster     = "HolsterState",           -- AHeldenEquipableItem 0x4D9
    canAuto     = "bCanAutoFire",           -- AHeldenMeleeWeapon 0xC72 / Ranged 0xFA8
    autoRate    = "AutoFireRate",           -- AHeldenMeleeWeapon 0xC74
    autoLoop    = "bUseAutoFireLoop",       -- AHeldenMeleeWeapon 0xC78
    autoEffect  = "bAutoFireEffect",        -- AHeldenMeleeWeapon 0xC88
    fireRate    = "FireRate",               -- AHeldenRangedWeapon 0xC68
    playerIn    = "PlayerInput",            -- APlayerController 0x428
    actionData  = "ActionInstanceData",     -- UEnhancedPlayerInput 0x4E8
    trigger     = "TriggerEvent",           -- FInputActionInstance 0x13
    elapsed     = "ElapsedProcessedTime",   -- FInputActionInstance 0x58
    uniqueName  = "UniqueName",             -- UHeldenItemDataAsset 0x38
    statsName   = "ItemStatsName",          -- UHeldenItemDataAsset 0x40
    itemClass   = "ItemClass",              -- UHeldenItemDataAsset, TSubclassOf
}

local HOOK = {
    attackServer = "/Script/Helden.HeldenWeapon:Attack_Server",
    attackMulti  = "/Script/Helden.HeldenWeapon:Attack_Multicast",
    autoEffect   = "/Script/Helden.HeldenMeleeWeapon:SetAutoFireEffect_Server",
}

-- ETriggerEvent, EnhancedInput_enums.hpp:116. FLAG values, not dense.
local TRIGGER = {
    [0] = "None", [1] = "Triggered", [2] = "Started",
    [4] = "Ongoing", [8] = "Canceled", [16] = "Completed",
}

-- EHeldenItemHolsterState, Helden_enums.hpp:906
local HOLSTER = { [0] = "None", [1] = "Equipped", [2] = "Holstered" }

local PROP_CHEAT = {
    manager    = "CheatManager",            -- APlayerController
    class      = "CheatClass",              -- APlayerController
    camera     = "PlayerCameraManager",     -- APlayerController
}

local FUNC = {
    equip      = "DebugEquipItem",          -- UHeldenCheatManager(FName)
}

local STATICS = "/Script/Engine.Default__GameplayStatics"
local MATHS   = "/Script/Engine.Default__KismetMathLibrary"

--- Every item with an attack, in test order. `name` is the item data asset's
--- short name (UE4SS_ObjectDump.txt, /Game/Gameplay/Items/Assets/), the first
--- guess at what DebugEquipItem wants. `class` is the Blueprint class the
--- spawn fallback uses, and `match` is the substring looked for in
--- EquipedItems to verify the equip really happened.
local ITEMS = {
    { name = "Malet_01",           class = "/Game/Gameplay/Items/BP_Malet_01.BP_Malet_01_C",                     match = "Malet_01" },
    { name = "Malet_02",           class = "/Game/Gameplay/Items/BP_Malet_02.BP_Malet_02_C",                     match = "Malet_02" },
    { name = "Malet_Golden_01",    class = "/Game/Gameplay/Items/BP_Malet_Golden_01.BP_Malet_Golden_01_C",       match = "Malet_Golden" },
    { name = "Knife_01",           class = "/Game/Gameplay/Items/BP_Knife_01.BP_Knife_01_C",                     match = "Knife" },
    { name = "Machete_01",         class = "/Game/Gameplay/Items/BP_Machete_01.BP_Machete_01_C",                 match = "Machete" },
    { name = "Broom_01",           class = "/Game/Gameplay/Items/BP_Broom_01.BP_Broom_01_C",                     match = "Broom" },
    { name = "HandSaw_01",         class = "/Game/Gameplay/Items/BP_HandSaw_01.BP_HandSaw_01_C",                 match = "HandSaw" },
    { name = "Spear_01",           class = "/Game/Gameplay/Items/BP_Spear_01.BP_Spear_01_C",                     match = "Spear" },
    { name = "SpikeClub_01",       class = "/Game/Gameplay/Items/BP_SpikeClub_01.BP_SpikeClub_01_C",             match = "SpikeClub_01" },
    { name = "SpikeClub_Elite_01", class = "/Game/Gameplay/Items/BP_SpikeClub_Elite_01.BP_SpikeClub_Elite_01_C", match = "SpikeClub_Elite" },
    { name = "Umbrella_01",        class = "/Game/Gameplay/Items/BP_Umbrella_01.BP_Umbrella_01_C",               match = "Umbrella" },
    { name = "Battery_01",         class = "/Game/Gameplay/Items/BP_Battery_01.BP_Battery_01_C",                 match = "Battery" },
    { name = "Radar_01",           class = "/Game/Gameplay/Items/BP_Radar_01.BP_Radar_01_C",                     match = "Radar" },
    { name = "Shield_01",          class = "/Game/Gameplay/Items/BP_Shield_01.BP_Shield_01_C",                   match = "Shield" },
    -- ranged, for contrast
    { name = "NailGun_01",         class = "/Game/Gameplay/Items/BP_NailGun_01.BP_NailGun_01_C",                 match = "NailGun" },
    { name = "Shotgun_01",         class = "/Game/Gameplay/Items/BP_Shotgun_01.BP_Shotgun_01_C",                 match = "Shotgun" },
    { name = "Sniper_01",          class = "/Game/Gameplay/Items/BP_Sniper_01.BP_Sniper_01_C",                   match = "Sniper" },
    { name = "GrenadeLauncher_01", class = "/Game/Gameplay/Items/BP_GrenadeLauncher_01.BP_GrenadeLauncher_01_C", match = "GrenadeLauncher" },
    { name = "Flamethrower_01",    class = "/Game/Gameplay/Items/BP_Flamethrower_01.BP_Flamethrower_01_C",       match = "Flamethrower" },
    { name = "GlueGun_01",         class = "/Game/Gameplay/Items/BP_GlueGun_01.BP_GlueGun_01_C",                 match = "GlueGun" },
}

local OUT_FILE = "BetterInteraction_attack.txt"
local KEY_TOGGLE = Key.F11
local KEY_EQUIP = Key.F10
local KEY_FLIP = Key.F9
local KEY_RATE = Key.F8
local KEY_ALL = Key.F5    -- F7 is BetterInteractionDev's stash-money key
local KEY_GUARD = Key.F4
local KEY_SERVER = Key.F3
local KEY_MULTI = Key.F2
local PUMP_MS = 100
local SAMPLE_EVERY = 2   -- 200 ms
local VERIFY_TICKS = 5   -- how long after DebugEquipItem to look for the item

-- The action's own name, matched case-insensitively, so a rebind is irrelevant.
local WATCH = { "attack" }

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

--- Flushed per line (crash rule J).
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
-- Null-wrapper primitives (crash rules A and B). Copied from the hold probe.
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

local function fmtBool(value)
    if value == nil then return "?" end
    return value and "true" or "false"
end

local function fmtNum(value, pattern)
    if value == nil then return "?" end
    return string.format(pattern or "%.3f", value)
end

--- The bare object behind a wrapper that may be a TArray element or a hook
--- parameter. Both answer to :get(); a plain object does not, and keeps itself.
local function deref(wrapper)
    local inner = nil
    pcall(function() inner = wrapper:get() end)
    if inner ~= nil then return inner end
    return wrapper
end

-- ==========================================================================
-- Sampling. NO UOBJECT IS HELD ACROSS A SAMPLE (see the hold probe's note on
-- the save-start crash). The controller is re-found every sample.
-- ==========================================================================

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

--- One line per item the character carries. A melee weapon is recognised by
--- its bCanAutoFire reading as a BOOLEAN; on anything else the property read
--- answers a non-boolean wrapper (rule A), which is the test.
local function describeItem(item)
    local cls = className(item)
    local holster = enumStr(numberProp(item, PROP.holster), HOLSTER)
    local canAuto = boolProp(item, PROP.canAuto)
    if canAuto == nil then
        return string.format("%-28s %-9s (no auto-fire fields)", cls, holster),
            holster == "Equipped"
    end
    local rate = numberProp(item, PROP.autoRate)
    local kind = "melee"
    if rate == nil then
        rate = numberProp(item, PROP.fireRate)
        kind = "ranged"
    end
    return string.format("%-28s %-9s %-6s bCanAutoFire=%-5s rate=%s loop=%s effect=%s",
        cls, holster, kind, fmtBool(canAuto), fmtNum(rate),
        fmtBool(boolProp(item, PROP.autoLoop)),
        fmtBool(boolProp(item, PROP.autoEffect))),
        holster == "Equipped"
end

--- Every carried item, and the one in hand. Returns the joined text and a
--- count, so rule H can say "carrying nothing" rather than nothing at all.
local function equippedState(controller)
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return "no pawn", 0 end
    local items = get(pawn, PROP.equipped)
    if items == nil then return PROP.equipped .. " did not read", 0 end

    local lines, count = {}, 0
    local ok = pcall(function()
        items:ForEach(function(_, element)
            local item = deref(element)
            if not real(item) then return end
            count = count + 1
            local text, inHand = describeItem(item)
            lines[#lines + 1] = (inHand and "  IN HAND  " or "           ") .. text
        end)
    end)
    if not ok then return "the " .. PROP.equipped .. " walk raised", 0 end
    if count == 0 then return "carrying nothing", 0 end
    return table.concat(lines, "\n"), count
end

--- The attack action's live trigger state -- the proven ActionInstanceData walk.
local function inputState(controller)
    local input = get(controller, PROP.playerIn)
    if not real(input) then return "PlayerInput did not resolve", nil end
    local map = get(input, PROP.actionData)
    if map == nil then return PROP.actionData .. " did not read", nil end

    local parts, primary, seen = {}, nil, 0
    local ok = pcall(function()
        map:ForEach(function(key, value)
            seen = seen + 1
            local action = deref(key)
            local name = shortName(fullName(action)):lower()
            local wanted = false
            for _, want in ipairs(WATCH) do
                if name:find(want, 1, true) ~= nil then wanted = true end
            end
            if not wanted then return end
            local instance = deref(value)
            local trig = numberProp(instance, PROP.trigger)
            local elapsed = numberProp(instance, PROP.elapsed)
            parts[#parts + 1] = string.format("%s=%s held=%s",
                shortName(fullName(action)), enumStr(trig, TRIGGER),
                fmtNum(elapsed, "%.2f"))
            if primary == nil then primary = trig end
        end)
    end)
    if not ok then return "the " .. PROP.actionData .. " walk raised", nil end
    if #parts == 0 then
        return string.format("no action matching %s among %d in the map",
            table.concat(WATCH, "/"), seen), nil
    end
    return table.concat(parts, "  |  "), primary
end

-- ==========================================================================
-- The recorder
-- ==========================================================================

local recording = false
local samples, changes = 0, 0
local last = {}
local ticksSeen = 0
local guard   -- the runaway guard, assigned below once meleeInHand exists

local function sample()
    ticksSeen = ticksSeen + 1
    if ticksSeen % SAMPLE_EVERY ~= 0 then return end
    local controller = localController()
    if controller == nil then
        if last.items ~= "<no controller>" then
            last.items = "<no controller>"
            emit(string.format("%8.3f  no local %s (menu, or a transition)",
                os.clock(), CLASS.controller))
        end
        return
    end

    samples = samples + 1
    local itemText, count = equippedState(controller)
    local inputText, trigger = inputState(controller)
    if guard ~= nil then
        local ok, err = pcall(guard, trigger)
        if not ok then log("guard error: " .. tostring(err)) end
    end

    if itemText ~= last.items then
        last.items = itemText
        changes = changes + 1
        emit(string.format("%8.3f  carried items changed (%d):", os.clock(), count))
        emit(itemText)
    end
    if inputText ~= last.input or trigger ~= last.trigger then
        last.input, last.trigger = inputText, trigger
        changes = changes + 1
        emit(string.format("%8.3f  input  %s", os.clock(), inputText))
    end
end

-- ==========================================================================
-- F10 -- equip the next weapon. Route 1 the cheat manager, route 2 a spawn.
-- Nothing is held across ticks except plain Lua values (a name, a class
-- path, a countdown); every UObject is re-resolved when it is needed.
-- ==========================================================================

local nextItem = 1
--- The equip in flight: { item = ITEMS[n], ticksLeft = N }. Set by the cheat
--- route, consumed by verifyEquip when the countdown reaches zero.
local pending = nil

--- Does the pawn now carry something whose class name contains `match`?
local function carries(controller, match)
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return false, "no pawn" end
    local items = get(pawn, PROP.equipped)
    if items == nil then return false, PROP.equipped .. " did not read" end
    local found = false
    pcall(function()
        items:ForEach(function(_, element)
            local item = deref(element)
            if real(item) and className(item):find(match, 1, true) then found = true end
        end)
    end)
    return found, nil
end

--- The controller's cheat manager, constructing one if the game made none --
--- exactly what CheatManagerEnablerMod does, and that mod has run on this
--- profile. Returns the manager or nil, and says which it was.
local function cheatManager(controller)
    local manager = get(controller, PROP_CHEAT.manager)
    if real(manager) then return manager, "existing" end
    local class = get(controller, PROP_CHEAT.class)
    if not real(class) then return nil, "controller has no CheatClass" end
    local made = nil
    local ok = pcall(function() made = StaticConstructObject(class, controller) end)
    if not ok or not real(made) then return nil, "StaticConstructObject refused" end
    local assigned = pcall(function() controller[PROP_CHEAT.manager] = made end)
    if not assigned then return nil, "could not assign CheatManager" end
    return made, "constructed " .. className(made)
end

--- Route 2: spawn the weapon's Blueprint class two metres in front of the
--- camera. The icon probe's proven path, minus the parts about treasure.
local function spawnItem(controller, item)
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then emit("  spawn: no pawn") return end

    local statics = nil
    pcall(function() statics = StaticFindObject(STATICS) end)
    if not real(statics) then emit("  spawn: no GameplayStatics CDO") return end

    local class = nil
    pcall(function() class = StaticFindObject(item.class) end)
    if not real(class) then pcall(function() class = LoadAsset(item.class) end) end
    if not real(class) then emit("  spawn: could not resolve " .. item.class) return end

    local where, facing, from = nil, nil, "camera"
    pcall(function()
        local cam = deref(get(controller, PROP_CHEAT.camera))
        if not real(cam) then return end
        local maths = StaticFindObject(MATHS)
        if not real(maths) then return end
        local rotation = cam:GetCameraRotation()
        where = cam:GetCameraLocation()
        facing = maths:GetForwardVector(rotation)
    end)
    if where == nil or facing == nil then
        from = "pawn"
        where, facing = nil, nil
        pcall(function() where = pawn:K2_GetActorLocation() end)
        pcall(function() facing = pawn:GetActorForwardVector() end)
    end
    if where == nil or facing == nil then emit("  spawn: no camera or pawn transform") return end
    local spot = {
        X = where.X + facing.X * 200.0,
        Y = where.Y + facing.Y * 200.0,
        Z = where.Z + facing.Z * 200.0 + (from == "camera" and 0.0 or 60.0),
    }
    local transform = { Translation = spot, Rotation = { X = 0, Y = 0, Z = 0, W = 1 },
                        Scale3D = { X = 1, Y = 1, Z = 1 } }

    local actor = nil
    local began = pcall(function()
        actor = deref(statics:BeginDeferredActorSpawnFromClass(pawn, class, transform, 0, pawn, 0))
    end)
    if not began or not real(actor) then
        emit("  spawn: BeginDeferredActorSpawnFromClass gave nothing back ("
            .. (began and "returned" or "threw") .. ")")
        return
    end
    local finished = pcall(function() statics:FinishSpawningActor(actor, transform, 0) end)
    emit(string.format("  spawn: %s %s in front of the %s -- %s", className(actor),
        finished and "spawned" or "FinishSpawningActor THREW", from,
        "walk over and pick it up"))
end

--- The game's own name for each item, read off the UHeldenItemDataAsset
--- objects: UniqueName (Helden.hpp, 0x38) keyed by the short name of the
--- ItemClass it points at. Run 1 (attack-2) showed DebugEquipItem takes the
--- asset's file name for twelve items and refuses it for eight -- so the
--- FName is something else, and this is the field it can only be.
---
--- One FindAllOf, on a keypress, and ONLY STRINGS are kept (rule C).
local uniqueNames = nil   -- classShort -> UniqueName string
local statsNames  = nil   -- classShort -> ItemStatsName string

--- attack-3's table: UniqueName == the asset file name for all 30 assets, so
--- it never was the discriminator. The eight that refused were EXACTLY the
--- eight whose ItemStatsName differs from it (Malet, Malet_Reinforced,
--- Malet_Golden, Broom, Radar, NailGun, Flamethrower, GlueGun); all twelve
--- that worked have the two equal. So the stats name goes first, the unique
--- name second, and the spawn last. Assets named *_AI point at the same
--- class as the player one and are skipped so they cannot overwrite it --
--- Knife_01_AI did exactly that in attack-3.

local function fnameStr(value)
    if type(value) == "string" then return value end
    local text = nil
    pcall(function() text = value:ToString() end)
    if type(text) == "string" then return text end
    return nil
end

local function readUniqueNames()
    uniqueNames, statsNames = {}, {}
    local seen, kept = 0, 0
    emit("  item data assets (ItemClass -> UniqueName / ItemStatsName):")
    pcall(function()
        for _, asset in ipairs(FindAllOf(CLASS.itemAsset) or {}) do
            if real(asset) then
                seen = seen + 1
                local assetName = shortName(fullName(asset))
                local unique = fnameStr(get(asset, PROP.uniqueName))
                local stats = fnameStr(get(asset, PROP.statsName))
                local class = get(asset, PROP.itemClass)
                local classShort = real(class) and shortName(fullName(class)) or "-"
                local ai = assetName:find("_AI$") ~= nil
                emit(string.format("    %-30s %-28s -> %-22s stats=%s%s",
                    assetName, classShort, unique or "?", stats or "?",
                    ai and "   (AI variant, skipped)" or ""))
                if classShort ~= "-" and not ai then
                    if unique ~= nil then uniqueNames[classShort] = unique end
                    if stats ~= nil then statsNames[classShort] = stats end
                    kept = kept + 1
                end
            end
        end
    end)
    emit(string.format("  %d assets seen, %d kept", seen, kept))
end

--- The names to try for an item, best first, no duplicates.
local function nameLadder(item)
    local classShort = shortName(item.class)
    local ladder, have = {}, {}
    local function add(name, source)
        if name ~= nil and not have[name] then
            have[name] = true
            ladder[#ladder + 1] = { name = name, source = source }
        end
    end
    add(statsNames[classShort], "ItemStatsName")
    add(uniqueNames[classShort], "UniqueName")
    add(item.name, "asset file name")
    return ladder
end

--- Call DebugEquipItem with the next name on the ladder, or spawn when the
--- ladder is empty. Arms the verify on success.
local function tryNextName(controller, item, ladder, step)
    if step > #ladder then
        emit("  every name refused -> spawn route")
        spawnItem(controller, item)
        return
    end
    local manager, how = cheatManager(controller)
    if manager == nil then
        emit("  cheat manager: " .. how .. " -> straight to the spawn route")
        spawnItem(controller, item)
        return
    end
    if step == 1 then emit("  cheat manager: " .. how) end
    local entry = ladder[step]
    local called = pcall(function() manager[FUNC.equip](manager, FName(entry.name)) end)
    if not called then
        emit("  " .. FUNC.equip .. "(\"" .. entry.name .. "\") THREW")
        tryNextName(controller, item, ladder, step + 1)
        return
    end
    emit(string.format("  %s(\"%s\") [%s] returned; verifying in %d ms",
        FUNC.equip, entry.name, entry.source, VERIFY_TICKS * PUMP_MS))
    pending = { item = item, ladder = ladder, step = step, ticksLeft = VERIFY_TICKS }
end

--- F10 pressed: try the cheat manager on the next item and arm the verify.
local function equipNext()
    local item = ITEMS[nextItem]
    nextItem = nextItem % #ITEMS + 1
    emit("")
    emit(string.format("%8.3f  F10: %s  (%d of %d)", os.clock(), item.name,
        (nextItem - 2) % #ITEMS + 1, #ITEMS))

    local controller = localController()
    if controller == nil then emit("  no local controller; are you in a level?") return end

    local already = carries(controller, item.match)
    if already then emit("  already carrying one; F10 again for the next item") return end

    if uniqueNames == nil then readUniqueNames() end
    tryNextName(controller, item, nameLadder(item), 1)
end

--- Runs every pump tick; acts once when the countdown ends.
local function verifyEquip()
    if pending == nil then return end
    pending.ticksLeft = pending.ticksLeft - 1
    if pending.ticksLeft > 0 then return end
    local item, ladder, step = pending.item, pending.ladder, pending.step
    pending = nil
    local controller = localController()
    if controller == nil then emit("  verify: no controller") return end
    local found, why = carries(controller, item.match)
    if found then
        emit(string.format("  VERIFIED: %s is now carried -- \"%s\" [%s] is the name it wants",
            item.name, ladder[step].name, ladder[step].source))
        return
    end
    emit("  not carried after \"" .. ladder[step].name .. "\""
        .. (why and (" (" .. why .. ")") or ""))
    tryNextName(controller, item, ladder, step + 1)
end

-- ==========================================================================
-- F9 -- flip bCanAutoFire on the weapon in hand. One bool, read straight
-- back. The weapon is found fresh from the pawn's array; nothing is held.
-- ==========================================================================

--- The melee weapon in hand. attack-5 required HolsterState == Equipped and
--- that silently skipped every weapon the cheat manager had handed over --
--- those read HolsterState None (0) for as long as they are carried, so the
--- knife, machete, broom and Malet_02 were never flipped at all, which is
--- the whole of "it only worked for the two mallets". Now: prefer Equipped,
--- otherwise the only melee weapon carried, and SAY which it was.
local function meleeInHand()
    local controller = localController()
    if controller == nil then return nil, "no local controller" end
    local pawn = get(controller, PROP.pawn)
    if not real(pawn) then return nil, "no pawn" end
    local items = get(pawn, PROP.equipped)
    if items == nil then return nil, PROP.equipped .. " did not read" end

    local equipped, melee, seen, meleeCount = nil, nil, 0, 0
    pcall(function()
        items:ForEach(function(_, element)
            local item = deref(element)
            if not real(item) then return end
            seen = seen + 1
            local canAuto = boolProp(item, PROP.canAuto)
            local rate = numberProp(item, PROP.autoRate)
            -- a MELEE weapon: AutoFireRate reads as a number only on
            -- AHeldenMeleeWeapon (ranged has FireRate instead).
            if canAuto == nil or rate == nil then return end
            meleeCount = meleeCount + 1
            if melee == nil then melee = item end
            if equipped == nil and numberProp(item, PROP.holster) == 1 then equipped = item end
        end)
    end)
    if equipped ~= nil then return equipped, "Equipped" end
    if melee ~= nil and meleeCount == 1 then
        return melee, "the only melee weapon carried (HolsterState "
            .. enumStr(numberProp(melee, PROP.holster), HOLSTER) .. ")"
    end
    return nil, string.format("%d melee weapon(s) among %d carried, none Equipped",
        meleeCount, seen)
end

local function flipAutoFire()
    emit("")
    emit(string.format("%8.3f  F9: flip %s on the weapon in hand", os.clock(), PROP.canAuto))
    local target, how = meleeInHand()
    if target == nil then emit("  " .. how) return end
    emit("  target: " .. className(target) .. " -- " .. how)

    local before = boolProp(target, PROP.canAuto)
    local wrote = pcall(function() target[PROP.canAuto] = not before end)
    local after = boolProp(target, PROP.canAuto)
    emit(string.format("  %s: %s %s -> wrote %s -> reads back %s%s",
        className(target), PROP.canAuto, fmtBool(before), fmtBool(not before),
        fmtBool(after),
        (not wrote) and "  (the write THREW)"
            or ((after ~= (not before)) and "  (DID NOT STICK)" or "")))
    emit("  now HOLD attack for ~3 s and watch for Attack_Multicast lines at the")
    emit("  weapon's own AutoFireRate. F9 again puts it back.")
end

--- F8: cycle AutoFireRate on the weapon in hand through RATES. attack-5
--- measured the loop at 0.50 s against 0.39-0.42 s for fast clicking, and
--- Daniel: "slightly slower than spam clicking, which shouldn't be the
--- case". The question is whether the rate is the only limiter or whether
--- the swing animation clamps it -- so the rate is driven DOWN past any
--- plausible clamp and the resulting gaps say which.
local RATES = { 0.5, 0.4, 0.3, 0.2, 0.1 }
local rateIndex = 0

local function cycleRate()
    emit("")
    emit(string.format("%8.3f  F8: cycle %s on the weapon in hand", os.clock(), PROP.autoRate))
    local target, how = meleeInHand()
    if target == nil then emit("  " .. how) return end
    rateIndex = rateIndex % #RATES + 1
    local before = numberProp(target, PROP.autoRate)
    local wanted = RATES[rateIndex]
    local wrote = pcall(function() target[PROP.autoRate] = wanted end)
    local after = numberProp(target, PROP.autoRate)
    emit(string.format("  %s: %s %s -> wrote %.2f -> reads back %s%s  (bCanAutoFire=%s)",
        className(target), PROP.autoRate, fmtNum(before, "%.2f"), wanted,
        fmtNum(after, "%.2f"),
        (not wrote) and "  (the write THREW)"
            or ((after == nil or math.abs(after - wanted) > 0.001) and "  (DID NOT STICK)" or ""),
        fmtBool(boolProp(target, PROP.canAuto))))
    emit("  now HOLD attack for ~3 s. If the gaps follow the rate, the rate is the")
    emit("  limiter; if they stop shrinking, the animation is.")
end

--- F5: what the SHIPPED feature would do -- flag every melee weapon in the
--- world, not just the one in hand, so a weapon picked up afterwards has
--- the flag from its first frame in hand.
---
--- attack-6 found the runaway: a mallet flipped WHILE IN HAND kept swinging
--- after the key was released -- 6 extra swings at 0.5, then 170+ at 0.3
--- that no press or release would stop. The saw, which ships with the flag
--- true, stops on release every time. The distinguishing guess is that the
--- stop path is wired when the weapon is drawn, from the flag's value AT
--- THAT MOMENT, so a flag flipped later has a loop with no off switch. F5
--- tests exactly that: flag everything, then holster and re-draw (or drop
--- and pick up), then hold and release.
---
--- One FindAllOf per keypress (rule E: a keypress, not a hot path). Nothing
--- is kept. Rate is set to ATTACK_RATE at the same time, the measured
--- fastest-click cadence.
local ATTACK_RATE = 0.4

local function flagAll()
    emit("")
    emit(string.format("%8.3f  F5: %s=true and %s=%.2f on EVERY melee weapon in the world",
        os.clock(), PROP.canAuto, PROP.autoRate, ATTACK_RATE))
    local seen, flipped, rated, failed = 0, 0, 0, 0
    pcall(function()
        for _, weapon in ipairs(FindAllOf(CLASS.melee) or {}) do
            if real(weapon) then
                seen = seen + 1
                local name = fullName(weapon)
                if name:find("Default__", 1, true) == nil then
                    local canAuto = boolProp(weapon, PROP.canAuto)
                    local rate = numberProp(weapon, PROP.autoRate)
                    local ok = true
                    if canAuto == false then
                        pcall(function() weapon[PROP.canAuto] = true end)
                        if boolProp(weapon, PROP.canAuto) == true then flipped = flipped + 1
                        else ok = false end
                    end
                    if rate ~= nil and math.abs(rate - ATTACK_RATE) > 0.001 then
                        pcall(function() weapon[PROP.autoRate] = ATTACK_RATE end)
                        local back = numberProp(weapon, PROP.autoRate)
                        if back ~= nil and math.abs(back - ATTACK_RATE) < 0.001 then rated = rated + 1
                        else ok = false end
                    end
                    if not ok then
                        failed = failed + 1
                        emit("    DID NOT STICK on " .. className(weapon) .. " " .. shortName(name))
                    end
                end
            end
        end
    end)
    emit(string.format("  %d %s objects seen; flag flipped on %d, rate set on %d, %d failed",
        seen, CLASS.melee, flipped, rated, failed))
    emit("  now HOLSTER and RE-DRAW the weapon (or drop it and pick it up), then")
    emit("  hold ~3 s and RELEASE. The question is whether it stops on release.")
end

-- ==========================================================================
-- F4 -- the RUNAWAY GUARD, cycling through kill methods.
--
-- attack-7 narrowed the runaway to a TAP: a mallet flagged before draw
-- stopped cleanly on release after a 2.5 s hold, twice -- but a press
-- shorter than one 200 ms sample started the loop and the release was
-- lost, and 28 swings followed that no further tap ended. So the shipped
-- feature needs its OWN off switch, and this finds one that works.
--
-- The guard runs inside sample(): when the attack action has read None for
-- GUARD_SAMPLES consecutive samples and the melee weapon in hand still has
-- bAutoFireEffect == true (the loop is running), it fires the current
-- method and logs it. A real release drops the effect within ~100 ms, so
-- two clean samples (400 ms) cannot false-positive on a legitimate hold.
--
-- Methods, cycled by F4:
--   off  -- watch only, log what WOULD have fired
--   A    -- write bCanAutoFire = false, restore true on the next sample
--   B    -- call SetAutoFireEffect_Server(false)   (Helden.hpp:6201)
--   C    -- call OnToggleAutoFireEffect(false)     (Helden.hpp:6203)
-- Whether Attack_Multicast lines keep coming after a kill is the verdict.
-- ==========================================================================

local GUARD_SAMPLES = 2
-- attack-8: A (flag off), B (effect setter false) and C (Blueprint toggle
-- false) all left the swings running -- 14, 13 and 12 more respectively --
-- and B made the guard BLIND by clearing the very flag it keys on. The loop
-- is a native timer none of those reach. What ends it every time is a
-- holster or drop. D starves it instead: AutoFireRate is written to
-- STARVE_RATE on a runaway and put back to ATTACK_RATE when the key is next
-- pressed. If the timer re-reads the rate per swing, the next swing is a
-- week away; if it does not, D fails like the rest and route A is dead.
local GUARD_MODES = { "off", "R" }
local STARVE_RATE = 600000.0
local guardMode = 1
local noneRun = 0            -- consecutive samples with the attack action None
local starved = false        -- D wrote STARVE_RATE; restore on the next press
local guardFires = 0

local function cycleGuard()
    guardMode = guardMode % #GUARD_MODES + 1
    noneRun, starved = 0, false
    emit("")
    emit(string.format("%8.3f  F4: runaway guard -> %s", os.clock(), GUARD_MODES[guardMode]))
    log("runaway guard: " .. GUARD_MODES[guardMode])
end

--- Called from sample() with the attack action's raw trigger value.
guard = function(trigger)
    local mode = GUARD_MODES[guardMode]
    local target = meleeInHand()
    if target == nil then noneRun = 0 return end

    if starved and trigger ~= nil and trigger ~= 0 then
        starved = false
        pcall(function() target[PROP.autoRate] = ATTACK_RATE end)
        emit(string.format("%8.3f  guard D: key pressed again, %s restored to %s",
            os.clock(), PROP.autoRate, fmtNum(numberProp(target, PROP.autoRate), "%.2f")))
    end

    if trigger == 0 then noneRun = noneRun + 1 else noneRun = 0 end
    if noneRun < GUARD_SAMPLES then return end
    if boolProp(target, PROP.autoEffect) ~= true then return end

    -- The loop is running with the key up: a runaway.
    guardFires = guardFires + 1
    if mode == "off" then
        if noneRun == GUARD_SAMPLES then
            emit(string.format("%8.3f  guard off: RUNAWAY seen on %s (would fire)",
                os.clock(), className(target)))
        end
        return
    end
    noneRun = 0   -- one shot per detection; re-arm on the next clean pair
    if starved then return end   -- already starved; wait for the next press
    local wrote = pcall(function() target[PROP.autoRate] = STARVE_RATE end)
    starved = true
    emit(string.format("%8.3f  guard D fired on %s: wrote %s=%.0f -> reads %s%s",
        os.clock(), className(target), PROP.autoRate, STARVE_RATE,
        fmtNum(numberProp(target, PROP.autoRate), "%.0f"), wrote and "" or "  (THREW)"))
    emit("  -> at most ONE more swing is expected if the timer re-reads the rate")
end

-- ==========================================================================
-- THE REPEATER -- route B, as the shipped feature would do it.
--
-- attack-9: guard D stopped a runaway in one swing but JAMMED the weapon --
-- the starved timer stays pending, and every later press toggled the effect
-- and swung nothing until a holster. And F3, Attack_Server(0), swung the
-- mallet "as if normally pressing LMB, both functionally and the animation"
-- while Attack_Multicast(0) did nothing. So the game's loop is abandoned
-- and the mod repeats the chain itself:
--
--   * The GAME always starts a chain: a real press, a real Attack_Multicast
--     (the hook). The mod never initiates a swing, so every lock the game
--     applies to the first swing (dialogue, menus, holster) is respected.
--   * RATE seconds after the last swing, if the attack action still reads
--     Started/Ongoing and a melee weapon is Equipped, call Attack_Server
--     with the next combo index. That call is one the player could have
--     made by clicking, which is what puts this in co-op bucket 2.
--   * If no Attack_Multicast follows our call, the game refused it; the
--     chain ends and waits for a fresh real press. Key up: chain ends.
--
-- The controller is re-found at each step (rule C), at most 1/RATE times a
-- second and only while a chain is live -- zero scans otherwise.
-- ==========================================================================

local noteSwingRef   -- read by the Attack_Multicast hook below
local REPEAT_RATE = 0.40
local chain = nil     -- { nextAt, combo, calledAt } while a chain is live
local lastSwing = { at = nil, combo = nil, weapon = nil }
local repeaterCalls, repeaterRefused = 0, 0

--- Attack action state: true if Started/Ongoing (flag bits 2 or 4).
local function attackHeld(controller)
    local _, trigger = inputState(controller)
    return trigger ~= nil and (trigger == 2 or trigger == 4), trigger
end

--- Fed by the Attack_Multicast hook: a swing happened.
local function noteSwing(weaponClass, combo)
    lastSwing.at, lastSwing.combo, lastSwing.weapon = os.clock(), combo, weaponClass
    if GUARD_MODES[guardMode] ~= "R" then return end
    if chain == nil then
        chain = { nextAt = lastSwing.at + REPEAT_RATE, combo = combo, calledAt = nil }
        emit(string.format("%8.3f  repeater: chain opened by the game's swing (combo %s)",
            lastSwing.at, tostring(combo)))
    else
        chain.nextAt = lastSwing.at + REPEAT_RATE
        chain.combo = combo
    end
end

--- Runs every pump tick. Cheap when no chain is live.
noteSwingRef = noteSwing

local function repeaterTick()
    if chain == nil then return end
    if GUARD_MODES[guardMode] ~= "R" then chain = nil return end
    local now = os.clock()
    if now < chain.nextAt then return end

    -- Our previous call produced no swing: the game refused. Stop.
    if chain.calledAt ~= nil and (lastSwing.at == nil or lastSwing.at < chain.calledAt) then
        repeaterRefused = repeaterRefused + 1
        emit(string.format("%8.3f  repeater: no swing followed our call -- refused; chain closed", now))
        chain = nil
        return
    end

    local controller = localController()
    if controller == nil then chain = nil emit("  repeater: no controller; chain closed") return end
    local held, trigger = attackHeld(controller)
    if not held then
        emit(string.format("%8.3f  repeater: key up (trigger %s); chain closed after %d call(s)",
            now, tostring(trigger), repeaterCalls))
        chain = nil
        return
    end
    local target, how = meleeInHand()
    if target == nil or numberProp(target, PROP.holster) ~= 1 then
        emit(string.format("%8.3f  repeater: no melee weapon Equipped (%s); chain closed", now, how))
        chain = nil
        return
    end

    local combo = (chain.combo or 0) + 1
    local ok, err = pcall(function() target.Attack_Server(target, combo) end)
    repeaterCalls = repeaterCalls + 1
    chain.calledAt = now
    chain.nextAt = now + REPEAT_RATE
    emit(string.format("%8.3f  repeater: Attack_Server(%d) on %s %s", now, combo,
        className(target), ok and "called" or ("THREW " .. tostring(err))))
end

-- ==========================================================================
-- F3 / F2 -- route B's primitive: can the mod swing the weapon itself?
-- Attack_Server(0) and Attack_Multicast(0) on the melee weapon in hand, one
-- call per press. The hooks log the call; whether a swing is SEEN is
-- Daniel's eyes, and whether Attack_Server leads to an Attack_Multicast
-- line of its own is the file's. If either produces a real swing, the mod
-- can drive the cadence itself and never needs the game's loop at all.
-- ==========================================================================

local function callAttack(which)
    emit("")
    emit(string.format("%8.3f  %s: call %s(0) on the weapon in hand",
        os.clock(), which == "Attack_Server" and "F3" or "F2", which))
    local target, how = meleeInHand()
    if target == nil then emit("  " .. how) return end
    local ok, err = pcall(function() target[which](target, 0) end)
    emit(string.format("  %s: %s(0) %s -- did it swing?", className(target), which,
        ok and "returned" or ("THREW " .. tostring(err))))
end

-- ==========================================================================
-- Hooks. Log only. They run inside the game's own call and touch nothing but
-- their parameters and the file. Registered whether or not recording is on,
-- because the swing that answers the question may be the first one.
-- ==========================================================================

local lastAttack = { server = nil, multi = nil }

--- Once per weapon class: every montage in AttackAnimChain and its play
--- length, so the next file can say whether the measured click cadence is
--- derivable from the animation (and the CADENCE table in main.lua could
--- become a formula). Best effort: GetPlayLength is a UAnimSequenceBase
--- UFunction; if it is not callable here the line says so.
local montagesLogged = {}
local function logMontages(weapon)
    local class = className(weapon)
    if montagesLogged[class] then return end
    montagesLogged[class] = true
    local chainStruct = get(weapon, "AttackAnimChain")
    local attacks = get(chainStruct, "Attacks")
    local lines, n = {}, 0
    local walked = pcall(function()
        attacks:ForEach(function(_, element)
            local entry = deref(element)
            local montage = deref(get(entry, "Montage"))
            n = n + 1
            local length = nil
            pcall(function() length = montage:GetPlayLength() end)
            local rate = numberProp(montage, "RateScale")
            lines[#lines + 1] = string.format("      [%d] %-40s length=%s rateScale=%s",
                n, real(montage) and shortName(fullName(montage)) or "-",
                type(length) == "number" and string.format("%.3f", length) or "?",
                rate and string.format("%.2f", rate) or "?")
        end)
    end)
    if not walked then
        emit("  montages: AttackAnimChain.Attacks did not walk on " .. class)
        return
    end
    emit(string.format("  montages on %s (%d in AttackAnimChain):", class, n))
    for _, line in ipairs(lines) do emit(line) end
end

local function logAttack(which, self, combo)
    local weapon = deref(self)
    if which == "Attack_Multicast" then pcall(logMontages, weapon) end
    local index = deref(combo)
    if type(index) ~= "number" then
        local n = nil
        pcall(function() n = tonumber(tostring(index)) end)
        index = n
    end
    local now = os.clock()
    local gap = lastAttack[which] and (now - lastAttack[which]) or nil
    lastAttack[which] = now
    emit(string.format("%8.3f  %-16s %-28s combo=%s gap=%s", now, which,
        className(weapon), index ~= nil and tostring(index) or "?",
        gap and string.format("%.3fs", gap) or "first"))
    if which == "Attack_Multicast" and noteSwingRef ~= nil then
        pcall(noteSwingRef, className(weapon), index)
    end
end

local function registerHooks()
    local results = {}
    results[#results + 1] = (pcall(function()
        RegisterHook(HOOK.attackServer, function(self, combo)
            pcall(logAttack, "Attack_Server", self, combo)
        end)
    end) and "hooked " or "COULD NOT HOOK ") .. HOOK.attackServer

    results[#results + 1] = (pcall(function()
        RegisterHook(HOOK.attackMulti, function(self, combo)
            pcall(logAttack, "Attack_Multicast", self, combo)
        end)
    end) and "hooked " or "COULD NOT HOOK ") .. HOOK.attackMulti

    results[#results + 1] = (pcall(function()
        RegisterHook(HOOK.autoEffect, function(self, active)
            pcall(function()
                emit(string.format("%8.3f  %-16s %-28s active=%s", os.clock(),
                    "SetAutoFireFx", className(deref(self)),
                    tostring(deref(active))))
            end)
        end)
    end) and "hooked " or "COULD NOT HOOK ") .. HOOK.autoEffect

    for _, line in ipairs(results) do
        emit("  " .. line)
        log(line)
    end
end

local function toggle()
    recording = not recording
    if recording then
        samples, changes = 0, 0
        last = {}
        ticksSeen = 0
        emit("")
        emit("================================================================")
        emit(string.format(" %s %s   RECORDING from %s", MOD, VERSION,
            os.date("%Y-%m-%d %H:%M:%S")))
        emit("================================================================")
        emit(" One line per CHANGE, plus one per hooked attack call.")
        emit("   carried items   every AHeldenEquipableItem on the pawn, with")
        emit("                   HolsterState and the auto-fire fields if it has them")
        emit("   input           the attack action's ETriggerEvent and hold time")
        emit("   Attack_Server / Attack_Multicast   weapon, combo index, gap since")
        emit("                   the previous call of the same kind")
        emit("")
        emit(" WHAT TO DO: equip each melee weapon in turn. For each: click once,")
        emit(" wait, click as fast as you can for ~3 s, wait, then HOLD for ~3 s.")
        emit(" The gaps under fast clicking are the game's own cadence; the gaps")
        emit(" under hold, if any, say whether the weapon already auto-fires.")
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
-- The pump (crash rule K). One LoopAsync, one ExecuteInGameThread. The
-- keybind sets a flag and nothing else.
-- ==========================================================================

local pendingToggle = false
local pendingEquip = false
local pendingFlip = false
local pendingRate = false
local pendingAll = false
local pendingGuard = false
local pendingServer = false
local pendingMulti = false
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
            if pendingEquip then
                pendingEquip = false
                local ok, err = pcall(equipNext)
                if not ok then
                    log("equip error: " .. tostring(err))
                    emit("  equip error: " .. tostring(err))
                end
            end
            if pendingFlip then
                pendingFlip = false
                local ok, err = pcall(flipAutoFire)
                if not ok then
                    log("flip error: " .. tostring(err))
                    emit("  flip error: " .. tostring(err))
                end
            end
            if pendingRate then
                pendingRate = false
                local ok, err = pcall(cycleRate)
                if not ok then
                    log("rate error: " .. tostring(err))
                    emit("  rate error: " .. tostring(err))
                end
            end
            if pendingAll then
                pendingAll = false
                local ok, err = pcall(flagAll)
                if not ok then
                    log("flag-all error: " .. tostring(err))
                    emit("  flag-all error: " .. tostring(err))
                end
            end
            if pendingGuard then
                pendingGuard = false
                local ok, err = pcall(cycleGuard)
                if not ok then log("guard cycle error: " .. tostring(err)) end
            end
            if pendingServer then
                pendingServer = false
                local ok, err = pcall(callAttack, "Attack_Server")
                if not ok then log("attack call error: " .. tostring(err)) end
            end
            if pendingMulti then
                pendingMulti = false
                local ok, err = pcall(callAttack, "Attack_Multicast")
                if not ok then log("attack call error: " .. tostring(err)) end
            end
            do
                local ok, err = pcall(verifyEquip)
                if not ok then log("verify error: " .. tostring(err)) end
            end
            do
                local ok, err = pcall(repeaterTick)
                if not ok then log("repeater error: " .. tostring(err)) end
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
local boundEquip = pcall(function()
    RegisterKeyBind(KEY_EQUIP, function() pendingEquip = true end)
end)
local boundFlip = pcall(function()
    RegisterKeyBind(KEY_FLIP, function() pendingFlip = true end)
end)
local boundRate = pcall(function()
    RegisterKeyBind(KEY_RATE, function() pendingRate = true end)
end)
local boundAll = pcall(function()
    RegisterKeyBind(KEY_ALL, function() pendingAll = true end)
end)
local boundGuard = pcall(function()
    RegisterKeyBind(KEY_GUARD, function() pendingGuard = true end)
end)
local boundServer = pcall(function()
    RegisterKeyBind(KEY_SERVER, function() pendingServer = true end)
end)
local boundMulti = pcall(function()
    RegisterKeyBind(KEY_MULTI, function() pendingMulti = true end)
end)

emit("")
emit(string.format("---- %s %s loaded %s", MOD, VERSION, os.date("%Y-%m-%d %H:%M:%S")))
registerHooks()

log("loaded " .. VERSION .. ". F11 is read-only; F10 puts weapons in the world.")
if not pumpStarted then
    log("FATAL: LoopAsync did not start -- nothing will ever run.")
end
log(bound and "F11  start / stop recording -> " .. OUT_FILE
    or "F11 could not be registered")
log(boundEquip and string.format("F10  equip / spawn the next of %d weapons (solo only)", #ITEMS)
    or "F10 could not be registered")
log(boundFlip and "F9   flip bCanAutoFire on the weapon in hand (writes one bool)"
    or "F9 could not be registered")
log(boundRate and "F8   cycle AutoFireRate 0.5/0.4/0.3/0.2/0.1 on the weapon in hand"
    or "F8 could not be registered")
log(boundAll and "F5   flag EVERY melee weapon in the world, rate 0.40"
    or "F5 could not be registered")
log(boundGuard and "F4   REPEATER off <-> R: the mod repeats a chain the game started"
    or "F4 could not be registered")
log(boundServer and "F3   call Attack_Server(0) on the weapon in hand"
    or "F3 could not be registered")
log(boundMulti and "F2   call Attack_Multicast(0) on the weapon in hand"
    or "F2 could not be registered")
