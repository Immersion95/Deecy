//! SDL3-backed gamepad input layer.
//!
//! This module replaces the GLFW-based gamepad API previously used by Deecy.
//! Motivation: GLFW reads gamepads through DirectInput on Windows, and some
//! environments (notably Steam with PlayStation / Steam Input handling enabled)
//! can hide or remap PS4/PS5 controllers in ways that break GLFW-based input.
//! SDL3's gamepad API uses SDL's controller database and HIDAPI/OS backends,
//! which is the path used by many emulators for DualShock/DualSense support.
//!
//! Public enums (`Button`, `Axis`) intentionally use the same tag names as the
//! previous `zglfw.Gamepad.Button` / `zglfw.Gamepad.Axis` types, so existing
//! `config.zon` and `shortcuts.zon` files continue to parse.
//!
//! We ship a minimal `extern` binding rather than depending on SDL headers, so
//! the only build requirement is linking against the `SDL3` library.

const std = @import("std");

const log = std.log.scoped(.gamepad);

// ============================================================================
// Minimal SDL3 bindings
// ============================================================================
//
// We declare only the symbols we use. These declarations match SDL 3.2+.

const c = struct {
    // Subsystem flags
    pub const SDL_INIT_JOYSTICK: u32 = 0x00000200;
    pub const SDL_INIT_GAMEPAD: u32 = 0x00002000;

    // Button / axis indices — stable SDL3 ABI values.
    pub const SDL_GAMEPAD_BUTTON_SOUTH: c_int = 0;
    pub const SDL_GAMEPAD_BUTTON_EAST: c_int = 1;
    pub const SDL_GAMEPAD_BUTTON_WEST: c_int = 2;
    pub const SDL_GAMEPAD_BUTTON_NORTH: c_int = 3;
    pub const SDL_GAMEPAD_BUTTON_BACK: c_int = 4;
    pub const SDL_GAMEPAD_BUTTON_GUIDE: c_int = 5;
    pub const SDL_GAMEPAD_BUTTON_START: c_int = 6;
    pub const SDL_GAMEPAD_BUTTON_LEFT_STICK: c_int = 7;
    pub const SDL_GAMEPAD_BUTTON_RIGHT_STICK: c_int = 8;
    pub const SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: c_int = 9;
    pub const SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: c_int = 10;
    pub const SDL_GAMEPAD_BUTTON_DPAD_UP: c_int = 11;
    pub const SDL_GAMEPAD_BUTTON_DPAD_DOWN: c_int = 12;
    pub const SDL_GAMEPAD_BUTTON_DPAD_LEFT: c_int = 13;
    pub const SDL_GAMEPAD_BUTTON_DPAD_RIGHT: c_int = 14;

    pub const SDL_GAMEPAD_AXIS_LEFTX: c_int = 0;
    pub const SDL_GAMEPAD_AXIS_LEFTY: c_int = 1;
    pub const SDL_GAMEPAD_AXIS_RIGHTX: c_int = 2;
    pub const SDL_GAMEPAD_AXIS_RIGHTY: c_int = 3;
    pub const SDL_GAMEPAD_AXIS_LEFT_TRIGGER: c_int = 4;
    pub const SDL_GAMEPAD_AXIS_RIGHT_TRIGGER: c_int = 5;

    // Hint strings. These must be set before SDL initializes the joystick /
    // gamepad subsystem.
    pub const SDL_HINT_NO_SIGNAL_HANDLERS = "SDL_NO_SIGNAL_HANDLERS";
    pub const SDL_HINT_JOYSTICK_HIDAPI = "SDL_JOYSTICK_HIDAPI";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS4 = "SDL_JOYSTICK_HIDAPI_PS4";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS5 = "SDL_JOYSTICK_HIDAPI_PS5";
    pub const SDL_HINT_JOYSTICK_HIDAPI_SWITCH = "SDL_JOYSTICK_HIDAPI_SWITCH";
    pub const SDL_HINT_JOYSTICK_HIDAPI_XBOX = "SDL_JOYSTICK_HIDAPI_XBOX";
    pub const SDL_HINT_JOYSTICK_RAWINPUT = "SDL_JOYSTICK_RAWINPUT";
    pub const SDL_HINT_JOYSTICK_RAWINPUT_CORRELATE_XINPUT = "SDL_JOYSTICK_RAWINPUT_CORRELATE_XINPUT";
    pub const SDL_HINT_JOYSTICK_WGI = "SDL_JOYSTICK_WGI";
    pub const SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS = "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS";

    // Opaque handles
    pub const SDL_Gamepad = opaque {};
    pub const SDL_JoystickID = i32;

    // Event type codes we care about. In SDL3, GAMEPAD_ADDED/REMOVED are
    // 0x653/0x654 and their payload's `which` member is already a joystick
    // instance id, not the temporary device index used by SDL2.
    pub const SDL_EVENT_GAMEPAD_ADDED: u32 = 0x653;
    pub const SDL_EVENT_GAMEPAD_REMOVED: u32 = 0x654;

    // SDL3's SDL_Event union is 128 bytes. We only inspect the leading type
    // field and gdevice.which, but the backing buffer must be large enough for
    // SDL_PollEvent to write a complete event.
    pub const SDL_Event = extern struct {
        type: u32,
        padding: [124]u8,
    };

    pub extern fn SDL_Init(flags: u32) callconv(.c) bool;
    pub extern fn SDL_QuitSubSystem(flags: u32) callconv(.c) void;
    pub extern fn SDL_GetError() callconv(.c) ?[*:0]const u8;
    pub extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) bool;
    pub extern fn SDL_free(mem: ?*anyopaque) callconv(.c) void;

    pub extern fn SDL_PollEvent(event: *SDL_Event) callconv(.c) bool;

    pub extern fn SDL_GetGamepads(count: *c_int) callconv(.c) ?[*]SDL_JoystickID;
    pub extern fn SDL_IsGamepad(instance_id: SDL_JoystickID) callconv(.c) bool;
    pub extern fn SDL_OpenGamepad(instance_id: SDL_JoystickID) callconv(.c) ?*SDL_Gamepad;
    pub extern fn SDL_CloseGamepad(gamepad: *SDL_Gamepad) callconv(.c) void;
    pub extern fn SDL_GetGamepadFromID(instance_id: SDL_JoystickID) callconv(.c) ?*SDL_Gamepad;
    pub extern fn SDL_GamepadConnected(gamepad: *SDL_Gamepad) callconv(.c) bool;
    pub extern fn SDL_GetGamepadName(gamepad: *SDL_Gamepad) callconv(.c) ?[*:0]const u8;
    pub extern fn SDL_UpdateGamepads() callconv(.c) void;
    pub extern fn SDL_GetGamepadButton(gamepad: *SDL_Gamepad, button: c_int) callconv(.c) bool;
    pub extern fn SDL_GetGamepadAxis(gamepad: *SDL_Gamepad, axis: c_int) callconv(.c) i16;
    pub extern fn SDL_RumbleGamepad(gamepad: *SDL_Gamepad, low_freq: u16, high_freq: u16, duration_ms: u32) callconv(.c) bool;
};

