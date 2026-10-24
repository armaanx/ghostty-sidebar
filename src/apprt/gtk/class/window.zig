const std = @import("std");
const build_config = @import("../../../build_config.zig");
const assert = @import("../../../quirks.zig").inlineAssert;
const adw = @import("adw");
const gdk = @import("gdk");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const i18n = @import("../../../os/main.zig").i18n;
const apprt = @import("../../../apprt.zig");
const configpkg = @import("../../../config.zig");
const TitlebarStyle = configpkg.Config.GtkTitlebarStyle;
const input = @import("../../../input.zig");
const CoreSurface = @import("../../../Surface.zig");
const ext = @import("../ext.zig");
const gtk_version = @import("../gtk_version.zig");
const adw_version = @import("../adw_version.zig");
const gresource = @import("../build/gresource.zig");
const winprotopkg = @import("../winproto.zig");
const Common = @import("../class.zig").Common;
const Config = @import("config.zig").Config;
const Application = @import("application.zig").Application;
const CloseConfirmationDialog = @import("close_confirmation_dialog.zig").CloseConfirmationDialog;
const SplitTree = @import("split_tree.zig").SplitTree;
const Surface = @import("surface.zig").Surface;
const Tab = @import("tab.zig").Tab;
const TabSidebarRow = @import("tab_sidebar_row.zig").TabSidebarRow;
const TitleDialog = @import("title_dialog.zig").TitleDialog;
const tab_sidebar_row = @import("tab_sidebar_row.zig");
const SidebarTheme = configpkg.Config.GtkTabsSidebarTheme;
const sidebar_state = @import("../sidebar_state.zig");
const SidebarColor = configpkg.Config.Color;
const DebugWarning = @import("debug_warning.zig").DebugWarning;
const CommandPalette = @import("command_palette.zig").CommandPalette;
const WeakRef = @import("../weak_ref.zig").WeakRef;

const log = std.log.scoped(.gtk_ghostty_window);

