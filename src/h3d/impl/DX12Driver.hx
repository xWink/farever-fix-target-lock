package h3d.impl;

// Minimal compile-time wrappers required by hl-imgui's frame hook.
abstract DX12Driver(Dynamic) {
    public var frame(get, never):DX12Frame;
    inline function get_frame():DX12Frame
        return cast HlxRuntime.resolveField(this, "frame");

    public var frames(get, never):Dynamic;
    inline function get_frames():Dynamic
        return HlxRuntime.resolveField(this, "frames");

    public var window(get, never):DX12Window;
    inline function get_window():DX12Window
        return cast HlxRuntime.resolveField(this, "window");
}

abstract DX12Window(Dynamic) {
    public var win(get, never):imgui.ImGui.Window;
    inline function get_win():imgui.ImGui.Window
        return HlxRuntime.resolveAbstract(
            HlxRuntime.resolveField(this, "win"),
            (null : imgui.ImGui.Window)
        );
}

abstract DX12Frame(Dynamic) {
    public var commandList(get, never):imgui.ImGui.Resource;
    inline function get_commandList():imgui.ImGui.Resource
        return HlxRuntime.resolveAbstract(
            HlxRuntime.resolveField(this, "commandList"),
            (null : imgui.ImGui.Resource)
        );
}

