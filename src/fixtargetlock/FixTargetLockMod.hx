package fixtargetlock;

import haxe.Json;
import hlx.runtime.HlxPrefixControl;
import sys.FileSystem;
import sys.io.File;

@:build(hlx.runtime.Mod.build())
class FixTargetLockMod {
    static inline var CONFIG_PATH = "hlx/mods/fix-target-lock/config.json";

    static var enabled:Bool = true;
    static var autoUnlockOnDeath:Bool = true;
    static var quickSwapTarget:Bool = false;
    static var disableCameraMovement:Bool = false;

    static var lastConfigModified:Float = -1.0;
    static var configCheckTimer:Float = 0.0;

    static var inputType:hl.Bytes;
    static var playerControllerType:hl.Bytes;
    static var unitControllerType:hl.Bytes;
    static var gameCameraType:hl.Bytes;
    static var gameObjectType:hl.Bytes;
    static var baseSkillType:hl.Bytes;
    static var skillScriptType:hl.Bytes;
    static var skillTargetType:hl.Bytes;
    static var constType:hl.Bytes;
    static var isPressedMember:hlx.runtime.ResolvedMember;
    static var lockAutoTargetMember:hlx.runtime.ResolvedMember;
    static var leaveLockMember:hlx.runtime.ResolvedMember;
    static var getGameCameraMember:hlx.runtime.ResolvedMember;
    static var getLockedTargetMember:hlx.runtime.ResolvedMember;
    static var isDeadMember:hlx.runtime.ResolvedMember;
    static var lockTargetMember:hlx.runtime.ResolvedMember;
    static var getStepByTypeMember:hlx.runtime.ResolvedMember;
    static var allowAimingMember:hlx.runtime.ResolvedMember;
    static var lastController:Dynamic;
    static var originalTargetLock:Null<Bool>;
    static var lastAppliedTargetLock:Null<Bool>;
    static var cameraUpdateTargetLock:Null<Bool>;
    static var lastStatus:String = "Waiting for Farever";

    static function main():Void {
        loadConfig();
        saveConfig();
    }

    @:hlx.postfix(client.PlayerController.updateInputs)
    static function afterUpdateInputs(instance:Dynamic, dt:Float, result:Void):Void {
        configCheckTimer += dt;
        if (configCheckTimer >= 1.0) {
            configCheckTimer = 0.0;
            reloadConfigIfChanged();
        }
        lastController = instance;

        try {
            applyFeatureFlag();
            if (!enabled) {
                lastStatus = "Disabled";
                return;
            }

            if (!resolveMembers()) {
                lastStatus = "Waiting for Farever input methods";
                return;
            }

            var pressed:Dynamic = HlxRuntime.callResolved(isPressedMember, ["LockTarget"]);
            if (pressed != true) {
                if (!autoUnlockDeadTarget(instance))
                    updateStatus(instance);
                return;
            }

            var inLock:Dynamic = HlxRuntime.resolveField(instance, "inLock");
            if (inLock == true) {
                var swapped = false;
                var aimedTarget:Dynamic = HlxRuntime.resolveField(instance, "autoTarget");
                if (quickSwapTarget && aimedTarget != null) {
                    var lockedTarget = getLockedTarget(instance);
                    if (lockedTarget != aimedTarget) {
                        HlxRuntime.callResolved(lockTargetMember, [instance, aimedTarget]);
                        updateStatus(instance);
                        swapped = true;
                    }
                }

                if (!swapped) {
                    HlxRuntime.callResolved(leaveLockMember, [instance]);
                    lastStatus = "Unlocked";
                }
            } else {
                HlxRuntime.callResolved(lockAutoTargetMember, [instance]);
                updateStatus(instance);
            }

            autoUnlockDeadTarget(instance);
        } catch (e:Dynamic) {
            lastStatus = "Error: " + Std.string(e);
            trace("[FixTargetLock] " + lastStatus);
        }
    }

    static function resolveMembers():Bool {
        if (inputType == null)
            inputType = HlxRuntime.resolveType("lib.Input");
        if (playerControllerType == null)
            playerControllerType = HlxRuntime.resolveType("client.PlayerController");
        if (inputType == null || playerControllerType == null)
            return false;

        if (isPressedMember == null)
            isPressedMember = HlxRuntime.resolveStaticMember(inputType, "isPressed");
        if (lockAutoTargetMember == null)
            lockAutoTargetMember = HlxRuntime.resolveMember(playerControllerType, "lockAutoTarget");
        if (leaveLockMember == null)
            leaveLockMember = HlxRuntime.resolveMember(playerControllerType, "leaveLock");
        if (lockTargetMember == null)
            lockTargetMember = HlxRuntime.resolveMember(playerControllerType, "lockTarget");

        return isPressedMember != null
            && lockAutoTargetMember != null
            && leaveLockMember != null
            && lockTargetMember != null;
    }

