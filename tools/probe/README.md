# Probes

Read-only instruments. **Nothing in this directory ever ships in a package**
(packaging rule 4). They are kept as evidence of how a finding was reached.

| Probe | Phase | What it answers |
|---|---|---|
| `BetterInteractionProbe` | 0 | the real current value of every interaction knob, per component, grouped by owning actor class |
| `BetterInteractionAttackProbe` | hold-to-attack | per carried weapon: `bCanAutoFire`, `AutoFireRate` and the loop/effect flags; the attack action's trigger state; and a log-only hook on `Attack_Server` / `Attack_Multicast` giving the game's own swing cadence and combo index. F11 toggles recording (read-only). F10 equips the next of 20 attack items, by cheat manager first and a real spawn second, so every weapon can be tested without farming (writes to the world; solo only). |

## Installing one by hand

A UE4SS Lua mod is a folder with `Scripts/main.lua` and an **empty**
`enabled.txt` beside it. `enabled.txt` is the whole registration mechanism —
nothing has to be added to `mods.txt` or `mods.json`.

Shimloader redirects `Helden\Binaries\Win64\Mods` to the active r2modman
profile, so the destination is

```
%APPDATA%\Thunderstore Mod Manager\DataFolder\GrainRot\profiles\<profile>\shimloader\mod\
```

Copy the whole probe folder there, gating the copy on the checker's exit code —
never on a piped `grep`, which tests grep's exit code instead (crash rule I):

```bash
py tools/lua_check.py tools/probe/BetterInteractionProbe/Scripts/main.lua && cp -r tools/probe/BetterInteractionProbe "$PROFILE/shimloader/mod/" || echo REFUSED
```

Then `md5sum` both paths and compare. A probe that silently did not update is
worse than one that is missing, because the log looks plausible.

## Reading the output

Every probe writes beside `UE4SS.log` in `Helden\Binaries\Win64\`, falling back
to `%TEMP%` if that directory is not writable. The report says which it used.

Each probe writes a **flushed** forensics log. UE4SS's own log is buffered and
loses the last seconds before a crash, so if the game dies, the probe's `.log`
is the file that says where it was — not `UE4SS.log`.
