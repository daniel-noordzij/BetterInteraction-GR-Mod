"""Build the hand-installable zip, and optionally unpack it into a real profile.

Same rules as the Thunderstore build -- they come from modpackage.py, which both
builders import, so neither can drift from the other.

This one has NO release blockers: a hand-install zip is how the mod gets tested
on a second machine, which is one of the things blocking a public release. It
would be circular to gate it on that.

Layout mirrors an r2modman profile, so unzipping over `shimloader/` is the whole
install:

    mod/BetterInteraction/Scripts/main.lua
    mod/BetterInteraction/enabled.txt
    README.md
    CHANGELOG.md

The config is not in the zip; the mod writes its own on first run and logs
where it put it.

Usage:
    py tools/build_standalone.py
    py tools/build_standalone.py --install "<...>/profiles/<name>/shimloader"
"""

import os
import shutil
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modpackage as mp


def build(staging):
    """Profile-shaped, unlike the Thunderstore layout: here the mod's folder
    name IS present, because nothing is going to add it for us."""
    keys = mp.stage(staging)

    # Reshape mod/ -> mod/<ModName>/ for a direct profile drop.
    plain = os.path.join(staging, "mod")
    named = os.path.join(staging, "_mod", mp.MOD_NAME)
    os.makedirs(os.path.dirname(named), exist_ok=True)
    shutil.move(plain, named)
    shutil.move(os.path.join(staging, "_mod"), plain)

    shutil.copy2(os.path.join(mp.STANDALONE_DIR, "README.md"),
                 os.path.join(staging, "README.md"))
    # The same changelog as the Thunderstore package, and checked the same way.
    # A hand-installer has no mod page to read it on, so the zip is the only
    # place they will ever see what changed.
    mp.check_changelog(mp.SOURCE_CHANGELOG, mp.read_version())
    shutil.copy2(mp.SOURCE_CHANGELOG, os.path.join(staging, "CHANGELOG.md"))
    return keys


def install(staging, target):
    """Copy into a live profile, then VERIFY by md5 -- CLAUDE.md rule 8: deploy
    the change yourself, then verify it landed."""
    if not os.path.isdir(target):
        raise mp.PackagingError("no such profile directory: " + target)
    if os.path.basename(os.path.normpath(target)) != "shimloader":
        raise mp.PackagingError(
            "expected a path ending in 'shimloader', got: " + target
            + " -- pointing this at the wrong folder would scatter files into a "
              "profile with no way to tell what came from where")

    copied = []
    for base, _dirs, files in os.walk(staging):
        for name in files:
            if name in ("README.md", "CHANGELOG.md") and base == staging:
                continue                    # zip paperwork, not profile files
            source = os.path.join(base, name)
            rel = os.path.relpath(source, staging)
            dest = os.path.join(target, rel)
            os.makedirs(os.path.dirname(dest), exist_ok=True)
            shutil.copy2(source, dest)
            copied.append((rel, source, dest))

    print("\ninstalled into %s" % target)
    bad = 0
    for rel, source, dest in copied:
        same = mp.md5(source) == mp.md5(dest)
        if not same:
            bad += 1
        print("   %-46s %s" % (rel.replace("\\", "/"),
                               "ok" if same else "MD5 MISMATCH"))
    if bad:
        raise mp.PackagingError("%d file(s) did not land intact" % bad)


def main(argv):
    target = None
    if "--install" in argv:
        index = argv.index("--install")
        if index + 1 >= len(argv):
            print("--install needs a path to a profile's shimloader directory")
            return 2
        target = argv[index + 1]

    version = mp.read_version()
    print("version %s" % version)
    print(mp.run_lua_check())

    staging = tempfile.mkdtemp(prefix="bi-sa-")
    try:
        keys = build(staging)
        print("staged %d settings" % len(keys))

        lua = mp.read_text(os.path.join(staging, "mod", mp.MOD_NAME,
                                        "Scripts", "main.lua"))
        bound = mp.check_keybinds(lua)
        mp.check_diagnostic_survives(lua)
        mp.check_no_audience_flag(lua)
        mp.check_no_probes(staging)
        print("keybinds shipped: %s" % ", ".join(bound))

        os.makedirs(mp.DIST, exist_ok=True)
        out = os.path.join(mp.DIST, "%s-%s-standalone.zip" % (mp.MOD_NAME, version))
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            for base, _dirs, files in os.walk(staging):
                for name in sorted(files):
                    path = os.path.join(base, name)
                    zf.write(path, os.path.relpath(path, staging).replace("\\", "/"))
        print("\nwrote %s  (%d bytes)" % (out, os.path.getsize(out)))
        with zipfile.ZipFile(out) as zf:
            for name in sorted(zf.namelist()):
                print("   " + name)

        if target is not None:
            install(staging, target)
        return 0
    except mp.PackagingError as error:
        print("REFUSED: %s" % error)
        return 1
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
