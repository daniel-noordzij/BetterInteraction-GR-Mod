# BetterInteraction — Grain Rot QoL mod

Project brief for Claude Code. Read this fully before touching any file.

## What we are building

A **publicly released quality-of-life mod for Grain Rot** that makes interaction
kinder to the player's hand and less fiddly generally. One deliverable:

- **`BetterInteraction`** — a UE4SS Lua mod, distributed on Thunderstore in the
  existing `grain-rot` community, packaged for `unreal-shimloader`.

The headline feature is **no more spam-clicking**: anything the game currently
asks you to hammer becomes a single action. Alongside it sits one fix for an
input-timing bug in the base game. Each feature is individually switchable from
a config file.

**The five features are listed in "What we are actually building" below.** That
list came from Daniel on 29 Aug 2026 and it replaces the guesses this file
originally carried. In particular **prompt reach and aim forgiveness are NOT
wanted** — the interaction angle and distance are fine as the game ships them.
An earlier version of this brief nominated those as "Phase 1 … the cheapest
possible win and it may be most of the mod"; that was an assumption, it was
built, it worked, and it was not the requirement.

Target audience is the game's mod community, not just us. It must be installable
by a stranger through r2modman, survive game patches without a rewrite, and be
safe to run in a co-op lobby.

**This is a QoL mod, not a cheat.** That line is a design constraint, not a
disclaimer — see "The line between QoL and cheating" below.

## Environment facts (verified — do not re-derive, do not contradict)

| Thing | Value |
|---|---|
| Game | Grain Rot |
| Developer / Publisher | Beck & Branch Games / Neem Interactive |
| Released | 7 August 2026, Steam, Windows only |
| Genre | 1–20 player co-op extraction horror + base building |
| Engine | Unreal Engine 5.7.4.0 |
| Product version string | `++UE5+Release-5.7-CL-51494982` |
| Shipping exe | `Helden-Win64-Shipping.exe` |
| Modding loader | UE4SS (RE-UE4SS) v3.0.1 Beta, Git SHA `e31aaaa6` |
| Anti-cheat | **None shipped.** No EAC / BattlEye / EOS binaries anywhere in the install |
| Pak encryption | **None.** Unencrypted, unsigned IoStore containers |

### Verified on Daniel's machine