    // Farever normally refreshes autoTarget inside startSkillAim and can pass a
    // newly looked-at enemy to the attack despite Hero.lockedTarget. Every skill
    // that immediately submits Target(autoTarget), including basic attacks, is
    // redirected to the hard lock. Skills entering manual point/ground aiming
    // continue through Farever's original targeting path.
    @:hlx.prefix(client.UnitController.startSkillAim)
    static function forceLockedAttackTarget(instance:Dynamic, skill:Dynamic, callback:Dynamic, input:String):HlxPrefixControl {
        if (!enabled || instance != lastController)
            return Continue;

        try {
            var inLock:Dynamic = HlxRuntime.resolveField(instance, "inLock");
            if (inLock != true)
                return Continue;

            var lockedTarget = getLockedTarget(instance);
            if (lockedTarget == null)
                return Continue;

            if (baseSkillType == null)
                baseSkillType = HlxRuntime.resolveType("st.skill.BaseSkill");
            if (baseSkillType == null)
                return Continue;
            if (getStepByTypeMember == null)
                getStepByTypeMember = HlxRuntime.resolveMember(baseSkillType, "getStepByType");
            if (getStepByTypeMember == null)
                return Continue;

            // Step type 25 is Farever's explicit aiming step. startSkillAim only
            // enters manual targeting when that step exists and the skill script
            // allows aiming; every other branch immediately emits Target(autoTarget).
            var aimingStep:Dynamic = HlxRuntime.callResolved(getStepByTypeMember, [skill, 25]);
            if (aimingStep != null) {
                if (skillScriptType == null)
                    skillScriptType = HlxRuntime.resolveType("script.SkillScript");
                if (skillScriptType == null)
                    return Continue;
                if (allowAimingMember == null)
                    allowAimingMember = HlxRuntime.resolveMember(skillScriptType, "allowAiming");
                if (allowAimingMember == null)
                    return Continue;

                var script:Dynamic = HlxRuntime.resolveField(skill, "script");
                if (script == null)
                    return Continue;
                var usesManualAim:Dynamic = HlxRuntime.callResolved(allowAimingMember, [script]);
                if (usesManualAim == true)
                    return Continue;
            }

            if (skillTargetType == null)
                skillTargetType = HlxRuntime.resolveType("st.skill.SkillTarget");
            if (skillTargetType == null)
                return Continue;

            var forcedTarget:Dynamic = HlxRuntime.constructEnum(skillTargetType, "Target", [lockedTarget]);
            if (forcedTarget == null)
                return Continue;

            Reflect.callMethod(null, callback, [forcedTarget]);
            return Skip;
        } catch (e:Dynamic) {
            // Preserve normal combat if a game update changes any target types.
            trace("[FixTargetLock] strict target fallback: " + Std.string(e));
            return Continue;
        }
    }

    static function resolveDeathCheckMembers():Bool {
        if (unitControllerType == null)
            unitControllerType = HlxRuntime.resolveType("client.UnitController");
        if (gameCameraType == null)
            gameCameraType = HlxRuntime.resolveType("client.GameCamera");
        if (gameObjectType == null)
            gameObjectType = HlxRuntime.resolveType("ent.GameObject");
        if (unitControllerType == null || gameCameraType == null || gameObjectType == null)
            return false;

        if (getGameCameraMember == null)
            getGameCameraMember = HlxRuntime.resolveMember(unitControllerType, "get_gameCamera");
        if (getLockedTargetMember == null)
            getLockedTargetMember = HlxRuntime.resolveMember(gameCameraType, "getLockedTarget");
        if (isDeadMember == null)
            isDeadMember = HlxRuntime.resolveMember(gameObjectType, "isDead");

        return getGameCameraMember != null
            && getLockedTargetMember != null
            && isDeadMember != null;
    }

    static function autoUnlockDeadTarget(controller:Dynamic):Bool {
        if (!autoUnlockOnDeath)
            return false;

        var inLock:Dynamic = HlxRuntime.resolveField(controller, "inLock");
        if (inLock != true || !resolveDeathCheckMembers())
            return false;

        var target:Dynamic = getLockedTarget(controller);

        // A missing weak target is no longer a usable lock and is treated like a
        // despawned/dead target. Otherwise, ask the game for its native death state.
        var shouldUnlock = target == null;
        if (!shouldUnlock) {
            var dead:Dynamic = HlxRuntime.callResolved(isDeadMember, [target]);
            shouldUnlock = dead == true;
        }

        if (shouldUnlock) {
            HlxRuntime.callResolved(leaveLockMember, [controller]);
            lastStatus = "Unlocked (target defeated)";
            return true;
        }
        return false;
    }

    static function getLockedTarget(controller:Dynamic):Dynamic {
        if (!resolveDeathCheckMembers())
            return null;
        var camera:Dynamic = HlxRuntime.callResolved(getGameCameraMember, [controller]);
        return camera == null
            ? null
            : HlxRuntime.callResolved(getLockedTargetMember, [camera]);
    }

