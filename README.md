# Farever Fix Target Lock

An unofficial HLX mod that restores Farever's non-functional **Lock Target** action.

Look at an enemy and press Farever's existing Lock Target binding to lock it. Press the same binding again to unlock. While locked, Farever routes single-target attacks to that enemy even if another enemy moves under the crosshair. Area-of-effect and point-targeted skills keep their normal targeting.

The mod uses Farever's existing `lockedTarget`, `SkillTarget`, and `hard-lock` HUD systems rather than implementing a separate combat targeting system.

For every attack that Farever immediately submits as `Target(autoTarget)`, including normal staff attacks, the mod replaces the last-second `autoTarget` choice with a native `SkillTarget.Target` containing the locked enemy. This prevents another enemy under the crosshair from stealing the attack. Skills that enter Farever's manual point/ground-targeting mode continue through the original targeting path.

## Installation

1. Install [HLX Core](https://www.nexusmods.com/site/mods/2118?tab=files) in the Farever game directory.
2. Install the [Farever ImGui plugin](https://www.nexusmods.com/farever/mods/4) so `imgui64.hdll` is located at `Farever\hlx\plugins\imgui64.hdll`.
3. Create `Farever\hlx\mods\fix-target-lock\`.
4. Place `fix-target-lock.hl` in that folder.
5. Fully close and relaunch Farever.

## Usage

The settings window opens automatically the first time the mod runs.

- **Enable** restores the target-lock feature. Disabling the mod clears the current lock and restores Farever's original feature flag.
- **Auto-unlock when target dies** clears the lock as soon as the locked enemy is defeated or despawns. It is enabled by default.
- **Press Lock Target to switch targets** changes the lock directly to Farever's current `autoTarget` when another enemy is aimed at. Pressing it without another valid target still unlocks normally. It is disabled by default.
- **Disable automatic camera movement** prevents Farever from pulling the camera's yaw and pitch toward the locked enemy, leaving camera rotation under manual control while preserving the normal locked-camera sensitivity. It is disabled by default.
- Use Farever's normal **Lock Target** key or controller binding to toggle a target lock.
- Farever's native animated hard-lock indicator appears above the locked enemy.
- Press `F9` to reopen the settings window. The settings hotkey can be changed from the window.

Settings are saved to `Farever\hlx\mods\fix-target-lock\config.json`.

## How it works

Farever contains a nearly complete target-lock implementation, but `PlayerController.updateInputs()` does not check the `LockTarget` input action. The mod adds that missing toggle behavior:

- unlocked + Lock Target: calls Farever's `lockAutoTarget()` using the enemy currently selected by its normal auto-targeting code;
- locked + Lock Target: calls Farever's `leaveLock()`;
- enabled: keeps Farever's `Const.Camera.TargetLock` feature flag active.

Farever already stores the target on `Hero.lockedTarget`, feeds target-based skills through `SkillTarget.Target`, leaves `SkillTarget.Point` behavior intact, and marks the corresponding enemy widget with the native `hard-lock` style.


## Building (for developers)

Requires Haxe 4.3.x, `hlx-runtime`, and `hl-imgui`.

```text
haxelib git hlx-runtime https://github.com/hlx-framework/hlx-core.git main hlx-runtime/src
haxelib git hl-imgui https://github.com/laymain/farever-mods.git main imgui/hl-imgui/src
haxe compile.hxml
```

Output: `build/fix-target-lock/fix-target-lock.hl`

## Compatibility

This mod relies on Farever's internal HashLink layout. Game updates can require a rebuild or adjustment.

## Disclaimer

Unofficial community mod. Not affiliated with or endorsed by Farever's developers, HLX, Steam, or Valve.