// ============================================================================
// Public types
// ============================================================================

/// Gamepad buttons. Tag names match `zglfw.Gamepad.Button` for backward
/// compatibility with serialized configurations.
pub const Button = enum(u8) {
    a = 0,
    b = 1,
    x = 2,
    y = 3,
    left_bumper = 4,
    right_bumper = 5,
    back = 6,
    start = 7,
    guide = 8,
    left_thumb = 9,
    right_thumb = 10,
    dpad_up = 11,
    dpad_right = 12,
    dpad_down = 13,
    dpad_left = 14,

    pub const count: usize = @typeInfo(Button).@"enum".fields.len;
};

/// Analog axes. Tag names match `zglfw.Gamepad.Axis`. Trigger axes use the
/// same GLFW convention: at rest they return -1, and at full press +1.
pub const Axis = enum(u8) {
    left_x = 0,
    left_y = 1,
    right_x = 2,
    right_y = 3,
    left_trigger = 4,
    right_trigger = 5,

    pub const count: usize = @typeInfo(Axis).@"enum".fields.len;
};

/// Per-button action. Matches the `.press` / `.release` tags of `zglfw.Action`
/// so existing call sites work unmodified.
pub const ButtonAction = enum(u8) {
    release = 0,
    press = 1,
};

/// Snapshot of a gamepad's state at a given instant.
pub const State = struct {
    buttons: [Button.count]ButtonAction = @splat(.release),
    axes: [Axis.count]f32 = @splat(0),
};

