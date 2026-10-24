//! Compact now-playing card for the vertical tab sidebar: album cover,
//! play/pause and next. Talks to a media player over MPRIS (the standard
//! D-Bus interface Linux players expose, including the Spotify desktop
//! app). Hidden while the player isn't running. Event driven: no timers.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;

const log = std.log.scoped(.gtk_ghostty_sidebar_media);

const mpris_path = "/org/mpris/MediaPlayer2";
const mpris_player_iface = "org.mpris.MediaPlayer2.Player";

// The generated binding marks the result non-null, but GLib returns NULL
// for missing keys.
extern fn g_variant_lookup_value(
    dictionary: *glib.Variant,
    key: [*:0]const u8,
    expected_type: ?*const glib.VariantType,
) ?*glib.Variant;

pub const SidebarMedia = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySidebarMedia",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        proxy: ?*gio.DBusProxy = null,
        handlers: [2]c_ulong = .{ 0, 0 },
        enabled: bool = false,
        playing: bool = false,
        has_track: bool = false,
        art_url: ?[:0]u8 = null,

        // Template bindings
        art: *gtk.Image,
        art_frame: *adw.Bin,
        play_button: *gtk.Button,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
    }

    fn alloc() std.mem.Allocator {
        return std.heap.c_allocator;
    }

    //---------------------------------------------------------------
    // Public API

    /// Connect to `org.mpris.MediaPlayer2.<player>` (for example
    /// "spotify"). Safe to call again; only the first call connects.
    pub fn connectPlayer(self: *Self, player: []const u8) void {
        const priv = self.private();
        if (priv.proxy != null) return;
        var buf: [128]u8 = undefined;
        const name = std.fmt.bufPrintZ(&buf, "org.mpris.MediaPlayer2.{s}", .{player}) catch return;
        gio.DBusProxy.newForBus(
            .session,
            .{ .do_not_auto_start = true },
            null,
            name.ptr,
            mpris_path,
            mpris_player_iface,
            null,
            proxyReady,
            self.ref(),
        );
    }

    /// Whether the card may show at all (setting + sidebar expanded).
    pub fn setEnabled(self: *Self, enabled: bool) void {
        self.private().enabled = enabled;
        self.updateVisibility();
    }

    /// Kept for the window's focus handling; the card has no timers.
    pub fn setActive(_: *Self, _: bool) void {}

    //---------------------------------------------------------------
    // D-Bus

    fn proxyReady(_: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        var err: ?*glib.Error = null;
        const proxy = gio.DBusProxy.newForBusFinish(result, &err) orelse {
            if (err) |e| {
                log.warn("could not create MPRIS proxy: {s}", .{e.f_message orelse "?"});
                e.free();
            }
            return;
        };
        const priv = self.private();
        priv.proxy = proxy;
        priv.handlers[0] = gio.DBusProxy.signals.g_properties_changed.connect(proxy, *Self, propertiesChanged, self, .{});
        priv.handlers[1] = gobject.Object.signals.notify.connect(proxy, *Self, ownerChanged, self, .{ .detail = "g-name-owner" });
        self.refresh();
    }

    fn propertiesChanged(
        _: *gio.DBusProxy,
        _: *glib.Variant,
        _: [*][*:0]u8,
        self: *Self,
    ) callconv(.c) void {
        self.refresh();
    }

    fn ownerChanged(_: *gio.DBusProxy, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.refresh();
    }

    fn callPlayer(self: *Self, method: [:0]const u8) void {
        const proxy = self.private().proxy orelse return;
        proxy.call(method.ptr, null, .{}, -1, null, null, null);
    }

    //---------------------------------------------------------------
    // State

    fn lookupString(meta: *glib.Variant, key: [:0]const u8) ?*glib.Variant {
        const v = g_variant_lookup_value(meta, key.ptr, null) orelse return null;
        const t = std.mem.span(v.getTypeString());
        if (std.mem.eql(u8, t, "s") or std.mem.eql(u8, t, "o")) return v;
        v.unref();
        return null;
    }

    fn setOwned(slot: *?[:0]u8, value: ?[]const u8) bool {
        const changed = changed: {
            if (slot.* == null and value == null) break :changed false;
            if (slot.* == null or value == null) break :changed true;
            break :changed !std.mem.eql(u8, slot.*.?, value.?);
        };
        if (!changed) return false;
        if (slot.*) |old| alloc().free(old);
        slot.* = if (value) |v| alloc().dupeZ(u8, v) catch null else null;
        return true;
    }

    fn refresh(self: *Self) void {
        const priv = self.private();
        const proxy = priv.proxy orelse return;

        const running = running: {
            const owner = proxy.getNameOwner() orelse break :running false;
            glib.free(owner);
            break :running true;
        };
        if (!running) {
            priv.has_track = false;
            priv.playing = false;
            self.updateVisibility();
            return;
        }

        if (proxy.getCachedProperty("PlaybackStatus")) |status| {
            defer status.unref();
            priv.playing = std.mem.eql(u8, std.mem.span(status.getString(null)), "Playing");
        }
        priv.play_button.setIconName(
            if (priv.playing) "media-playback-pause-symbolic" else "media-playback-start-symbolic",
        );

        const meta = proxy.getCachedProperty("Metadata") orelse {
            priv.has_track = false;
            self.updateVisibility();
            return;
        };
        defer meta.unref();

        var title: []const u8 = "";
        const title_v = lookupString(meta, "xesam:title");
        defer if (title_v) |v| v.unref();
        if (title_v) |v| title = std.mem.span(v.getString(null));

        // Tooltip: "Title — Artist, Artist".
        var tip_buf: [512]u8 = undefined;
        var w: std.Io.Writer = .fixed(&tip_buf);
        w.writeAll(title) catch {};
        if (g_variant_lookup_value(meta, "xesam:artist", null)) |v| {
            defer v.unref();
            if (std.mem.eql(u8, std.mem.span(v.getTypeString()), "as")) {
                var i: usize = 0;
                while (i < v.nChildren()) : (i += 1) {
                    const item = v.getChildValue(i);
                    defer item.unref();
                    const name = std.mem.span(item.getString(null));
                    if (name.len == 0) continue;
                    w.writeAll(if (i == 0) " — " else ", ") catch break;
                    w.writeAll(name) catch break;
                }
            }
        }
        var tip_z_buf: [520]u8 = undefined;
        const tip_z = std.fmt.bufPrintZ(&tip_z_buf, "{s}", .{w.buffered()}) catch "";
        priv.art_frame.as(gtk.Widget).setTooltipText(tip_z.ptr);

        var art_changed = false;
        if (lookupString(meta, "mpris:artUrl")) |v| {
            defer v.unref();
            art_changed = setOwned(&priv.art_url, std.mem.span(v.getString(null)));
        } else art_changed = setOwned(&priv.art_url, null);

        priv.has_track = title.len > 0;
        if (art_changed) self.loadArt();
        self.updateVisibility();
    }

    fn updateVisibility(self: *Self) void {
        const priv = self.private();
        self.as(gtk.Widget).setVisible(@intFromBool(priv.enabled and priv.has_track));
    }

    //---------------------------------------------------------------
    // Album art

    fn loadArt(self: *Self) void {
        const priv = self.private();
        priv.art.setFromIconName("audio-x-generic-symbolic");
        const url = priv.art_url orelse return;
        if (!std.mem.startsWith(u8, url, "https://") and
            !std.mem.startsWith(u8, url, "http://") and
            !std.mem.startsWith(u8, url, "file://")) return;
        const file = gio.File.newForUri(url.ptr);
        defer file.unref();
        file.loadContentsAsync(null, artLoaded, self.ref());
    }

    fn artLoaded(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const file: *gio.File = @ptrCast(source orelse return);
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        var err: ?*glib.Error = null;
        if (file.loadContentsFinish(result, &contents, &len, null, &err) == 0) {
            if (err) |e| {
                log.info("could not load album art: {s}", .{e.f_message orelse "?"});
                e.free();
            }
            return;
        }
        defer glib.free(contents);

        // Ignore art for a track that's no longer current.
        const uri = file.getUri();
        defer glib.free(uri);
        const current = self.private().art_url orelse return;
        if (!std.mem.eql(u8, std.mem.span(uri), current)) return;

        const bytes = glib.Bytes.new(contents, len);
        defer bytes.unref();
        var terr: ?*glib.Error = null;
        const texture = gdk.Texture.newFromBytes(bytes, &terr) orelse {
            if (terr) |e| e.free();
            return;
        };
        defer texture.unref();
        self.private().art.setFromPaintable(texture.as(gdk.Paintable));
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn playPauseClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.callPlayer("PlayPause");
    }

    fn nextClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.callPlayer("Next");
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.proxy) |proxy| {
            for (priv.handlers) |h| {
                if (h != 0) gobject.signalHandlerDisconnect(proxy.as(gobject.Object), h);
            }
            proxy.unref();
            priv.proxy = null;
        }

        gtk.Widget.disposeTemplate(self.as(gtk.Widget), getGObjectType());
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.art_url) |v| alloc().free(v);
        gobject.Object.virtual_methods.finalize.call(Class.parent, self.as(Parent));
    }

    const C = Common(Self, Private);
    pub const as = C.as;
    pub const ref = C.ref;
    pub const unref = C.unref;
    const private = C.private;

    pub const Class = extern struct {
        parent_class: Parent.Class,
        var parent: *Parent.Class = undefined;
        pub const Instance = Self;

        fn init(class: *Class) callconv(.c) void {
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "sidebar-media",
                }),
            );

            class.bindTemplateChildPrivate("art", .{});
            class.bindTemplateChildPrivate("art_frame", .{});
            class.bindTemplateChildPrivate("play_button", .{});

            class.bindTemplateCallback("play_pause_clicked", &playPauseClicked);
            class.bindTemplateCallback("next_clicked", &nextClicked);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
