package fixtargetlock;

import haxe.Json;
import imgui.ImGui;
import imgui.Enums.ImGuiKey;
import imgui.ref.BoolRef;
import sys.FileSystem;
import sys.io.File;

@:build(hlx.runtime.Mod.build())
class FixTargetLockMod {
    static inline var CONFIG_PATH = "hlx/mods/fix-target-lock/config.json";

    static var enabled = new BoolRef(true);
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
    static var constType:hl.Bytes;
    static var isPressedMember:hlx.runtime.ResolvedMember;
    static var lockAutoTargetMember:hlx.runtime.ResolvedMember;
    static var leaveLockMember:hlx.runtime.ResolvedMember;
    static var lastController:Dynamic;
    static var originalTargetLock:Null<Bool>;
    static var lastAppliedEnabled:Null<Bool>;
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
                updateStatus(instance);
                return;
            }

            var inLock:Dynamic = HlxRuntime.resolveField(instance, "inLock");
            if (inLock == true) {
                HlxRuntime.callResolved(leaveLockMember, [instance]);
                lastStatus = "Unlocked";
                trace("[FixTargetLock] target unlocked");
            } else {
                HlxRuntime.callResolved(lockAutoTargetMember, [instance]);
                updateStatus(instance);
                trace("[FixTargetLock] lock action pressed: " + lastStatus);
            }
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

        return isPressedMember != null
            && lockAutoTargetMember != null
            && leaveLockMember != null;
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

        if (lastAppliedEnabled == enabled.get())
            return;

        Reflect.setField(camera, "TargetLock", enabled.get() ? true : originalTargetLock);
        lastAppliedEnabled = enabled.get();
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
        lastAppliedEnabled = null;
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
                lastAppliedEnabled = null;
                applyFeatureFlag();
            }
            saveConfig();
        }

        ImGui.text("Status: " + lastStatus);
        ImGui.textWrapped("Use Farever's existing Lock Target binding. Press once while aiming at an enemy to lock; press it again to unlock.");
        ImGui.textWrapped("Single-target attacks use the lock. Area-of-effect attacks keep their normal targeting.");

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