/// Translate from our `Button` enum to the SDL_GAMEPAD_BUTTON_* index. Note
/// that our enum tag names match GLFW's old names, while SDL3 uses location
/// names for face buttons: south/east/west/north.
fn toSdlButton(btn: Button) c_int {
    return switch (btn) {
        .a => c.SDL_GAMEPAD_BUTTON_SOUTH,
        .b => c.SDL_GAMEPAD_BUTTON_EAST,
        .x => c.SDL_GAMEPAD_BUTTON_WEST,
        .y => c.SDL_GAMEPAD_BUTTON_NORTH,
        .left_bumper => c.SDL_GAMEPAD_BUTTON_LEFT_SHOULDER,
        .right_bumper => c.SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER,
        .back => c.SDL_GAMEPAD_BUTTON_BACK,
        .start => c.SDL_GAMEPAD_BUTTON_START,
        .guide => c.SDL_GAMEPAD_BUTTON_GUIDE,
        .left_thumb => c.SDL_GAMEPAD_BUTTON_LEFT_STICK,
        .right_thumb => c.SDL_GAMEPAD_BUTTON_RIGHT_STICK,
        .dpad_up => c.SDL_GAMEPAD_BUTTON_DPAD_UP,
        .dpad_right => c.SDL_GAMEPAD_BUTTON_DPAD_RIGHT,
        .dpad_down => c.SDL_GAMEPAD_BUTTON_DPAD_DOWN,
        .dpad_left => c.SDL_GAMEPAD_BUTTON_DPAD_LEFT,
    };
}

fn toSdlAxis(axis: Axis) c_int {
    return switch (axis) {
        .left_x => c.SDL_GAMEPAD_AXIS_LEFTX,
        .left_y => c.SDL_GAMEPAD_AXIS_LEFTY,
        .right_x => c.SDL_GAMEPAD_AXIS_RIGHTX,
        .right_y => c.SDL_GAMEPAD_AXIS_RIGHTY,
        .left_trigger => c.SDL_GAMEPAD_AXIS_LEFT_TRIGGER,
        .right_trigger => c.SDL_GAMEPAD_AXIS_RIGHT_TRIGGER,
    };
}

// ============================================================================
// Handles
// ============================================================================

/// Opaque controller identifier. The underlying value is an SDL_JoystickID,
/// which is a stable instance identifier assigned to a physical controller.
///
/// The `maximum_supported` constant is preserved from the previous GLFW-based
/// API; it bounds UI allocation but does not meaningfully limit SDL.
pub const Joystick = enum(c.SDL_JoystickID) {
    _,

    pub const maximum_supported: usize = 16;

    pub fn isPresent(self: Joystick) bool {
        if (!initialized) return false;
        const id: c.SDL_JoystickID = @intFromEnum(self);
        if (c.SDL_GetGamepadFromID(id)) |gp|
            return c.SDL_GamepadConnected(gp);
        return c.SDL_IsGamepad(id);
    }

    pub fn asGamepad(self: Joystick) ?Gamepad {
        if (!initialized) return null;
        const id: c.SDL_JoystickID = @intFromEnum(self);
        if (!c.SDL_IsGamepad(id)) return null;
        const gp = c.SDL_GetGamepadFromID(id) orelse c.SDL_OpenGamepad(id) orelse return null;
        if (!c.SDL_GamepadConnected(gp)) return null;
        return .{ .handle = gp };
    }

    /// Convenience rumble accessor that mirrors the API the previous
    /// `zglfw.Joystick` exposed.
    pub fn setRumble(self: Joystick, low: f32, high: f32) bool {
        const gp = self.asGamepad() orelse return false;
        return gp.setRumble(low, high);
    }
};

/// Short-lived view over an opened controller. Cheap to copy.
pub const Gamepad = struct {
    handle: *c.SDL_Gamepad,

    pub fn getState(self: Gamepad) error{Disconnected}!State {
        if (!c.SDL_GamepadConnected(self.handle))
            return error.Disconnected;
        var state: State = .{};
        inline for (std.meta.fields(Button)) |f| {
            const btn: Button = @enumFromInt(f.value);
            state.buttons[f.value] = if (c.SDL_GetGamepadButton(self.handle, toSdlButton(btn))) .press else .release;
        }
        inline for (std.meta.fields(Axis)) |f| {
            const axis: Axis = @enumFromInt(f.value);
            const raw = c.SDL_GetGamepadAxis(self.handle, toSdlAxis(axis));
            state.axes[f.value] = switch (axis) {
                // SDL trigger range is [0, 32767]; GLFW reports triggers as
                // [-1, +1] with rest = -1. Remap to match so existing clamping
                // logic continues to work.
                .left_trigger, .right_trigger => blk: {
                    const norm = @as(f32, @floatFromInt(raw)) / 32767.0;
                    break :blk norm * 2.0 - 1.0;
                },
                // Sticks: SDL range [-32768, 32767] → [-1, +1]. We clamp the
                // negative side so we never emit less than -1.
                else => @max(-1.0, @as(f32, @floatFromInt(raw)) / 32767.0),
            };
        }
        return state;
    }

    pub fn getName(self: Gamepad) [:0]const u8 {
        const ptr = c.SDL_GetGamepadName(self.handle) orelse return "Unknown Controller";
        return std.mem.span(ptr);
    }

    /// Set rumble strength, each parameter in [0, 1]. Returns true on success.
    ///
    /// SDL requires a duration; we pass a conservative 1-second window, and the
    /// caller refreshes rumble every frame via Deecy's per-frame rumble update.
    pub fn setRumble(self: Gamepad, low: f32, high: f32) bool {
        const lo: u16 = @intFromFloat(std.math.clamp(low, 0, 1) * 65535.0);
        const hi: u16 = @intFromFloat(std.math.clamp(high, 0, 1) * 65535.0);
        return c.SDL_RumbleGamepad(self.handle, lo, hi, 1000);
    }
};

