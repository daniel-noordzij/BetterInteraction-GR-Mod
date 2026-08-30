"""AFTER A GAME UPDATE: what did the patch move?

CLAUDE.md rule 3: "The game will patch and break things. Assume the exe changes
monthly. Keep every version-fragile thing in data files, not scattered through
code." This is the other half of that -- the thing that tells you WHICH of those
names stopped being true.

Everything the mod depends on by name lives in its CLASS, PROP, MACHINE and COIN
tables. This extracts them from the shipped Lua rather than keeping a second
list, because a second list is a list that goes stale, and checks each one
against the game's own dumps.

    py tools/patch_check.py --baseline    record today's game as the reference
    py tools/patch_check.py               compare the current game against it

A name that has vanished is not automatically a broken feature -- the dumps only
cover what UE4SS reflected -- but it is exactly the shortlist worth re-probing,
and it is a great deal shorter than the whole mod.
"""

import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BASELINE = os.path.join(ROOT, "data", "patch_baseline.json")
LUA = os.path.join(ROOT, "mod", "lua", "BetterInteraction", "Scripts", "main.lua")

GAME = r"F:\SteamLibrary\steamapps\common\Grain Rot"
EXE = os.path.join(GAME, "Helden", "Binaries", "Win64", "Helden-Win64-Shipping.exe")
DUMPS = os.path.join(GAME, "Helden", "Binaries", "Win64", "CXXHeaderDump")
STEAMAPPS = os.path.join(GAME, os.pardir, os.pardir)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def steam_buildid():
    """From the appmanifest that points at this install folder."""
    try:
        for name in os.listdir(STEAMAPPS):
            if not name.startswith("appmanifest_"):
                continue
            path = os.path.join(STEAMAPPS, name)
            with open(path, "r", encoding="utf-8", errors="replace") as handle:
                text = handle.read()
            if '"Grain Rot"' not in text:
                continue
            build = re.search(r'"buildid"\s*"(\d+)"', text)
            appid = re.search(r'"appid"\s*"(\d+)"', text)
            return {"appid": appid.group(1) if appid else None,
                    "buildid": build.group(1) if build else None,
                    "manifest": name}
    except OSError:
        pass
    return {"appid": None, "buildid": None, "manifest": None}


def names_the_mod_depends_on():
    """Pull them out of the mod itself, so this can never disagree with it."""
    text = open(LUA, "r", encoding="utf-8").read()
    found = {}

    for table in ("CLASS", "PROP"):
        block = re.search(r"^local %s = \{(.*?)^\}" % table, text, re.S | re.M)
        if block:
            found[table] = sorted(set(
                re.findall(r'=\s*"([A-Za-z_][A-Za-z_0-9]*)"', block.group(1))))

    for table in ("MACHINE", "COIN"):
        block = re.search(r"^local %s = \{(.*?)^\}" % table, text, re.S | re.M)
        if block:
            found[table] = sorted(set(
                re.findall(r"^\s*([A-Za-z_][A-Za-z_0-9]*)\s*=", block.group(1),
                           re.M)))
    return found


def dump_corpus():
    """Every reflected name the game currently exposes, as one blob per file."""
    blobs = []
    if not os.path.isdir(DUMPS):
        return None
    for name in sorted(os.listdir(DUMPS)):
        if name.endswith(".hpp"):
            with open(os.path.join(DUMPS, name), "r", encoding="utf-8",
                      errors="replace") as handle:
                blobs.append(handle.read())
    return "\n".join(blobs)


def check_names(found, corpus):
    missing = {}
    for table, names in found.items():
        gone = []
        for name in names:
            # SUBSTRING, not a word match. The mod stores class names the way
            # UE4SS wants them -- "HeldenCoinDispenser" -- while the dump writes
            # the C++ name "AHeldenCoinDispenser", and there is no word boundary
            # between the prefix and the name. Matching loosely means this can
            # only ever UNDER-report, which is the safe direction for a tool
            # whose whole output is "go and re-probe these".
            if name not in corpus:
                gone.append(name)
        if gone:
            missing[table] = gone
    return missing


def snapshot():
    return {
        "exe": {"path": EXE,
                "exists": os.path.isfile(EXE),
                "size": os.path.getsize(EXE) if os.path.isfile(EXE) else None,
                "sha256": sha256(EXE) if os.path.isfile(EXE) else None},
        "steam": steam_buildid(),
        "names": names_the_mod_depends_on(),
    }


def main(argv):
    current = snapshot()

    if "--baseline" in argv:
        os.makedirs(os.path.dirname(BASELINE), exist_ok=True)
        with open(BASELINE, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(current, handle, indent=2, sort_keys=True)
            handle.write("\n")
        total = sum(len(v) for v in current["names"].values())
        print("baseline written: %s" % BASELINE)
        print("  exe sha256 %s" % (current["exe"]["sha256"] or "MISSING"))
        print("  steam buildid %s" % (current["steam"]["buildid"] or "unknown"))
        print("  %d version-fragile names across %d tables"
              % (total, len(current["names"])))
        return 0

    if not os.path.isfile(BASELINE):
        print("no baseline yet -- run: py tools/patch_check.py --baseline")
        return 2

    with open(BASELINE, "r", encoding="utf-8") as handle:
        old = json.load(handle)

    changed = False
    if old["exe"]["sha256"] != current["exe"]["sha256"]:
        changed = True
        print("THE EXE CHANGED")
        print("  was %s" % old["exe"]["sha256"])
        print("  now %s" % current["exe"]["sha256"])
    if old["steam"]["buildid"] != current["steam"]["buildid"]:
        changed = True
        print("STEAM BUILDID: %s -> %s" % (old["steam"]["buildid"],
                                           current["steam"]["buildid"]))
    if not changed:
        print("same game build as the baseline.")

    corpus = dump_corpus()
    if corpus is None:
        print("\nno CXXHeaderDump to check names against -- generate one with"
              " UE4SS before trusting this.")
        return 1

    missing = check_names(current["names"], corpus)
    total = sum(len(v) for v in current["names"].values())
    if not missing:
        print("\nall %d version-fragile names still exist in the dump." % total)
        return 0

    print("\nNAMES THE MOD USES THAT ARE NO LONGER IN THE DUMP:")
    for table in sorted(missing):
        for name in missing[table]:
            print("   %-10s %s" % (table, name))
    print("\nThat is the shortlist to re-probe. A missing name is not proof a"
          "\nfeature broke -- the dump only covers what UE4SS reflected -- but"
          "\nnothing else in the mod needs looking at first.")
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
