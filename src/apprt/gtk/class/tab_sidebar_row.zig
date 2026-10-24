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
const Tab = @import("tab.zig").Tab;

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
        pin_icon: *gtk.Image,
        close_button: *gtk.Button,
        subtitle: *gtk.Label,

        pub var offset: c_int = 0;
    };

    /// Create a row for `page`. `position` is the tab index (for the
    /// compact badge number).
    pub fn new(page: *adw.TabPage, position: c_uint, compact: bool, show_path: bool) *Self {
        const self = gobject.ext.newInstance(Self, .{
            .page = page,
            .position = position,
            .compact = compact,
        });

        // Pinned tabs show a pin and can't be closed from the sidebar.
        const pinned = page.getPinned() != 0;
        const priv = self.private();
        priv.pin_icon.as(gtk.Widget).setVisible(@intFromBool(pinned));
        priv.close_button.as(gtk.Widget).setVisible(@intFromBool(!pinned));
        priv.subtitle.as(gtk.Widget).setVisible(@intFromBool(show_path));
        if (pinned) self.as(gtk.Widget).addCssClass("pinned");
        return self;
    }

    pub fn getPage(self: *Self) ?*adw.TabPage {
        return self.private().page;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));
        self.updateBadge();

        // Drag this row to reorder tabs or move them between groups.
        const source = gtk.DragSource.new();
        source.setActions(.{ .move = true });
        _ = gtk.DragSource.signals.prepare.connect(source, *Self, dragPrepare, self, .{});
        _ = gtk.DragSource.signals.drag_begin.connect(source, *Self, dragBegin, self, .{});
        self.as(gtk.Widget).addController(source.as(gtk.EventController));

        // Accept other rows dropped onto this one.
        const target = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
        _ = gtk.DropTarget.signals.motion.connect(target, *Self, dropMotion, self, .{});
        _ = gtk.DropTarget.signals.leave.connect(target, *Self, dropLeave, self, .{});
        _ = gtk.DropTarget.signals.drop.connect(target, *Self, dropDrop, self, .{});
        self.as(gtk.Widget).addController(target.as(gtk.EventController));
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

        widget.removeCssClass("has-color");
        if (value) |v| if (isTabColor(v)) {
            var buf: [32]u8 = undefined;
            const class = std.fmt.bufPrintZ(&buf, "color-{s}", .{v}) catch return;
            widget.addCssClass(class.ptr);
            widget.addCssClass("has-color");
        };
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn closeClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        self.closeTab();
    }

    fn primaryPressed(
        _: *gtk.GestureClick,
        n_press: c_int,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        // Don't claim the sequence, so a drag can still start.
        const page = self.private().page orelse return;
        const window = ext.getAncestor(Window, self.as(gtk.Widget)) orelse return;
        window.selectSidebarPage(page);

        // Double-click renames the tab.
        if (n_press == 2) {
            if (gobject.ext.cast(Tab, page.getChild())) |tab| tab.promptTabTitle();
        }
    }

    //---------------------------------------------------------------
    // Drag and drop

    fn dragPrepare(
        _: *gtk.DragSource,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) ?*gdk.ContentProvider {
        const page = self.private().page orelse return null;
        var value = gobject.ext.Value.newFrom(page);
        defer value.unset();
        return gdk.ContentProvider.newForValue(&value);
    }

    fn dragBegin(source: *gtk.DragSource, _: *gdk.Drag, self: *Self) callconv(.c) void {
        // Use a live snapshot of the row as the drag icon.
        const paintable = gtk.WidgetPaintable.new(self.as(gtk.Widget));
        defer paintable.unref();
        source.setIcon(paintable.as(gdk.Paintable), 20, 16);
    }

    fn dropMotion(
        _: *gtk.DropTarget,
        _: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) gdk.DragAction {
        const widget = self.as(gtk.Widget);
        const after = y > @as(f64, @floatFromInt(widget.getHeight())) / 2;
        if (after) {
            widget.removeCssClass("drop-before");
            widget.addCssClass("drop-after");
        } else {
            widget.removeCssClass("drop-after");
            widget.addCssClass("drop-before");
        }
        return .{ .move = true };
    }

    fn dropLeave(_: *gtk.DropTarget, self: *Self) callconv(.c) void {
        self.as(gtk.Widget).removeCssClass("drop-before");
        self.as(gtk.Widget).removeCssClass("drop-after");
    }

    fn dropDrop(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) c_int {
        dropLeave(undefined, self);
        const dragged = gobject.ext.Value.get(value, ?*adw.TabPage) orelse return 0;
        const target = self.private().page orelse return 0;
        const widget = self.as(gtk.Widget);
        const after = y > @as(f64, @floatFromInt(widget.getHeight())) / 2;
        const window = ext.getAncestor(Window, widget) orelse return 0;
        window.sidebarDropOnPage(dragged, target, after);
        return 1;
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
            class.bindTemplateChildPrivate("pin_icon", .{});
            class.bindTemplateChildPrivate("close_button", .{});
            class.bindTemplateChildPrivate("subtitle", .{});

            class.bindTemplateCallback("close_clicked", &closeClicked);
            class.bindTemplateCallback("primary_pressed", &primaryPressed);
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