| Thing | Value |
|---|---|
| Steam install root | `F:\SteamLibrary\steamapps\common\Grain Rot\` |
| Binary dir | `Grain Rot\Helden\Binaries\Win64\` |
| Lua mods directory | `%APPDATA%\Thunderstore Mod Manager\DataFolder\GrainRot\profiles\<profile>\shimloader\mod\` — shimloader redirects `Win64\Mods` here. **Not** `Content\Paks\LogicMods\`, which is for Blueprint pak mods only |
| Profile config dir | `…\<profile>\shimloader\cfg\` — sits beside `mod`, `overlay`, `pak`. This is where our config file goes |
| Mod layout | `mod\BetterInteraction\Scripts\main.lua` + an empty `mod\BetterInteraction\enabled.txt` |
| Lua | 5.4 with the full stdlib — `io` (incl. `io.popen`), `os`, `require`, `package`. Write+readback verified. cwd is the `Win64\` dir |
| Dumps on disk | `Win64\UE4SS_ObjectDump.txt` (33 MB), `Win64\CXXHeaderDump\` (948 headers — `Helden.hpp` 667 KB, `Engine.hpp` 1.7 MB), and a `.usmap` |

### The internal project name is `Helden`, not `GrainRot`

The UE project was named `Helden`. Every native class is `AHelden*` / `UHelden*`,
content lives under `Helden/Content/…`, and any third-party guide naming
`GRAIN_ROT-Win64-Shipping.exe` is wrong. **Game logic is native C++, not
Blueprint** — the `BP_Helden*` headers are near-empty stubs that add a component
or two. Target native classes and `UFunction`s by name.

### UE4SS on 5.7 — the important part

UE4SS's built-in AOB signatures **do not fully resolve on stock UE 5.7 builds**.
This is already solved for Grain Rot: the **Thunderstore `GrainRot_UE4SS`
community package** ships 5.7.4 signature overrides derived from RE-UE4SS issue
#1228 (by aslavd). The `TyrnelQoL` Nexus mod ships the same lineage.

**Do not attempt to generate our own AOBs.** Depend on the existing overrides
and treat them as an external dependency to re-check after every game patch.

**They are NOT vendored, and that is deliberate** (verified 30 Aug 2026): the
`Thunderstore-GrainRot_UE4SS` package ships them at
`overlay/UE4SS_Signatures/{FName_Constructor,GNatives,GUObjectHashTables,StaticConstructObject}.lua`
and our manifest depends on it. A second copy in our own package would be a
second thing to keep current, and could conflict with the first.

UE4SS **cannot be upgraded**: the experimental branch supports at most 5.6 and
will not boot 5.7. We are pinned to this build and its bugs.

---

## The interaction surface

Read out of the CXX header dump and the object dump on 29 Aug 2026. These are
facts about **what exists**. Which of them actually governs a given annoyance is
**not yet established** — that is Phase 0's job.

### `UInteractionComponent : USceneComponent` — the whole mod, basically

Every interactable in the game owns one. **1519 instances** exist in the dump.

| Property | Offset | What it is worth to us |
|---|---|---|
| `bool bIsHoldInteraction` | 0x318 | tap vs hold. **The spam-click switch** |
| `float HoldInteractionDuration` | 0x31C | how long the hold takes |
| `bool bAutoEndHoldInteract` | 0x321 | whether the hold completes on its own |
| `bool bHolsterDuringHoldInteract` | 0x320 | holsters the held item during a hold |
| `bool bAllowSoulHoldInteract` | 0x319 | hold interactions while a spirit |
| `float InteractionCooldown` | 0x2C4 | the gap between repeats — the spam-rate governor |
| `float MaxInteractDistance` | 0x2D8 | reach |
| `bool bLineTraceValidate` | 0x2DC | whether a clear line of sight is required |
| `float LineTraceDiscardRadius` | 0x2E0 | aim forgiveness |
| `FText PromptInteractionText` | 0x2C8 | the prompt wording |
| `EHeldenActionLock InputAction` | 0x2E4 | which button drives it |
| `bool bIsInteractable` / `bLockInteraction` | 0x2C0 / 0x2C2 | availability |
| `bool bDisableDuringDialogue` | 0x2C1 | |
| `bool bUseInteractVolume`, `FName InteractVolumeComponentTag` | 0x2EC / 0x2F0 | volume-based instead of distance-based |
| `bool bUseCustomInteractLocation`, `FVector CustomInteractLocation` | 0x2F8 / 0x300 | where the prompt anchors |
| `EHeldenResource InteractCostResource`, `int32 InteractCost` | 0x2E5 / 0x2E8 | **DO NOT TOUCH — economy, not QoL** |
| `TWeakObjectPtr<APawn> CharacterInProximity` | 0x324 | who is near it |
| `UInteractionSettings* InteractionSettings` | 0x338 | back-pointer to the shared asset |

Functions: `SetIsInteractable(bool)`, `GetInteractionLocation(APawn*)`,
`GetHoldInteractAlpha(float)`.

Delegates it broadcasts: `InteractionBeginDelegate`, `LocalInteractionBeginDelegate`,
`HoldInteractUpdateDelegate(APawn*, float InAlpha)`, `GainFocusDelegate`,
`LostFocusDelegate`, `RequestInteractLocationDelegate`.

### `UInteractionSettings : UDataAsset` — the global knobs

**One live instance: `/Game/Core/InteractionSettings.InteractionSettings`.**
Also reachable as `UHeldenDataSingleton::InteractionSettings` (offset 0x1D8) and
as `UHeldenInteractionSubsystem::InteractSettings`.

| Property | Offset |
|---|---|
| `FName OutlineTag` | 0x30 |
| `float InteractProximityDistance` | 0x38 |
| `float InteractProximityAngle` | 0x3C |

Three floats on one asset that likely govern "does the prompt appear at all" for
the entire game. If a change here does what we want, it is by a wide margin the
cheapest and most patch-stable version of this mod.

### `UHeldenInteractionSubsystem : UTickableWorldSubsystem` — the safe entry point

Live instance in the persistent level:
`/Game/Maps/Helden_Main.Helden_Main:HeldenInteractionSubsystem_2147480855`.

| Property | Offset | Note |
|---|---|---|
| `TArray<FHeldenInteractionEntry> RegisteredInteractionEntries` | 0x48 | every registered component. `FHeldenInteractionEntry` is one field: `UInteractionComponent* Component` |
| `TArray<UInteractionComponent*> HotInteractions` | 0x58 | the ones live right now |
| `UInteractionSettings* InteractSettings` | 0x68 | |

**This matters more than anything else in this document.** It means we reach every
interaction component by a **property walk from an object we already hold**, and
never by `FindAllOf` over 1519 objects on a timer. That is the difference between
the safest tier of access and the most crash-prone one — see crash rule E.

### `AHeldenInteractableObject : AHeldenObject` — the actor base

Roughly 30 subclasses: `AHeldenChest`, `AHeldenDoor`, `AHeldenElevator`,
`AHeldenElevatorButton`, `AHeldenElevatorMachine`, `AHeldenEndDayObject`,
`AHeldenEquipableItem`, `AHeldenGumballMachine`, `AHeldenItemtSlot` [sic],
`AHeldenLeverObject`, `AHeldenLotteryWheel`, `AHeldenOpenableObject`,
`AHeldenOutpostStash`, `AHeldenPackageLootSpot`, `AHeldenPackageSpot`,
`AHeldenSwitch`, `AHeldenTipJar`, `AHeldenUpgradeMachine`, `AHeldenUnlockableObject`,
`AHeldenCoinDepositObject`, `AHeldenInteractableLock`, `AHeldenTeleportGate`,
`AHeldenSoulTeleport`, `AHeldenInspectableView`, `AHeldenAudioLogInteraction`,
`AHeldenConstructDiscover`, `AHeldenCosmeticLoot`, `AHeldenPhysicsOpenableObject`.

Key members: `UInteractionComponent* InteractComponent` (0x420),
`bool bInteractionLocked` (0x454), `TArray<AHeldenInteractableObject*> ForwardInteractions`,
`bool bUseInteractRequirement` + `FHeldenRequirement InteractRequirement`.

Functions on the base: `Interact(APawn*)`, `Interact_Local(APawn*)`,
`OnInteract(APawn*)`, `OnInteract_Local(APawn*)`,
`HoldInteractUpdate(APawn*, float InAlpha)`, `GainInteractFocus(APawn*)`,
`LostInteractFocus(APawn*)`, `CanBeInteracted(APawn*)`, `CanBeInteractedBP(APawn*)`,
`DisableInteractForDuration_Auth(float)`, `SetCanBeInteracted_Auth(bool)`.

### The character side

`AHeldenCharacter` carries `UInteractionComponent* InteractComponent` (0x C10),
`TWeakObjectPtr<AActor> CurrentInteraction` (0xBB0) with `OnRep_CurrentInteraction`,
and these functions: `Interact_Local(APawn*)`, `Interact_Auth(APawn*)`,
`InteractObjectEvent_Server(uint8 InEvent)`, `AbortCurrrentInteraction_Server()` [sic],
`CanBeInteracted(APawn*)`.

The `_Auth` / `_Server` suffixes are the whole co-op story: **the server decides
whether an interaction actually happens.** See co-op below.

### Per-actor spam and cooldown candidates

Not confirmed as the cause of any specific annoyance — a menu to probe against.

| Where | Property |
|---|---|
| `AHeldenUpgradeMachine` | `float PickUpItemCooldown` (0x524), `int32 CoinsLeftToPay` (0x630), `AHeldenCoinDepositObject* CoinDeposit` |
| `AHeldenCoinDepositObject` | `FHeldenMoney RequiredMoney`, `FHeldenMontage InteractAnimation`, `UHeldenEffectPreset* InsertCoinEffect` |
| `AHeldenOpenGumballObject` | `float PostDestroyInteractCooldown` (0x658), `GiveRewardDelay`, `ShowHudRewardDelay` |
| `AHeldenLeverObject` | `float LeverPauseDuration`, `float LeverAnimDuration` |
| `AHeldenTipJar` | `FHeldenMoney RerollCost` |
| `AHeldenOutpostStash` | opens `UHeldenStashWidget` — a menu, so item transfer is UI, not repeated interaction |

**`CoinsLeftToPay` on the upgrade machine is the strongest signal in this table
that the game has a coin-at-a-time deposit loop** — which is exactly the shape of
thing "prevent spam clicking" is about. It is a signal, not a finding.

### The UI hold button

`UHeldenHoldButtonWidget : UHeldenButtonWidget` — `float RequiredHoldDuration`
(0x410), `UHeldenProgressBar* HoldProgressBar`, `void OnSetHoldTime(float)`.
Menu hold-to-confirm prompts. A separate, smaller QoL target with its own risk
profile (it is pure UI, so it is the safest thing in this document).

### `UInteractionWidget : UUserWidget` — the world prompt

`FText PromptText`, `EHeldenInteractState InteractState`
(`Hidden`=0, `ProximityRange`=1, `Focused`=2), `UHeldenProgressBar* ProgressBarWidget`,
`UHeldenPriceEntry* InteractCostWidget`, `UHeldenInputIconWidget* InputIcon`.
Functions include `SetHoldInteractAlpha(float)` and `SetPromptText(FText)`.

### `EHeldenActionLock` — the input action enum

`Jump`=0, `Interact`=1, `Move`=2, `Look`=3, `Sprint`=4, `FlashLight`=5, `Crouch`=6,
`Dodge`=7, `UI_Accept`=8 … `Attack`=15, `SecondaryInteract`=16,
`TertiaryInteract`=17 … `InventoryAction01`–`04`=29–32, `PushToTalk`=34,
`DropItemAction`=36, `AltAttack`=37, `PhysZoom`=38, `PhysRotate`=39, and more.

`UInteractionComponent.InputAction` is one of these. Three separate interact
actions exist (`Interact`, `SecondaryInteract`, `TertiaryInteract`).

---

## What works through UE4SS on this build

Proven during live sessions on this exact game build, in a sibling project. Do
not retest these; do not design around a technique this table calls dead.

| Technique | Result | Use it? |
|---|---|---|
| **Reading and writing properties on persistent UObjects** | **Works.** This is the backbone | **Yes — primary** |
| `RegisterHook` on `_Multicast` / `_Server` RPCs | Fires | Yes |
| `RegisterHook` on `_Client` RPCs | Fires, and carries parameters | Yes |
| **`RegisterHook` on `HeldenInteractableObject:Interact`** | **Fires.** Proven in probes and in shipped production use | **Yes — this mod's main event hook** |
| `RegisterHook` on `OnRep_*` | **Never fires.** RepNotifies are direct native calls and bypass UE4SS's reflection hooks. Proven: the property demonstrably changed, the hook never ran | No |
| `RegisterHook` on other plain native `UFunction`s | **Mostly never fires.** `StartNewDay`, `EndCurrentDay`, `HasFact` all silent while their events definitely occurred | Only where proven, one at a time |
| `RegisterHook` on widget `OnInitalize*` / `OnSet*` | **Never fires.** Eight functions across three screens | No |
| `NotifyOnNewObject` | Works, but noisy — and see crash rule G | Carefully |

**Only reflection-dispatched calls are hookable** — `_Multicast` / `_Server` /
`_Client` RPCs, and functions the Blueprint layer invokes. `Interact` is in the
second group, which is why it works when its neighbours do not. Everything else
must be polled.

`Interact_Local`, `OnInteract`, `HoldInteractUpdate`, `GainInteractFocus`,
`CanBeInteracted` are **unproven**. Test each individually before building on it;
do not assume they inherit `Interact`'s luck.

### The memory-safety rule

> Fields of persistent `UObject`s are safe to read, write and convert.
> **Fields of a struct returned by value across the Lua/native boundary are not** —
> reading one can hard-crash the process to desktop.

`pcall` **cannot catch this**. It catches Lua errors, not access violations in
game memory. Learned by crashing the game twice, from two different call sites,
and the earlier-failing variant is what ruled out every other explanation.

Relevant here: `FHeldenMoney`, `FHeldenRequirement`, `FHeldenMontage` and
`FVector` members are struct-shaped. Read and write them **in place on the
persistent object**, never through a by-value getter.

Also: `TArray` has no `Add` method from Lua — grow by index-append at `count + 1`.
`TMap:Add` accepts a plain Lua table as the struct value.

---

## Crash-safety rules for the Lua mod. Every one is written in blood.

A sibling mod on this same game produced fifteen-plus fatal errors across two
machines, in four apparently different places. They were three families, and
almost every one came from breaking a rule below. UE4SS gives you no stack, no
symbols, and `pcall` cannot catch an access violation — so a mistake here is not
an error message, it is a dead process and an hour of dump parsing.

**A. A wrapper around null is TRUTHY. Never test a UObject for existence with truthiness.**

`FindFirstOf`, `StaticFindObject` and property reads return a *wrapper* whether or
not the object exists. `if not x`, `if x`, `x ~= nil` all pass for a wrapper around
nothing, and the next line writes into null. This trap has been paid for five
separate times, once silently breaking a feature for an entire session.

| you have | the test |
|---|---|
| a `FindFirstOf` result | `resolve(nil, "ClassName")` — returns nil for a null wrapper |
| a `StaticFindObject` result | keep the call, test `fullName(x) ~= ""` |
| a value that should be a number/bool | `type(x) == "number"` / `"boolean"` — never `~= nil` |
| a CACHED reference you already held | `alive(x)`, and see rule C |

```lua
local function resolve(cached, class)
    if alive(cached) and fullName(cached) ~= "" then return cached end
    local found = nil
    pcall(function() found = FindFirstOf(class) end)
    if found ~= nil and fullName(found) == "" then return nil end   -- null wrapper
    return found
