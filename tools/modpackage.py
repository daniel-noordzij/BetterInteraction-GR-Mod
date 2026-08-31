"""THE PACKAGING RULES. Both builders import this and neither restates them.

CLAUDE.md: "Decided once in tools/modpackage.py; both builders import it. A rule
that lives in one builder is a rule the other one breaks."

The five rules, and where each is enforced:

  1. ONE MOD BUILD. No host build, no guest build. Host vs guest is a runtime
     question and a build-time flag cannot answer a per-lobby one. Enforced by
     there being exactly one staging function, with no audience parameter --
     check_no_audience_flag() also refuses the shape in the shipped Lua.
  2. THE SHIPPED MOD BINDS NO KEYS AT ALL. Stronger than the original rule,
     which allowed a named few: a released mod has no business claiming a key
     on someone else's keyboard, and "no keybinds" is an absence check that
     cannot be weakened by adding a name to a list.
  3. THE INSTRUMENT SURVIVES, checked separately. "The keybinds are gone" and
     "a bug reporter still has something to send" are two claims, so they are
     two functions. With F3 removed the instrument is the LOG, so that is what
     is checked.
  4. NO PROBES, EVER. check_no_probes() walks what is actually staged.
  5. THE CONFIG SHIPS AS A FILE the user can read and edit, not as constants
     baked into main.lua.

And the gate that is not a packaging rule but is load-bearing anyway:
lua_check must pass, and the build must be gated on ITS EXIT CODE (CLAUDE.md
rule I -- a broken main.lua reached the profile twice because a guard tested
grep's exit code instead).
"""

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

MOD_NAME = "BetterInteraction"
SOURCE_LUA = os.path.join(ROOT, "mod", "lua", MOD_NAME, "Scripts", "main.lua")
SOURCE_ENABLED = os.path.join(ROOT, "mod", "lua", MOD_NAME, "enabled.txt")
SOURCE_CFG = os.path.join(ROOT, "mod", "cfg", MOD_NAME + ".cfg")
THUNDERSTORE_DIR = os.path.join(ROOT, "mod", "thunderstore")
STANDALONE_DIR = os.path.join(ROOT, "mod", "standalone")
LUA_CHECK = os.path.join(ROOT, "tools", "lua_check.py")
DIST = os.path.join(ROOT, "dist")

# Rule 2. EMPTY, and that is the rule: the shipped mod binds nothing. F3 and F4
# were removed at Daniel's request for 1.0.0, and with them the argument that a
# release may claim keys on a stranger's keyboard. Any RegisterKeyBind in the
# shipped file is now a build failure.
ALLOWED_KEYBINDS = {}

# Things that are true of the mod but NOT yet true of a public release. The
# Thunderstore builder refuses to run while any of these stands, because
# CLAUDE.md is explicit: "Nothing ships publicly until this is settled on two
# machines."
RELEASE_BLOCKERS = [
    "CO-OP IS UNVERIFIED. Features 1, 2 and 3 write authoritative state and are "
    "host/solo by nature; feature 5 is bucket 2 but has never run in a lobby. "
    "The mod page cannot honestly describe co-op behaviour yet.",
    "THE MOD HAS NEVER RUN ON A SECOND MACHINE. Every measurement in "
    "docs/DESIGN.md comes from one PC with several other Lua mods loaded.",
]


class PackagingError(Exception):
    pass


def read_version():
    """The single source of truth for the version: the shipped Lua."""
    with open(SOURCE_LUA, "r", encoding="utf-8") as handle:
        found = re.search(r'^local VERSION\s*=\s*"([^"]+)"', handle.read(), re.M)
    if not found:
        raise PackagingError("no VERSION in " + SOURCE_LUA)
    version = found.group(1)
    # Thunderstore takes strict major.minor.patch and nothing else. The first
    # build produced "0.26.0-hooksize" -- a development codename that would have
    # been rejected on upload, or worse, accepted and stuck. The version is the
    # one thing a package cannot be wrong about, so it is checked here rather
    # than discovered later.
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise PackagingError(
            "VERSION is %r, which Thunderstore will not take -- it must be "
            "major.minor.patch with no suffix. Development codenames belong in "
            "the log line, not in the version." % version)
    return version


