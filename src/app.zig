const App = @This();
const std = @import("std");
const builtin = @import("builtin");
const assert = @import("quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const apprt = @import("apprt.zig");
const Surface = @import("Surface.zig");
const input = @import("input.zig");
const configpkg = @import("config.zig");
const Config = configpkg.Config;
const BlockingQueue = @import("datastruct/main.zig").BlockingQueue;
const renderer = @import("renderer.zig");
const font = @import("font/main.zig");
const global = @import("global.zig");
const log = std.log.scoped(.app);
const SurfaceList = std.ArrayListUnmanaged(*apprt.Surface);
alloc: Allocator,
surfaces: SurfaceList,
focused: bool = true,
focused_surface: ?*Surface = null,
mailbox: Mailbox.Queue,
font_grid_set: font.SharedGridSet,
last_notification_time: ?std.Io.Timestamp = null,
last_notification_digest: u64 = 0,
config_conditional_state: configpkg.ConditionalState,
first: bool = true,
pub const CreateError = Allocator.Error || font.SharedGridSet.InitError;
pub fn create(alloc: Allocator) CreateError!*App {
    var app = try alloc.create(App);
    errdefer alloc.destroy(app);
    try app.init(alloc);
    if (comptime @hasDecl(font.Discover, "warmup")) {
        if (std.Thread.spawn(
            .{},
            font.Discover.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("font warmup thread spawn failed err={}", .{err});
        }
    }
    if (comptime @hasDecl(renderer.Renderer.API, "warmup")) {
        if (std.Thread.spawn(
            .{},
            renderer.Renderer.API.warmup,
            .{},
        )) |thr| thr.detach() else |err| {
            log.warn("renderer warmup thread spawn failed err={}", .{err});
        }
    }
    return app;
}
pub fn init(
    self: *App,
    alloc: Allocator,
) CreateError!void {
    var font_grid_set = try font.SharedGridSet.init(alloc);
    errdefer font_grid_set.deinit();
    self.* = .{
        .alloc = alloc,
        .surfaces = .empty,
        .mailbox = .{},
        .font_grid_set = font_grid_set,
        .config_conditional_state = .{},
    };
}
pub fn deinit(self: *App) void {
    for (self.surfaces.items) |surface| surface.deinit();
    self.surfaces.deinit(self.alloc);
    assert(self.font_grid_set.count() == 0);
    self.font_grid_set.deinit();
}
pub fn destroy(self: *App) void {
    self.deinit();
    self.alloc.destroy(self);
}
pub fn tick(self: *App, rt_app: *apprt.App) !void {
    try self.drainMailbox(rt_app);
}
pub fn updateConfig(self: *App, rt_app: *apprt.App, config: *const Config) !void {
    for (self.surfaces.items) |surface| {
        try surface.core().handleMessage(.{ .change_config = config });
    }
    var applied_: ?configpkg.Config = config.changeConditionalState(
        self.config_conditional_state,
    ) catch |err| err: {
        log.warn("failed to apply conditional state to config err={}", .{err});
        break :err null;
    };
    defer if (applied_) |*c| c.deinit();
    const applied: *const configpkg.Config = if (applied_) |*c| c else config;
    _ = try rt_app.performAction(
        .app,
        .config_change,
        .{ .config = applied },
    );
}
pub fn addSurface(
    self: *App,
    rt_surface: *apprt.Surface,
) Allocator.Error!void {
    try self.surfaces.append(self.alloc, rt_surface);
    _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .stop,
    ) catch |err| {
        log.warn("error stopping quit timer err={}", .{err});
    };
}
pub fn deleteSurface(self: *App, rt_surface: *apprt.Surface) void {
    if (self.focused_surface) |focused| {
        if (focused == rt_surface.core()) {
            self.focused_surface = null;
        }
    }
    var i: usize = 0;
    while (i < self.surfaces.items.len) {
        if (self.surfaces.items[i] == rt_surface) {
            _ = self.surfaces.swapRemove(i);
            continue;
        }
        i += 1;
    }
    if (self.surfaces.items.len == 0) _ = rt_surface.rtApp().performAction(
        .app,
        .quit_timer,
        .start,
    ) catch |err| {
        log.warn("error starting quit timer err={}", .{err});
    };
}
pub fn focusedSurface(self: *const App) ?*Surface {
    const surface = self.focused_surface orelse return null;
    if (!self.hasSurface(surface)) return null;
    return surface;
}
pub fn needsConfirmQuit(self: *const App) bool {
    for (self.surfaces.items) |v| {
        if (v.core().needsConfirmQuit()) return true;
    }
    return false;
}
fn drainMailbox(self: *App, rt_app: *apprt.App) !void {
    while (self.mailbox.pop(global.io())) |message| {
        if (comptime std.log.logEnabled(.debug, .app)) {
            switch (message) {
                else => log.debug("mailbox message={t}", .{message}),
            }
        }
        switch (message) {
            .open_config => |v| try self.performAction(
                rt_app,
                .{
                    .open_config = switch (v) {
                        .os_open => .os_open,
                        .new_window => .new_window,
                    },
                },
            ),
            .new_window => |msg| try self.newWindow(rt_app, msg),
            .close => |surface| self.closeSurface(surface),
            .surface_message => |msg| try self.surfaceMessage(msg.surface, msg.message),
            .quit => {
                log.info("quit message received, short circuiting mailbox drain", .{});
                try self.performAction(rt_app, .quit);
                return;
            },
        }
    }
}
pub fn closeSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    surface.close();
}
pub fn focusSurface(self: *App, surface: *Surface) void {
    if (!self.hasSurface(surface)) return;
    self.focused_surface = surface;
}
pub fn newWindow(self: *App, rt_app: *apprt.App, msg: Message.NewWindow) !void {
    const target: apprt.Target = target: {
        const parent = msg.parent orelse break :target .app;
        if (self.hasSurface(parent)) break :target .{ .surface = parent };
        break :target .app;
    };
    _ = try rt_app.performAction(
        target,
        .new_window,
        {},
    );
}
pub fn focusEvent(self: *App, focused: bool) void {
    if (self.focused == focused) return;
    log.debug("focus event focused={}", .{focused});
    self.focused = focused;
}
pub fn keyEvent(
    self: *App,
    rt_app: *apprt.App,
    event: input.KeyEvent,
) bool {
    switch (event.action) {
        .release => return false,
        .press, .repeat => {},
    }
    const entry = rt_app.config.keybind.set.getEvent(event) orelse return false;
    const leaf: input.Binding.Set.GenericLeaf = switch (entry.value_ptr.*) {
        .leader => return false,
        inline .leaf, .leaf_chained => |leaf| leaf.generic(),
    };
    const actions: []const input.Binding.Action = leaf.actionsSlice();
    assert(actions.len > 0);
    if (!self.focused and !leaf.flags.global) return false;
    if (leaf.flags.global) {
        self.performAllChainedAction(rt_app, actions);
        return true;
    }
    assert(self.focused);
    assert(!leaf.flags.global);
    for (actions) |action| if (action.scoped(.app) == null) return false;
    for (actions) |action| {
        self.performAction(
            rt_app,
            action.scoped(.app).?,
        ) catch |err| {
            log.warn("error performing app keybind action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
    return true;
}
pub fn colorSchemeEvent(
    self: *App,
    rt_app: *apprt.App,
    scheme: apprt.ColorScheme,
) !void {
    const new_scheme: configpkg.ConditionalState.Theme = switch (scheme) {
        .light => .light,
        .dark => .dark,
    };
    if (self.config_conditional_state.theme == new_scheme) return;
    self.config_conditional_state.theme = new_scheme;
    _ = try rt_app.performAction(
        .app,
        .reload_config,
        .{ .soft = true },
    );
}
pub fn performAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action.Scoped(.app),
) !void {
    switch (action) {
        .unbind => unreachable,
        .ignore => {},
        .quit => _ = try rt_app.performAction(.app, .quit, {}),
        .new_window => _ = try self.newWindow(rt_app, .{ .parent = null }),
        .open_config => |v| _ = try rt_app.performAction(
            .app,
            .open_config,
            switch (v) {
                .os_open => .os_open,
                .new_window => .new_window,
            },
        ),
        .reload_config => _ = try rt_app.performAction(.app, .reload_config, .{}),
        .close_all_windows => _ = try rt_app.performAction(.app, .close_all_windows, {}),
        .toggle_quick_terminal => _ = try rt_app.performAction(.app, .toggle_quick_terminal, {}),
        .toggle_visibility => _ = try rt_app.performAction(.app, .toggle_visibility, {}),
        .check_for_updates => _ = try rt_app.performAction(.app, .check_for_updates, {}),
        .show_gtk_inspector => _ = try rt_app.performAction(.app, .show_gtk_inspector, {}),
        .undo => _ = try rt_app.performAction(.app, .undo, {}),
        .redo => _ = try rt_app.performAction(.app, .redo, {}),
    }
}
pub fn performAllChainedAction(
    self: *App,
    rt_app: *apprt.App,
    actions: []const input.Binding.Action,
) void {
    for (actions) |action| {
        self.performAllAction(rt_app, action) catch |err| {
            log.warn("error performing chained action action={s} err={}", .{
                @tagName(action),
                err,
            });
        };
    }
}
pub fn performAllAction(
    self: *App,
    rt_app: *apprt.App,
    action: input.Binding.Action,
) !void {
    switch (action.scope()) {
        .app => try self.performAction(
            rt_app,
            action.scoped(.app).?,
        ),
        .surface => for (self.surfaces.items) |surface| {
            _ = surface.core().performBindingAction(action) catch |err| {
                log.warn("error performing binding action on surface id={x} err={}", .{
                    surface.core().id,
                    err,
                });
            };
        },
    }
}
fn surfaceMessage(self: *App, surface: *Surface, msg: apprt.surface.Message) !void {
    if (self.hasSurface(surface)) {
        try surface.handleMessage(msg);
    }
}
fn hasSurface(self: *const App, surface: *const Surface) bool {
    for (self.surfaces.items) |v| {
        if (v.core() == surface) return true;
    }
    return false;
}
pub fn findSurfaceByID(self: *const App, id: u64) ?*Surface {
    for (self.surfaces.items) |v| {
        const surface: *Surface = v.core();
        if (surface.id == id) return surface;
    }
    return null;
}
pub const Message = union(enum) {
    open_config: OpenConfig,
    new_window: NewWindow,
    close: *Surface,
    quit: void,
    surface_message: struct {
        surface: *Surface,
        message: apprt.surface.Message,
    },
    const NewWindow = struct {
        parent: ?*Surface = null,
    };
    pub const OpenConfig = enum {
        os_open,
        new_window,
    };
};
pub const Mailbox = struct {
    pub const Queue = BlockingQueue(Message, 64);
    rt_app: *apprt.App,
    mailbox: *Queue,
    pub fn push(self: Mailbox, msg: Message, timeout: Queue.Timeout) Queue.Size {
        const result = self.mailbox.push(global.io(), msg, timeout);
        self.rt_app.wakeup();
        return result;
    }
};
pub const Wasm = if (!builtin.target.isWasm()) struct {} else struct {
    const wasm = @import("os/wasm.zig");
    const alloc = wasm.alloc;
};
