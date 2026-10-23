const std = @import("std");
const adw = @import("adw");
const gdk = @import("gdk");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const ext = @import("../ext.zig");
const gresource = @import("../build/gresource.zig");
const Common = @import("../class.zig").Common;
const Window = @import("window.zig").Window;

const log = std.log.scoped(.gtk_ghostty_tab_sidebar_row);

/// Tab colors a user can pick. The name is used as a CSS class
/// (`color-<name>`) and as the target of the `win.set-tab-color` action.
pub const tab_colors = [_][:0]const u8{
    "red",
    "orange",
    "yellow",
    "green",
    "teal",
    "blue",
    "purple",
    "pink",
    "gray",
};

/// Returns true if `name` is one of `tab_colors`.
pub fn isTabColor(name: []const u8) bool {
    for (tab_colors) |c| {
        if (std.mem.eql(u8, c, name)) return true;
    }
    return false;
}

/// One entry in the vertical tab sidebar. It renders an `adw.TabPage` either
/// as a full row (color bar, title, working directory, attention dot, close
/// button) or, when `compact` is set, as a small numbered badge.
pub const TabSidebarRow = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyTabSidebarRow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The tab page this row shows.
        pub const page = struct {
            pub const name = "page";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*adw.TabPage,
                .{
                    .accessor = C.privateObjFieldAccessor("page"),
                },
            );
        };

        /// Zero-based position of the tab, used for the compact badge.
        pub const position = struct {
            pub const name = "position";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                c_uint,
                .{
                    .default = 0,
                    .minimum = 0,
                    .maximum = std.math.maxInt(c_uint),
                    .accessor = gobject.ext.typedAccessor(Self, c_uint, .{
                        .getter = getPosition,
                        .setter = setPosition,
                    }),
                },
            );
        };

        /// Show the compact badge instead of the full row.
        pub const compact = struct {
            pub const name = "compact";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = C.privateShallowFieldAccessor("compact"),
                },
            );
        };

        /// Color name of the tab (mirrors `GhosttyTab:color`).
        pub const @"tab-color" = struct {
            pub const name = "tab-color";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(Self, ?[:0]const u8, .{
                        .getter = getTabColor,
                        .getter_transfer = .none,
                        .setter = setTabColor,
                        .setter_transfer = .full,
                    }),
                },
            );
        };
    };

    const Private = struct {
        page: ?*adw.TabPage = null,
        position: c_uint = 0,
        compact: bool = false,
        tab_color: ?[:0]const u8 = null,

        // Template bindings
        badge: *gtk.Label,

        pub var offset: c_int = 0;
    };

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.updateBadge();
    }

    //---------------------------------------------------------------
    // Properties

    fn getPosition(self: *Self) c_uint {
        return self.private().position;
    }

    fn setPosition(self: *Self, value: c_uint) void {
        self.private().position = value;
        self.updateBadge();
    }

    fn updateBadge(self: *Self) void {
        const priv = self.private();
        var buf: [16]u8 = undefined;
        const text = std.fmt.bufPrintZ(&buf, "{d}", .{priv.position + 1}) catch return;
        priv.badge.setLabel(text.ptr);
    }

    fn getTabColor(self: *Self) ?[:0]const u8 {
        return self.private().tab_color;
    }

    fn setTabColor(self: *Self, value: ?[:0]const u8) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Remove every color class, then add the new one if valid.
        for (tab_colors) |c| {
            var buf: [32]u8 = undefined;
            const class = std.fmt.bufPrintZ(&buf, "color-{s}", .{c}) catch continue;
            widget.removeCssClass(class.ptr);
        }

        if (priv.tab_color) |v| glib.free(@ptrCast(@constCast(v)));
        priv.tab_color = value;

        if (value) |v| if (isTabColor(v)) {
            var buf: [32]u8 = undefined;
            const class = std.fmt.bufPrintZ(&buf, "color-{s}", .{v}) catch return;
            widget.addCssClass(class.ptr);
        };
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.closeTab();
    }

    fn middlePressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        self.closeTab();
    }

    fn secondaryPressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        _ = gesture.as(gtk.Gesture).setState(.claimed);
        const page = self.private().page orelse return;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        window.showSidebarTabMenu(self.as(gtk.Widget), page, x, y);
    }

    fn closeTab(self: *Self) void {
        const page = self.private().page orelse return;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        window.closeSidebarPage(page);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.page) |v| {
            v.unref();
            priv.page = null;
        }

        gtk.Widget.disposeTemplate(
            self.as(gtk.Widget),
            getGObjectType(),
        );

        gobject.Object.virtual_methods.dispose.call(
            Class.parent,
            self.as(Parent),
        );
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        if (priv.tab_color) |v| {
            glib.free(@ptrCast(@constCast(v)));
            priv.tab_color = null;
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
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
                    .name = "tab-sidebar-row",
                }),
            );

            gobject.ext.registerProperties(class, &.{
                properties.page.impl,
                properties.position.impl,
                properties.compact.impl,
                properties.@"tab-color".impl,
            });

            class.bindTemplateChildPrivate("badge", .{});

            class.bindTemplateCallback("close_clicked", &closeClicked);
            class.bindTemplateCallback("middle_pressed", &middlePressed);
            class.bindTemplateCallback("secondary_pressed", &secondaryPressed);

            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
