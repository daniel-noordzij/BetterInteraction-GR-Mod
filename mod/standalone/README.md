# BetterInteraction — hand install

Use this zip if you are not installing through r2modman / Thunderstore Mod
Manager. If you are, install the Thunderstore package instead — it pulls in
UE4SS for you and this does not.

## You need first

- **Grain Rot** on Windows
- **unreal-shimloader**, and the **GrainRot_UE4SS** community package on top of
  it. That package carries the UE 5.7.4 signature overrides without which UE4SS
  does not fully start on this build. This mod does not include them and depends
  on it rather than duplicating them.

## Install

Unzip straight over your profile's `shimloader` folder. It contains only the two
folders that belong there:

```
shimloader/
  mod/BetterInteraction/Scripts/main.lua
  mod/BetterInteraction/enabled.txt
  cfg/BetterInteraction.cfg
```

With Thunderstore Mod Manager that folder is:

```
%APPDATA%\Thunderstore Mod Manager\DataFolder\GrainRot\profiles\<profile>\shimloader\
```

`enabled.txt` is meant to be empty — UE4SS uses its presence, not its contents.

## Check it is running

Launch the game and look for `BetterInteraction.log` in

```
<Grain Rot>\Helden\Binaries\Win64\
```

The first lines say which version loaded and which config file it read. If it
found no config it writes one for you and says where it put it.

## Keys

**None.** The mod binds no keys, so it cannot clash with anything you have set.
Edit the config and restart the game to change a setting.

If something is wrong, send `BetterInteraction.log` from that same folder. It
says what the mod did and why.

## Uninstall

Delete `mod/BetterInteraction/` and `cfg/BetterInteraction.cfg`. The mod writes
nothing into your save.

## Multiplayer

Solo and hosting only for now, and untested in a real lobby. See the mod page.
