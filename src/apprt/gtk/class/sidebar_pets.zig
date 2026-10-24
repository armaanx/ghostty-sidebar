//! Animated pixel-art pets that live in a strip at the bottom of the
//! vertical tab sidebar. They walk, idle, nap, jump when clicked, and react
//! to the terminal: alarmed while a tab needs attention, cheering when a
//! command finishes. The animation only runs while the window is active
//! and the sidebar is expanded, at 10 frames per second.
const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const sprites = @import("../pet_sprites.zig");

const log = std.log.scoped(.gtk_ghostty_sidebar_pets);

/// Each source pixel is drawn as a scale x scale block, so the art stays
/// crisp without relying on texture filtering.
const scale = 3;
const pet_px = sprites.size * scale;
const strip_height = pet_px + 26;
const tick_ms = 100;

/// Parse a comma separated list of pet ids into a bit mask over
/// `sprites.pets`. Unknown names are ignored.
pub fn maskFromList(list: []const u8) u32 {
    var mask: u32 = 0;
    var it = std.mem.tokenizeAny(u8, list, ", \t");
    while (it.next()) |name| {
        for (sprites.pets, 0..) |p, i| {
            if (std.mem.eql(u8, p.id, name)) mask |= @as(u32, 1) << @intCast(i);
        }
    }
    return mask;
}

/// Write the pet ids in `mask` as a comma separated list into `buf`.
pub fn listFromMask(mask: u32, buf: []u8) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    var first = true;
    for (sprites.pets, 0..) |p, i| {
        if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
        if (!first) w.writeAll(",") catch break;
        w.writeAll(p.id) catch break;
        first = false;
    }
    return w.buffered();
}

const Mood = enum { walk, idle, sleep, jump, cheer, alarm };

const PetState = struct {
    owner: *SidebarPets,
    def: *const sprites.Pet,
    picture: *gtk.Picture,
    /// [frame][flipped]
    textures: [3][2]*gdk.Texture,
    bubble: ?*gtk.Label = null,
    bubble_ttl: u16 = 0,
    x: f32 = 0,
    dir: f32 = 1,
    mood: Mood = .walk,
    mood_ticks: u16 = 0,
    tick: u32 = 0,
    jumps_left: u8 = 0,
    jump_t: u8 = 0,
    shown: ?struct { frame: u8, flip: u1 } = null,

    fn deinit(self: *PetState) void {
        for (self.textures) |pair| for (pair) |t| t.unref();
    }
};