pub const Window = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.ApplicationWindow;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyWindow",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// The active surface is the focus that should be receiving all
        /// surface-targeted actions. This is usually the focused surface,
        /// but may also not be focused if the user has selected a non-surface
        /// widget.
        pub const @"active-surface" = struct {
            pub const name = "active-surface";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Surface,
                .{
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        ?*Surface,
                        .{
                            .getter = Self.getActiveSurface,
                        },
                    ),
                },
            );
        };

        pub const config = struct {
            pub const name = "config";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?*Config,
                .{
                    .accessor = C.privateObjFieldAccessor("config"),
                },
            );
        };

        pub const debug = struct {
            pub const name = "debug";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = build_config.is_debug,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = struct {
                            pub fn getter(_: *Self) bool {
                                return build_config.is_debug;
                            }
                        }.getter,
                    }),
                },
            );
        };

        pub const @"titlebar-style" = struct {
            pub const name = "titlebar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                TitlebarStyle,
                .{
                    .default = .native,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        TitlebarStyle,
                        .{
                            .getter = Self.getTitlebarStyle,
                        },
                    ),
                },
            );
        };

        pub const @"headerbar-visible" = struct {
            pub const name = "headerbar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getHeaderbarVisible,
                    }),
                },
            );
        };

        pub const @"quick-terminal" = struct {
            pub const name = "quick-terminal";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.privateFieldAccessor(
                        Self,
                        Private,
                        &Private.offset,
                        "quick_terminal",
                    ),
                },
            );
        };

        pub const @"tabs-autohide" = struct {
            pub const name = "tabs-autohide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsAutohide,
                    }),
                },
            );
        };

        pub const @"tabs-wide" = struct {
            pub const name = "tabs-wide";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsWide,
                    }),
                },
            );
        };

        pub const @"tabs-visible" = struct {
            pub const name = "tabs-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = true,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getTabsVisible,
                    }),
                },
            );
        };

        pub const @"sidebar-visible" = struct {
            pub const name = "sidebar-visible";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getSidebarVisible,
                    }),
                },
            );
        };

        pub const @"sidebar-compact" = struct {
            pub const name = "sidebar-compact";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getSidebarCompact,
                    }),
                },
            );
        };

        pub const @"sidebar-resizable" = struct {
            pub const name = "sidebar-resizable";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                bool,
                .{
                    .default = false,
                    .accessor = gobject.ext.typedAccessor(Self, bool, .{
                        .getter = Self.getSidebarResizable,
                    }),
                },
            );
        };

        pub const @"toolbar-style" = struct {
            pub const name = "toolbar-style";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                adw.ToolbarStyle,
                .{
                    .default = .raised,
                    .accessor = gobject.ext.typedAccessor(
                        Self,
                        adw.ToolbarStyle,
                        .{
                            .getter = Self.getToolbarStyle,
                        },
                    ),
                },
            );
        };
    };

    const Private = struct {
        /// Whether this window is a quick terminal. If it is then it
        /// behaves slightly differently under certain scenarios.
        quick_terminal: bool = false,

        /// The window decoration override. If this is not set then we'll
        /// inherit whatever the config has. This allows overriding the
        /// config on a per-window basis.
        window_decoration: ?configpkg.WindowDecoration = null,

        /// Binding group for our active tab.
        tab_bindings: *gobject.BindingGroup,

        /// The configuration that this surface is using.
        config: ?*Config = null,

        /// State and logic for windowing protocol for a window.
        winproto: winprotopkg.Window,

        /// Kind of hacky to have this but this lets us know if we've
        /// initialized any single surface yet. We need this because we
        /// gate default size on this so that we don't resize the window
        /// after surfaces already exist.
        ///
        /// I think long term we can probably get rid of this by implementing
        /// a property or method that gets us all the surfaces in all the
        /// tabs and checking if we have zero or one that isn't initialized.
        ///
        /// For now, this logic is more similar to our legacy GTK side.
        surface_init: bool = false,

        /// See tabOverviewOpen for why we have this.
        tab_overview_focus_timer: ?c_uint = null,

        /// A weak reference to a command palette.
        command_palette: WeakRef(CommandPalette) = .empty,

        /// Tab page that the context menu was opened for.
        /// setup by `setup-menu`.
        context_menu_page: ?*adw.TabPage = null,

        // Template bindings
        tab_overview: *adw.TabOverview,
        tab_bar: *adw.TabBar,
        tab_view: *adw.TabView,
        toolbar: *adw.ToolbarView,
        toast_overlay: *adw.ToastOverlay,
        sidebar_layout: *gtk.Box,
        sidebar_revealer: *gtk.Revealer,
        sidebar: *gtk.Box,
        sidebar_handle: *gtk.Box,
        sidebar_content: *gtk.Box,
        sidebar_guide: *gtk.Box,
        sidebar_list: *gtk.Box,
        tab_context_menu: *gio.MenuModel,

        /// Vertical tab sidebar state, cycled by `cycle_tab_sidebar`.
        sidebar_mode: SidebarMode = .expanded,

        /// Width of the expanded sidebar in pixels. Starts from the config.
        sidebar_width: c_int = 240,

        /// Sidebar theme for this window. Starts from the config and can be
        /// changed from the main menu.
        sidebar_theme: SidebarTheme = .graphite,

        /// Pointer offset inside the resize handle when a drag began.
        sidebar_drag_grab_x: f64 = 0,

        /// Sidebar accent color (attention dots, guide, attention ring).
        sidebar_accent: SidebarColor = .{ .r = 0x4e, .g = 0xa1, .b = 0xff },

        /// Translucent "glass" tab cards.
        sidebar_glass: bool = false,

        /// Show working directories under tab titles.
        sidebar_show_paths: bool = true,

        /// Pending idle source that rebuilds the sidebar rows.
        sidebar_rebuild_source: ?c_uint = null,

        /// Names of collapsed tab groups. Owned strings.
        collapsed_groups: std.ArrayListUnmanaged([:0]u8) = .empty,

        /// Page waiting for a "New Group" name from the dialog (ref held).
        group_dialog_page: ?*adw.TabPage = null,

        /// Group being renamed by the dialog. Owned string.
        group_dialog_rename: ?[:0]u8 = null,

        pub var offset: c_int = 0;
    };

    pub fn new(
        app: *Application,
        overrides: struct {
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *Self {
        const win = gobject.ext.newInstance(Self, .{
            .application = app,
        });

        if (overrides.title) |title| {
            // If the overrides have a title set, we set that immediately
            // so that any applications inspecting the window states see an
            // immediate title set when the window appears, rather than waiting
            // possibly a few event loop ticks for it to sync from the surface.
            win.as(gtk.Window).setTitle(title);
        }

        return win;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        gtk.Widget.initTemplate(self.as(gtk.Widget));

        // If our configuration is null then we get the configuration
        // from the application.
        const priv = self.private();

        const config = config: {
            if (priv.config) |config| break :config config.get();
            const app = Application.default();
            const config = app.getConfig();
            priv.config = config;
            break :config config.get();
        };

        // We initialize our windowing protocol to none because we can't
        // actually initialize this until we get realized.
        priv.winproto = .none;

        // Vertical tab sidebar starting state comes from the config, then
        // the remembered state file (last choice made in the UI) wins.
        priv.sidebar_theme = config.@"gtk-tabs-sidebar-theme";
        priv.sidebar_width = clampSidebarWidth(
            @intCast(@min(config.@"gtk-tabs-sidebar-width", 10_000)),
        );
        priv.sidebar_accent = config.@"gtk-tabs-sidebar-accent";
        priv.sidebar_glass = config.@"gtk-tabs-sidebar-glass";
        priv.sidebar_show_paths = config.@"gtk-tabs-sidebar-show-paths";
        {
            const saved = sidebar_state.load(Application.default().allocator());
            if (saved.width) |v| priv.sidebar_width = clampSidebarWidth(v);
            if (saved.mode) |v| priv.sidebar_mode = v;
            if (saved.theme) |v| priv.sidebar_theme = v;
            if (saved.accent) |v| priv.sidebar_accent = v;
            if (saved.glass) |v| priv.sidebar_glass = v;
            if (saved.show_paths) |v| priv.sidebar_show_paths = v;
        }

        // Dropping a tab on empty sidebar space moves it to the end and
        // out of its group.
        {
            const target = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
            _ = gtk.DropTarget.signals.drop.connect(target, *Self, sidebarDropOnEmpty, self, .{});
            priv.sidebar.as(gtk.Widget).addController(target.as(gtk.EventController));
        }

        // Add our dev CSS class if we're in debug mode.
        if (comptime build_config.is_debug) {
            self.as(gtk.Widget).addCssClass("devel");
        }

        // Setup our tab binding group. This ensures certain properties
        // are only synced from the currently active tab.
        priv.tab_bindings = gobject.BindingGroup.new();
        priv.tab_bindings.bind("title", self.as(gobject.Object), "title", .{});

        // Set our window icon. We can't set this in the blueprint file
        // because its dependent on the build config.
        self.as(gtk.Window).setIconName(build_config.bundle_id);

        // Initialize our actions
        self.initActionMap();

        // Start states based on config.
        if (config.maximize) self.as(gtk.Window).maximize();
        if (config.fullscreen != .false) self.as(gtk.Window).fullscreen();

        // If we have an explicit title set, we set that immediately
        // so that any applications inspecting the window states see
        // an immediate title set when the window appears, rather than
        // waiting possibly a few event loop ticks for it to sync from
        // the surface.
        if (config.title) |title| {
            self.as(gtk.Window).setTitle(title);
        }

        // We always sync our appearance at the end because loading our
        // config and such can affect our bindings which are setup initially
        // in initTemplate.
        self.syncAppearance();

        // We need to do this so that the title initializes properly,
        // I think because its a dynamic getter.
        self.as(gobject.Object).notifyByPspec(properties.@"active-surface".impl.param_spec);
    }

    /// Setup our action map.
    fn initActionMap(self: *Self) void {
        const s_variant_type = glib.ext.VariantType.newFor([:0]const u8);
        defer s_variant_type.free();
        const accent_hex = accentHex(self.private().sidebar_accent);

        const actions = [_]ext.actions.Action(Self){
            .init("about", actionAbout, null),
            .init("close", actionClose, null),
            .init("close-tab", actionCloseTab, s_variant_type),
            .init("new-tab", actionNewTab, null),
            .init("new-window", actionNewWindow, null),
            .init("prompt-surface-title", actionPromptSurfaceTitle, null),
            .init("prompt-tab-title", actionPromptTabTitle, null),
            .init("prompt-context-tab-title", actionPromptContextTabTitle, null),
            .init("ring-bell", actionRingBell, null),
            .init("split-right", actionSplitRight, null),
            .init("split-left", actionSplitLeft, null),
            .init("split-up", actionSplitUp, null),
            .init("split-down", actionSplitDown, null),
            .init("copy", actionCopy, null),
            .init("paste", actionPaste, null),
            .init("reset", actionReset, null),
            .init("clear", actionClear, null),
            // TODO: accept the surface that toggled the command palette
            .init("toggle-command-palette", actionToggleCommandPalette, null),
            .init("toggle-inspector", actionToggleInspector, null),
            .init("set-tab-color", actionSetTabColor, s_variant_type),
            .init("set-active-tab-color", actionSetActiveTabColor, s_variant_type),
            .init("cycle-tab-sidebar", actionCycleTabSidebar, null),
            .initStateful(
                "sidebar-theme",
                actionSidebarTheme,
                s_variant_type,
                glib.Variant.newString(@tagName(self.private().sidebar_theme)),
            ),
            .initStateful(
                "sidebar-accent",
                actionSidebarAccent,
                s_variant_type,
                glib.Variant.newString(&accent_hex),
            ),
            .initStateful(
                "sidebar-glass",
                actionSidebarGlass,
                null,
                glib.Variant.newBoolean(@intFromBool(self.private().sidebar_glass)),
            ),
            .initStateful(
                "sidebar-show-paths",
                actionSidebarShowPaths,
                null,
                glib.Variant.newBoolean(@intFromBool(self.private().sidebar_show_paths)),
            ),
            .init("toggle-pin-tab", actionTogglePinTab, null),
            .init("set-tab-group", actionSetTabGroup, s_variant_type),
            .init("new-tab-group", actionNewTabGroup, null),
            .init("rename-tab-group", actionRenameTabGroup, s_variant_type),
            .init("ungroup-tab-group", actionUngroupTabGroup, s_variant_type),
            .init("close-tab-group", actionCloseTabGroup, s_variant_type),
        };

        ext.actions.add(Self, self, &actions);
    }

    /// Winproto backend for this window.
    pub fn winproto(self: *Self) *winprotopkg.Window {
        return &self.private().winproto;
    }

    /// Create a new tab with the given parent. The tab will be inserted
    /// at the position dictated by the `window-new-tab-position` config.
    /// The new tab will be selected.
    pub fn newTab(self: *Self, parent_: ?*CoreSurface) void {
        _ = self.newTabPage(parent_, .tab, .none);
    }

    pub fn newTabForWindow(
        self: *Self,
        parent_: ?*CoreSurface,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) void {
        _ = self.newTabPage(
            parent_,
            .window,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );
    }

    fn newTabPage(
        self: *Self,
        parent_: ?*CoreSurface,
        context: apprt.surface.NewSurfaceContext,
        overrides: struct {
            command: ?configpkg.Command = null,
            working_directory: ?[:0]const u8 = null,
            title: ?[:0]const u8 = null,

            pub const none: @This() = .{};
        },
    ) *adw.TabPage {
        const priv: *Private = self.private();
        const tab_view = priv.tab_view;

        // Create our new tab object
        const tab = Tab.new(
            priv.config,
            .{
                .command = overrides.command,
                .working_directory = overrides.working_directory,
                .title = overrides.title,
            },
        );

        if (parent_) |p| {
            // For a new window's first tab, inherit the parent's initial size hints.
            if (context == .window) {
                surfaceInit(p.rt_surface.gobj(), self);
            }
            tab.setParentWithContext(p, context);
        }

        // Get the position that we should insert the new tab at.
        const config = if (priv.config) |v| v.get() else {
            // If we don't have a config we just append it at the end.
            // This should never happen.
            return tab_view.append(tab.as(gtk.Widget));
        };
        const position = switch (config.@"window-new-tab-position") {
            .current => current: {
                const selected = tab_view.getSelectedPage() orelse
                    break :current tab_view.getNPages();
                const current = tab_view.getPagePosition(selected);
                break :current current + 1;
            },

            .end => tab_view.getNPages(),
        };

        // Add the page and select it
        const page = tab_view.insert(tab.as(gtk.Widget), position);
        tab_view.setSelectedPage(page);

        // Create some property bindings
        _ = tab.as(gobject.Object).bindProperty(
            "title",
            page.as(gobject.Object),
            "title",
            .{ .sync_create = true },
        );
        _ = tab.as(gobject.Object).bindProperty(
            "tooltip",
            page.as(gobject.Object),
            "tooltip",
            .{ .sync_create = true },
        );

        // Bind signals
        const split_tree = tab.getSplitTree();
        _ = SplitTree.signals.changed.connect(
            split_tree,
            *Self,
            tabSplitTreeChanged,
            self,
            .{},
        );

        // Run an initial notification for the surface tree so we can setup
        // initial state.
        tabSplitTreeChanged(
            split_tree,
            null,
            split_tree.getTree(),
            self,
        );

        return page;
    }

    pub const SelectTab = union(enum) {
        previous,
        next,
        last,
        n: usize,
    };

    /// Select the tab as requested. Returns true if the tab selection
    /// changed.
    pub fn selectTab(self: *Self, n: SelectTab) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // Get our current tab numeric position
        const selected = tab_view.getSelectedPage() orelse return false;
        const current = tab_view.getPagePosition(selected);

        // Get our total
        const total = tab_view.getNPages();

        const goto: c_int = switch (n) {
            .previous => if (current > 0)
                current - 1
            else
                total - 1,

            .next => if (current < total - 1)
                current + 1
            else
                0,

            .last => total - 1,

            .n => |v| n: {
                // 1-indexed
                if (v == 0) return false;

                const n_int = std.math.cast(
                    c_int,
                    v,
                ) orelse return false;
                break :n @min(n_int - 1, total - 1);
            },
        };
        assert(goto >= 0);
        assert(goto < total);

        // If our target is the same as our current then we do nothing.
        if (goto == current) return false;

        // Add the page and select it
        const page = tab_view.getNthPage(goto);
        tab_view.setSelectedPage(page);

        return true;
    }

    /// Move the tab containing the given surface by the given amount.
    /// Returns if this affected any tab positioning.
    pub fn moveTab(
        self: *Self,
        surface: *Surface,
        amount: isize,
    ) bool {
        const priv = self.private();
        const tab_view = priv.tab_view;

        // If we have one tab we never move.
        const total = tab_view.getNPages();
        if (total == 1) return false;

        // Get the tab that contains the given surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse return false;

        // Get the page position that contains the tab.
        const page = tab_view.getPage(tab.as(gtk.Widget));
        const pos = tab_view.getPagePosition(page);

        // Move it
        const desired_pos: c_int = desired: {
            const initial: c_int = @intCast(pos + amount);
            const max = total - 1;
            break :desired if (initial < 0)
                max + initial + 1
            else if (initial > max)
                initial - max - 1
            else
                initial;
        };
        assert(desired_pos >= 0);
        assert(desired_pos < total);

        return tab_view.reorderPage(page, desired_pos) != 0;
    }

    pub fn toggleTabOverview(self: *Self) void {
        const priv = self.private();
        const tab_overview = priv.tab_overview;
        const is_open = tab_overview.getOpen() != 0;
        tab_overview.setOpen(@intFromBool(!is_open));
    }

    /// Toggle the visible property.
    pub fn toggleVisibility(self: *Self) void {
        const widget = self.as(gtk.Widget);
        widget.setVisible(@intFromBool(widget.isVisible() == 0));
    }

    /// Updates various appearance properties. This should always be safe
    /// to call multiple times. This should be called whenever a change
    /// happens that might affect how the window appears (config change,
    /// fullscreen, etc.).
    fn syncAppearance(self: *Self) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);

        // Toggle style classes based on whether we're using CSDs or SSDs.
        //
        // These classes are defined in the gtk.Window documentation:
        // https://docs.gtk.org/gtk4/class.Window.html#css-nodes.
        {
            // Reset all style classes first
            inline for (&.{
                "ssd",
                "csd",
                "solid-csd",
                "no-border-radius",
            }) |class|
                widget.removeCssClass(class);

            const csd_enabled = priv.winproto.clientSideDecorationEnabled();
            self.as(gtk.Window).setDecorated(@intFromBool(csd_enabled));

            if (csd_enabled) {
                const display = widget.getDisplay();

                // We do the exact same check GTK is doing internally and toggle
                // either the `csd` or `solid-csd` style, based on whether the user's
                // window manager is deemed _non-compositing_.
                //
                // In practice this only impacts users of traditional X11 window
                // managers (e.g. i3, dwm, awesomewm, etc.) and not X11 desktop
                // environments or Wayland compositors/DEs.
                if (display.isRgba() != 0 and display.isComposited() != 0) {
                    widget.addCssClass("csd");
                } else {
                    widget.addCssClass("solid-csd");
                }
            } else {
                widget.addCssClass("ssd");
                // Fix any artifacting that may occur in window corners.
                widget.addCssClass("no-border-radius");
            }
        }

        // Trigger all our dynamic properties that depend on the config.
        inline for (&.{
            "headerbar-visible",
            "tabs-autohide",
            "tabs-visible",
            "tabs-wide",
            "sidebar-visible",
            "sidebar-compact",
            "sidebar-resizable",
            "toolbar-style",
            "titlebar-style",
        }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Remainder uses the config
        const config = if (priv.config) |v| v.get() else return;

        // Only add a solid background if we're opaque.
        self.toggleCssClass(
            "background",
            config.@"background-opacity" >= 1,
        );

        // Apply class to color headerbar if window-theme is set to `ghostty` and
        // GTK version is before 4.16. The conditional is because above 4.16
        // we use GTK CSS color variables.
        self.toggleCssClass(
            "window-theme-ghostty",
            !gtk_version.atLeast(4, 16, 0) and
                config.@"window-theme" == .ghostty,
        );

        // Move the tab bar to the proper location. With a vertical
        // sidebar the tab bar is hidden (see getTabsVisible) unless the
        // titlebar style needs it, in which case it stays on top.
        priv.toolbar.remove(priv.tab_bar.as(gtk.Widget));
        switch (config.@"gtk-tabs-location") {
            .top, .left, .right => priv.toolbar.addTopBar(priv.tab_bar.as(gtk.Widget)),
            .bottom => priv.toolbar.addBottomBar(priv.tab_bar.as(gtk.Widget)),
        }

        // Put the vertical tab sidebar on the configured side and apply
        // its size and theme.
        self.syncSidebar();

        // Do our window-protocol specific appearance sync.
        priv.winproto.syncAppearance() catch |err| {
            log.warn("failed to sync winproto appearance error={}", .{err});
        };
    }

    /// Sync the state of any actions on this window.
    fn syncActions(self: *Self) void {
        const has_selection = selection: {
            const surface = self.getActiveSurface() orelse
                break :selection false;
            const core_surface = surface.core() orelse
                break :selection false;
            break :selection core_surface.hasSelection();
        };

        const action_map: *gio.ActionMap = gobject.ext.cast(
            gio.ActionMap,
            self,
        ) orelse return;
        const action: *gio.SimpleAction = gobject.ext.cast(
            gio.SimpleAction,
            action_map.lookupAction("copy") orelse return,
        ) orelse return;
        action.setEnabled(@intFromBool(has_selection));
    }

    fn toggleCssClass(self: *Self, class: [:0]const u8, value: bool) void {
        const widget = self.as(gtk.Widget);
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Perform a binding action on the window's active surface.
    fn performBindingAction(
        self: *Self,
        action: input.Binding.Action,
    ) void {
        const surface = self.getActiveSurface() orelse return;
        const core_surface = surface.core() orelse return;
        _ = core_surface.performBindingAction(action) catch |err| {
            log.warn("error performing binding action error={}", .{err});
            return;
        };
    }

    /// Queue a simple text-based toast. All text-based toasts share the
    /// same timeout for consistency.
    ///
    // This is not `pub` because we should be using signals emitted by
    // other widgets to trigger our toasts. Other objects should not
    // trigger toasts directly.
    fn addToast(self: *Self, title: [*:0]const u8) void {
        const toast = adw.Toast.new(title);
        toast.setTimeout(3);
        self.private().toast_overlay.addToast(toast);
    }

    fn connectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        const priv = self.private();
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            // Before adding any new signal handlers, disconnect any that we may
            // have added before. Otherwise we may get multiple handlers for the
            // same signal.
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );

            _ = Surface.signals.@"present-request".connect(
                surface,
                *Self,
                surfacePresentRequest,
                self,
                .{},
            );
            _ = Surface.signals.@"clipboard-write".connect(
                surface,
                *Self,
                surfaceClipboardWrite,
                self,
                .{},
            );
            _ = Surface.signals.menu.connect(
                surface,
                *Self,
                surfaceMenu,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-fullscreen".connect(
                surface,
                *Self,
                surfaceToggleFullscreen,
                self,
                .{},
            );
            _ = Surface.signals.@"toggle-maximize".connect(
                surface,
                *Self,
                surfaceToggleMaximize,
                self,
                .{},
            );

            // If we've never had a surface initialize yet, then we register
            // this signal. Its theoretically possible to launch multiple surfaces
            // before init so we could register this on multiple and that is not
            // a problem because we'll check the flag again in each handler.
            if (!priv.surface_init) {
                _ = Surface.signals.init.connect(
                    surface,
                    *Self,
                    surfaceInit,
                    self,
                    .{},
                );
            }
        }
    }

    /// Disconnect all the surface handlers for the given tree. This should
    /// be called whenever a tree is no longer present in the window, e.g.
    /// when a tab is detached or the tree changes.
    fn disconnectSurfaceHandlers(
        self: *Self,
        tree: *const Surface.Tree,
    ) void {
        var it = tree.iterator();
        while (it.next()) |entry| {
            const surface = entry.view;
            _ = gobject.signalHandlersDisconnectMatched(
                surface.as(gobject.Object),
                .{ .data = true },
                0,
                0,
                null,
                null,
                self,
            );
        }
    }

    //---------------------------------------------------------------
    // Properties

    /// Whether this terminal is a quick terminal or not.
    pub fn isQuickTerminal(self: *Self) bool {
        return self.private().quick_terminal;
    }

    /// Get the currently active surface. See the "active-surface" property.
    /// This does not ref the value.
    pub fn getActiveSurface(self: *Self) ?*Surface {
        const tab = self.getSelectedTab() orelse return null;
        return tab.getActiveSurface();
    }

    /// Returns the configuration for this window. The reference count
    /// is not increased.
    pub fn getConfig(self: *Self) ?*Config {
        return self.private().config;
    }

    /// Get the tab view for this window.
    pub fn getTabView(self: *Self) *adw.TabView {
        return self.private().tab_view;
    }

    /// Get the current window decoration value for this window.
    pub fn getWindowDecoration(self: *Self) configpkg.WindowDecoration {
        const priv = self.private();
        if (priv.window_decoration) |v| return v;
        if (priv.config) |v| return v.get().@"window-decoration";
        return .auto;
    }

    /// Toggle the window decorations for this window.
    pub fn toggleWindowDecorations(self: *Self) void {
        const priv = self.private();

        if (priv.window_decoration) |_| {
            // Unset any previously set window decoration settings
            self.setWindowDecoration(null);
            return;
        }

        const config = if (priv.config) |v| v.get() else return;
        self.setWindowDecoration(switch (config.@"window-decoration") {
            // Use auto when the decoration is initially none
            .none => .auto,

            // Anything non-none to none
            .auto, .client, .server => .none,
        });
    }

    /// Set the window decoration override for this window. If this is null,
    /// then we'll revert back to the configuration's default.
    fn setWindowDecoration(
        self: *Self,
        new_: ?configpkg.WindowDecoration,
    ) void {
        const priv = self.private();
        priv.window_decoration = new_;
        self.syncAppearance();
    }

    /// Get the currently selected tab as a Tab object.
    fn getSelectedTab(self: *Self) ?*Tab {
        const priv = self.private();
        const page = priv.tab_view.getSelectedPage() orelse return null;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));
        return gobject.ext.cast(Tab, child);
    }

    /// Returns true if this window needs confirmation before quitting.
    fn getNeedsConfirmQuit(self: *Self) bool {
        const priv = self.private();
        const n = priv.tab_view.getNPages();
        assert(n >= 0);

        for (0..@intCast(n)) |i| {
            const page = priv.tab_view.getNthPage(@intCast(i));
            const child = page.getChild();
            const tab = gobject.ext.cast(Tab, child) orelse {
                log.warn("unexpected non-Tab child in tab view", .{});
                continue;
            };
            if (tab.getNeedsConfirmQuit()) return true;
        }

        return false;
    }

    fn isFullscreen(self: *Window) bool {
        return self.as(gtk.Window).isFullscreen() != 0;
    }

    fn isMaximized(self: *Window) bool {
        return self.as(gtk.Window).isMaximized() != 0;
    }

    fn getHeaderbarVisible(self: *Self) bool {
        const priv = self.private();

        // Never display the header bar when CSDs are disabled.
        const csd_enabled = priv.winproto.clientSideDecorationEnabled();
        if (!csd_enabled) return false;

        // Never display the header bar as a quick terminal.
        if (priv.quick_terminal) return false;

        // If we're fullscreen we never show the header bar.
        if (self.isFullscreen()) return false;

        // The remainder needs a config
        const config_obj = self.private().config orelse return true;
        const config = config_obj.get();

        // *Conditionally* disable the header bar when maximized, and
        // gtk-titlebar-hide-when-maximized is set
        if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") {
            return false;
        }

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs never show the titlebar.
            .tabs => false,

            // If the titlebar style is native show the titlebar if configured
            // to do so.
            .native => config.@"gtk-titlebar",
        };
    }

    fn getTabsAutohide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        return switch (config.@"gtk-titlebar-style") {
            // If the titlebar style is tabs we cannot autohide.
            .tabs => false,

            .native => switch (config.@"window-show-tab-bar") {
                // Auto we always autohide... obviously.
                .auto => true,

                // Always we never autohide because we always show the tab bar.
                .always => false,

                // Never we autohide because it doesn't actually matter,
                // since getTabsVisible will return false.
                .never => true,
            },
        };
    }

    fn getTabsVisible(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;

        switch (config.@"gtk-titlebar-style") {
            .tabs => {
                // *Conditionally* disable the tab bar when maximized, the titlebar
                // style is tabs, and gtk-titlebar-hide-when-maximized is set.
                if (self.isMaximized() and config.@"gtk-titlebar-hide-when-maximized") return false;

                // If the titlebar style is tabs the tab bar must always be visible.
                return true;
            },
            .native => {
                // The vertical sidebar replaces the tab bar.
                if (config.@"gtk-tabs-location".isVertical()) return false;

                return switch (config.@"window-show-tab-bar") {
                    .always, .auto => true,
                    .never => false,
                };
            },
        }
    }

    fn getSidebarVisible(self: *Self) bool {
        const priv = self.private();

        // The quick terminal is too small for a sidebar.
        if (priv.quick_terminal) return false;

        const config = if (priv.config) |v| v.get() else return false;
        if (!config.@"gtk-tabs-location".isVertical()) return false;

        // Respect the user's choice to never show tabs.
        if (config.@"window-show-tab-bar" == .never) return false;

        return priv.sidebar_mode != .hidden;
    }

    fn getSidebarCompact(self: *Self) bool {
        return self.private().sidebar_mode == .compact;
    }

    fn getSidebarResizable(self: *Self) bool {
        return self.getSidebarVisible() and
            self.private().sidebar_mode == .expanded;
    }

    //---------------------------------------------------------------
    // Vertical tab sidebar

    pub const SidebarMode = sidebar_state.SidebarMode;

    const sidebar_min_width: c_int = 160;
    const sidebar_max_width: c_int = 480;
    const sidebar_compact_width: c_int = 60;

    fn clampSidebarWidth(width: c_int) c_int {
        return std.math.clamp(width, sidebar_min_width, sidebar_max_width);
    }

    fn sidebarIsVertical(self: *Self) bool {
        const config = if (self.private().config) |v| v.get() else return false;
        return config.@"gtk-tabs-location".isVertical();
    }

    fn sidebarOnRight(self: *Self) bool {
        const config = if (self.private().config) |v| v.get() else return false;
        return config.@"gtk-tabs-location" == .right;
    }

    /// Cycle expanded -> compact -> hidden -> expanded. Returns false if
    /// tabs aren't shown in a sidebar, so the key press passes through.
    pub fn cycleSidebarMode(self: *Self) bool {
        if (!self.sidebarIsVertical()) return false;
        const priv = self.private();
        priv.sidebar_mode = switch (priv.sidebar_mode) {
            .expanded => .compact,
            .compact => .hidden,
            .hidden => .expanded,
        };
        self.syncSidebar();
        self.saveSidebarState();
        return true;
    }

    /// Apply side, size, theme and visibility of the vertical tab sidebar.
    fn syncSidebar(self: *Self) void {
        const priv = self.private();
        const right = self.sidebarOnRight();

        // Order the layout children: [sidebar][handle][content] on the
        // left, [content][handle][sidebar] on the right.
        const layout = priv.sidebar_layout;
        const sidebar = priv.sidebar_revealer.as(gtk.Widget);
        const handle = priv.sidebar_handle.as(gtk.Widget);
        const content = priv.sidebar_content.as(gtk.Widget);
        if (right) {
            layout.reorderChildAfter(content, null);
            layout.reorderChildAfter(handle, content);
            layout.reorderChildAfter(sidebar, handle);
        } else {
            layout.reorderChildAfter(sidebar, null);
            layout.reorderChildAfter(handle, sidebar);
            layout.reorderChildAfter(content, handle);
        }

        // Width depends on the mode. Hidden keeps the last width so the
        // slide-out animation doesn't jump.
        const sidebar_widget = priv.sidebar.as(gtk.Widget);
        const width: c_int = switch (priv.sidebar_mode) {
            .compact => sidebar_compact_width,
            .expanded, .hidden => priv.sidebar_width,
        };
        sidebar_widget.setSizeRequest(width, -1);

        // CSS classes: side, compact and theme.
        toggleWidgetCssClass(sidebar_widget, "right", right);
        toggleWidgetCssClass(sidebar_widget, "left", !right);
        toggleWidgetCssClass(handle, "right", right);
        toggleWidgetCssClass(sidebar_widget, "compact", priv.sidebar_mode == .compact);
        inline for (@typeInfo(SidebarTheme).@"enum".fields) |field| {
            toggleWidgetCssClass(
                sidebar_widget,
                "theme-" ++ field.name,
                @intFromEnum(priv.sidebar_theme) == field.value,
            );
        }

        // Glass: translucent, frosted tab rows. The sidebar and window stay
        // opaque.
        const vertical = self.sidebarIsVertical();
        const glass = priv.sidebar_glass and vertical;
        toggleWidgetCssClass(sidebar_widget, "glass", glass);

        // Hide the sidebar widget itself when hidden; a collapsed revealer
        // would still reserve its width.
        sidebar.setVisible(@intFromBool(self.getSidebarVisible()));

        applySidebarAccent(self.as(gtk.Widget), priv.sidebar_accent);

        // Sidebar-only menu items do nothing for horizontal tabs.
        inline for (.{
            "cycle-tab-sidebar",
            "sidebar-theme",
            "sidebar-accent",
            "sidebar-glass",
            "sidebar-show-paths",
            "set-tab-group",
            "new-tab-group",
        }) |name| {
            if (self.as(gio.ActionMap).lookupAction(name)) |action| {
                if (gobject.ext.cast(gio.SimpleAction, action)) |simple| {
                    simple.setEnabled(@intFromBool(vertical));
                }
            }
        }

        inline for (.{ "sidebar-visible", "sidebar-compact", "sidebar-resizable" }) |key| {
            self.as(gobject.Object).notifyByPspec(
                @field(properties, key).impl.param_spec,
            );
        }

        // Full rows vs compact badges.
        self.queueSidebarRebuild();
    }

    fn saveSidebarState(self: *Self) void {
        const priv = self.private();
        sidebar_state.save(Application.default().allocator(), .{
            .width = priv.sidebar_width,
            .mode = priv.sidebar_mode,
            .theme = priv.sidebar_theme,
            .accent = priv.sidebar_accent,
            .glass = priv.sidebar_glass,
            .show_paths = priv.sidebar_show_paths,
        });
    }

    fn accentHex(c: SidebarColor) [6:0]u8 {
        var buf: [6:0]u8 = undefined;
        _ = std.fmt.bufPrint(&buf, "{x:0>2}{x:0>2}{x:0>2}", .{ c.r, c.g, c.b }) catch unreachable;
        return buf;
    }

    /// App-wide CSS provider that defines `--sb-accent`. The accent is
    /// shared by every window, like the saved state.
    var accent_provider: ?*gtk.CssProvider = null;

    fn applySidebarAccent(widget: *gtk.Widget, c: SidebarColor) void {
        const provider = accent_provider orelse provider: {
            const p = gtk.CssProvider.new();
            gtk.StyleContext.addProviderForDisplay(
                widget.getDisplay(),
                p.as(gtk.StyleProvider),
                gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 50,
            );
            accent_provider = p;
            break :provider p;
        };

        var buf: [128]u8 = undefined;
        const css = std.fmt.bufPrintZ(
            &buf,
            "window {{ --sb-accent: rgb({d},{d},{d}); }}",
            .{ c.r, c.g, c.b },
        ) catch return;
        provider.loadFromString(css.ptr);
    }

    //---------------------------------------------------------------
    // Sidebar rows: pinned tabs, ungrouped tabs and tab groups. The
    // sidebar is rebuilt from the tab view on an idle callback whenever
    // tabs are added, removed, moved, pinned or regrouped.

    fn queueSidebarRebuild(self: *Self) void {
        const priv = self.private();
        if (priv.sidebar_rebuild_source != null) return;
        priv.sidebar_rebuild_source = glib.idleAdd(sidebarRebuildIdle, self);
    }

    fn sidebarRebuildIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        self.private().sidebar_rebuild_source = null;
        self.rebuildSidebar();
        return 0;
    }

    fn pageTab(page: *adw.TabPage) ?*Tab {
        return gobject.ext.cast(Tab, page.getChild());
    }

    fn pageGroup(page: *adw.TabPage) ?[:0]const u8 {
        if (page.getPinned() != 0) return null;
        const tab = pageTab(page) orelse return null;
        return tab.getGroup();
    }

    fn eqlGroup(a: ?[:0]const u8, b: ?[:0]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }

    fn isGroupCollapsed(self: *Self, name: []const u8) bool {
        for (self.private().collapsed_groups.items) |g| {
            if (std.mem.eql(u8, g, name)) return true;
        }
        return false;
    }

    fn setGroupCollapsed(self: *Self, name: []const u8, collapsed: bool) void {
        const priv = self.private();
        const alloc = Application.default().allocator();
        for (priv.collapsed_groups.items, 0..) |g, i| {
            if (std.mem.eql(u8, g, name)) {
                if (!collapsed) {
                    alloc.free(g);
                    _ = priv.collapsed_groups.swapRemove(i);
                }
                return;
            }
        }
        if (collapsed) {
            const owned = alloc.dupeZ(u8, name) catch return;
            priv.collapsed_groups.append(alloc, owned) catch alloc.free(owned);
        }
    }

    /// Keep each group's tabs next to each other in the tab view, in the
    /// order the groups first appear. Pinned tabs always come first.
    fn normalizeGroupOrder(self: *Self) void {
        const tab_view = self.private().tab_view;
        const n: usize = @intCast(tab_view.getNPages());
        if (n < 2) return;

        const alloc = Application.default().allocator();
        const pages = alloc.alloc(*adw.TabPage, n) catch return;
        defer alloc.free(pages);
        const desired = alloc.alloc(*adw.TabPage, n) catch return;
        defer alloc.free(desired);
        const used = alloc.alloc(bool, n) catch return;
        defer alloc.free(used);
        @memset(used, false);

        for (pages, 0..) |*p, i| p.* = tab_view.getNthPage(@intCast(i));

        var out: usize = 0;
        for (pages, 0..) |p, i| {
            if (used[i]) continue;
            const group = pageGroup(p);
            if (group == null) {
                desired[out] = p;
                out += 1;
                used[i] = true;
                continue;
            }
            for (pages[i..], i..) |q, j| {
                if (used[j]) continue;
                if (!eqlGroup(pageGroup(q), group)) continue;
                desired[out] = q;
                out += 1;
                used[j] = true;
            }
        }

        for (desired, 0..) |p, i| {
            if (tab_view.getPagePosition(p) != @as(c_int, @intCast(i))) {
                _ = tab_view.reorderPage(p, @intCast(i));
            }
        }
    }

    fn rebuildSidebar(self: *Self) void {
        const priv = self.private();
        if (!self.sidebarIsVertical()) return;

        self.normalizeGroupOrder();

        // Remove the old rows.
        const list = priv.sidebar_list;
        while (list.as(gtk.Widget).getFirstChild()) |child| list.remove(child);

        const compact = priv.sidebar_mode == .compact;
        const tab_view = priv.tab_view;
        const selected = tab_view.getSelectedPage();
        const n: c_int = tab_view.getNPages();

        var i: c_int = 0;
        var prev_pinned = false;
        var prev_group: ?[:0]const u8 = null;
        while (i < n) : (i += 1) {
            const page = tab_view.getNthPage(i);
            const pinned = page.getPinned() != 0;
            const group = pageGroup(page);

            // Separator after the pinned tabs.
            if (i > 0 and prev_pinned and !pinned) {
                list.append(makeSidebarSeparator());
            }

            // Group header (or a separator in compact mode) when a new
            // group starts.
            if (group) |name| {
                if (!eqlGroup(prev_group, group)) {
                    if (compact) {
                        if (i > 0) list.append(makeSidebarSeparator());
                    } else {
                        list.append(self.makeGroupHeader(name, selected));
                    }
                }
            } else if (prev_group != null and !pinned) {
                if (compact) list.append(makeSidebarSeparator());
            }

            prev_pinned = pinned;
            prev_group = group;

            // Collapsed groups hide their tabs (only in full mode).
            if (!compact) if (group) |name| if (self.isGroupCollapsed(name)) continue;

            const row = TabSidebarRow.new(page, @intCast(i), compact, priv.sidebar_show_paths);
            if (group != null) row.as(gtk.Widget).addCssClass("in-group");
            list.append(row.as(gtk.Widget));
        }

        self.updateSidebarSelection();
    }

    fn makeSidebarSeparator() *gtk.Widget {
        const sep = gtk.Separator.new(.horizontal);
        sep.as(gtk.Widget).addCssClass("sidebar-separator");
        return sep.as(gtk.Widget);
    }

    const group_data_key = "ghostty-tab-group";

    fn makeGroupHeader(self: *Self, name: [:0]const u8, selected: ?*adw.TabPage) *gtk.Widget {
        const tab_view = self.private().tab_view;
        const collapsed = self.isGroupCollapsed(name);

        // Count members and check whether the selected tab is inside.
        var count: usize = 0;
        var has_selected = false;
        var i: c_int = 0;
        while (i < tab_view.getNPages()) : (i += 1) {
            const page = tab_view.getNthPage(i);
            if (!eqlGroup(pageGroup(page), name)) continue;
            count += 1;
            if (selected == page) has_selected = true;
        }

        const box = gtk.Box.new(.horizontal, 6);
        const widget = box.as(gtk.Widget);
        widget.addCssClass("tab-group-header");
        if (collapsed) widget.addCssClass("collapsed");
        if (has_selected) widget.addCssClass("has-selected");
        widget.setTooltipText(if (collapsed) "Expand group" else "Collapse group");

        const chevron = gtk.Image.newFromIconName(
            if (collapsed) "pan-end-symbolic" else "pan-down-symbolic",
        );
        chevron.as(gtk.Widget).addCssClass("tab-group-chevron");
        box.append(chevron.as(gtk.Widget));

        const label = gtk.Label.new(name.ptr);
        label.setXalign(0);
        label.setEllipsize(.end);
        label.setMaxWidthChars(1);
        label.as(gtk.Widget).setHexpand(1);
        label.as(gtk.Widget).addCssClass("tab-group-name");
        box.append(label.as(gtk.Widget));

        var buf: [16]u8 = undefined;
        const count_text = std.fmt.bufPrintZ(&buf, "{d}", .{count}) catch "?";
        const count_label = gtk.Label.new(count_text.ptr);
        count_label.as(gtk.Widget).addCssClass("tab-group-count");
        box.append(count_label.as(gtk.Widget));

        // Remember the group name on the widget for the handlers.
        widget.as(gobject.Object).setDataFull(
            group_data_key,
            @ptrCast(glib.ext.dupeZ(u8, name).ptr),
            glib.free,
        );

        const click = gtk.GestureClick.new();
        click.as(gtk.GestureSingle).setButton(0);
        _ = gtk.GestureClick.signals.pressed.connect(click, *Self, groupHeaderPressed, self, .{});
        widget.addController(click.as(gtk.EventController));

        const target = gtk.DropTarget.new(adw.TabPage.getGObjectType(), .{ .move = true });
        _ = gtk.DropTarget.signals.drop.connect(target, *Self, groupHeaderDrop, self, .{});
        widget.addController(target.as(gtk.EventController));

        return widget;
    }

    fn controllerGroupName(controller: *gtk.EventController) ?[:0]const u8 {
        const widget = controller.getWidget() orelse return null;
        const data = widget.as(gobject.Object).getData(group_data_key) orelse return null;
        const ptr: [*:0]const u8 = @ptrCast(data);
        return std.mem.span(ptr);
    }

    fn groupHeaderPressed(
        gesture: *gtk.GestureClick,
        _: c_int,
        x: f64,
        y: f64,
        self: *Self,
    ) callconv(.c) void {
        const controller = gesture.as(gtk.EventController);
        const name = controllerGroupName(controller) orelse return;
        _ = gesture.as(gtk.Gesture).setState(.claimed);

        switch (gesture.as(gtk.GestureSingle).getCurrentButton()) {
            1 => {
                self.setGroupCollapsed(name, !self.isGroupCollapsed(name));
                self.queueSidebarRebuild();
            },
            3 => {
                const widget = controller.getWidget() orelse return;
                self.showGroupMenu(widget, name, x, y);
            },
            else => {},
        }
    }

    fn groupHeaderDrop(
        target: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const name = controllerGroupName(target.as(gtk.EventController)) orelse return 0;
        const page = gobject.ext.Value.get(value, ?*adw.TabPage) orelse return 0;
        self.moveTabToGroup(page, name);
        return 1;
    }

    fn updateSidebarSelection(self: *Self) void {
        const priv = self.private();
        const selected = priv.tab_view.getSelectedPage();
        const selected_group = if (selected) |p| pageGroup(p) else null;
        var child = priv.sidebar_list.as(gtk.Widget).getFirstChild();
        while (child) |w| : (child = w.getNextSibling()) {
            if (gobject.ext.cast(TabSidebarRow, w)) |row| {
                toggleWidgetCssClass(w, "selected", row.getPage() == selected);
                continue;
            }
            // Group headers: highlight when the selected tab is inside.
            if (w.as(gobject.Object).getData(group_data_key)) |data| {
                const name = std.mem.span(@as([*:0]const u8, @ptrCast(data)));
                toggleWidgetCssClass(w, "has-selected", eqlGroup(selected_group, name));
            }
        }
    }

    /// Select a tab from its sidebar row and give the terminal focus.
    pub fn selectSidebarPage(self: *Self, page: *adw.TabPage) void {
        self.private().tab_view.setSelectedPage(page);
        if (self.getActiveSurface()) |surface| surface.grabFocus();
    }

    /// Put `page` in `group` (null = no group), unpinning it first.
    fn moveTabToGroup(self: *Self, page: *adw.TabPage, group: ?[:0]const u8) void {
        const priv = self.private();
        const tab = pageTab(page) orelse return;
        if (page.getPinned() != 0) priv.tab_view.setPagePinned(page, 0);
        tab.setGroup(group);
        if (group) |g| self.setGroupCollapsed(g, false);

        // Move it after the last tab already in that group, so groups
        // stay together.
        if (group) |g| {
            var last: c_int = -1;
            var i: c_int = 0;
            while (i < priv.tab_view.getNPages()) : (i += 1) {
                const p = priv.tab_view.getNthPage(i);
                if (p == page) continue;
                if (eqlGroup(pageGroup(p), g)) last = i;
            }
            if (last >= 0) {
                const from = priv.tab_view.getPagePosition(page);
                const to = if (from < last) last else last + 1;
                _ = priv.tab_view.reorderPage(page, to);
            }
        }
        self.queueSidebarRebuild();
    }

    /// A sidebar row was dropped onto another row. The dragged tab moves
    /// next to the target and takes on its group and pinned state.
    pub fn sidebarDropOnPage(
        self: *Self,
        dragged: *adw.TabPage,
        target: *adw.TabPage,
        after: bool,
    ) void {
        if (dragged == target) return;
        const priv = self.private();
        const tab_view = priv.tab_view;
        const tab = pageTab(dragged) orelse return;

        const target_pinned = target.getPinned() != 0;
        if ((dragged.getPinned() != 0) != target_pinned) {
            tab_view.setPagePinned(dragged, @intFromBool(target_pinned));
        }
        tab.setGroup(if (target_pinned) null else pageGroup(target));

        const from = tab_view.getPagePosition(dragged);
        var to = tab_view.getPagePosition(target);
        if (after) to += 1;
        if (from < to) to -= 1;
        _ = tab_view.reorderPage(dragged, to);
        self.queueSidebarRebuild();
    }

    fn sidebarDropOnEmpty(
        _: *gtk.DropTarget,
        value: *gobject.Value,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) c_int {
        const page = gobject.ext.Value.get(value, ?*adw.TabPage) orelse return 0;
        const priv = self.private();
        const tab = pageTab(page) orelse return 0;
        if (page.getPinned() != 0) priv.tab_view.setPagePinned(page, 0);
        tab.setGroup(null);
        _ = priv.tab_view.reorderPage(page, priv.tab_view.getNPages() - 1);
        self.queueSidebarRebuild();
        return 1;
    }

    fn toggleWidgetCssClass(widget: *gtk.Widget, class: [:0]const u8, value: bool) void {
        if (value)
            widget.addCssClass(class.ptr)
        else
            widget.removeCssClass(class.ptr);
    }

    /// Close a tab from its sidebar row. Uses the same confirmation path
    /// as closing from the tab bar.
    pub fn closeSidebarPage(self: *Self, page: *adw.TabPage) void {
        self.private().tab_view.closePage(page);
    }

    /// Show a popover menu built from `model` at (x, y) in `widget`.
    fn popupSidebarMenu(widget: *gtk.Widget, model: *gio.MenuModel, x: f64, y: f64) void {
        const popover = gtk.PopoverMenu.newFromModel(model);
        popover.as(gtk.Widget).setParent(widget);
        popover.as(gtk.Popover).setHasArrow(0);
        popover.as(gtk.Popover).setPosition(.bottom);
        const rect: gdk.Rectangle = .{
            .f_x = @intFromFloat(x),
            .f_y = @intFromFloat(y),
            .f_width = 1,
            .f_height = 1,
        };
        popover.as(gtk.Popover).setPointingTo(&rect);
        _ = gtk.Popover.signals.closed.connect(
            popover.as(gtk.Popover),
            ?*anyopaque,
            sidebarMenuClosed,
            null,
            .{},
        );
        popover.as(gtk.Popover).popup();
    }

    fn menuItemWithTarget(menu: *gio.Menu, label: [:0]const u8, action: [:0]const u8, target: [:0]const u8) void {
        const item = gio.MenuItem.new(label.ptr, null);
        defer item.unref();
        item.setActionAndTargetValue(action.ptr, glib.Variant.newString(target.ptr));
        menu.appendItem(item);
    }

    /// Show the tab context menu for a sidebar row: rename, pin, color
    /// and group. Built on demand because the group list changes.
    pub fn showSidebarTabMenu(
        self: *Self,
        row: *gtk.Widget,
        page: *adw.TabPage,
        x: f64,
        y: f64,
    ) void {
        const priv = self.private();
        priv.context_menu_page = page;
        const pinned = page.getPinned() != 0;
        const current_group = pageGroup(page);

        const menu = gio.Menu.new();
        defer menu.unref();

        const main = gio.Menu.new();
        defer main.unref();
        main.append("Rename Tab…", "win.prompt-context-tab-title");
        main.append(if (pinned) "Unpin Tab" else "Pin Tab", "win.toggle-pin-tab");
        menu.appendSection(null, main.as(gio.MenuModel));

        // Tab colors.
        const colors = gio.Menu.new();
        defer colors.unref();
        menuItemWithTarget(colors, "None", "win.set-tab-color", "none");
        inline for (tab_sidebar_row.tab_colors) |c| {
            const label = comptime label: {
                var l: [c.len:0]u8 = undefined;
                @memcpy(&l, c);
                l[0] = std.ascii.toUpper(l[0]);
                const final = l;
                break :label &final;
            };
            menuItemWithTarget(colors, label, "win.set-tab-color", c);
        }

        // Groups: existing groups, new group, remove from group.
        const groups = gio.Menu.new();
        defer groups.unref();
        const listed = gio.Menu.new();
        defer listed.unref();
        {
            var seen: [32][:0]const u8 = undefined;
            var n_seen: usize = 0;
            var i: c_int = 0;
            while (i < priv.tab_view.getNPages()) : (i += 1) {
                const g = pageGroup(priv.tab_view.getNthPage(i)) orelse continue;
                if (eqlGroup(g, current_group)) continue;
                var dup = false;
                for (seen[0..n_seen]) |prev| {
                    if (std.mem.eql(u8, prev, g)) dup = true;
                }
                if (dup or n_seen == seen.len) continue;
                seen[n_seen] = g;
                n_seen += 1;
                menuItemWithTarget(listed, g, "win.set-tab-group", g);
            }
        }
        groups.appendSection(null, listed.as(gio.MenuModel));
        const group_actions = gio.Menu.new();
        defer group_actions.unref();
        group_actions.append("New Group…", "win.new-tab-group");
        if (current_group != null) {
            menuItemWithTarget(group_actions, "Remove from Group", "win.set-tab-group", "");
        }
        groups.appendSection(null, group_actions.as(gio.MenuModel));

        const subs = gio.Menu.new();
        defer subs.unref();
        subs.appendSubmenu("Tab Color", colors.as(gio.MenuModel));
        if (!pinned) subs.appendSubmenu("Move to Group", groups.as(gio.MenuModel));
        menu.appendSection(null, subs.as(gio.MenuModel));

        popupSidebarMenu(row, menu.as(gio.MenuModel), x, y);
    }

    /// Show the menu for a group header: rename, ungroup, close.
    fn showGroupMenu(self: *Self, header: *gtk.Widget, name: [:0]const u8, x: f64, y: f64) void {
        _ = self;
        const menu = gio.Menu.new();
        defer menu.unref();
        menuItemWithTarget(menu, "Rename Group…", "win.rename-tab-group", name);
        menuItemWithTarget(menu, "Ungroup Tabs", "win.ungroup-tab-group", name);
        menuItemWithTarget(menu, "Close Group", "win.close-tab-group", name);
        popupSidebarMenu(header, menu.as(gio.MenuModel), x, y);
    }

    fn sidebarMenuClosed(popover: *gtk.Popover, _: ?*anyopaque) callconv(.c) void {
        // Unparent on idle so a clicked menu item can still activate its
        // action through the widget tree first.
        _ = glib.idleAdd(sidebarMenuUnparent, popover);
    }

    fn sidebarMenuUnparent(ud: ?*anyopaque) callconv(.c) c_int {
        const popover: *gtk.Popover = @ptrCast(@alignCast(ud orelse return 0));
        popover.as(gtk.Widget).unparent();
        return 0;
    }

    fn btnCycleSidebar(_: *gtk.Button, self: *Self) callconv(.c) void {
        _ = self.cycleSidebarMode();
    }

    fn sidebarDragBegin(
        _: *gtk.GestureDrag,
        x: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        self.private().sidebar_drag_grab_x = x;
    }

    fn sidebarDragUpdate(
        gesture: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.sidebar_mode != .expanded) return;

        // Use the pointer position in the (non-moving) layout box rather
        // than the drag offset, because the handle moves as we resize.
        var hx: f64 = 0;
        var hy: f64 = 0;
        if (gesture.as(gtk.Gesture).getPoint(null, &hx, &hy) == 0) return;
        var lx: f64 = 0;
        var ly: f64 = 0;
        if (priv.sidebar_handle.as(gtk.Widget).translateCoordinates(
            priv.sidebar_layout.as(gtk.Widget),
            hx,
            hy,
            &lx,
            &ly,
        ) == 0) return;

        const handle_left = lx - priv.sidebar_drag_grab_x;
        const width: f64 = if (self.sidebarOnRight()) width: {
            const layout_width: f64 = @floatFromInt(priv.sidebar_layout.as(gtk.Widget).getWidth());
            const handle_width: f64 = @floatFromInt(priv.sidebar_handle.as(gtk.Widget).getWidth());
            break :width layout_width - handle_left - handle_width;
        } else handle_left;

        priv.sidebar_width = clampSidebarWidth(@intFromFloat(@round(width)));
        self.showSidebarGuide();
    }

    /// Position the drag guide line at the pending sidebar edge.
    fn showSidebarGuide(self: *Self) void {
        const priv = self.private();
        const guide = priv.sidebar_guide.as(gtk.Widget);
        const handle_width = priv.sidebar_handle.as(gtk.Widget).getWidth();
        const x: c_int = if (self.sidebarOnRight())
            priv.sidebar_layout.as(gtk.Widget).getWidth() - priv.sidebar_width - handle_width
        else
            priv.sidebar_width;
        guide.setMarginStart(@max(0, x));
        guide.setVisible(1);
    }

    fn sidebarDragEnd(
        _: *gtk.GestureDrag,
        _: f64,
        _: f64,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.sidebar_guide.as(gtk.Widget).setVisible(0);
        if (priv.sidebar_mode != .expanded) return;

        // Resize the terminal once, now that the drag is done.
        priv.sidebar.as(gtk.Widget).setSizeRequest(priv.sidebar_width, -1);
        self.saveSidebarState();
    }

    /// Resolve the page a tab color action applies to and set it.
    fn applyTabColor(page_: ?*adw.TabPage, param_: ?*glib.Variant) void {
        const page = page_ orelse return;
        const param = param_ orelse return;
        const tab = gobject.ext.cast(Tab, page.getChild()) orelse return;

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const name = std.mem.span(str orelse return);
        if (tab_sidebar_row.isTabColor(name)) {
            tab.setColor(name);
        } else {
            tab.setColor(null);
        }
    }

    fn actionSetTabColor(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        applyTabColor(priv.context_menu_page orelse priv.tab_view.getSelectedPage(), param_);
    }

    fn actionSetActiveTabColor(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        applyTabColor(self.private().tab_view.getSelectedPage(), param_);
    }

    fn actionCycleTabSidebar(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        _ = self.cycleSidebarMode();
    }

    fn actionSidebarTheme(
        action: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse return;
        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const theme = std.meta.stringToEnum(
            SidebarTheme,
            std.mem.span(str orelse return),
        ) orelse return;

        self.private().sidebar_theme = theme;
        action.setState(param);
        self.syncSidebar();
        self.saveSidebarState();
    }

    fn actionSidebarAccent(
        action: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const param = param_ orelse return;
        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        const color = sidebar_state.parseHex(std.mem.span(str orelse return)) orelse return;
        self.private().sidebar_accent = color;
        action.setState(param);
        self.syncSidebar();
        self.saveSidebarState();
    }

    fn actionSidebarGlass(
        action: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.sidebar_glass = !priv.sidebar_glass;
        action.setState(glib.Variant.newBoolean(@intFromBool(priv.sidebar_glass)));
        self.syncSidebar();
        self.saveSidebarState();
    }

    fn actionSidebarShowPaths(
        action: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        priv.sidebar_show_paths = !priv.sidebar_show_paths;
        action.setState(glib.Variant.newBoolean(@intFromBool(priv.sidebar_show_paths)));
        self.queueSidebarRebuild();
        self.saveSidebarState();
    }

    /// The page a tab action applies to: the right-clicked tab, or the
    /// selected tab when used from the main menu.
    fn actionPage(self: *Self) ?*adw.TabPage {
        const priv = self.private();
        return priv.context_menu_page orelse priv.tab_view.getSelectedPage();
    }

    fn variantString(param_: ?*glib.Variant) ?[:0]const u8 {
        const param = param_ orelse return null;
        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);
        return std.mem.span(str orelse return null);
    }

    fn actionTogglePinTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page = self.actionPage() orelse return;
        const pin = page.getPinned() == 0;
        // Pinned tabs live in their own section, outside any group.
        if (pin) if (pageTab(page)) |tab| tab.setGroup(null);
        self.private().tab_view.setPagePinned(page, @intFromBool(pin));
        self.queueSidebarRebuild();
    }

    fn actionSetTabGroup(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page = self.actionPage() orelse return;
        const name = variantString(param_) orelse return;
        self.moveTabToGroup(page, if (name.len == 0) null else name);
    }

    fn clearGroupDialog(self: *Self) void {
        const priv = self.private();
        if (priv.group_dialog_page) |p| p.unref();
        priv.group_dialog_page = null;
        if (priv.group_dialog_rename) |v| Application.default().allocator().free(v);
        priv.group_dialog_rename = null;
    }

    fn actionNewTabGroup(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const page = self.actionPage() orelse return;
        self.clearGroupDialog();
        self.private().group_dialog_page = @ptrCast(page.as(gobject.Object).ref());
        self.presentGroupDialog(null);
    }

    fn actionRenameTabGroup(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = variantString(param_) orelse return;
        self.clearGroupDialog();
        self.private().group_dialog_rename =
            Application.default().allocator().dupeZ(u8, name) catch return;
        self.presentGroupDialog(name);
    }

    fn presentGroupDialog(self: *Self, initial: ?[:0]const u8) void {
        const dialog = TitleDialog.new(.group, initial);
        _ = TitleDialog.signals.set.connect(dialog, *Self, groupDialogSet, self, .{});
        dialog.present(self.as(gtk.Widget));
    }

    fn groupDialogSet(_: *TitleDialog, title_ptr: [*:0]const u8, self: *Self) callconv(.c) void {
        defer self.clearGroupDialog();
        const priv = self.private();
        const name = std.mem.trim(u8, std.mem.span(title_ptr), " \t");
        if (name.len == 0) return;
        const alloc = Application.default().allocator();
        const owned = alloc.dupeZ(u8, name) catch return;
        defer alloc.free(owned);

        if (priv.group_dialog_page) |page| {
            self.moveTabToGroup(page, owned);
            return;
        }

        if (priv.group_dialog_rename) |old| {
            const was_collapsed = self.isGroupCollapsed(old);
            self.setGroupCollapsed(old, false);
            var i: c_int = 0;
            while (i < priv.tab_view.getNPages()) : (i += 1) {
                const page = priv.tab_view.getNthPage(i);
                if (!eqlGroup(pageGroup(page), old)) continue;
                if (pageTab(page)) |tab| tab.setGroup(owned);
            }
            if (was_collapsed) self.setGroupCollapsed(owned, true);
            self.queueSidebarRebuild();
        }
    }

    fn actionUngroupTabGroup(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = variantString(param_) orelse return;
        const priv = self.private();
        self.setGroupCollapsed(name, false);
        var i: c_int = 0;
        while (i < priv.tab_view.getNPages()) : (i += 1) {
            const page = priv.tab_view.getNthPage(i);
            if (!eqlGroup(pageGroup(page), name)) continue;
            if (pageTab(page)) |tab| tab.setGroup(null);
        }
        self.queueSidebarRebuild();
    }

    fn actionCloseTabGroup(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = variantString(param_) orelse return;
        const priv = self.private();
        // Collect first: closing changes the page list.
        var pages: [256]*adw.TabPage = undefined;
        var n: usize = 0;
        var i: c_int = 0;
        while (i < priv.tab_view.getNPages() and n < pages.len) : (i += 1) {
            const page = priv.tab_view.getNthPage(i);
            if (!eqlGroup(pageGroup(page), name)) continue;
            pages[n] = page;
            n += 1;
        }
        for (pages[0..n]) |page| priv.tab_view.closePage(page);
    }

    fn getTabsWide(self: *Self) bool {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return true;
        return config.@"gtk-wide-tabs";
    }

    fn getToolbarStyle(self: *Self) adw.ToolbarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .raised;
        return switch (config.@"gtk-toolbar-style") {
            .flat => .flat,
            .raised => .raised,
            .@"raised-border" => .raised_border,
        };
    }

    fn getTitlebarStyle(self: *Self) TitlebarStyle {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return .native;
        return config.@"gtk-titlebar-style";
    }

    fn propConfig(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.config) |config_obj| {
            const config = config_obj.get();
            if (config.@"app-notifications".@"config-reload") {
                self.addToast(i18n._("Reloaded the configuration"));
            }
        }

        self.syncAppearance();
    }

    fn propGdkSurfaceHeight(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propIsActive(
        _: *gtk.Window,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Hide quick-terminal if set to autohide
        if (self.isQuickTerminal()) {
            if (self.getConfig()) |cfg| {
                if (cfg.get().@"quick-terminal-autohide" and self.as(gtk.Window).isActive() == 0) {
                    self.toggleVisibility();
                }
            }
        }

        // Don't change urgency if we're not the active window.
        if (self.as(gtk.Window).isActive() == 0) return;

        self.winproto().setUrgent(false) catch |err| {
            log.warn(
                "winproto failed to reset urgency={}",
                .{err},
            );
        };
    }

    fn propGdkSurfaceWidth(
        _: *gdk.Surface,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // X11 needs to fix blurring on resize, but winproto implementations
        // could do anything.
        self.private().winproto.resizeEvent() catch |err| {
            log.warn(
                "winproto resize event failed error={}",
                .{err},
            );
        };
    }

    fn propFullscreened(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMaximized(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        self.syncAppearance();
    }

    fn propMenuActive(
        button: *gtk.MenuButton,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // Debian 12 is stuck on GTK 4.8
        if (!gtk_version.atLeast(4, 10, 0)) return;

        // We only care if we're activating. If we're activating then
        // we need to check the validity of our menu items.
        const active = button.getActive() != 0;
        if (!active) return;

        self.syncActions();
    }

    fn propQuickTerminal(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        if (priv.surface_init) {
            log.warn("quick terminal property can't be changed after surfaces have been initialized", .{});
            return;
        }

        if (priv.quick_terminal) {
            // Initialize the quick terminal at the app-layer
            Application.default().winproto().initQuickTerminal(self) catch |err| {
                log.warn("failed to initialize quick terminal error={}", .{err});
                return;
            };
        }
    }

    fn propScaleFactor(
        _: *adw.ApplicationWindow,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // On some platforms (namely X11) we need to refresh our appearance when
        // the scale factor changes. In theory this could be more fine-grained as
        // a full refresh could be expensive, but a) this *should* be rare, and
        // b) quite noticeable visual bugs would occur if this is not present.
        self.private().winproto.syncAppearance() catch |err| {
            log.warn(
                "failed to sync appearance after scale factor has been updated={}",
                .{err},
            );
            return;
        };
    }

    fn closureTitlebarStyleIsTab(
        _: *Self,
        value: TitlebarStyle,
    ) callconv(.c) c_int {
        return @intFromBool(switch (value) {
            .native => false,
            .tabs => true,
        });
    }

    fn closureSubtitle(
        _: *Self,
        config_: ?*Config,
        pwd_: ?[*:0]const u8,
    ) callconv(.c) ?[*:0]const u8 {
        const config = if (config_) |v| v.get() else return null;
        return switch (config.@"window-subtitle") {
            .false => null,
            .@"working-directory" => pwd: {
                const pwd = pwd_ orelse return null;
                break :pwd glib.ext.dupeZ(u8, std.mem.span(pwd));
            },
        };
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();

        priv.command_palette.set(null);

        if (priv.sidebar_rebuild_source) |source| {
            _ = glib.Source.remove(source);
            priv.sidebar_rebuild_source = null;
        }
        self.clearGroupDialog();

        if (priv.config) |v| {
            v.unref();
            priv.config = null;
        }

        priv.tab_bindings.setSource(null);

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
        priv.tab_bindings.unref();
        priv.winproto.deinit(Application.default().allocator());
        {
            const alloc = Application.default().allocator();
            for (priv.collapsed_groups.items) |g| alloc.free(g);
            priv.collapsed_groups.deinit(alloc);
        }

        gobject.Object.virtual_methods.finalize.call(
            Class.parent,
            self.as(Parent),
        );
    }

    //---------------------------------------------------------------
    // Signal handlers

    fn windowRealize(_: *gtk.Widget, self: *Window) callconv(.c) void {
        const app = Application.default();

        // Initialize our window protocol logic
        if (winprotopkg.Window.init(
            app.allocator(),
            app.winproto(),
            self,
        )) |wp| {
            self.private().winproto = wp;
        } else |err| {
            log.warn("failed to initialize window protocol error={}", .{err});
            return;
        }

        // We need to setup resize notifications on our surface,
        // which is only available after the window had been realized.
        if (self.as(gtk.Native).getSurface()) |gdk_surface| {
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceWidth,
                self,
                .{ .detail = "width" },
            );
            _ = gobject.Object.signals.notify.connect(
                gdk_surface,
                *Self,
                propGdkSurfaceHeight,
                self,
                .{ .detail = "height" },
            );
        }

        // When we are realized we always setup our appearance since this
        // calls some winproto functions.
        self.syncAppearance();
    }

    fn btnNewTab(_: *adw.SplitButton, self: *Self) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn tabOverviewCreateTab(
        _: *adw.TabOverview,
        self: *Self,
    ) callconv(.c) *adw.TabPage {
        return self.newTabPage(if (self.getActiveSurface()) |v| v.core() else null, .tab, .none);
    }

    fn tabOverviewOpen(
        tab_overview: *adw.TabOverview,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        // We only care about when the tab overview is closed.
        if (tab_overview.getOpen() != 0) return;

        // On tab overview close, focus is sometimes lost. This is an
        // upstream issue in libadwaita[1]. When this is resolved we
        // can put a runtime version check here to avoid this workaround.
        //
        // Our workaround is to start a timer after 500ms to refocus
        // the currently selected tab. We choose 500ms because the adw
        // animation is 400ms.
        //
        // [1]: https://gitlab.gnome.org/GNOME/libadwaita/-/issues/670

        // If we have an old timer remove it
        const priv = self.private();
        if (priv.tab_overview_focus_timer) |timer| {
            _ = glib.Source.remove(timer);
        }

        // Restart our timer
        priv.tab_overview_focus_timer = glib.timeoutAdd(
            500,
            tabOverviewFocusTimer,
            self,
        );
    }

    fn tabOverviewFocusTimer(
        ud: ?*anyopaque,
    ) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));

        // Always note our timer is removed
        self.private().tab_overview_focus_timer = null;

        // Get our currently active surface which should respect the newly
        // selected tab. Grab focus.
        const surface = self.getActiveSurface() orelse return 0;
        surface.grabFocus();

        // Remove the timer
        return 0;
    }

    fn windowCloseRequest(
        _: *gtk.Window,
        self: *Self,
    ) callconv(.c) c_int {
        if (self.getNeedsConfirmQuit()) {
            // Show a confirmation dialog
            const dialog: *CloseConfirmationDialog = .new(.window);
            _ = CloseConfirmationDialog.signals.@"close-request".connect(
                dialog,
                *Self,
                closeConfirmationClose,
                self,
                .{},
            );

            // Show it
            dialog.present(self.as(gtk.Widget));
            return @intFromBool(true);
        }

        self.as(gtk.Window).destroy();
        return @intFromBool(false);
    }

    fn closeConfirmationClose(
        _: *CloseConfirmationDialog,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).destroy();
    }

    fn closeConfirmationCloseTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(true));
    }

    fn closeConfirmationCancelTab(
        _: *CloseConfirmationDialog,
        page: *adw.TabPage,
    ) callconv(.c) void {
        const tab_view = ext.getAncestor(
            adw.TabView,
            page.getChild().as(gtk.Widget),
        ) orelse {
            log.warn("close confirmation called for non-existent page", .{});
            return;
        };
        tab_view.closePageFinish(page, @intFromBool(false));
    }

    fn tabViewClosePage(
        _: *adw.TabView,
        page: *adw.TabPage,
        self: *Self,
    ) callconv(.c) c_int {
        const priv = self.private();
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse
            return @intFromBool(false);

        // If the tab says it doesn't need confirmation then we go ahead
        // and close immediately.
        if (!tab.getNeedsConfirmQuit()) {
            priv.tab_view.closePageFinish(page, @intFromBool(true));
            return @intFromBool(true);
        }

        // Show a confirmation dialog
        const dialog: *CloseConfirmationDialog = .new(.tab);
        _ = CloseConfirmationDialog.signals.@"close-request".connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCloseTab,
            page,
            .{},
        );
        _ = CloseConfirmationDialog.signals.cancel.connect(
            dialog,
            *adw.TabPage,
            closeConfirmationCancelTab,
            page,
            .{},
        );

        // Show it
        dialog.present(child);
        return @intFromBool(true);
    }

    fn tabViewSelectedPage(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Always reset our binding source in case we have no pages.
        priv.tab_bindings.setSource(null);

        // Get our current page which MUST be a Tab object.
        const page = priv.tab_view.getSelectedPage() orelse return;
        const child = page.getChild();
        assert(gobject.ext.isA(child, Tab));

        // Setup our binding group. This ensures things like the title
        // are synced from the active tab.
        priv.tab_bindings.setSource(child.as(gobject.Object));

        // If the tab was previously marked as needing attention
        // (e.g. due to a bell character), we now unmark that
        page.setNeedsAttention(@intFromBool(false));

        self.updateSidebarSelection();
    }

    fn tabViewPageReordered(
        _: *adw.TabView,
        _: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        self.queueSidebarRebuild();
    }

    fn tabViewPageAttached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // Get the attached page which must be a Tab object.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;

        // Attach listeners for the tab.
        _ = Tab.signals.@"close-request".connect(
            tab,
            *Self,
            tabCloseRequest,
            self,
            .{},
        );

        // Attach listeners for the surface.
        //
        // Interesting behavior here that was previously undocumented but
        // I'm going to make it explicit here: we accept all the signals here
        // (like toggle-fullscreen) regardless of whether the surface or tab
        // is focused. At the time of writing this we have no API that could
        // really trigger these that way but its theoretically possible.
        //
        // What is DEFINITELY possible is something like OSC52 triggering
        // a clipboard-write signal on an unfocused tab/surface. We definitely
        // want to show the user a notification about that but our notification
        // right now is a toast that doesn't make it clear WHO used the
        // clipboard. We probably want to change that in the future.
        //
        // I'm not sure how desirable all the above is, and we probably
        // should be thoughtful about future signals here. But all of this
        // behavior is consistent with macOS and the previous GTK apprt,
        // but that behavior was all implicit and not documented, so here
        // I am.
        if (tab.getSurfaceTree()) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn tabViewPageDetached(
        _: *adw.TabView,
        page: *adw.TabPage,
        _: c_int,
        self: *Self,
    ) callconv(.c) void {
        // We need to get the tab to disconnect the signals.
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        _ = gobject.signalHandlersDisconnectMatched(
            tab.as(gobject.Object),
            .{ .data = true },
            0,
            0,
            null,
            null,
            self,
        );

        // Remove the tree handlers
        if (tab.getSurfaceTree()) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }
    }

    fn tabViewCreateWindow(
        _: *adw.TabView,
        _: *Self,
    ) callconv(.c) *adw.TabView {
        // Create a new window without creating a new tab.
        const win = gobject.ext.newInstance(
            Self,
            .{
                .application = Application.default(),
            },
        );

        // We have to show it otherwise it'll just be hidden.
        gtk.Window.present(win.as(gtk.Window));

        // Get our tab view
        return win.private().tab_view;
    }

    fn tabCloseRequest(
        tab: *Tab,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.tab_view.getPage(tab.as(gtk.Widget));
        // TODO: connect close page handler to tab to check for confirmation
        priv.tab_view.closePage(page);
    }

    fn tabViewNPages(
        _: *adw.TabView,
        _: *gobject.ParamSpec,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        self.queueSidebarRebuild();
        if (priv.tab_view.getNPages() == 0) {
            // If we have no pages left then we want to close window.

            // If the tab overview is open, then we don't close the window
            // because its a rather abrupt experience. This also fixes an
            // issue where dragging out the last tab in the tab overview
            // won't cause Ghostty to exit.
            if (priv.tab_overview.getOpen() != 0) return;

            self.as(gtk.Window).close();
        }
    }
    fn setupTabMenu(
        _: *adw.TabView,
        page: ?*adw.TabPage,
        self: *Self,
    ) callconv(.c) void {
        self.private().context_menu_page = page;
    }

    fn surfaceClipboardWrite(
        _: *Surface,
        clipboard_type: apprt.Clipboard,
        text: [*:0]const u8,
        self: *Self,
    ) callconv(.c) void {
        // We only toast for the standard clipboard.
        if (clipboard_type != .standard) return;

        // We only toast if configured to
        const priv = self.private();
        const config_obj = priv.config orelse return;
        const config = config_obj.get();
        if (!config.@"app-notifications".@"clipboard-copy") {
            return;
        }

        if (text[0] != 0)
            self.addToast(i18n._("Copied to clipboard"))
        else
            self.addToast(i18n._("Cleared clipboard"));
    }

    fn surfaceMenu(
        _: *Surface,
        self: *Self,
    ) callconv(.c) void {
        self.syncActions();
    }

    fn surfacePresentRequest(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        // Verify that this surface is actually in this window.
        {
            const surface_window = ext.getAncestor(
                Self,
                surface.as(gtk.Widget),
            ) orelse {
                log.warn(
                    "present request called for non-existent surface",
                    .{},
                );
                return;
            };
            if (surface_window != self) {
                log.warn(
                    "present request called for surface in different window",
                    .{},
                );
                return;
            }
        }

        // Get the tab for this surface.
        const tab = ext.getAncestor(
            Tab,
            surface.as(gtk.Widget),
        ) orelse {
            log.warn("present request surface not found", .{});
            return;
        };

        // Get the page that contains this tab
        const priv = self.private();
        const tab_view = priv.tab_view;
        const page = tab_view.getPage(tab.as(gtk.Widget));
        tab_view.setSelectedPage(page);

        // Grab focus
        surface.grabFocus();

        // Bring the window to the front.
        self.as(gtk.Window).present();
    }

    fn surfaceToggleFullscreen(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isFullscreen() != 0) {
            self.as(gtk.Window).unfullscreen();
        } else {
            self.as(gtk.Window).fullscreen();
        }

        // We react to the changes in the propFullscreen callback
    }

    fn surfaceToggleMaximize(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        _ = surface;
        if (self.as(gtk.Window).isMaximized() != 0) {
            self.as(gtk.Window).unmaximize();
        } else {
            self.as(gtk.Window).maximize();
        }

        // We react to the changes in the propMaximized callback
    }

    fn surfaceInit(
        surface: *Surface,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();

        // Make sure we init only once
        if (priv.surface_init) return;
        priv.surface_init = true;

        // Setup our default and minimum size.
        if (surface.getDefaultSize()) |size| {
            self.as(gtk.Window).setDefaultSize(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
        if (surface.getMinSize()) |size| {
            self.as(gtk.Widget).setSizeRequest(
                @intCast(size.width),
                @intCast(size.height),
            );
        }
    }

    fn tabSplitTreeChanged(
        _: *SplitTree,
        old_tree: ?*const Surface.Tree,
        new_tree: ?*const Surface.Tree,
        self: *Self,
    ) callconv(.c) void {
        if (old_tree) |tree| {
            self.disconnectSurfaceHandlers(tree);
        }

        if (new_tree) |tree| {
            self.connectSurfaceHandlers(tree);
        }
    }

    fn actionAbout(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const name = "Ghostty";
        const icon = "com.mitchellh.ghostty";
        const website = "https://ghostty.org";

        if (adw_version.supportsDialogs()) {
            adw.showAboutDialog(
                self.as(gtk.Widget),
                "application-name",
                name,
                "developer-name",
                i18n._("Ghostty Developers"),
                "application-icon",
                icon,
                "version",
                build_config.version_string.ptr,
                "issue-url",
                "https://github.com/ghostty-org/ghostty/issues",
                "website",
                website,
                @as(?*anyopaque, null),
            );
        } else {
            gtk.showAboutDialog(
                self.as(gtk.Window),
                "program-name",
                name,
                "logo-icon-name",
                icon,
                "title",
                i18n._("About Ghostty"),
                "version",
                build_config.version_string.ptr,
                "website",
                website,
                @as(?*anyopaque, null),
            );
        }
    }

    fn actionClose(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        self.as(gtk.Window).close();
    }

    fn actionCloseTab(
        _: *gio.SimpleAction,
        param_: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const param = param_ orelse {
            log.warn("win.close-tab called without a parameter", .{});
            return;
        };

        var str: ?[*:0]const u8 = null;
        param.get("&s", &str);

        const mode = std.meta.stringToEnum(
            input.Binding.Action.CloseTabMode,
            std.mem.span(
                str orelse {
                    log.warn("invalid mode provided to win.close-tab", .{});
                    return;
                },
            ),
        ) orelse {
            log.warn("invalid mode provided to win.close-tab: {s}", .{str.?});
            return;
        };

        self.performBindingAction(.{ .close_tab = mode });
    }

    fn actionNewWindow(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_window);
    }

    fn actionNewTab(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.new_tab);
    }

    fn actionPromptContextTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Self,
    ) callconv(.c) void {
        const priv = self.private();
        const page = priv.context_menu_page orelse return;
        const child = page.getChild();
        const tab = gobject.ext.cast(Tab, child) orelse return;
        tab.promptTabTitle();
    }

    fn actionPromptSurfaceTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_surface_title);
    }

    fn actionPromptTabTitle(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.prompt_tab_title);
    }

    fn actionSplitRight(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .right });
    }

    fn actionSplitLeft(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .left });
    }

    fn actionSplitUp(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .up });
    }

    fn actionSplitDown(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .new_split = .down });
    }

    fn actionCopy(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.{ .copy_to_clipboard = .mixed });
    }

    fn actionPaste(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.paste_from_clipboard);
    }

    fn actionReset(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.reset);
    }

    fn actionClear(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        self.performBindingAction(.clear_screen);
    }

    fn actionRingBell(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        const priv = self.private();
        const config = if (priv.config) |v| v.get() else return;

        if (config.@"bell-features".system) system: {
            const native = self.as(gtk.Native).getSurface() orelse {
                log.warn("unable to get native surface from window", .{});
                break :system;
            };
            native.beep();
        }

        if (config.@"bell-features".attention) attention: {
            // Dont set urgency if the window is already active.
            if (self.as(gtk.Window).isActive() != 0) break :attention;

            // Request user attention
            self.winproto().setUrgent(true) catch |err| {
                log.warn("winproto failed to set urgency={}", .{err});
            };
        }
    }

    /// Toggle the command palette.
    ///
    /// TODO: accept the surface that toggled the command palette as a parameter
    fn toggleCommandPalette(self: *Window) void {
        const priv = self.private();

        // Get a reference to a command palette. First check the weak reference
        // that we save to see if we already have one stored. If we don't then
        // create a new one.
        const command_palette = priv.command_palette.get() orelse command_palette: {
            // Create a fresh command palette.
            const command_palette = CommandPalette.new();

            // Synchronize our config to the command palette's config.
            _ = gobject.Object.bindProperty(
                self.as(gobject.Object),
                "config",
                command_palette.as(gobject.Object),
                "config",
                .{ .sync_create = true },
            );

            // Listen to the activate signal to know if the user selected an option in
            // the command palette.
            _ = CommandPalette.signals.trigger.connect(
                command_palette,
                *Window,
                signalCommandPaletteTrigger,
                self,
                .{},
            );

            // Save a weak reference to the command palette. We use a weak reference to avoid
            // reference counting cycles that might cause problems later.
            priv.command_palette.set(command_palette);

            break :command_palette command_palette;
        };
        defer command_palette.unref();

        // Tell the command palette to toggle itself. If the dialog gets
        // presented (instead of hidden) it will be modal over our window.
        command_palette.toggle(self);
    }

    // React to a signal from a command palette asking an action to be performed.
    fn signalCommandPaletteTrigger(_: *CommandPalette, action: *const input.Binding.Action, self: *Self) callconv(.c) void {
        // If the activation actually has an action, perform it.
        self.performBindingAction(action.*);
    }

    /// React to a GTK action requesting that the command palette be toggled.
    fn actionToggleCommandPalette(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleCommandPalette();
    }

    /// Toggle the Ghostty inspector for the active surface.
    fn toggleInspector(self: *Self) void {
        const surface = self.getActiveSurface() orelse return;
        _ = surface.controlInspector(.toggle);
    }

    /// React to a GTK action requesting that the Ghostty inspector be toggled.
    fn actionToggleInspector(
        _: *gio.SimpleAction,
        _: ?*glib.Variant,
        self: *Window,
    ) callconv(.c) void {
        // TODO: accept the surface that toggled the command palette as a
        // parameter
        self.toggleInspector();
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
            gobject.ext.ensureType(DebugWarning);
            gobject.ext.ensureType(SplitTree);
            gobject.ext.ensureType(Surface);
            gobject.ext.ensureType(Tab);
            gobject.ext.ensureType(TabSidebarRow);
            gtk.Widget.Class.setTemplateFromResource(
                class.as(gtk.Widget.Class),
                comptime gresource.blueprint(.{
                    .major = 1,
                    .minor = 5,
                    .name = "window",
                }),
            );

            // Properties
            gobject.ext.registerProperties(class, &.{
                properties.@"active-surface".impl,
                properties.config.impl,
                properties.debug.impl,
                properties.@"headerbar-visible".impl,
                properties.@"quick-terminal".impl,
                properties.@"tabs-autohide".impl,
                properties.@"tabs-visible".impl,
                properties.@"tabs-wide".impl,
                properties.@"sidebar-visible".impl,
                properties.@"sidebar-compact".impl,
                properties.@"sidebar-resizable".impl,
                properties.@"toolbar-style".impl,
                properties.@"titlebar-style".impl,
            });

            // Bindings
            class.bindTemplateChildPrivate("tab_overview", .{});
            class.bindTemplateChildPrivate("tab_bar", .{});
            class.bindTemplateChildPrivate("tab_view", .{});
            class.bindTemplateChildPrivate("toolbar", .{});
            class.bindTemplateChildPrivate("toast_overlay", .{});
            class.bindTemplateChildPrivate("sidebar_layout", .{});
            class.bindTemplateChildPrivate("sidebar_revealer", .{});
            class.bindTemplateChildPrivate("sidebar", .{});
            class.bindTemplateChildPrivate("sidebar_handle", .{});
            class.bindTemplateChildPrivate("sidebar_content", .{});
            class.bindTemplateChildPrivate("sidebar_guide", .{});
            class.bindTemplateChildPrivate("sidebar_list", .{});
            class.bindTemplateChildPrivate("tab_context_menu", .{});

            // Template Callbacks
            class.bindTemplateCallback("cycle_sidebar", &btnCycleSidebar);
            class.bindTemplateCallback("sidebar_drag_begin", &sidebarDragBegin);
            class.bindTemplateCallback("sidebar_drag_update", &sidebarDragUpdate);
            class.bindTemplateCallback("sidebar_drag_end", &sidebarDragEnd);
            class.bindTemplateCallback("page_reordered", &tabViewPageReordered);
            class.bindTemplateCallback("realize", &windowRealize);
            class.bindTemplateCallback("new_tab", &btnNewTab);
            class.bindTemplateCallback("overview_create_tab", &tabOverviewCreateTab);
            class.bindTemplateCallback("overview_notify_open", &tabOverviewOpen);
            class.bindTemplateCallback("close_request", &windowCloseRequest);
            class.bindTemplateCallback("close_page", &tabViewClosePage);
            class.bindTemplateCallback("page_attached", &tabViewPageAttached);
            class.bindTemplateCallback("page_detached", &tabViewPageDetached);
            class.bindTemplateCallback("setup_tab_menu", &setupTabMenu);
            class.bindTemplateCallback("tab_create_window", &tabViewCreateWindow);
            class.bindTemplateCallback("notify_n_pages", &tabViewNPages);
            class.bindTemplateCallback("notify_selected_page", &tabViewSelectedPage);
            class.bindTemplateCallback("notify_config", &propConfig);
            class.bindTemplateCallback("notify_fullscreened", &propFullscreened);
            class.bindTemplateCallback("notify_is_active", &propIsActive);
            class.bindTemplateCallback("notify_maximized", &propMaximized);
            class.bindTemplateCallback("notify_menu_active", &propMenuActive);
            class.bindTemplateCallback("notify_quick_terminal", &propQuickTerminal);
            class.bindTemplateCallback("notify_scale_factor", &propScaleFactor);
            class.bindTemplateCallback("titlebar_style_is_tabs", &closureTitlebarStyleIsTab);
            class.bindTemplateCallback("computed_subtitle", &closureSubtitle);

            // Virtual methods
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
        pub const bindTemplateChildPrivate = C.Class.bindTemplateChildPrivate;
        pub const bindTemplateCallback = C.Class.bindTemplateCallback;
    };
};
