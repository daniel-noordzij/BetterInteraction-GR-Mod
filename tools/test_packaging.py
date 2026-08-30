"""Check the checker: every packaging rule must actually refuse a violation.

A rule that has never been seen to fail is a rule nobody knows works. Each case
here breaks exactly one thing and asserts modpackage refuses it -- and none of
them touches the real sources, so running this cannot damage the mod.

    py tools/test_packaging.py
"""

import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import modpackage as mp

GOOD_LUA = mp.read_text(mp.SOURCE_LUA)
RESULTS = []


def expect_refusal(label, run):
    try:
        run()
    except mp.PackagingError as error:
        RESULTS.append((True, label, str(error).split(".")[0][:78]))
        return
    RESULTS.append((False, label, "NO REFUSAL -- the rule does not work"))


def expect_pass(label, run):
    try:
        run()
        RESULTS.append((True, label, "accepted, as it should be"))
    except mp.PackagingError as error:
        RESULTS.append((False, label, "wrongly refused: %s" % error))


# --- rule 2: a keybind that is not on the allowed list -----------------------
expect_refusal("rule 2  a rogue dev keybind is refused",
               lambda: mp.check_keybinds(
                   GOOD_LUA + "\nRegisterKeyBind(KEY_GIVE_MONEY, function() end)\n"))

expect_refusal("rule 2  ...even when it is switched off",
               lambda: mp.check_keybinds(
                   GOOD_LUA + "\nif false then RegisterKeyBind(KEY_CHEAT, f) end\n"))

expect_pass("rule 2  the real mod passes",
            lambda: mp.check_keybinds(GOOD_LUA))

# --- rule 3: the diagnostic must survive, checked separately -----------------
expect_refusal("rule 3  removing the diagnostic keybind is refused",
               lambda: mp.check_diagnostic_survives(
                   GOOD_LUA.replace("RegisterKeyBind(KEY_DIAG", "-- gone(")))

expect_pass("rule 3  the real mod keeps it",
            lambda: mp.check_diagnostic_survives(GOOD_LUA))

# --- rule 1: no build-time audience flag -------------------------------------
expect_refusal("rule 1  a host/guest build flag is refused",
               lambda: mp.check_no_audience_flag(
                   GOOD_LUA + "\nlocal HOST_BUILD = true\n"))

# --- rule 4: no probes -------------------------------------------------------
def staged_with_probe():
    root = tempfile.mkdtemp(prefix="bi-test-")
    scripts = os.path.join(root, "mod", "Scripts")
    os.makedirs(scripts)
    with open(os.path.join(scripts, "main.lua"), "w", encoding="utf-8") as fh:
        fh.write("-- fine\n")
    probe = os.path.join(root, "mod", "probe")
    os.makedirs(probe)
    with open(os.path.join(probe, "main.lua"), "w", encoding="utf-8") as fh:
        fh.write("-- BetterInteractionProbe\n")
    return lambda: mp.check_no_probes(root)


expect_refusal("rule 4  a probe file in the package is refused", staged_with_probe())

# --- rule 5: the config is a file, and it agrees with the mod ----------------
def missing_config():
    root = tempfile.mkdtemp(prefix="bi-test-")
    return lambda: mp.check_config_is_a_file(os.path.join(root, "nope.cfg"))


expect_refusal("rule 5  a missing config file is refused", missing_config())

expect_refusal("rule 5  a config key the mod never reads is refused",
               lambda: mp.check_config_matches_lua(
                   GOOD_LUA, mp.check_config_is_a_file(mp.SOURCE_CFG)
                   + ["free_money"]))

expect_refusal("rule 5  a mod setting with no config key is refused",
               lambda: mp.check_config_matches_lua(
                   GOOD_LUA,
                   [k for k in mp.check_config_is_a_file(mp.SOURCE_CFG)
                    if k != "deposit_all"]))

expect_pass("rule 5  the shipped config and the mod agree",
            lambda: mp.check_config_matches_lua(
                GOOD_LUA, mp.check_config_is_a_file(mp.SOURCE_CFG)))

# --- the gate that is not a rule but decides every build ---------------------
expect_pass("gate    lua_check accepts the mod", mp.run_lua_check)


width = max(len(label) for _ok, label, _detail in RESULTS)
failed = 0
for ok, label, detail in RESULTS:
    if not ok:
        failed += 1
    print("%-4s %-*s  %s" % ("ok" if ok else "FAIL", width, label, detail))
print("\n%d checks, %d failed" % (len(RESULTS), failed))
sys.exit(1 if failed else 0)
