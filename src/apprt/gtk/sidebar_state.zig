//! Remembered vertical tab sidebar settings, saved across restarts in
//! `$XDG_STATE_HOME/ghostty-sidebar/state` (usually
//! `~/.local/state/ghostty-sidebar/state`).
//!
//! The config file holds defaults; this file holds the last choice made
//! with the mouse or menus and wins over the config. Delete it to go back
//! to the config values.
//!
//! Format: one `key = value` per line. Unknown keys and bad values are
//! ignored, so an old or hand-edited file never breaks startup.
const std = @import("std");
const Allocator = std.mem.Allocator;

const configpkg = @import("../../config.zig");
const sidebar_pets = @import("class/sidebar_pets.zig");
const internal_os = @import("../../os/main.zig");

const log = std.log.scoped(.gtk_ghostty_sidebar_state);

pub const SidebarMode = enum { expanded, compact, hidden };
pub const Theme = configpkg.Config.GtkTabsSidebarTheme;
pub const Color = configpkg.Config.Color;

pub const State = struct {
    width: ?c_int = null,
    mode: ?SidebarMode = null,
    theme: ?Theme = null,
    accent: ?Color = null,
    glass: ?bool = null,
    show_paths: ?bool = null,
    /// Bit mask over pet_sprites.pets.
    pets: ?u32 = null,
    media: ?bool = null,
    explorer_open: ?bool = null,
    explorer_width: ?c_int = null,
};

const max_file_size = 4096;

fn path(alloc: Allocator) ![]u8 {
    const dir = try internal_os.xdg.state(alloc, .{ .subdir = "ghostty-sidebar" });
    defer alloc.free(dir);
    return try std.fs.path.join(alloc, &.{ dir, "state" });
}

/// Load the saved state. Missing or unreadable files give an empty state.
pub fn load(alloc: Allocator) State {
    var result: State = .{};
    const p = path(alloc) catch return result;
    defer alloc.free(p);

    const data = std.fs.cwd().readFileAlloc(alloc, p, max_file_size) catch |err| {
        if (err != error.FileNotFound) log.warn("could not read {s}: {}", .{ p, err });
        return result;
    };
    defer alloc.free(data);

    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "width")) {
            result.width = std.fmt.parseInt(c_int, value, 10) catch null;
        } else if (std.mem.eql(u8, key, "mode")) {
            result.mode = std.meta.stringToEnum(SidebarMode, value);
        } else if (std.mem.eql(u8, key, "theme")) {
            result.theme = std.meta.stringToEnum(Theme, value);
        } else if (std.mem.eql(u8, key, "accent")) {
            result.accent = parseHex(value);
        } else if (std.mem.eql(u8, key, "glass")) {
            if (std.mem.eql(u8, value, "true")) result.glass = true;
            if (std.mem.eql(u8, value, "false")) result.glass = false;
        } else if (std.mem.eql(u8, key, "show-paths")) {
            if (std.mem.eql(u8, value, "true")) result.show_paths = true;
            if (std.mem.eql(u8, value, "false")) result.show_paths = false;
        } else if (std.mem.eql(u8, key, "pets")) {
            result.pets = sidebar_pets.maskFromList(value);
        } else if (std.mem.eql(u8, key, "media")) {
            if (std.mem.eql(u8, value, "true")) result.media = true;
            if (std.mem.eql(u8, value, "false")) result.media = false;
        } else if (std.mem.eql(u8, key, "explorer-open")) {
            if (std.mem.eql(u8, value, "true")) result.explorer_open = true;
            if (std.mem.eql(u8, value, "false")) result.explorer_open = false;
        } else if (std.mem.eql(u8, key, "explorer-width")) {
            result.explorer_width = std.fmt.parseInt(c_int, value, 10) catch null;
        }
    }

    return result;
}

/// Save the state. Writes a temporary file and renames it so a crash
/// never leaves a half-written file. Errors are logged and ignored.
pub fn save(alloc: Allocator, state: State) void {
    saveImpl(alloc, state) catch |err| {
        log.warn("could not save sidebar state: {}", .{err});
    };
}

fn saveImpl(alloc: Allocator, state: State) !void {
    const p = try path(alloc);
    defer alloc.free(p);
    if (std.fs.path.dirname(p)) |dir| try std.fs.cwd().makePath(dir);

    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("# Remembered ghostty-sidebar layout. Delete to reset to config values.\n");
    if (state.width) |v| try w.print("width = {d}\n", .{v});
    if (state.mode) |v| try w.print("mode = {s}\n", .{@tagName(v)});
    if (state.theme) |v| try w.print("theme = {s}\n", .{@tagName(v)});
    if (state.accent) |c| try w.print("accent = #{x:0>2}{x:0>2}{x:0>2}\n", .{ c.r, c.g, c.b });
    if (state.glass) |v| try w.print("glass = {}\n", .{v});
    if (state.show_paths) |v| try w.print("show-paths = {}\n", .{v});
    if (state.pets) |mask| {
        var pbuf: [256]u8 = undefined;
        try w.print("pets = {s}\n", .{sidebar_pets.listFromMask(mask, &pbuf)});
    }
    if (state.media) |v| try w.print("media = {}\n", .{v});
    if (state.explorer_open) |v| try w.print("explorer-open = {}\n", .{v});
    if (state.explorer_width) |v| try w.print("explorer-width = {d}\n", .{v});

    const tmp = try std.fmt.allocPrint(alloc, "{s}.tmp", .{p});
    defer alloc.free(tmp);
    try std.fs.cwd().writeFile(.{ .sub_path = tmp, .data = w.buffered() });
    try std.fs.cwd().rename(tmp, p);
}

/// Parse `#rrggbb` or `rrggbb`.
pub fn parseHex(value: []const u8) ?Color {
    const hex = if (value.len > 0 and value[0] == '#') value[1..] else value;
    if (hex.len != 6) return null;
    return .{
        .r = std.fmt.parseInt(u8, hex[0..2], 16) catch return null,
        .g = std.fmt.parseInt(u8, hex[2..4], 16) catch return null,
        .b = std.fmt.parseInt(u8, hex[4..6], 16) catch return null,
    };
}
