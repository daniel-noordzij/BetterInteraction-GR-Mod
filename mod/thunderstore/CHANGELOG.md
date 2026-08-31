# Changelog

## 1.0.0 — 31 August 2026

First public release. Everything below is new because nothing came before it;
earlier version numbers exist only in the repository and were never published.

**Pay a machine off in one press.** The elevator, the upgrade machine and the
gumball machine all take their price in fixed instalments — 5 gold, 20 gold, one
artifact. One press now pays as much of what is still owed as you can afford.
The price itself is untouched.

**One coin instead of thirty.** The grinder pays out per item ground and splits
each payout into small coins. The split is raised so each item comes out whole,
and coins lying near each other are merged into as few as is safe. A pile is
never merged into a single coin, and no coin passes the configured cap.

**Stop losing a hold you started early.** Holding the interact key before the
prompt appears normally swallows the input. It now starts the hold as soon as
the prompt shows.

**Co-op: only the host needs the mod.** Guests get the same behaviour with a
completely unmodified game, because the work happens on the machine that is
allowed to do it, on behalf of whoever pressed the button. A guest running it
too is harmless.

**No keybinds.** The mod claims nothing on your keyboard. Settings live in
`BetterInteraction.cfg`, which the mod writes itself on first run.

### Known limits

- Tested with two players on two machines. Three or more is untested.
- Tested alongside one particular set of other mods, and no other.
- Hold-to-skip dialogue was attempted and dropped. UE4SS delivers one key event
  per press with no repeat, so a mod cannot tell a held key from a tapped one.