end
```

**B. `IsValid()` DEREFERENCES. It is not safe on a freed object.**

It reads through the pointer — on freed memory that *is* the crash, not a test for
it. `fullName()` is the same: it walks the Outer chain. Neither can tell "freed"
from "alive"; they only tell "null wrapper" from "object".

**C. Never reuse a held UObject unless a clearing event provably PRECEDES the dereference.**

A "validate-and-reuse" cache that called `fullName()` on a held controller at the
top of each pass crashed 100% of save starts on both machines, because at a world
change that object is freed *before* the code that nils the cache runs. It
replaced exposure to a race with a certainty.

- **forget-then-validate, never validate-then-forget.**
- A cache is safe only where something structural guarantees the object outlived
  the gap (a widget built once with the HUD).
- Everything else re-resolves. A rescan is exposure to a race; a stale pointer is
  a crash.

**This is the rule this mod will be most tempted to break.** Caching 1519
`UInteractionComponent` pointers so you don't have to re-walk the subsystem array
is exactly the shape that has already killed the game twice. Re-walk the array.

**D. Deferred work must not outlive its world. Capture the world epoch at SCHEDULE time.**

```lua
local epoch = binding.epoch                     -- captured when scheduled
defer.at(delay, "what this is", function()
    -- defer checks epoch ~= binding.epoch centrally, BEFORE any dereference
end)
```

Bump the epoch at every world change. A `K2_DestroyActor` on an object the level
purge had already taken is a real crash we have shipped; the tell was a `+800ms`
step firing *before* the `+50ms` steps, because it had been scheduled in the
previous world.

**E. Walking the global object array is the mod's single largest crash exposure.**

`FindFirstOf` / `FindAllOf` iterate every UObject, and upstream RE-UE4SS issue
**#1328** documents that walk racing GC and returning *text fragments as object
pointers* — ASCII read as addresses. It is unfixed, and `bUseUObjectArrayCache=false`
does not prevent it.

**Never scan on a hot path.** Prefer, in order: a property walk from an object you
already have; a throttle (one scan per second); and only then a scan. A registry
filled by `NotifyOnNewObject` is **not** a substitute — a registry is a cache, rule
C applies in full, and one such registry probed clean for seconds and then crashed
the game the first time GC got a long gap.

**For this mod, rule E is nearly free to obey**: `UHeldenInteractionSubsystem`
gives you every interaction component by property walk. Resolve the subsystem
once per pass, walk its arrays, touch nothing else.

**F. Do not do expensive or destructive work during a level transition.**
Gate on "has this world ever been playable" — a fact, not a timer. Save-start
crashes and a corrupted `.sav` both came from work landing in that window.

**G. Do not read the object inside a `NotifyOnNewObject` callback.**
It runs inside the game's construction; properties read 0 or crash. Store the
wrapper, defer every read to a later step.

**H. A guard that can silently do nothing must say so.**
Log the skip and what was skipped, or "the fix never ran" and "the fix ran and did
nothing" look identical in the log — which has already cost a whole test run. When
a count disagrees with expectation, log the population, not a sample of it.

**I. Check, then deploy — and gate on the checker's own exit code.**

```bash
py tools/lua_check.py > /dev/null 2>&1 && cp ... || echo REFUSED
```

A broken `main.lua` reached the profile twice because the guard was
`lua_check | grep -v ok && cp`, which tests **grep's** exit code. Verify with
`md5sum` on both paths afterwards.

**J. When you cannot name the cause, ship instrumentation, not a fix.**

Write one **flushed** line to a file before every step of the suspect path,
timestamped. UE4SS's own log is buffered and loses the last seconds before a
crash. Eleven lines of file I/O once ended a hunt that six code changes could not.
Crash dumps live in `%LOCALAPPDATA%\Helden\Saved\Crashes\UECC-*` —
`CrashContext.runtime-xml` carries the stack without needing the minidump, and
`PCallStackHash` identifies the family in one line.

**K. NEVER schedule through UE4SS. All delayed work goes through one queue.
This rule is load-bearing for every session that touches `main.lua`, forever.**

Upstream RE-UE4SS **#1180**, unfixed on any build that boots 5.7:
`process_simple_actions` drains the engine-tick action vector with `erase_if`, its
mutex is RECURSIVE, and an `ExecuteWithDelay` / `ExecuteInGameThread` call made
from inside any drained callback appends mid-iteration and corrupts the stored Lua
registry refs. The process then dies with "Abort signal received" or
`Ref was not function`. **Seven of one tester's fifteen crashes in a single session
were this.** These look random, strike hardest on slow machines and unfocused
windows, and come back the moment someone reintroduces the pattern — because it
works fine on a fast machine.

```lua
LoopAsync(TICK_MS, function()
    if inFlight then return false end       -- never queue faster than the game drains
    inFlight = true
    ExecuteInGameThread(function()          -- the ONLY steady append we make
        inFlight = false
        defer.drain()                       -- our own table, swapped before it runs
        pass()
    end)
    return false
end)
```

- **Every delay is `defer.at`, every retry ladder is one `defer.poll`, every
  "next frame" is `defer.at(0, ...)`.** The queue drains once per pass on the game
  thread; scheduling from inside a drained entry is safe by construction, because
  it appends to our live table and never the one being walked.
- **`defer` captures the world epoch centrally** (rule D) and drops stale entries
  with a diag line (rule H). Do not hand-roll a second epoch guard — one site's
  hand-rolled guard compared against an epoch that was never captured, which made
  that feature silently dead for weeks.
- **All UObject work runs on the game thread. Keybind callbacks are NOT on it** —
  route their bodies through `defer.at(0, ...)`. Any new callback source gets the
  same treatment unless proven otherwise.
- The pump — the single `ExecuteInGameThread` in the `LoopAsync` body — is the
  only steady append the mod makes. There is never a reason for a second one.

---

## Co-op — the central design problem for this mod

The game is peer-to-peer with a lobby host, up to 20 players, and it replicates a
seed and rebuilds procedural content locally. **Interaction is authority-gated**:
`Interact_Auth`, `InteractObjectEvent_Server`, `AbortCurrrentInteraction_Server`
and `DisableInteractForDuration_Auth` all say the server decides whether an
interaction actually happened.

That splits every feature into one of three buckets, and **each feature must
declare its bucket in a comment at the site before it is written**:

**1. Local presentation — safe, and where most of this mod should live.**
`InteractProximityDistance`, `InteractProximityAngle`, `LineTraceDiscardRadius`,
`MaxInteractDistance`, `PromptInteractionText`, the `UInteractionWidget` progress
bar, `UHeldenHoldButtonWidget.RequiredHoldDuration`. These change what *your*
machine shows and offers. They need no agreement with anyone.

**2. Local input shaping — safe if it only re-sends what the player could send.**
Turning a spam-press into a hold, or auto-repeating `Interact` while a button is
down, is legitimate as long as every resulting call is one the unmodded game
would have accepted at that moment. This is the headline feature and it lives here.

**3. Authoritative state — the trap.**
`InteractionCooldown`, `bIsHoldInteraction` and `HoldInteractionDuration` may be
validated server-side. If they are, a client that shortens its own cooldown gets a
prompt that lets it press faster while the host silently rejects the extra presses
— which reads to the player as the mod being broken, not as a desync. **Establish
by test whether the host validates these before shipping anything that changes
them**, and say in the docs what happens when only some of the lobby has the mod.

Two hard prohibitions:

- **Never write into `GameState.Facts` or anything reaching `UHeldenSaveGame`.**
  Those replicate *and* persist, so they contaminate the save file. A sibling
  project corrupted a `ProfileSaveGame.sav` learning this.
- **Never force the game's own save.** It is a real corruption risk.

Design for a 2+ player lobby from the first line. "It works when I host" is not a
finished feature. For anything a guest must see or feel, name the channel in the
design before writing the code.

## The line between QoL and cheating

This mod goes on a public mod page and people will play it with strangers. Where
the line falls is a design decision, so it is written down here rather than
re-litigated per feature.

**In scope.** Fewer button presses for the same outcome. Prompts that appear when
you are obviously looking at the thing. Holds that are not tediously long. Aim
forgiveness. Anything that changes *effort*, not *result*.

**Out of scope, and not up for discussion.**
- `InteractCost` / `InteractCostResource` — that is the economy.
- Reach extended past "you are standing at it" into "you are across the room".
- `bUseInteractRequirement` / `InteractRequirement`, `bInteractRequiresQuest`,
  `bIsQuestObjective` / `bCompleteObjectiveOnInteract`, `bSetFactOnInteract` — that
  is progression.
- `SetCanBeInteracted_Auth` / `bLockInteraction` to open something the game locked.

If a feature request sits on the line, ship it **off by default** behind its own
config key and say so on the mod page.

---

## Architecture

One Lua file, one loop, one queue. There is no bridge, no second process, no
native component.

```
LoopAsync pump (rule K)
  └── defer.drain()                    every delayed step in the mod
  └── pass()
        ├── resolve UHeldenInteractionSubsystem   (re-resolved, never cached — rule C)
        ├── walk RegisteredInteractionEntries / HotInteractions
        └── apply the enabled config knobs to each UInteractionComponent

