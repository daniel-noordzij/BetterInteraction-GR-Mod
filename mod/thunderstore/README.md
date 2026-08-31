# BetterInteraction

A Grain Rot mod that takes the spam-clicking out of interacting. Pay a machine in
one press, and pick up one coin instead of thirty. That's it!

## What it does

Grain Rot takes your money in instalments: 5 gold a press at the elevator, 20 at
the upgrade machine, one artifact at a time at the gumball machine. This lets one
press pay as much of what you still owe as you can afford. The price is untouched
— 100 gold is still 100 gold, it is just one press instead of twenty.

The grinder pays out in a shower of small coins, one every 0.4 seconds, and each
one is a separate pickup. This stops the splitting, and merges coins already
lying near each other into as few as it safely can. It keeps them under 100 gold
each rather than putting a whole run on one object that could roll under the
floor, and the total is never changed.

Every feature switches off on its own in `BetterInteraction.cfg`, which the mod
writes itself the first time it runs. Edit it and restart the game. The mod binds
no keys.

It never changes what anything costs, never unlocks anything the game locked,
never touches quest or progression state, and writes nothing into your save.

## Multiplayer

Only the host needs it. Everything here is something only the server is allowed
to do, so the mod does it on the host for whoever pressed the button — a guest
pays from their own purse, in one press, on a completely unmodified game. A guest
running it too is harmless; their copy stands down.

Tested with two players on two machines.

## AI usage disclosure and information

- This mod **has been** vibe-coded.
- This mod does **not** contain AI generated art.
- The Lua was written with an LLM (Claude), working to a spec I wrote and under
  my direction.
- None of the game internals are guessed. Every class and property this mod
  touches came straight out of the game's own header and object dumps, and both
  the machines and the grinder were measured in game with a read-only probe
  before any of the real mod got written.

## Credits

Thanks to the RE-UE4SS project, and to the Grain Rot UE4SS overlay for the UE
5.7.4 signature work that makes any Lua mod possible on this build.