pub const SidebarPets = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttySidebarPets",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    const Private = struct {
        fixed: *gtk.Fixed = undefined,
        pets: std.ArrayListUnmanaged(*PetState) = .empty,
        timer: ?c_uint = null,
        running: bool = false,
        alarm: bool = false,
        prng: std.Random.DefaultPrng = .init(0),

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        priv.prng = .init(@bitCast(std.time.milliTimestamp()));

        const fixed = gtk.Fixed.new();
        fixed.as(gtk.Widget).setSizeRequest(-1, strip_height);
        fixed.as(gtk.Widget).setOverflow(.hidden);
        priv.fixed = fixed;
        self.as(adw.Bin).setChild(fixed.as(gtk.Widget));
        self.as(gtk.Widget).addCssClass("sidebar-pets");
    }

    fn alloc() std.mem.Allocator {
        return std.heap.c_allocator;
    }

    fn rand(self: *Self) std.Random {
        return self.private().prng.random();
    }

    //---------------------------------------------------------------
    // Public API

    /// Show the pets in `mask` (bits over `sprites.pets`).
    pub fn setPets(self: *Self, mask: u32) void {
        const priv = self.private();
        self.clearPets();

        const width: f32 = @floatFromInt(@max(self.as(gtk.Widget).getWidth(), 200));
        for (&sprites.pets, 0..) |*def, i| {
            if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
            const state = alloc().create(PetState) catch continue;
            state.* = .{
                .owner = self,
                .def = def,
                .picture = undefined,
                .textures = undefined,
                .x = self.rand().float(f32) * (width - pet_px),
                .dir = if (self.rand().boolean()) 1 else -1,
                .mood = if (priv.running) .walk else .sleep,
            };
            for (0..3) |f| {
                state.textures[f][0] = makeTexture(&def.frames[f], false);
                state.textures[f][1] = makeTexture(&def.frames[f], true);
            }

            const picture = gtk.Picture.newForPaintable(state.textures[0][0].as(gdk.Paintable));
            const pw = picture.as(gtk.Widget);
            pw.setSizeRequest(pet_px, pet_px);
            pw.setTooltipText(def.name.ptr);
            pw.addCssClass("sidebar-pet");
            pw.setCursorFromName("pointer");
            state.picture = picture;

            const click = gtk.GestureClick.new();
            _ = gtk.GestureClick.signals.pressed.connect(click, *PetState, petClicked, state, .{});
            pw.addController(click.as(gtk.EventController));

            priv.fixed.put(pw, state.x, groundY(state));
            priv.pets.append(alloc(), state) catch {
                priv.fixed.remove(pw);
                state.deinit();
                alloc().destroy(state);
                continue;
            };
        }

        self.as(gtk.Widget).setVisible(@intFromBool(priv.pets.items.len > 0));
        self.render();
    }

    /// Run or pause the animation. Paused pets fall asleep.
    pub fn setRunning(self: *Self, running: bool) void {
        const priv = self.private();
        if (priv.running == running) return;
        priv.running = running;
        if (running) {
            if (priv.timer == null) priv.timer = glib.timeoutAdd(tick_ms, onTick, self);
            for (priv.pets.items) |p| {
                if (p.mood == .sleep) p.mood = .walk;
            }
        } else {
            if (priv.timer) |t| _ = glib.Source.remove(t);
            priv.timer = null;
            for (priv.pets.items) |p| {
                p.mood = .sleep;
                p.jump_t = 0;
            }
            self.render();
        }
    }

    /// Something needs attention: pets stop and shout.
    pub fn setAlarm(self: *Self, alarm: bool) void {
        const priv = self.private();
        if (priv.alarm == alarm) return;
        priv.alarm = alarm;
        for (priv.pets.items) |p| {
            if (alarm) {
                p.mood = .alarm;
                self.showBubble(p, "!", 12);
            } else if (p.mood == .alarm) {
                p.mood = .walk;
            }
        }
    }

    /// A command finished: everyone jumps (or looks worried if it failed).
    pub fn celebrate(self: *Self, success: bool) void {
        const priv = self.private();
        if (!priv.running) return;
        const notes = [_][:0]const u8{ "♪", "♫", "★", "✓" };
        for (priv.pets.items) |p| {
            if (p.mood == .alarm) continue;
            if (!success) {
                p.mood = .idle;
                p.mood_ticks = 20;
                self.showBubble(p, "✗", 14);
                continue;
            }
            p.mood = .cheer;
            p.jumps_left = 2;
            p.jump_t = 0;
            self.showBubble(p, notes[self.rand().uintLessThan(usize, notes.len)], 14);
        }
    }

    //---------------------------------------------------------------
    // Animation

    fn groundY(p: *const PetState) f64 {
        const base: f64 = @floatFromInt(strip_height - pet_px - 2);
        return if (p.def.floats) base - 8 else base;
    }

    fn onTick(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.step();
        self.render();
        return 1;
    }

    fn step(self: *Self) void {
        const priv = self.private();
        const width: f32 = @floatFromInt(self.as(gtk.Widget).getWidth());
        if (width < pet_px) return;
        const max_x = width - pet_px;
        const r = self.rand();

        for (priv.pets.items) |p| {
            p.tick +%= 1;
            if (p.bubble_ttl > 0) {
                p.bubble_ttl -= 1;
                if (p.bubble_ttl == 0) self.removeBubble(p);
            }

            switch (p.mood) {
                .walk => {
                    p.x += p.dir * p.def.speed;
                    if (p.x <= 0) {
                        p.x = 0;
                        p.dir = 1;
                    } else if (p.x >= max_x) {
                        p.x = max_x;
                        p.dir = -1;
                    }
                    if (r.uintLessThan(u16, 100) < 2) {
                        p.mood = .idle;
                        p.mood_ticks = 15 + r.uintLessThan(u16, 30);
                    } else if (r.uintLessThan(u16, 1000) < 4) {
                        p.dir = -p.dir;
                    }
                },
                .idle => {
                    if (p.mood_ticks > 0) p.mood_ticks -= 1;
                    if (p.mood_ticks == 0) {
                        if (r.uintLessThan(u16, 100) < 12) {
                            p.mood = .sleep;
                            p.mood_ticks = 60 + r.uintLessThan(u16, 120);
                        } else {
                            p.mood = .walk;
                            if (r.boolean()) p.dir = -p.dir;
                        }
                    }
                },
                .sleep => {
                    if (p.tick % 25 == 0) self.showBubble(p, "z", 10);
                    if (p.mood_ticks > 0) p.mood_ticks -= 1;
                    if (p.mood_ticks == 0) p.mood = .walk;
                },
                .jump, .cheer => {
                    p.jump_t += 1;
                    if (p.jump_t >= 8) {
                        p.jump_t = 0;
                        if (p.jumps_left > 0) p.jumps_left -= 1;
                        if (p.jumps_left == 0) p.mood = .walk;
                    }
                },
                .alarm => {
                    if (p.tick % 15 == 0) self.showBubble(p, "!", 8);
                },
            }

            // Keep inside the strip if the sidebar was resized.
            p.x = std.math.clamp(p.x, 0, max_x);
        }
    }

    fn render(self: *Self) void {
        const priv = self.private();
        for (priv.pets.items) |p| {
            const frame: u8 = switch (p.mood) {
                .sleep => 2,
                .idle => 0,
                .alarm => @intCast((p.tick / 2) % 2),
                .walk => @intCast((p.tick / 3) % 2),
                .jump, .cheer => 1,
            };
            const flip: u1 = if (p.dir < 0) 1 else 0;
            if (p.shown == null or p.shown.?.frame != frame or p.shown.?.flip != flip) {
                p.picture.setPaintable(p.textures[frame][flip].as(gdk.Paintable));
                p.shown = .{ .frame = frame, .flip = flip };
            }

            var y = groundY(p);
            if (p.def.floats and p.mood != .sleep) {
                const t: f64 = @floatFromInt(p.tick);
                y += @sin(t * 0.35) * 3;
            }
            if (p.mood == .jump or p.mood == .cheer) {
                // Parabola over 8 ticks, peak 18px.
                const t: f64 = @floatFromInt(p.jump_t);
                y -= 18 * (1 - std.math.pow(f64, (t - 4) / 4, 2));
            }

            priv.fixed.move(p.picture.as(gtk.Widget), p.x, y);
            if (p.bubble) |b| priv.fixed.move(b.as(gtk.Widget), p.x + pet_px - 14, @max(0, y - 14));
        }
    }

    fn showBubble(self: *Self, p: *PetState, text: [:0]const u8, ttl: u16) void {
        const priv = self.private();
        self.removeBubble(p);
        const label = gtk.Label.new(text.ptr);
        label.as(gtk.Widget).addCssClass("pet-bubble");
        label.as(gtk.Widget).setCanTarget(0);
        priv.fixed.put(label.as(gtk.Widget), p.x + pet_px - 14, @max(0, groundY(p) - 14));
        p.bubble = label;
        p.bubble_ttl = ttl;
    }

    fn removeBubble(self: *Self, p: *PetState) void {
        if (p.bubble) |b| self.private().fixed.remove(b.as(gtk.Widget));
        p.bubble = null;
        p.bubble_ttl = 0;
    }

    fn petClicked(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        p: *PetState,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        const self = p.owner;
        const hearts = [_][:0]const u8{ "♥", "♥", "✦", "!?" };
        p.mood = .jump;
        p.jumps_left = 1;
        p.jump_t = 0;
        self.showBubble(p, hearts[self.rand().uintLessThan(usize, hearts.len)], 12);
        if (!self.private().running) self.render();
    }

    fn clearPets(self: *Self) void {
        const priv = self.private();
        for (priv.pets.items) |p| {
            self.removeBubble(p);
            priv.fixed.remove(p.picture.as(gtk.Widget));
            p.deinit();
            alloc().destroy(p);
        }
        priv.pets.clearRetainingCapacity();
    }

    /// Build a scaled RGBA texture from a 16x16 palette grid.
    fn makeTexture(frame: *const [sprites.size][]const u8, flip: bool) *gdk.Texture {
        var buf: [pet_px * pet_px * 4]u8 = undefined;
        for (0..pet_px) |y| {
            for (0..pet_px) |x| {
                const sx = x / scale;
                const sy = y / scale;
                const col = if (flip) sprites.size - 1 - sx else sx;
                const rgba = sprites.color(frame[sy][col]);
                const i = (y * pet_px + x) * 4;
                @memcpy(buf[i .. i + 4], &rgba);
            }
        }
        const bytes = glib.Bytes.new(&buf, buf.len);
        defer bytes.unref();
        const texture = gdk.MemoryTexture.new(pet_px, pet_px, .r8g8b8a8, bytes, pet_px * 4);
        return texture.as(gdk.Texture);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.timer) |t| _ = glib.Source.remove(t);
        priv.timer = null;
        self.clearPets();
        priv.pets.deinit(alloc());
        priv.pets = .empty;

        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
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
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
        }

        pub const as = C.Class.as;
    };
};