RegisterHook "HeldenInteractableObject:Interact"   (proven hookable)
  └── input shaping: auto-repeat / hold conversion
```

**The game re-applies its own values.** Assume every property we write gets
overwritten — on spawn, on level load, on state change. The mod is therefore a
*reconciler*, not a one-shot patcher: it re-asserts the desired value every pass
and does not assume a write stuck. Log when a value it wrote has been reverted,
at most once per object per world (rule H).

**Everything version-fragile goes in data, not code.** Class names, function
names, property names and the signature files each live in exactly one place, so
a game patch is one file to update.

### Config

A user-editable config file in `…\<profile>\shimloader\cfg\`, read at startup and
on a reload keybind. One key per feature, every feature independently switchable,
and every default conservative. `io` is available, so plain Lua or simple JSON —
no dependency.

Ship a diagnostic keybind that writes current state to a file and changes nothing.
It is the only instrument a bug reporter has.

## Repo layout

```
better-interaction/
├── CLAUDE.md                       # this file
├── mod/
│   ├── lua/BetterInteraction/
│   │   ├── Scripts/main.lua
│   │   └── enabled.txt
│   ├── cfg/BetterInteraction.cfg   # shipped defaults
│   ├── standalone/README.md        # install guide for the hand-installed zip
│   └── thunderstore/               # manifest.json, page README, icon.png
├── tools/
│   ├── lua_check.py                # block-structure check; refuses the truthiness form,
│   │                               # and every name that resolves to a nil global
│   ├── modpackage.py               # THE packaging rules; both builders import them
│   ├── test_packaging.py           # proves each rule REFUSES a violation, not just
│   │                               # that today's code passes
│   ├── build_thunderstore.py       # refuses while RELEASE_BLOCKERS stand
│   ├── build_standalone.py         # --install <profile> unpacks into a real r2modman profile
│   ├── make_icon.py                # the 256x256 Thunderstore icon, stdlib only
│   ├── patch_check.py              # AFTER A GAME UPDATE: what the patch moved
│   └── probe/                      # probes, kept as evidence, never shipped
├── data/
│   ├── patch_baseline.json         # exe hash + Steam buildid
│   └── inventory/                  # probe output, by date
└── docs/
    └── DESIGN.md                   # the working record