def run_lua_check():
    """Rule I: gate on the CHECKER'S OWN EXIT CODE, never on its output."""
    result = subprocess.run([sys.executable, LUA_CHECK, SOURCE_LUA],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise PackagingError("lua_check refused the mod:\n" + result.stdout
                             + result.stderr)
    return result.stdout.strip()


def check_keybinds(lua_source):
    """Rule 2 -- an ABSENCE check. Every key the file binds must be allowed."""
    bound = set(re.findall(r"RegisterKeyBind\(\s*([A-Za-z_][A-Za-z_0-9.]*)",
                           lua_source))
    unexpected = sorted(bound - set(ALLOWED_KEYBINDS))
    if unexpected:
        raise PackagingError(
            "the shipped mod binds keys: " + ", ".join(unexpected)
            + ". Rule 2: a release binds NOTHING. Dev keybinds are CUT, not "
              "disabled -- delete the block rather than switching it off.")
    return sorted(bound)


def check_diagnostic_survives(lua_source):
    """Rule 3 -- a PRESENCE check, deliberately separate from rule 2.

    The diagnostic used to be F3. With no keybinds left, the log IS the
    instrument, so a build that cannot produce one has nothing to send with a
    bug report and must not ship.
    """
    if not re.search(r'^local LOG_FILE\s*=', lua_source, re.M):
        raise PackagingError(
            "the mod declares no log file. Rule 3: with the keybinds gone the "
            "log is the only thing a bug reporter can send, and 'the keybinds "
            "are gone' and 'the instrument is still there' are two claims.")
    if not re.search(r"^local function log\(", lua_source, re.M):
        raise PackagingError("the mod has no log() -- see rule 3")


def check_no_audience_flag(lua_source):
    """Rule 1 -- one build. A host/guest switch cannot exist at build time."""
    for pattern in (r"\bIS_HOST\b", r"\bHOST_BUILD\b", r"\bGUEST_BUILD\b",
                    r"\bBUILD_AUDIENCE\b"):
        if re.search(pattern, lua_source):
            raise PackagingError(
                "the mod carries a build-time audience flag (" + pattern
                + "). Rule 1: host vs guest is a RUNTIME question and one build "
                  "answers it at runtime or not at all.")


def check_no_probes(staged_root):
    """Rule 4 -- nothing from tools/probe/ may appear in a package."""
    offenders = []
    for base, _dirs, files in os.walk(staged_root):
        for name in files:
            path = os.path.join(base, name)
            if "probe" in os.path.relpath(path, staged_root).lower():
                offenders.append(os.path.relpath(path, staged_root))
            elif name.endswith(".lua"):
                with open(path, "r", encoding="utf-8", errors="replace") as fh:
                    head = fh.read(4000)
                if "Probe" in head and "BetterInteraction" + "Probe" in head:
                    offenders.append(os.path.relpath(path, staged_root))
    if offenders:
        raise PackagingError("probe files staged for release: "
                             + ", ".join(sorted(offenders)))


def check_config_is_a_file(staged_cfg):
    """Rule 5 -- shipped as an editable file with the defaults in it."""
    if not os.path.isfile(staged_cfg):
        raise PackagingError("no config file staged. Rule 5: the config ships "
                             "as a file the user can read and edit.")
    with open(staged_cfg, "r", encoding="utf-8") as handle:
        text = handle.read()
    keys = re.findall(r"^([a-z_]+)\s*=", text, re.M)
    if not keys:
        raise PackagingError("the staged config declares no settings at all")
    return keys


def check_config_matches_lua(lua_source, config_keys):
    """Every shipped key must exist in the mod, and vice versa.

    A config key the mod does not read is a lie to the user; a mod setting with
    no config key is rule 5's "baked into main.lua" in miniature. Both are
    build failures, and each names the offenders rather than just failing.
    """
    block = re.search(r"^local cfg = \{(.*?)^\}", lua_source, re.S | re.M)
    if not block:
        raise PackagingError("cannot find the cfg defaults table in the mod")
    lua_keys = set(re.findall(r"^\s*([a-z_]+)\s*=", block.group(1), re.M))
    missing = sorted(set(config_keys) - lua_keys)
    unshipped = sorted(lua_keys - set(config_keys))
    if missing:
        raise PackagingError("the config ships keys the mod never reads: "
                             + ", ".join(missing))
    if unshipped:
        raise PackagingError("the mod has settings with no config key: "
                             + ", ".join(unshipped)
                             + ". Rule 5: defaults belong in the file, not in "
                               "constants the user cannot see.")


def stage(staged_root):
    """Rule 1: ONE staging function, no audience parameter.

    Package layout, taken from real installed Grain Rot packages rather than
    assumed -- r2modman maps a package's mod/ onto shimloader/mod/<PackageName>/,
    so the mod's own folder name is NOT repeated inside the package.
    """
    lua = read_text(SOURCE_LUA)
    check_no_audience_flag(lua)
    check_keybinds(lua)
    check_diagnostic_survives(lua)

    scripts = os.path.join(staged_root, "mod", "Scripts")
    os.makedirs(scripts, exist_ok=True)
    shutil.copy2(SOURCE_LUA, os.path.join(scripts, "main.lua"))
    shutil.copy2(SOURCE_ENABLED, os.path.join(staged_root, "mod", "enabled.txt"))

    # THE CONFIG IS NOT SHIPPED, and that is deliberate rather than an omission.
    #
    # No Grain Rot package ships a cfg/ folder, and r2modman nests a package's
    # subfolders under the package name -- so a shipped cfg/ would most likely
    # land at shimloader/cfg/BetterInteraction/BetterInteraction.cfg, which is
    # NOT where the mod looks. A user editing that file would see no effect,
    # which is worse than there being no file at all.
    #
    # The mod writes its own on first run instead, into a path it has just read
    # from, and logs where it put it. Rule 5 is satisfied by the user ending up
    # with an editable file -- not by that file having travelled in the zip.
    #
    # The repo copy is still checked against the mod on every build, because it
    # is the documented reference the mod page points at, and a reference that
    # disagrees with the code is worse than none.
    keys = check_config_is_a_file(SOURCE_CFG)
    check_config_matches_lua(lua, keys)
    check_no_probes(staged_root)
    return keys


def read_text(path):
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def md5(path):
    digest = hashlib.md5()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_manifest(path, version, template):
    """The version comes from the Lua, never from the template -- one source of
    truth, so a release can never disagree with the mod it contains."""
    data = json.loads(read_text(template))
    data["version_number"] = version
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(data, handle, indent=4)
        handle.write("\n")
    return data
