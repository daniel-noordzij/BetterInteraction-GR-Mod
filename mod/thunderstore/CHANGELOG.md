# Changelog

## 1.0.0

First release.

- Pays the elevator, the upgrade machine and the gumball machine off in one
  press instead of one instalment at a time. The total charged is unchanged.
- Stops the grinder splitting a payout into small coins, and merges coins lying
  near each other, kept under 100 gold each so a whole run is never sitting on a
  single object.
- Only the host needs the mod. Guests get all of it on a completely unmodified
  game, because the work happens on the machine that is allowed to do it, for
  whoever pressed the button. A guest running it stands down entirely.
- Every feature is switchable in `BetterInteraction.cfg`, which
  the mod writes itself on first run.
