//! SDL2-backed gamepad input layer.
//!
//! This module replaces the GLFW-based gamepad API previously used by Deecy.
//! Motivation: GLFW reads gamepads through DirectInput on Windows, and some
//! environments (notably Steam with "PlayStation Configuration Support"
//! enabled) hide PS4/PS5 controllers from DirectInput, breaking GLFW-based
//! input. SDL2's HIDAPI backend talks to the controller directly and is
//! unaffected. Every other major emulator uses SDL for this reason, so using
//! SDL brings Deecy's controller behavior in line with the rest of the
//! ecosystem.
//!
//! Public enums (`Button`, `Axis`) intentionally use the same tag names as
//! the previous `zglfw.Gamepad.Button` / `zglfw.Gamepad.Axis` types, so
//! existing `config.zon` and `shortcuts.zon` files continue to parse.
//!
//! We ship a minimal `extern` binding rather than depending on SDL headers,
//! so the only build requirement is linking against the `SDL2` library.

const std = @import("std");
const builtin = @import("builtin");

const log = std.log.scoped(.gamepad);

// ============================================================================
// Minimal SDL2 bindings
// ============================================================================
//
// We declare only the symbols we use. SDL2's ABI is stable across all 2.x
// releases, so these signatures are safe to hard-code.

const c = struct {
    // Subsystem flags
    pub const SDL_INIT_JOYSTICK: u32 = 0x00000200;
    pub const SDL_INIT_GAMECONTROLLER: u32 = 0x00002000;

    // Booleans
    pub const SDL_FALSE: c_int = 0;
    pub const SDL_TRUE: c_int = 1;

    // Button / axis indices — stable SDL2 ABI values
    pub const SDL_CONTROLLER_BUTTON_A: c_int = 0;
    pub const SDL_CONTROLLER_BUTTON_B: c_int = 1;
    pub const SDL_CONTROLLER_BUTTON_X: c_int = 2;
    pub const SDL_CONTROLLER_BUTTON_Y: c_int = 3;
    pub const SDL_CONTROLLER_BUTTON_BACK: c_int = 4;
    pub const SDL_CONTROLLER_BUTTON_GUIDE: c_int = 5;
    pub const SDL_CONTROLLER_BUTTON_START: c_int = 6;
    pub const SDL_CONTROLLER_BUTTON_LEFTSTICK: c_int = 7;
    pub const SDL_CONTROLLER_BUTTON_RIGHTSTICK: c_int = 8;
    pub const SDL_CONTROLLER_BUTTON_LEFTSHOULDER: c_int = 9;
    pub const SDL_CONTROLLER_BUTTON_RIGHTSHOULDER: c_int = 10;
    pub const SDL_CONTROLLER_BUTTON_DPAD_UP: c_int = 11;
    pub const SDL_CONTROLLER_BUTTON_DPAD_DOWN: c_int = 12;
    pub const SDL_CONTROLLER_BUTTON_DPAD_LEFT: c_int = 13;
    pub const SDL_CONTROLLER_BUTTON_DPAD_RIGHT: c_int = 14;

    pub const SDL_CONTROLLER_AXIS_LEFTX: c_int = 0;
    pub const SDL_CONTROLLER_AXIS_LEFTY: c_int = 1;
    pub const SDL_CONTROLLER_AXIS_RIGHTX: c_int = 2;
    pub const SDL_CONTROLLER_AXIS_RIGHTY: c_int = 3;
    pub const SDL_CONTROLLER_AXIS_TRIGGERLEFT: c_int = 4;
    pub const SDL_CONTROLLER_AXIS_TRIGGERRIGHT: c_int = 5;

    // Hint strings
    pub const SDL_HINT_NO_SIGNAL_HANDLERS = "SDL_NO_SIGNAL_HANDLERS";
    pub const SDL_HINT_JOYSTICK_HIDAPI = "SDL_JOYSTICK_HIDAPI";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS4 = "SDL_JOYSTICK_HIDAPI_PS4";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS4_RUMBLE = "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS5 = "SDL_JOYSTICK_HIDAPI_PS5";
    pub const SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE = "SDL_JOYSTICK_HIDAPI_PS5_RUMBLE";
    pub const SDL_HINT_JOYSTICK_HIDAPI_SWITCH = "SDL_JOYSTICK_HIDAPI_SWITCH";
    pub const SDL_HINT_JOYSTICK_HIDAPI_XBOX = "SDL_JOYSTICK_HIDAPI_XBOX";
    pub const SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS = "SDL_JOYSTICK_ALLOW_BACKGROUND_EVENTS";

    // Opaque handles
    pub const SDL_GameController = opaque {};
    pub const SDL_JoystickID = i32;

    // Event type codes we care about (SDL2 stable values).
    pub const SDL_CONTROLLERDEVICEADDED: u32 = 0x650;
    pub const SDL_CONTROLLERDEVICEREMOVED: u32 = 0x651;

    // We never decode event payloads; we just need SDL_Event to be the right
    // size so SDL_PollEvent can write into it. In SDL2, SDL_Event is a union
    // of several structs and has a fixed 56-byte footprint on all supported
    // platforms.
    pub const SDL_Event = extern struct {
        type: u32,
        padding: [52]u8,
    };

    pub extern fn SDL_Init(flags: u32) callconv(.c) c_int;
    pub extern fn SDL_InitSubSystem(flags: u32) callconv(.c) c_int;
    pub extern fn SDL_QuitSubSystem(flags: u32) callconv(.c) void;
    pub extern fn SDL_GetError() callconv(.c) ?[*:0]const u8;
    pub extern fn SDL_SetHint(name: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int;

    pub extern fn SDL_PollEvent(event: *SDL_Event) callconv(.c) c_int;

    pub extern fn SDL_NumJoysticks() callconv(.c) c_int;
    pub extern fn SDL_IsGameController(joystick_index: c_int) callconv(.c) c_int;
    pub extern fn SDL_JoystickGetDeviceInstanceID(device_index: c_int) callconv(.c) SDL_JoystickID;

    pub extern fn SDL_GameControllerOpen(joystick_index: c_int) callconv(.c) ?*SDL_GameController;
    pub extern fn SDL_GameControllerClose(gamecontroller: *SDL_GameController) callconv(.c) void;
    pub extern fn SDL_GameControllerFromInstanceID(joyid: SDL_JoystickID) callconv(.c) ?*SDL_GameController;
    pub extern fn SDL_GameControllerGetAttached(gamecontroller: *SDL_GameController) callconv(.c) c_int;
    pub extern fn SDL_GameControllerName(gamecontroller: *SDL_GameController) callconv(.c) ?[*:0]const u8;
    pub extern fn SDL_GameControllerUpdate() callconv(.c) void;
    pub extern fn SDL_GameControllerGetButton(gamecontroller: *SDL_GameController, button: c_int) callconv(.c) u8;
    pub extern fn SDL_GameControllerGetAxis(gamecontroller: *SDL_GameController, axis: c_int) callconv(.c) i16;
    pub extern fn SDL_GameControllerRumble(gamecontroller: *SDL_GameController, low_freq: u16, high_freq: u16, duration_ms: u32) callconv(.c) c_int;
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

/// Translate from our `Button` enum to the stable SDL_CONTROLLER_BUTTON_*
/// index. Note that although our enum tag *names* match GLFW, the numeric
/// *values* after .y differ between GLFW and SDL, so always route through
/// this function.
fn toSdlButton(btn: Button) c_int {
    return switch (btn) {
        .a => c.SDL_CONTROLLER_BUTTON_A,
        .b => c.SDL_CONTROLLER_BUTTON_B,
        .x => c.SDL_CONTROLLER_BUTTON_X,
        .y => c.SDL_CONTROLLER_BUTTON_Y,
        .left_bumper => c.SDL_CONTROLLER_BUTTON_LEFTSHOULDER,
        .right_bumper => c.SDL_CONTROLLER_BUTTON_RIGHTSHOULDER,
        .back => c.SDL_CONTROLLER_BUTTON_BACK,
        .start => c.SDL_CONTROLLER_BUTTON_START,
        .guide => c.SDL_CONTROLLER_BUTTON_GUIDE,
        .left_thumb => c.SDL_CONTROLLER_BUTTON_LEFTSTICK,
        .right_thumb => c.SDL_CONTROLLER_BUTTON_RIGHTSTICK,
        .dpad_up => c.SDL_CONTROLLER_BUTTON_DPAD_UP,
        .dpad_right => c.SDL_CONTROLLER_BUTTON_DPAD_RIGHT,
        .dpad_down => c.SDL_CONTROLLER_BUTTON_DPAD_DOWN,
        .dpad_left => c.SDL_CONTROLLER_BUTTON_DPAD_LEFT,
    };
}

fn toSdlAxis(axis: Axis) c_int {
    return switch (axis) {
        .left_x => c.SDL_CONTROLLER_AXIS_LEFTX,
        .left_y => c.SDL_CONTROLLER_AXIS_LEFTY,
        .right_x => c.SDL_CONTROLLER_AXIS_RIGHTX,
        .right_y => c.SDL_CONTROLLER_AXIS_RIGHTY,
        .left_trigger => c.SDL_CONTROLLER_AXIS_TRIGGERLEFT,
        .right_trigger => c.SDL_CONTROLLER_AXIS_TRIGGERRIGHT,
    };
}

// ============================================================================
// Handles
// ============================================================================

/// Opaque controller identifier. The underlying value is an SDL_JoystickID,
/// which is a stable instance identifier assigned to a physical controller
/// when it is first opened by SDL. The ID is unique within a process and
/// survives as long as the controller remains connected.
///
/// The `maximum_supported` constant is preserved from the previous GLFW-based
/// API; it bounds enumeration iterations in a few places but does not
/// meaningfully limit SDL.
pub const Joystick = enum(c.SDL_JoystickID) {
    _,

    pub const maximum_supported: usize = 16;

    pub fn isPresent(self: Joystick) bool {
        if (!initialized) return false;
        const id: c.SDL_JoystickID = @intFromEnum(self);
        const ctrl = c.SDL_GameControllerFromInstanceID(id) orelse return false;
        return c.SDL_GameControllerGetAttached(ctrl) == c.SDL_TRUE;
    }

    pub fn asGamepad(self: Joystick) ?Gamepad {
        if (!initialized) return null;
        const id: c.SDL_JoystickID = @intFromEnum(self);
        const ctrl = c.SDL_GameControllerFromInstanceID(id) orelse return null;
        if (c.SDL_GameControllerGetAttached(ctrl) != c.SDL_TRUE) return null;
        return .{ .handle = ctrl };
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
    handle: *c.SDL_GameController,

    pub fn getState(self: Gamepad) error{Disconnected}!State {
        if (c.SDL_GameControllerGetAttached(self.handle) != c.SDL_TRUE)
            return error.Disconnected;
        var state: State = .{};
        inline for (std.meta.fields(Button)) |f| {
            const btn: Button = @enumFromInt(f.value);
            const pressed = c.SDL_GameControllerGetButton(self.handle, toSdlButton(btn)) != 0;
            state.buttons[f.value] = if (pressed) .press else .release;
        }
        inline for (std.meta.fields(Axis)) |f| {
            const axis: Axis = @enumFromInt(f.value);
            const raw = c.SDL_GameControllerGetAxis(self.handle, toSdlAxis(axis));
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
        const ptr = c.SDL_GameControllerName(self.handle) orelse return "Unknown Controller";
        return std.mem.span(ptr);
    }

    /// Set rumble strength, each parameter in [0, 1]. Returns true on success.
    ///
    /// SDL requires a duration; we pass a conservative 1-second window, and
    /// the caller is expected to refresh the rumble every frame (which Deecy
    /// already does via the per-frame rumble update loop).
    pub fn setRumble(self: Gamepad, low: f32, high: f32) bool {
        const lo: u16 = @intFromFloat(std.math.clamp(low, 0, 1) * 65535.0);
        const hi: u16 = @intFromFloat(std.math.clamp(high, 0, 1) * 65535.0);
        return c.SDL_GameControllerRumble(self.handle, lo, hi, 1000) == 0;
    }
};

// ============================================================================
// Lifecycle
// ============================================================================

var initialized: bool = false;

pub fn init() !void {
    if (initialized) return;

    // Hints must be set before SDL_Init. We ask SDL to use its HIDAPI drivers
    // for the controllers that are most affected by Steam / Windows driver
    // interference. These are the default values in recent SDL2 releases, but
    // we set them explicitly so behavior is reproducible across distros.
    _ = c.SDL_SetHint(c.SDL_HINT_NO_SIGNAL_HANDLERS, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS4, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS4_RUMBLE, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS5, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_PS5_RUMBLE, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_SWITCH, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_HIDAPI_XBOX, "1");
    _ = c.SDL_SetHint(c.SDL_HINT_JOYSTICK_ALLOW_BACKGROUND_EVENTS, "1");

    if (c.SDL_InitSubSystem(c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_JOYSTICK) != 0) {
        const err = c.SDL_GetError();
        const err_slice = if (err) |p| std.mem.span(p) else "(null)";
        log.err("SDL_InitSubSystem failed: {s}", .{err_slice});
        return error.GamepadInitFailed;
    }

    initialized = true;
    log.info("Gamepad subsystem initialized (SDL2).", .{});
}

pub fn deinit() void {
    if (!initialized) return;
    c.SDL_QuitSubSystem(c.SDL_INIT_GAMECONTROLLER | c.SDL_INIT_JOYSTICK);
    initialized = false;
}

/// Pump the SDL event queue and refresh controller state. Call this once per
/// frame before reading any controller.
///
/// SDL requires a pumped event queue to observe hot-plug events and to update
/// internal controller state (though the latter is handled explicitly via
/// `SDL_GameControllerUpdate`). We auto-open controllers on `CONTROLLERDEVICE_
/// ADDED` and close them on `CONTROLLERDEVICE_REMOVED`; this keeps
/// `SDL_GameControllerFromInstanceID` consistent with reality.
pub fn update() void {
    if (!initialized) return;

    var event: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&event) != 0) {
        switch (event.type) {
            c.SDL_CONTROLLERDEVICEADDED => {
                // `event.cdevice.which` is a device index; we read it
                // directly from the payload at offset 8 in SDL2's event.
                const device_index = readEventInt(&event);
                _ = c.SDL_GameControllerOpen(device_index);
            },
            c.SDL_CONTROLLERDEVICEREMOVED => {
                // `event.cdevice.which` is an instance id here, not a device
                // index. Same memory offset.
                const instance_id: c.SDL_JoystickID = readEventInt(&event);
                if (c.SDL_GameControllerFromInstanceID(instance_id)) |ctrl| {
                    c.SDL_GameControllerClose(ctrl);
                }
            },
            else => {},
        }
    }
    c.SDL_GameControllerUpdate();
}

/// SDL's controller device event stores its primary i32 payload starting at
/// byte 8 of the event struct (after `type: u32` and `timestamp: u32`). We
/// read it raw to avoid having to fully model the SDL_Event union.
fn readEventInt(event: *const c.SDL_Event) i32 {
    const bytes: [*]const u8 = @ptrCast(event);
    var value: i32 = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[8..12]);
    return value;
}

// ============================================================================
// Enumeration
// ============================================================================

/// Iterator over currently connected gamepads. Opening is lazy: the first
/// time we see a previously-unknown device we open it so it can later be
/// referenced by instance id.
pub const Iterator = struct {
    index: c_int = 0,
    count: c_int,

    pub fn next(self: *Iterator) ?Joystick {
        while (self.index < self.count) : (self.index += 1) {
            const i = self.index;
            if (c.SDL_IsGameController(i) != 0) {
                const instance_id = c.SDL_JoystickGetDeviceInstanceID(i);
                if (instance_id < 0) continue;
                if (c.SDL_GameControllerFromInstanceID(instance_id) == null) {
                    _ = c.SDL_GameControllerOpen(i);
                }
                self.index += 1;
                return @enumFromInt(instance_id);
            }
        }
        return null;
    }
};

pub fn iterate() Iterator {
    if (!initialized) return .{ .count = 0 };
    return .{ .count = c.SDL_NumJoysticks() };
}
