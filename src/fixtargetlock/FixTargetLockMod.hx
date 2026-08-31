package fixtargetlock;

import haxe.Json;
import imgui.ImGui;
import imgui.Enums.ImGuiKey;
import imgui.ref.BoolRef;
import hlx.runtime.HlxPrefixControl;
import sys.FileSystem;
import sys.io.File;

@:build(hlx.runtime.Mod.build())
class FixTargetLockMod {
    static inline var CONFIG_PATH = "hlx/mods/fix-target-lock/config.json";

    static var enabled = new BoolRef(true);
    static var autoUnlockOnDeath = new BoolRef(true);
    static var quickSwapTarget = new BoolRef(false);
    static var disableCameraMovement = new BoolRef(false);
    static var panelOpen = new BoolRef(true);
    static var hasSeenMenu:Bool = false;

    static var hotkeyKey:Int = ImGuiKey.F9;
    static var hotkeyCtrl:Bool = false;
    static var hotkeyShift:Bool = false;
    static var hotkeyAlt:Bool = false;
    static var hotkeySuper:Bool = false;
    static var capturingHotkey:Bool = false;

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
        panelOpen.set(!hasSeenMenu);
        ImGui.register(HlxRuntime.moduleName(), drawSettings);
        trace("[FixTargetLock] loaded; waiting for PlayerController");
    }

    @:hlx.postfix(client.PlayerController.updateInputs)
    static function afterUpdateInputs(instance:Dynamic, dt:Float, result:Void):Void {
        lastController = instance;

        try {
            applyFeatureFlag();
            if (!enabled.get()) {
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
                if (quickSwapTarget.get() && aimedTarget != null) {
                    var lockedTarget = getLockedTarget(instance);
                    if (lockedTarget != aimedTarget) {
                        HlxRuntime.callResolved(lockTargetMember, [instance, aimedTarget]);
                        updateStatus(instance);
                        swapped = true;
                        trace("[FixTargetLock] switched locked target");
                    }
                }

                if (!swapped) {
                    HlxRuntime.callResolved(leaveLockMember, [instance]);
                    lastStatus = "Unlocked";
                    trace("[FixTargetLock] target unlocked");
                }
            } else {
                HlxRuntime.callResolved(lockAutoTargetMember, [instance]);
                updateStatus(instance);
                trace("[FixTargetLock] lock action pressed: " + lastStatus);
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
        if (!enabled.get() || instance != lastController)
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
            trace("[FixTargetLock] forced attack to locked target");
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
        if (!autoUnlockOnDeath.get())
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
            trace("[FixTargetLock] automatically unlocked defeated target");
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
        var desired = enabled.get() ? true : originalTargetLock;
        if (lastAppliedTargetLock == desired)
            return;

        Reflect.setField(camera, "TargetLock", desired);
        lastAppliedTargetLock = desired;
    }

    @:hlx.prefix(client.GameCamera.postUpdate)
    static function beforeCameraPostUpdate(instance:Dynamic, dt:Float):HlxPrefixControl {
        cameraUpdateTargetLock = null;
        if (!enabled.get() || !disableCameraMovement.get())
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

    static function drawSettings():Void {
        if (!capturingHotkey && hotkeyPressed())
            panelOpen.set(!panelOpen.get());

        if (!panelOpen.get())
            return;

        ImGui.setNextWindowBgAlpha(0.98);
        if (!ImGui.begin("Fix Target Lock", panelOpen)) {
            ImGui.end();
            return;
        }

        if (!hasSeenMenu) {
            hasSeenMenu = true;
            saveConfig();
        }

        ImGui.text("Restores Farever's target-lock input");
        ImGui.separator();

        var oldEnabled = enabled.get();
        ImGui.checkbox("Enable", enabled);
        if (enabled.get() != oldEnabled) {
            if (!enabled.get())
                disableAndUnlock();
            else {
                lastAppliedTargetLock = null;
                applyFeatureFlag();
            }
            saveConfig();
        }

        var oldAutoUnlock = autoUnlockOnDeath.get();
        ImGui.checkbox("Auto-unlock when target dies", autoUnlockOnDeath);
        if (autoUnlockOnDeath.get() != oldAutoUnlock)
            saveConfig();

        var oldQuickSwap = quickSwapTarget.get();
        ImGui.checkbox("Press Lock Target to switch targets", quickSwapTarget);
        if (quickSwapTarget.get() != oldQuickSwap)
            saveConfig();

        var oldDisableCamera = disableCameraMovement.get();
        ImGui.checkbox("Disable automatic camera movement", disableCameraMovement);
        if (disableCameraMovement.get() != oldDisableCamera) {
            saveConfig();
        }

        ImGui.text("Status: " + lastStatus);
        ImGui.textWrapped("Use Farever's existing Lock Target binding. Press once while aiming at an enemy to lock; press it again to unlock.");
        ImGui.textWrapped("Single-target attacks use the lock. Area-of-effect attacks keep their normal targeting.");
        ImGui.textWrapped("Strict targeting is active: normal and immediate-target attacks are submitted with the locked enemy even while looking at another enemy.");

        ImGui.separator();
        ImGui.text("Open settings hotkey: " + hotkeyLabel());
        if (!capturingHotkey) {
            if (ImGui.button("Change hotkey"))
                capturingHotkey = true;
        } else {
            ImGui.text("Press a key combination...");
            ImGui.text("Hold Ctrl/Shift/Alt/Win, then press a key. Esc cancels.");
            captureNextHotkey();
        }

        ImGui.end();
    }

    static function hotkeyPressed():Bool {
        if (!ImGui.isKeyPressed(hotkeyKey, false))
            return false;
        return modifierDown(ImGuiKey.LeftCtrl, ImGuiKey.RightCtrl) == hotkeyCtrl
            && modifierDown(ImGuiKey.LeftShift, ImGuiKey.RightShift) == hotkeyShift
            && modifierDown(ImGuiKey.LeftAlt, ImGuiKey.RightAlt) == hotkeyAlt
            && modifierDown(ImGuiKey.LeftSuper, ImGuiKey.RightSuper) == hotkeySuper;
    }

    static function captureNextHotkey():Void {
        if (ImGui.isKeyPressed(ImGuiKey.Escape, false)) {
            capturingHotkey = false;
            return;
        }
        for (key in 512...632) {
            if (isModifierKey(key) || key == ImGuiKey.Escape)
                continue;
            if (ImGui.isKeyPressed(key, false)) {
                hotkeyKey = key;
                hotkeyCtrl = modifierDown(ImGuiKey.LeftCtrl, ImGuiKey.RightCtrl);
                hotkeyShift = modifierDown(ImGuiKey.LeftShift, ImGuiKey.RightShift);
                hotkeyAlt = modifierDown(ImGuiKey.LeftAlt, ImGuiKey.RightAlt);
                hotkeySuper = modifierDown(ImGuiKey.LeftSuper, ImGuiKey.RightSuper);
                capturingHotkey = false;
                saveConfig();
                return;
            }
        }
    }

    static inline function modifierDown(left:Int, right:Int):Bool
        return ImGui.isKeyDown(left) || ImGui.isKeyDown(right);

    static inline function isModifierKey(key:Int):Bool
        return key >= ImGuiKey.LeftCtrl && key <= ImGuiKey.RightSuper;

    static function hotkeyLabel():String {
        var parts = new Array<String>();
        if (hotkeyCtrl) parts.push("Ctrl");
        if (hotkeyShift) parts.push("Shift");
        if (hotkeyAlt) parts.push("Alt");
        if (hotkeySuper) parts.push("Win");
        parts.push(keyLabel(hotkeyKey));
        return parts.join(" + ");
    }

    static function keyLabel(key:Int):String {
        if (key >= ImGuiKey._0 && key <= ImGuiKey._9)
            return String.fromCharCode(48 + (key - ImGuiKey._0));
        if (key >= ImGuiKey.A && key <= ImGuiKey.Z)
            return String.fromCharCode(65 + (key - ImGuiKey.A));
        if (key >= ImGuiKey.F1 && key <= ImGuiKey.F24)
            return "F" + (key - ImGuiKey.F1 + 1);
        return switch (key) {
            case ImGuiKey.Tab: "Tab";
            case ImGuiKey.LeftArrow: "Left";
            case ImGuiKey.RightArrow: "Right";
            case ImGuiKey.UpArrow: "Up";
            case ImGuiKey.DownArrow: "Down";
            case ImGuiKey.PageUp: "Page Up";
            case ImGuiKey.PageDown: "Page Down";
            case ImGuiKey.Home: "Home";
            case ImGuiKey.End: "End";
            case ImGuiKey.Insert: "Insert";
            case ImGuiKey.Delete: "Delete";
            case ImGuiKey.Backspace: "Backspace";
            case ImGuiKey.Space: "Space";
            case ImGuiKey.Enter: "Enter";
            case ImGuiKey.Menu: "Menu";
            default: "Key " + key;
        };
    }

    static function loadConfig():Void {
        try {
            if (!FileSystem.exists(CONFIG_PATH))
                return;
            var data:Dynamic = Json.parse(File.getContent(CONFIG_PATH));
            if (Reflect.hasField(data, "enabled")) enabled.set(Reflect.field(data, "enabled"));
            if (Reflect.hasField(data, "autoUnlockOnDeath")) autoUnlockOnDeath.set(Reflect.field(data, "autoUnlockOnDeath"));
            if (Reflect.hasField(data, "quickSwapTarget")) quickSwapTarget.set(Reflect.field(data, "quickSwapTarget"));
            if (Reflect.hasField(data, "disableCameraMovement")) disableCameraMovement.set(Reflect.field(data, "disableCameraMovement"));
            if (Reflect.hasField(data, "hotkeyKey")) hotkeyKey = cast Reflect.field(data, "hotkeyKey");
            if (Reflect.hasField(data, "hotkeyCtrl")) hotkeyCtrl = Reflect.field(data, "hotkeyCtrl");
            if (Reflect.hasField(data, "hotkeyShift")) hotkeyShift = Reflect.field(data, "hotkeyShift");
            if (Reflect.hasField(data, "hotkeyAlt")) hotkeyAlt = Reflect.field(data, "hotkeyAlt");
            if (Reflect.hasField(data, "hotkeySuper")) hotkeySuper = Reflect.field(data, "hotkeySuper");
            if (Reflect.hasField(data, "hasSeenMenu")) hasSeenMenu = Reflect.field(data, "hasSeenMenu");
            else hasSeenMenu = true;
        } catch (_:Dynamic) {}
    }

    static function saveConfig():Void {
        try {
            File.saveContent(CONFIG_PATH, Json.stringify({
                enabled: enabled.get(),
                autoUnlockOnDeath: autoUnlockOnDeath.get(),
                quickSwapTarget: quickSwapTarget.get(),
                disableCameraMovement: disableCameraMovement.get(),
                hotkeyKey: hotkeyKey,
                hotkeyCtrl: hotkeyCtrl,
                hotkeyShift: hotkeyShift,
                hotkeyAlt: hotkeyAlt,
                hotkeySuper: hotkeySuper,
                hasSeenMenu: hasSeenMenu
            }, null, "  "));
        } catch (_:Dynamic) {}
    }
}