```

## What we are actually building

Daniel's list, 29 Aug 2026, verbatim in intent. Everything else in this file is
context for delivering these five things.

| # | The annoyance in the base game | The fix |
|---|---|---|
| **1** | Paying to leave by elevator: **5 gold at a time**, total 40 / 60 / 100 | insert all the gold you are carrying, up to the current quota |
| **2** | Paying the gumball machine: **1 artifact at a time**, total 3 | insert all the artifacts you are carrying, up to what is left |
| **3** | Picking up gold and artifacts after the grinder: **one input per coin**, and there can be dozens | picking one up also collects every gold/artifact coin in a small radius around it |
| **4** | Skipping NPC dialogue: **one space press per line** | hold space to keep skipping |
| **5** | **The eaten hold input.** Interacting with a hold object requires seeing the icon first. Hold the key even one frame early and the input is swallowed — you must release and re-press. (Fixing a spot, opening a casket, sitting on a chair.) | if the key is already held when the prompt appears, start the hold |

(5) is a different shape from the rest: it is a **timing bug**, not a repetition
count, and it is the only one that bites on every hold interaction in the game
rather than at specific machines. **It is being built first.**

(1) and (2) looked like the same mechanism and are **not**. Both machines'
counters are called `CoinsLeftToPay`, but the elevator's and the upgrade
machine's hold **currency** and drop by whatever was paid, while the gumball's
holds a **count of insertions** and drops by exactly one per press however much
was charged. Raising `RequiredMoney` is the whole fix for the first two and
destroys resources on the third. See `docs/DESIGN.md`, 30 Aug 2026.

### Phase plan

**Phase 0 — recon. Done.** A read-only probe walked every interaction component
in two worlds. The numbers are in `docs/DESIGN.md` §1.5 and are the reason
several of this file's original assumptions were retired.

**Phase 1 — the global knobs. Built, works, NOT WANTED.** `prompt_angle` and
`prompt_distance` apply correctly and are verified live; they stay in the config
defaulted to off because they are harmless and someone may want them. They are
not the mod.

**Phase 2 — feature 5, the eaten hold input.** In progress.

**Phase 3 — features 1 and 2**, the deposit-all mechanism, generalised across
all three coin-deposit machines.

**Phase 4 — feature 3**, the coin sweep.

**Phase 5 — feature 4**, hold-to-skip dialogue. Last because it has the most
unknowns and because advancing dialogue runs `Actions`/`PreActions`, which write
progression — see the fact/save prohibitions above.

**Phase 6 — co-op, config surface, Thunderstore release.** Co-op is deliberately
deferred at Daniel's direction (29 Aug 2026), not answered. Nothing ships
publicly until the bucket question for each feature is settled on two machines.

## Distribution

Thunderstore, in the existing `grain-rot` community, packaged for
`unreal-shimloader` so r2modman handles the UE4SS dependency. This is the path the
game's mod community already uses — do not invent a second one.

`manifest.json` dependencies: `Thunderstore-unreal_shimloader-1.1.7` and the Grain
Rot UE4SS package.

### Packaging rules — every build obeys these

Decided once in `tools/modpackage.py`; both builders import it. A rule that lives
in one builder is a rule the other one breaks.

1. **One mod build.** No host build, no guest build. Host vs guest is a runtime
   question. A build-time audience flag cannot answer a per-lobby question.
2. **Dev keybinds are cut, not disabled.** A disabled cheat is still a cheat one
   edited word from live, in a file people unpack and read. Delete the block and
   assert the absence of every key it registered.
3. **The diagnostic keybind survives, and that is checked separately.** "The
   cheats are gone" and "the instrument is still there" are two claims.
4. **No probes, ever.** Nothing under `tools/probe/` belongs in a package.
5. **Ship the config with conservative defaults**, and ship it as a file the user
   can read and edit, not as constants baked into `main.lua`.

## Hard rules for you (Claude Code)

1. **Never invent game internals.** The class, function and property names in this
   file came out of a real dump. Anything not in here, you do not know. If a task
   needs it, stop and ask Daniel to run a dump and paste the section. A hook
   written against a guessed name is worse than nothing, because it looks
   plausible and wastes a debugging session.

2. **Never hardcode addresses or offsets.** The offsets in this file are context
   for reading the dump, not values to use. Resolve everything by name through
   UE4SS's UObject system.

3. **The game will patch and break things.** Assume the exe changes monthly. Keep
   every version-fragile thing in data files, not scattered through code.

4. **Ask before adding dependencies.** The answer is almost always the stdlib.

5. **Never present a plausible cause as a confirmed one. Keep going until the
   evidence names the culprit.**

   The test for "sure": can you point at evidence that distinguishes this cause
   from the others? Not evidence *consistent* with it — evidence that rules the
   others out.

   | You have | It is | Say |
   |---|---|---|
   | a log line or readback only this cause explains | a finding | "this is the cause" |
   | "I changed this, the symptom is new, the timing fits" | a hypothesis | "best candidate, and it is not confirmed" |
   | "this code is wrong on its own terms" | a fix, unrelated to the symptom | "worth fixing either way; may or may not be it" |

   Those are three different claims and they must be worded differently — in the
   reply, in the commit message, and in `DESIGN.md`. A section that says **Not
   diagnosed** is worth more than one that says the wrong thing confidently.

   It follows that **a fix and its confirmation are two separate deliveries.** Ship
   the change, say plainly it is unconfirmed, say what would confirm it, and treat
   the next run's evidence as the thing that closes it — not the absence of a
   complaint.

6. **Every solution must work for all players by default, never just the host.**
   See the co-op section. Declare each feature's bucket at the site.

7. **Every set of test steps must say what has to be running.** Daniel cannot tell
   from a probe or a mod change whether it needs a lobby. State it explicitly, at
   the top, every time:

   | Say | Means |
   |---|---|
   | **No game at all** | Runs on this machine from the repo. Costs seconds, so it should already have been run before Daniel is asked for anything |
   | **Game only** | Launch through r2modman and play. One machine |
   | **Game, two machines** | A real lobby. Say which machine does what, in order |

   If a sequence changes what is needed part-way through, spell that out step by
   step rather than stating it once at the top.

8. **Deploy the change yourself, then verify it landed.** Copy into
   `<profile>\shimloader\mod\BetterInteraction\Scripts\main.lua`, gate the copy on
   the checker's exit code (rule I), and `md5sum` both paths. **Guests need a
   rebuilt zip** — a host-profile deploy reaches nobody else.

## Open questions

`docs/DESIGN.md` §2 is the live list and is more detailed. These are the ones
that shape the whole mod.

**Answered by measurement — do not re-derive:**

- [x] **Can Lua call these functions at all?** Yes. `HeldenPlayerController:Interact_Server(APawn*, UInteractionComponent*)`
      and `HeldenInteractableObject:Interact(APawn*)` both really perform the
      interaction. `Interact_Server` takes the component, so it is class-agnostic
      and works on things that are not `AHeldenInteractableObject` at all.
- [x] **Is `UInteractionSettings` one shared asset?** Yes — one asset, two
      independent routes agreeing, every component in two worlds pointing at it.
- [x] **Which interactions are repeat-fire?** Superseded by Daniel's list above.
      `InteractionCooldown` is **0.35 on all 739 components with zero variance**,
      so there is no per-class tuning to do and cooldown is not a lever.
- [x] **Does writing `RequiredMoney` change what a deposit takes?** Yes, exactly,
      including non-multiples.

**Still open, in the order they block work:**

- [ ] **What does `Interact_Server` do when the component is a HOLD?** Proven to
      complete a tap; completely unmeasured on a hold. It could start the hold,
      instantly complete the interaction, or do nothing — three different
      versions of feature 5. **This blocks Phase 2.**
- [ ] **Does the server rate-limit or distance-check re-issued `Interact_Server`
      calls?** Blocks feature 3's sweep.
- [ ] **Does `UHeldenDialogueWidget::AcceptAction()` advance a line, and is it
      callable?** Structurally it looks callable — it has its own native thunk,
      unlike the `On*` functions which all share `ExecuteUbergraph`. Blocks
      feature 4.
- [ ] **Co-op, for every feature.** Deferred at Daniel's direction, not answered.
      Feature 5 and feature 3 look like bucket 2; features 1 and 2 are bucket 3.
      Nothing ships publicly until this is settled on two machines.
- [ ] What does the `uint8` in `AHeldenCharacter::InteractObjectEvent_Server` mean?
      Not in the dump. It could be the hold begin/end channel, which would make
      feature 5 trivial. **Asking the dev (Nikko) is cheaper than reversing it.**
- [ ] Are `Interact_Local`, `HoldInteractUpdate` and `GainInteractFocus` hookable?
      Still unproven, and less important now that calling beats hooking.