    static function applyFeatureFlag():Void {
        if (constType == null)
            constType = HlxRuntime.resolveType("Const");
        if (constType == null)
            return;

        var camera:Dynamic = HlxRuntime.resolveStaticField(constType, "Camera");
        if (camera == null)
            return;

        if (originalTargetLock == null) {
            var current:Dynamic = Reflect.field(camera, "TargetLock");
            if (current == null)
                return;
            originalTargetLock = cast current;
        }

        // Keep Farever's lock mode enabled outside the camera update. Other
        // systems use this flag for locked sensitivity and targeting behavior.
        var desired = enabled ? true : originalTargetLock;
        if (lastAppliedTargetLock == desired)
            return;

        Reflect.setField(camera, "TargetLock", desired);
        lastAppliedTargetLock = desired;
    }

    @:hlx.prefix(client.GameCamera.postUpdate)
    static function beforeCameraPostUpdate(instance:Dynamic, dt:Float):HlxPrefixControl {
        cameraUpdateTargetLock = null;
        if (!enabled || !disableCameraMovement)
            return Continue;

        try {
            if (constType == null)
                constType = HlxRuntime.resolveType("Const");
            if (constType == null)
                return Continue;
            var camera:Dynamic = HlxRuntime.resolveStaticField(constType, "Camera");
            if (camera == null)
                return Continue;

            var current:Dynamic = Reflect.field(camera, "TargetLock");
            if (current == null)
                return Continue;
            cameraUpdateTargetLock = cast current;
            Reflect.setField(camera, "TargetLock", false);
        } catch (_:Dynamic) {
            cameraUpdateTargetLock = null;
        }
        return Continue;
    }

    @:hlx.postfix(client.GameCamera.postUpdate)
    static function afterCameraPostUpdate(instance:Dynamic, dt:Float, result:Void):Void {
        if (cameraUpdateTargetLock == null)
            return;
        try {
            if (constType != null) {
                var camera:Dynamic = HlxRuntime.resolveStaticField(constType, "Camera");
                if (camera != null)
                    Reflect.setField(camera, "TargetLock", cameraUpdateTargetLock);
            }
        } catch (_:Dynamic) {}
        cameraUpdateTargetLock = null;
    }

    static function updateStatus(controller:Dynamic):Void {
        var inLock:Dynamic = HlxRuntime.resolveField(controller, "inLock");
        if (inLock == true)
            lastStatus = "Target locked (native hard-lock indicator active)";
        else
            lastStatus = "Ready - look at an enemy and press Lock Target";
    }

    static function disableAndUnlock():Void {
        if (lastController != null && resolveMembers()) {
            try HlxRuntime.callResolved(leaveLockMember, [lastController]) catch (_:Dynamic) {}
        }
        lastAppliedTargetLock = null;
        applyFeatureFlag();
    }

    static function reloadConfigIfChanged():Void {
        try {
            if (!FileSystem.exists(CONFIG_PATH))
                return;
            var modified = FileSystem.stat(CONFIG_PATH).mtime.getTime();
            if (modified != lastConfigModified) {
                var wasEnabled = enabled;
                loadConfig();
                if (wasEnabled && !enabled)
                    disableAndUnlock();
                else if (!wasEnabled && enabled) {
                    lastAppliedTargetLock = null;
                    applyFeatureFlag();
                }
            }
        } catch (_:Dynamic) {}
    }

    static function updateConfigModifiedTime():Void {
        try {
            if (FileSystem.exists(CONFIG_PATH))
                lastConfigModified = FileSystem.stat(CONFIG_PATH).mtime.getTime();
        } catch (_:Dynamic) {}
    }

    static function loadConfig():Void {
        try {
            if (!FileSystem.exists(CONFIG_PATH))
                return;
            var data:Dynamic = Json.parse(File.getContent(CONFIG_PATH));
            if (Reflect.hasField(data, "enabled")) enabled = Reflect.field(data, "enabled");
            if (Reflect.hasField(data, "autoUnlockOnDeath")) autoUnlockOnDeath = Reflect.field(data, "autoUnlockOnDeath");
            if (Reflect.hasField(data, "quickSwapTarget")) quickSwapTarget = Reflect.field(data, "quickSwapTarget");
            if (Reflect.hasField(data, "disableCameraMovement")) disableCameraMovement = Reflect.field(data, "disableCameraMovement");
        } catch (_:Dynamic) {}
        updateConfigModifiedTime();
    }

    static function saveConfig():Void {
        try {
            File.saveContent(CONFIG_PATH, Json.stringify({
                enabled: enabled,
                autoUnlockOnDeath: autoUnlockOnDeath,
                quickSwapTarget: quickSwapTarget,
                disableCameraMovement: disableCameraMovement
            }, null, "  "));
            updateConfigModifiedTime();
        } catch (_:Dynamic) {}
    }
}
