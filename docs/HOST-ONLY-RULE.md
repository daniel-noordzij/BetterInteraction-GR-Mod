# The host-only rule

**For any multiplayer game mod. This outranks other architectural preferences —
convenience, symmetry, and whatever is easiest to write. Apply it first, and
depart from it only where you can say exactly why it is impossible.**

---

## The rule

> **Design so that the HOST alone running the mod delivers the full experience to
> every player in the lobby — including players who have no mod installed at
> all.**
>
> A guest must never be required to install anything. A guest who installs it
> anyway must get the same result as one who did not.

One install serves everyone. That is the whole point.

## Why this beats every alternative

- **It reaches the most players for the least coordination.** One person installs
  something; a lobby of twenty benefits. No "everyone grab this before we start".
- **There is no version matching.** The commonest way a modded lobby breaks is
  two people running builds that disagree. If only one machine runs the logic,
  there is nothing to disagree with.
- **A vanilla guest is never disadvantaged or broken.** They are not a
  second-class player; they simply cannot tell.
- **It cannot desync.** Guests never write shared state, so they never fight the
  server for it.
- **It degrades cleanly.** No host with the mod means the base game, exactly.

## How to actually build it

### 1. Classify every feature before writing a line of it

Three buckets. Write the bucket in a comment at the site, so the next person
cannot silently mix them:

| bucket | what it is | who may run it |
|---|---|---|
| **1 — Local presentation** | what *your* screen shows: prompts, meters, colours, text | anyone, independently |
| **2 — Local input shaping** | re-sending an input the player could have sent themselves at that moment | anyone, independently |
| **3 — Authoritative state** | anything the server owns: currency, progression, world objects | **the host, and only the host** |

Bucket 3 is where the value usually is. It is also the only bucket that needs
this rule.

### 2. On the host, act for the ACTING player — never the local one

This is the part that is easy to get wrong and hard to notice.

- **Hook the game's own action path**, so the acting player arrives as a
  parameter. Do not infer who it is.
- **Never assume the local player.** The host's own wallet, position and
  inventory are the wrong ones whenever a guest is the one acting.
- **Never guess by proximity.** "The nearest player is probably the one pressing
  the button" is false the moment a second player stands closer, and it fails in
  the worst direction: the mod sizes an action for a bystander and the game then
  refuses the person actually acting.

### 3. Make authoritative writes transient

Apply at the moment of the action; put the original back immediately afterwards.

- Nothing is left changed on an object nobody is using, so other clients never
  see a value that is wrong for them.
- Nothing is stranded if the mod stops, crashes or is uninstalled mid-session.
- The game's own UI keeps telling the truth, because you are not holding it in a
  lie between actions.

Pre-positioning state "ready" for a future action is the tempting shortcut. It
produces misleading displays for everyone else and a persistent leak.

### 4. Guests stand down, explicitly

Detect authority at runtime (in Unreal, `HasAuthority()` on a replicated actor)
and skip bucket 3 entirely when it is false. Log the decision once.

Treat an *unreadable* answer as "act" rather than "stand down" — a failed read
must not silently disable the mod in single player.

### 5. One build, no audience flag

Host versus guest is a **runtime** question. A build-time "host edition" cannot
answer it, because the same person hosts on Tuesday and joins on Wednesday.

## How to know you have done it

Three tests, and all three must pass:

1. **Host has the mod, guest has nothing.** The guest gets the full benefit.
2. **Both have the mod.** The guest's experience is identical to test 1 — their
   copy changes nothing that the host's copy did not already do.
3. **Only the guest has the mod.** Nothing breaks. They get bucket 1 and 2
   features and nothing else.

If test 1 fails, the feature is not finished, whatever it looks like on the
host's screen.

## Failure modes this exists to prevent

Every one of these was observed, not imagined:

- **A guest writing authoritative state** gets its value replicated back over by
  the server. The two fight, and the *visible* result is corruption — a counter
  that reads `3 → 2 → 2 → 0`. The writes changed nothing real; they only broke
  what the guest could see.
- **Sizing an action from the local player's state** made a feature do nothing at
  all for guests, silently, for weeks. The host's wallet was empty; the guest
  standing at the machine was holding 58 gold.
- **Guessing the actor by proximity** would have refused the real actor whenever
  a richer bystander stood closer — strictly worse than not helping.
- **Standing pre-positioned writes** made a machine display a price that was not
  what it would charge, for every player, all the time.

## When it genuinely cannot be done

Say so, in the code and on the mod page, and **degrade to the base game rather
than to something broken**. A feature that quietly does nothing is worse than a
feature that is documented as host-only, because the user cannot tell the
difference between "not supported" and "broken".

Before concluding it is impossible, check the one thing that is easy to miss:
**the server can usually read every player's state.** It holds every pawn, every
inventory and every wallet. "The host cannot know what the guest has" is very
often false, and it was false here.
