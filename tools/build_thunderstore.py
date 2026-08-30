"""Build the Thunderstore package.

Every rule it obeys lives in modpackage.py, which build_standalone.py imports
too -- CLAUDE.md: "A rule that lives in one builder is a rule the other one
breaks."

Layout, taken from real installed Grain Rot packages rather than assumed:
r2modman maps a package's mod/ onto shimloader/mod/<PackageName>/, so the mod's
own folder name is NOT repeated inside the package.

    manifest.json
    README.md
    icon.png
    mod/Scripts/main.lua
    mod/enabled.txt
    cfg/BetterInteraction.cfg

Usage:
    py tools/build_thunderstore.py            refuses while release blockers stand
    py tools/build_thunderstore.py --force    build anyway (for testing the zip)
"""

import os
import shutil
import struct
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modpackage as mp


def main(argv):
    force = "--force" in argv

    if mp.RELEASE_BLOCKERS and not force:
        print("REFUSED. This is not ready to publish:\n")
        for index, blocker in enumerate(mp.RELEASE_BLOCKERS, 1):
            print("  %d. %s\n" % (index, blocker))
        print("CLAUDE.md: \"Nothing ships publicly until this is settled on two")
        print("machines.\" Clear the blockers in tools/modpackage.py when they")
        print("are genuinely settled, or pass --force to build a zip for")
        print("testing without publishing it.")
        return 2

    version = mp.read_version()
    print("version %s (from the mod, not the manifest)" % version)
    print(mp.run_lua_check())

    staging = tempfile.mkdtemp(prefix="bi-ts-")
    try:
        keys = mp.stage(staging)
        print("staged %d settings" % len(keys))

        shutil.copy2(os.path.join(mp.THUNDERSTORE_DIR, "README.md"),
                     os.path.join(staging, "README.md"))
        icon = os.path.join(mp.THUNDERSTORE_DIR, "icon.png")
        if not os.path.isfile(icon):
            raise mp.PackagingError("no icon.png -- run tools/make_icon.py")
        # Thunderstore takes 256x256 and nothing else. Daniel's artwork arrived
        # at 650x650 and would have been rejected on upload; the build should
        # say so rather than the website.
        with open(icon, "rb") as handle:
            head = handle.read(24)
        if head[:8] != b"\x89PNG\r\n\x1a\n":
            raise mp.PackagingError("icon.png is not a PNG")
        width, height = struct.unpack(">II", head[16:24])
        if (width, height) != (256, 256):
            raise mp.PackagingError(
                "icon.png is %dx%d; Thunderstore requires exactly 256x256. "
                "Run: py tools/make_icon.py" % (width, height))
        shutil.copy2(icon, os.path.join(staging, "icon.png"))

        manifest = mp.write_manifest(
            os.path.join(staging, "manifest.json"), version,
            os.path.join(mp.THUNDERSTORE_DIR, "manifest.json"))
        if len(manifest["description"]) > 250:
            raise mp.PackagingError(
                "Thunderstore caps the description at 250 characters; this one "
                "is %d" % len(manifest["description"]))

        # Re-run the content rules on what is ACTUALLY staged, not on the
        # sources they came from -- the package is what ships.
        mp.check_no_probes(staging)
        lua = mp.read_text(os.path.join(staging, "mod", "Scripts", "main.lua"))
        bound = mp.check_keybinds(lua)
        mp.check_diagnostic_survives(lua)
        mp.check_no_audience_flag(lua)
        print("keybinds shipped: %s" % ", ".join(bound))

        os.makedirs(mp.DIST, exist_ok=True)
        out = os.path.join(mp.DIST, "%s-%s.zip" % (mp.MOD_NAME, version))
        with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as zf:
            for base, _dirs, files in os.walk(staging):
                for name in sorted(files):
                    path = os.path.join(base, name)
                    zf.write(path, os.path.relpath(path, staging).replace("\\", "/"))

        with zipfile.ZipFile(out) as zf:
            names = sorted(zf.namelist())
        print("\nwrote %s  (%d bytes)" % (out, os.path.getsize(out)))
        for name in names:
            print("   " + name)

        for required in ("manifest.json", "icon.png", "README.md",
                         "mod/Scripts/main.lua", "mod/enabled.txt"):
            if required not in names:
                raise mp.PackagingError("the zip is missing " + required)
        return 0
    except mp.PackagingError as error:
        print("REFUSED: %s" % error)
        return 1
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
