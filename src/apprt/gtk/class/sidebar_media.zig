//! Now-playing card for the vertical tab sidebar. Talks to a media player
//! over MPRIS (the standard D-Bus interface Linux players expose, including
//! the Spotify desktop app): shows title, artist and album art, and offers
//! previous / play-pause / next and seeking. Hidden while the player isn't
//! running.
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
        handlers: [3]c_ulong = .{ 0, 0, 0 },
        enabled: bool = false,
        active: bool = false,
        playing: bool = false,
        has_track: bool = false,
        timer: ?c_uint = null,
        tick: u32 = 0,
        seek_cooldown: u8 = 0,
        position_us: i64 = 0,
        length_us: i64 = 0,
        trackid: ?[:0]u8 = null,
        art_url: ?[:0]u8 = null,

        // Template bindings
        art: *gtk.Picture,
        title_label: *gtk.Label,
        artist_label: *gtk.Label,
        progress: *gtk.Scale,
        position_label: *gtk.Label,
        length_label: *gtk.Label,
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

    /// Whether to tick the progress bar (window active and card shown).
    pub fn setActive(self: *Self, active: bool) void {
        self.private().active = active;
        self.updateTimer();
        if (active) self.queryPosition();
    }

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
        priv.handlers[1] = gio.DBusProxy.signals.g_signal.connect(proxy, *Self, playerSignal, self, .{});
        priv.handlers[2] = gobject.Object.signals.notify.connect(proxy, *Self, ownerChanged, self, .{ .detail = "g-name-owner" });
        self.refresh();
        self.queryPosition();
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
        self.queryPosition();
    }

    fn playerSignal(
        _: *gio.DBusProxy,
        _: ?[*:0]u8,
        signal_name: [*:0]u8,
        params: *glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        if (!std.mem.eql(u8, std.mem.span(signal_name), "Seeked")) return;
        const v = params.getChildValue(0);
        defer v.unref();
        self.private().position_us = variantInt(v) orelse return;
        self.updateProgress();
    }

    fn callPlayer(self: *Self, method: [:0]const u8, params: ?*glib.Variant) void {
        const proxy = self.private().proxy orelse return;
        proxy.call(method.ptr, params, .{}, -1, null, null, null);
    }

    fn queryPosition(self: *Self) void {
        const priv = self.private();
        const proxy = priv.proxy orelse return;
        const owner = proxy.getNameOwner() orelse return;
        defer glib.free(owner);
        const args = [_]*glib.Variant{
            glib.Variant.newString(mpris_player_iface),
            glib.Variant.newString("Position"),
        };
        proxy.getConnection().call(
            owner,
            mpris_path,
            "org.freedesktop.DBus.Properties",
            "Get",
            glib.Variant.newTuple(&args, args.len),
            null,
            .{},
            2000,
            null,
            positionReady,
            self.ref(),
        );
    }

    fn positionReady(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const conn: *gio.DBusConnection = @ptrCast(source orelse return);
        var err: ?*glib.Error = null;
        const reply = conn.callFinish(result, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        defer reply.unref();
        const boxed = reply.getChildValue(0);
        defer boxed.unref();
        const inner = boxed.getVariant();
        defer inner.unref();
        const priv = self.private();
        if (priv.seek_cooldown > 0) return;
        priv.position_us = variantInt(inner) orelse return;
        self.updateProgress();
    }

    //---------------------------------------------------------------
    // State

    fn variantInt(v: *glib.Variant) ?i64 {
        const t = std.mem.span(v.getTypeString());
        if (std.mem.eql(u8, t, "x")) return v.getInt64();
        if (std.mem.eql(u8, t, "t")) return @intCast(@min(v.getUint64(), std.math.maxInt(i64)));
        if (std.mem.eql(u8, t, "i")) return v.getInt32();
        if (std.mem.eql(u8, t, "u")) return v.getUint32();
        return null;
    }

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
            self.updateTimer();
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

        // Artists are a string array; show them comma separated.
        var artist_buf: [256]u8 = undefined;
        var artist: []const u8 = "";
        if (g_variant_lookup_value(meta, "xesam:artist", null)) |v| {
            defer v.unref();
            if (std.mem.eql(u8, std.mem.span(v.getTypeString()), "as")) {
                var w: std.Io.Writer = .fixed(&artist_buf);
                const n = v.nChildren();
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const item = v.getChildValue(i);
                    defer item.unref();
                    if (i > 0) w.writeAll(", ") catch break;
                    w.writeAll(std.mem.span(item.getString(null))) catch break;
                }
                artist = w.buffered();
            }
        }

        if (g_variant_lookup_value(meta, "mpris:length", null)) |v| {
            defer v.unref();
            priv.length_us = variantInt(v) orelse 0;
        } else priv.length_us = 0;

        var track_changed = false;
        if (lookupString(meta, "mpris:trackid")) |v| {
            defer v.unref();
            track_changed = setOwned(&priv.trackid, std.mem.span(v.getString(null)));
        } else track_changed = setOwned(&priv.trackid, null);

        var art_changed = false;
        if (lookupString(meta, "mpris:artUrl")) |v| {
            defer v.unref();
            art_changed = setOwned(&priv.art_url, std.mem.span(v.getString(null)));
        } else art_changed = setOwned(&priv.art_url, null);

        var tbuf: [512]u8 = undefined;
        const title_z = std.fmt.bufPrintZ(&tbuf, "{s}", .{title}) catch "";
        priv.title_label.setLabel(title_z.ptr);
        priv.title_label.as(gtk.Widget).setTooltipText(title_z.ptr);
        var abuf: [300]u8 = undefined;
        const artist_z = std.fmt.bufPrintZ(&abuf, "{s}", .{artist}) catch "";
        priv.artist_label.setLabel(artist_z.ptr);

        priv.has_track = title.len > 0;
        if (art_changed) self.loadArt();
        if (track_changed) {
            priv.position_us = 0;
            self.queryPosition();
        }
        self.updateProgress();
        self.updateVisibility();
        self.updateTimer();
    }

    fn updateVisibility(self: *Self) void {
        const priv = self.private();
        self.as(gtk.Widget).setVisible(@intFromBool(priv.enabled and priv.has_track));
    }

    fn formatTime(buf: []u8, us: i64) [:0]const u8 {
        const total: u64 = @intCast(@max(0, @divTrunc(us, std.time.us_per_s)));
        return std.fmt.bufPrintZ(buf, "{d}:{d:0>2}", .{ total / 60, total % 60 }) catch "";
    }

    fn updateProgress(self: *Self) void {
        const priv = self.private();
        const length_s: f64 = @as(f64, @floatFromInt(@max(priv.length_us, 1))) / std.time.us_per_s;
        const pos_s: f64 = @as(f64, @floatFromInt(std.math.clamp(priv.position_us, 0, @max(priv.length_us, 0)))) / std.time.us_per_s;
        priv.progress.as(gtk.Range).setRange(0, length_s);
        priv.progress.as(gtk.Range).setValue(pos_s);
        var b1: [16]u8 = undefined;
        var b2: [16]u8 = undefined;
        priv.position_label.setLabel(formatTime(&b1, priv.position_us).ptr);
        priv.length_label.setLabel(formatTime(&b2, priv.length_us).ptr);
    }

    fn updateTimer(self: *Self) void {
        const priv = self.private();
        const want = priv.active and priv.enabled and priv.has_track and priv.playing;
        if (want and priv.timer == null) {
            priv.timer = glib.timeoutAdd(1000, onTick, self);
        } else if (!want) {
            if (priv.timer) |t| _ = glib.Source.remove(t);
            priv.timer = null;
        }
    }

    fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.tick +%= 1;
        if (priv.seek_cooldown > 0) priv.seek_cooldown -= 1;
        priv.position_us += std.time.us_per_s;
        self.updateProgress();
        // Resync with the player every few seconds.
        if (priv.tick % 5 == 0) self.queryPosition();
        return 1;
    }

    //---------------------------------------------------------------
    // Album art

    fn loadArt(self: *Self) void {
        const priv = self.private();
        priv.art.setPaintable(null);
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
        self.private().art.setPaintable(texture.as(gdk.Paintable));
    }

    //---------------------------------------------------------------
    // Template callbacks

    fn previousClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.callPlayer("Previous", null);
    }

    fn playPauseClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.callPlayer("PlayPause", null);
    }

    fn nextClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.callPlayer("Next", null);
    }

    fn progressChangeValue(
        _: *gtk.Range,
        _: gtk.ScrollType,
        value: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const trackid = priv.trackid orelse return 0;
        if (glib.Variant.isObjectPath(trackid.ptr) == 0) return 0;
        const pos: i64 = @intFromFloat(@max(0, value) * std.time.us_per_s);
        priv.position_us = pos;
        priv.seek_cooldown = 2;
        const args = [_]*glib.Variant{
            glib.Variant.newObjectPath(trackid.ptr),
            glib.Variant.newInt64(pos),
        };
        self.callPlayer("SetPosition", glib.Variant.newTuple(&args, args.len));
        return 0;
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.timer) |t| _ = glib.Source.remove(t);
        priv.timer = null;
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
        if (priv.trackid) |v| alloc().free(v);
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
            class.bindTemplateChildPrivate("title_label", .{});
            class.bindTemplateChildPrivate("artist_label", .{});
            class.bindTemplateChildPrivate("progress", .{});
            class.bindTemplateChildPrivate("position_label", .{});
            class.bindTemplateChildPrivate("length_label", .{});
            class.bindTemplateChildPrivate("play_button", .{});

            class.bindTemplateCallback("previous_clicked", &previousClicked);
            class.bindTemplateCallback("play_pause_clicked", &playPauseClicked);
            class.bindTemplateCallback("next_clicked", &nextClicked);
            class.bindTemplateCallback("progress_change_value", &progressChangeValue);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
