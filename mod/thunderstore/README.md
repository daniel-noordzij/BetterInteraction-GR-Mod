# BetterInteraction

A Grain Rot mod that takes the spam-clicking out of interacting. Pay a machine in
one press, and pick up a couple coins instead of a whole pile!

## What it does

Grain Rot takes your money in instalments: 5 gold a press at the elevator, 20 at
the upgrade machine, one artifact at a time at the gumball machine. This lets one
press pay as much of what you still owe as you can afford.

Normally the grinder is limited to dispensing one coin with a max value of 10
every 0.4 seconds. Now it not only spits them out faster but it also does so with
more value per coin, making less total coins required. On top of that, coins
will get merged together if they're close to eachother up to a value of 100.

Every feature is switchable off/on in `BetterInteraction.cfg`, which the mod
writes itself the first time it runs. Edit it and restart the game.

This never changes what anything costs, never unlocks anything the game locked,
never touches quest or progression state, and writes nothing into your save.

## Multiplayer

Only the host needs this. Everything here is something only the server is allowed
to do, so the mod does it on the host for whoever pressed the button. A guest
running it too is harmless; some features will simply be disabled for them.

The only thing that's client-side only is the `Hold-to-Attack` feature.
If a guest wants it, they'll need this mod too.

## Upcoming features

These are features that will be added in a later update to the mod:
- Holding space to skip dialogue instead of having to spam click space.

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
