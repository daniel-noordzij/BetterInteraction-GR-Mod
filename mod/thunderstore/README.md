# BetterInteraction

Quality of life for interacting with things. Fewer button presses for exactly the
same outcome — nothing here changes what you get, only how much work it is to
get it.

Every feature can be switched off on its own.

## What it does

**Pay a machine off in one press.** The elevator wants 5 gold at a time, the
upgrade machine 20, the gumball machine one artifact at a time. This lets a
single press pay whatever you can afford toward what is still owed. The total is
untouched — 100 gold is still 100 gold, it is just one press instead of five. If
you cannot cover the lot, one press pays what you have and the rest stays owed,
exactly as it would unmodded.

**One coin instead of thirty.** The grinder pays out per item ground and splits
each payout into coins of at most 5 gold or 1 artifact, so a full load can be
dozens of separate pickups. This raises the split so each item comes out whole,
and merges coins that are lying near each other into as few as it safely can.

Coins are merged **into the coin that was already there**, not the one that just
landed, and a pile is never merged into a single coin — that would put a whole
run's gold on one object that could roll somewhere you cannot reach. The default
keeps any one coin under 100 gold. The total is never changed: the merged coin is
written and read back *first*, and the others are only emptied once that is
confirmed.

**Stop losing a hold you started early.** Holding the interact key before the
prompt appears normally swallows the input — you have to let go and press again.
This starts the hold as soon as the prompt shows, so walking up to a chair,
casket or repair spot with the key already down just works. It only ever acts
where the game has already dropped the input; if the game is running its own
hold, the mod stays out of the way.

## Settings

The mod writes `BetterInteraction.cfg` itself the first time it runs, and the
log says where it put it. Edit it and press **F4** in game to reload — no
restart needed. Every setting is in there at its default, and a fully commented
copy explaining each one lives with the source.

**F3** writes a diagnostic report and changes nothing. If you are reporting a
problem, press it and include `BetterInteraction.log`.

## Multiplayer

**It works in co-op, and only the host needs it.** Paying machines and merging
coins are things only the server can really do, so the mod does them on the
host — for whoever pressed the button. A guest pays from their own purse, in one
press, wherever the host happens to be standing.

If a guest runs it too, nothing conflicts: their copy notices it is not the host
and leaves that side alone, keeping only the hold fix, which is purely local.

Tested with two players on two machines. **Three or more is untested**, and so is
running alongside mod sets other than the one it was developed with.

## What it deliberately does not do

This is a quality of life mod, not a cheat. It never changes what anything costs,
never unlocks anything the game locked, and never touches quest or progression
state. Where it takes an action for you, that action is one you could have taken
yourself at that moment.

Hold-to-skip dialogue was attempted and dropped: the game gives a mod no way to
tell a held key from a tapped one, which is the same reason the base game needs
one press per line.

## Credits

UE4SS 5.7 signature overrides come from the `GrainRot_UE4SS` package, which this
mod depends on rather than duplicating.