// ============================================================================
// Lifecycle
// ============================================================================

var initialized: bool = false;

pub fn init() !void {
    if (initialized) return;

    // Hints must be set before SDL_Init. Prefer the HIDAPI path for
    // PlayStation controllers to avoid the DirectInput/Steam/XInput ambiguity
    // that was causing DualSense devices to disappear after button presses.
    _ = c.SDL_SetHint(c.SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS4, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_SWITCH, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_XBOX, "1");

    // On Windows, RAWINPUT/WGI can produce duplicate or partial devices in the
    // exact failure mode described by some pads: triggers update but buttons do
    // not. Keep those off unless the user explicitly overrides via env vars.
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_RAWINPUT, "0");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_RAWINPUT_CORRELATE_XINPUT, "0");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_WGI, "0");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");

    if (!c.SDL_Init(c.SDL_INIT_GAMEPAD | c.SDL_INIT_JOYSTICK)) {
        const err = c.SDL_GetError();
        const err_slice = if (err) |p| std.mem.span(p) else "(null)";
        log.err("SDL_Init failed: {s}", .{err_slice});
        return error.GamepadInitFailed;
    }

    initialized = true;
    log.info("Gamepad subsystem initialized (SDL3).", .{});
}

pub fn deinit() void {
    if (!initialized) return;
    c.SDL_QuitSubSystem(c.SDL_INIT_GAMEPAD | c.SDL_INIT_JOYSTICK);
    initialized = false;
}

/// Pump the SDL event queue and refresh controller state. Call this once per
/// frame before reading any controller.
pub fn update() void {
    if (!initialized) return;

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event)) {
        switch (event.type) {
            c.SDL_EVENT_GAMEPAD_ADDED => {
                const instance_id = readGamepadDeviceEventWhich(&event);
                if (c.SDL_IsGamepad(instance_id))
                    _ = c.SDL_OpenGamepad(instance_id);
            },
            c.SDL_EVENT_GAMEPAD_REMOVED => {
                const instance_id = readGamepadDeviceEventWhich(&event);
                if (c.SDL_GetGamepadFromID(instance_id)) |gp|
                    c.SDL_CloseGamepad(gp);
            },
            else => {},
        }
    }
    c.SDL_UpdateGamepads();
}

/// SDL3's SDL_GamepadDeviceEvent stores `which` at byte 16:
/// type:u32, reserved:u32, timestamp:u64, which:SDL_JoystickID.
fn readGamepadDeviceEventWhich(event: *const c.SDL_Event) c.SDL_JoystickID {
    const bytes: [*]const u8 = @ptrCast(event);
    var value: c.SDL_JoystickID = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[16..20]);
    return value;
}

// ============================================================================
// Enumeration
// ============================================================================

/// Iterator over currently connected gamepads. SDL3 returns an allocated list of
/// instance ids; callers must `defer it.deinit()` after `iterate()`.
pub const Iterator = struct {
    index: c_int = 0,
    count: c_int = 0,
    ids: ?[*]c.SDL_JoystickID = null,

    pub fn deinit(self: *Iterator) void {
        if (self.ids) |ids| {
            c.SDL_free(@as(*anyopaque, @ptrCast(ids)));
            self.ids = null;
        }
        self.count = 0;
        self.index = 0;
    }

    pub fn next(self: *Iterator) ?Joystick {
        const ids = self.ids orelse return null;
        while (self.index < self.count) {
            const i = self.index;
            self.index += 1;
            const instance_id = ids[@intCast(i)];
            if (!c.SDL_IsGamepad(instance_id)) continue;
            if (c.SDL_GetGamepadFromID(instance_id) == null) {
                _ = c.SDL_OpenGamepad(instance_id);
            }
            return @enumFromInt(instance_id);
        }
        return null;
    }
};

pub fn iterate() Iterator {
    if (!initialized) return .{};
    var count: c_int = 0;
    const ids = c.SDL_GetGamepads(&count) orelse return .{};
    return .{ .count = count, .ids = ids };
}
