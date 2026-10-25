//! Document explorer panel shown beside the terminal. Lists the active
//! tab's working directory as a tree, filtered to documents (Markdown, PDF,
//! HTML). Markdown files preview inside the panel in a WebKitGTK view
//! (src/markdown-preview: GFM, footnotes, math, code highlighting, Mermaid);
//! other files open in the default app. The web view is created on the
//! first preview and destroyed when the panel closes, so it only uses
//! memory while you're previewing.
//!
//! Performance: folders are read asynchronously by GtkDirectoryList only
//! when expanded, rows are recycled by GtkListView, and changes on disk
//! arrive through file monitors. Nothing is scanned up front, and nothing
//! is loaded while the panel is closed.
const std = @import("std");
const adw = @import("adw");
const gio = @import("gio");
const glib = @import("glib");
const gobject = @import("gobject");
const gtk = @import("gtk");

const Common = @import("../class.zig").Common;
const gdk = @import("gdk");
const webkit = @import("../webkit.zig");
const state = &@import("../../../global.zig").state;

const log = std.log.scoped(.gtk_ghostty_file_explorer);

const attributes = "standard::name,standard::display-name,standard::type,standard::is-hidden,standard::size";

/// Folders that never hold documents worth browsing.
const skipped_dirs = [_][]const u8{
    "node_modules", "target", "__pycache__", "venv", "zig-out", "dist-newstyle",
};

/// Largest Markdown file previewed in the panel; bigger files open externally.
const max_preview_bytes = 4 * 1024 * 1024;

const Kind = enum { dir, markdown, pdf, html, other };

fn kindOf(info: *gio.FileInfo) Kind {
    if (info.getFileType() == .directory) return .dir;
    const name = std.mem.span(info.getName());
    const ext = std.fs.path.extension(name);
    var lower: [16]u8 = undefined;
    if (ext.len == 0 or ext.len > lower.len) return .other;
    const e = std.ascii.lowerString(&lower, ext);
    if (std.mem.eql(u8, e, ".md") or std.mem.eql(u8, e, ".markdown") or std.mem.eql(u8, e, ".mdx")) return .markdown;
    if (std.mem.eql(u8, e, ".pdf")) return .pdf;
    if (std.mem.eql(u8, e, ".html") or std.mem.eql(u8, e, ".htm")) return .html;
    return .other;
}

fn infoFile(info: *gio.FileInfo) ?*gio.File {
    const o = info.getAttributeObject("standard::file") orelse return null;
    return gobject.ext.cast(gio.File, o);
}

pub const FileExplorer = extern struct {
    const Self = @This();
    parent_instance: Parent,
    pub const Parent = adw.Bin;
    pub const getGObjectType = gobject.ext.defineClass(Self, .{
        .name = "GhosttyFileExplorer",
        .instanceInit = &init,
        .classInit = &Class.init,
        .parent_class = &Class.parent,
        .private = .{ .Type = Private, .offset = &Private.offset },
    });

    pub const properties = struct {
        /// Folder to show (the active tab's working directory).
        pub const root = struct {
            pub const name = "root";
            const impl = gobject.ext.defineProperty(
                name,
                Self,
                ?[:0]const u8,
                .{
                    .default = null,
                    .accessor = gobject.ext.typedAccessor(Self, ?[:0]const u8, .{
                        .getter = getRoot,
                        .getter_transfer = .none,
                        .setter = setRoot,
                        .setter_transfer = .full,
                    }),
                },
            );
        };
    };

    const Private = struct {
        /// Requested root (glib-owned string from the property setter).
        root: ?[:0]const u8 = null,
        /// Root currently shown (c_allocator-owned).
        shown_root: ?[:0]u8 = null,
        open: bool = false,
        palette: Palette = .{},

        filter: *gtk.CustomFilter = undefined,
        sorter: *gtk.CustomSorter = undefined,
        root_dir: ?*gtk.DirectoryList = null,
        root_items: ?*gtk.FilterListModel = null,

        stack: *gtk.Stack = undefined,
        list_view: *gtk.ListView = undefined,
        root_label: *gtk.Label = undefined,
        preview_title: *gtk.Label = undefined,
        preview_host: *adw.Bin = undefined,

        /// Web view for the Markdown preview (strong ref), created lazily.
        web_view: ?*gtk.Widget = null,
        /// preview.html finished loading; render calls can run.
        web_ready: bool = false,
        /// A render is waiting for the page to load.
        render_pending: bool = false,
        /// Keep the scroll position on the next render (live reload).
        keep_scroll: bool = false,

        /// Watches the previewed file for live reload.
        monitor: ?*gio.FileMonitor = null,
        reload_source: ?c_uint = null,

        /// File being previewed and its contents (for re-rendering).
        preview_file: ?*gio.File = null,
        preview_text: ?[]u8 = null,

        pub var offset: c_int = 0;
    };

    /// Colors and fonts for the preview, from the sidebar theme.
    pub const Palette = struct {
        dark: bool = true,
        fg: [:0]const u8 = "#e6e6e9",
        muted: [:0]const u8 = "#8c8c95",
        border: [:0]const u8 = "#2b2b30",
        code_bg: [:0]const u8 = "#29292e",
        accent: [3]u8 = .{ 0x4e, 0xa1, 0xff },
        code_font: [64:0]u8 = .{0} ** 64,

        fn eql(a: Palette, b: Palette) bool {
            return a.dark == b.dark and
                std.mem.eql(u8, a.fg, b.fg) and
                std.mem.eql(u8, a.muted, b.muted) and
                std.mem.eql(u8, &a.accent, &b.accent) and
                std.mem.eql(u8, &a.code_font, &b.code_font);
        }
    };

    fn alloc() std.mem.Allocator {
        return std.heap.c_allocator;
    }

    fn init(self: *Self, _: *Class) callconv(.c) void {
        const priv = self.private();
        const widget = self.as(gtk.Widget);
        widget.addCssClass("ghostty-tab-sidebar");
        widget.addCssClass("file-explorer");
        widget.setHexpand(0);

        priv.filter = gtk.CustomFilter.new(filterFunc, null, null);
        priv.sorter = gtk.CustomSorter.new(sortFunc, null, null);

        const box = gtk.Box.new(.vertical, 0);

        // Header: title + close.
        const header = gtk.Box.new(.horizontal, 0);
        header.as(gtk.Widget).addCssClass("sidebar-header");
        const heading = gtk.Label.new("Files");
        heading.as(gtk.Widget).addCssClass("sidebar-heading");
        heading.setXalign(0);
        heading.as(gtk.Widget).setHexpand(1);
        header.append(heading.as(gtk.Widget));
        header.append(iconButton("window-close-symbolic", "Close Files (Ctrl+Shift+M)", "win.toggle-file-explorer"));
        box.append(header.as(gtk.Widget));

        const root_label = gtk.Label.new("");
        root_label.as(gtk.Widget).addCssClass("explorer-root");
        root_label.setXalign(0);
        root_label.setEllipsize(.start);
        root_label.setMaxWidthChars(1);
        priv.root_label = root_label;
        box.append(root_label.as(gtk.Widget));

        const stack = gtk.Stack.new();
        stack.as(gtk.Widget).setVexpand(1);
        priv.stack = stack;

        // Page: tree.
        const factory = gtk.SignalListItemFactory.new();
        _ = gtk.SignalListItemFactory.signals.setup.connect(factory, *Self, rowSetup, self, .{});
        _ = gtk.SignalListItemFactory.signals.bind.connect(factory, *Self, rowBind, self, .{});
        const list_view = gtk.ListView.new(null, factory.as(gtk.ListItemFactory));
        list_view.setSingleClickActivate(1);
        list_view.as(gtk.Widget).addCssClass("explorer-list");
        _ = gtk.ListView.signals.activate.connect(list_view, *Self, rowActivated, self, .{});
        priv.list_view = list_view;
        const list_scroller = gtk.ScrolledWindow.new();
        list_scroller.setPolicy(.never, .automatic);
        list_scroller.setChild(list_view.as(gtk.Widget));
        _ = stack.addNamed(list_scroller.as(gtk.Widget), "list");

        // Page: empty folder.
        const empty = gtk.Label.new("No Markdown, PDF or HTML files here");
        empty.as(gtk.Widget).addCssClass("explorer-empty");
        empty.setWrap(1);
        empty.setJustify(.center);
        _ = stack.addNamed(empty.as(gtk.Widget), "empty");

        // Page: Markdown preview.
        const preview = gtk.Box.new(.vertical, 0);
        const pheader = gtk.Box.new(.horizontal, 4);
        pheader.as(gtk.Widget).addCssClass("preview-header");
        const back = gtk.Button.newFromIconName("go-previous-symbolic");
        back.as(gtk.Widget).addCssClass("flat");
        back.as(gtk.Widget).addCssClass("sidebar-collapse");
        back.as(gtk.Widget).setTooltipText("Back to files");
        back.as(gtk.Widget).setFocusOnClick(0);
        _ = gtk.Button.signals.clicked.connect(back, *Self, backClicked, self, .{});
        pheader.append(back.as(gtk.Widget));
        const ptitle = gtk.Label.new("");
        ptitle.as(gtk.Widget).addCssClass("preview-title");
        ptitle.setXalign(0);
        ptitle.setEllipsize(.middle);
        ptitle.setMaxWidthChars(1);
        ptitle.as(gtk.Widget).setHexpand(1);
        priv.preview_title = ptitle;
        pheader.append(ptitle.as(gtk.Widget));
        const ext_btn = gtk.Button.newFromIconName("document-open-symbolic");
        ext_btn.as(gtk.Widget).addCssClass("flat");
        ext_btn.as(gtk.Widget).addCssClass("sidebar-collapse");
        ext_btn.as(gtk.Widget).setTooltipText("Open in default app");
        ext_btn.as(gtk.Widget).setFocusOnClick(0);
        _ = gtk.Button.signals.clicked.connect(ext_btn, *Self, openExternalClicked, self, .{});
        pheader.append(ext_btn.as(gtk.Widget));
        preview.append(pheader.as(gtk.Widget));

        const host = adw.Bin.new();
        host.as(gtk.Widget).setVexpand(1);
        host.as(gtk.Widget).addCssClass("markdown-preview");
        priv.preview_host = host;
        preview.append(host.as(gtk.Widget));
        _ = stack.addNamed(preview.as(gtk.Widget), "preview");

        box.append(stack.as(gtk.Widget));
        self.as(adw.Bin).setChild(box.as(gtk.Widget));
    }

    fn iconButton(icon: [:0]const u8, tooltip: [:0]const u8, action: [:0]const u8) *gtk.Widget {
        const b = gtk.Button.newFromIconName(icon.ptr);
        const w = b.as(gtk.Widget);
        w.addCssClass("flat");
        w.addCssClass("sidebar-collapse");
        w.setTooltipText(tooltip.ptr);
        w.setFocusOnClick(0);
        w.setCanFocus(0);
        b.as(gtk.Actionable).setActionName(action.ptr);
        return w;
    }

    //---------------------------------------------------------------
    // Public API

    /// Open or close. While closed nothing is read from disk.
    pub fn setOpen(self: *Self, open: bool) void {
        const priv = self.private();
        if (priv.open == open) return;
        priv.open = open;
        if (open) {
            self.applyRoot();
            if (priv.preview_file) |f| if (std.mem.eql(u8, std.mem.span(priv.stack.getVisibleChildName() orelse ""), "preview")) {
                self.ensureWebView();
                self.loadPreview(f, true);
            };
        } else {
            // Free the web engine while the panel is closed.
            self.stopMonitor();
            self.destroyWebView();
        }
    }

    /// Colors used by the Markdown preview. Re-renders an open preview.
    pub fn setStyle(self: *Self, palette: Palette) void {
        const priv = self.private();
        if (priv.palette.eql(palette)) return;
        priv.palette = palette;
        if (priv.preview_text != null) {
            priv.keep_scroll = true;
            self.requestRender();
        }
    }

    fn getRoot(self: *Self) ?[:0]const u8 {
        return self.private().root;
    }

    fn setRoot(self: *Self, value: ?[:0]const u8) void {
        const priv = self.private();
        if (priv.root) |v| glib.free(@ptrCast(@constCast(v)));
        priv.root = value;
        if (priv.open) self.applyRoot();
    }

    //---------------------------------------------------------------
    // Tree

    fn applyRoot(self: *Self) void {
        const priv = self.private();
        const root = priv.root orelse return;
        if (root.len == 0 or root[0] != '/') return;
        if (priv.shown_root) |shown| if (std.mem.eql(u8, shown, root)) return;

        if (priv.shown_root) |old| alloc().free(old);
        priv.shown_root = alloc().dupeZ(u8, root) catch null;
        self.updateRootLabel(root);

        self.disconnectRootModel();

        const file = gio.File.newForPath(root.ptr);
        const dir = gtk.DirectoryList.new(attributes, file);
        file.unref();
        const filtered = gtk.FilterListModel.new(dir.as(gio.ListModel), self.filterRef());
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), self.sorterRef());
        const tree = gtk.TreeListModel.new(sorted.as(gio.ListModel), 0, 0, createChildModel, self, null);
        const selection = gtk.NoSelection.new(tree.as(gio.ListModel));
        priv.list_view.setModel(selection.as(gtk.SelectionModel));
        selection.unref();

        priv.root_dir = dir;
        priv.root_items = filtered;
        _ = gobject.Object.signals.notify.connect(dir, *Self, rootLoadingChanged, self, .{ .detail = "loading" });
        _ = gio.ListModel.signals.items_changed.connect(filtered.as(gio.ListModel), *Self, rootItemsChanged, self, .{});

        if (!std.mem.eql(u8, std.mem.span(priv.stack.getVisibleChildName() orelse ""), "preview")) {
            priv.stack.setVisibleChildName("list");
        }
    }

    fn disconnectRootModel(self: *Self) void {
        const priv = self.private();
        if (priv.root_dir) |dir| {
            _ = gobject.signalHandlersDisconnectMatched(dir.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        }
        if (priv.root_items) |items| {
            _ = gobject.signalHandlersDisconnectMatched(items.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        }
        priv.root_dir = null;
        priv.root_items = null;
    }

    fn updateRootLabel(self: *Self, root: [:0]const u8) void {
        var buf: [1024]u8 = undefined;
        const home = std.posix.getenv("HOME") orelse "";
        const text = if (home.len > 0 and std.mem.startsWith(u8, root, home) and
            (root.len == home.len or root[home.len] == '/'))
            std.fmt.bufPrintZ(&buf, "~{s}", .{root[home.len..]}) catch root
        else
            std.fmt.bufPrintZ(&buf, "{s}", .{root}) catch root;
        self.private().root_label.setLabel(text.ptr);
        self.private().root_label.as(gtk.Widget).setTooltipText(root.ptr);
    }

    fn rootLoadingChanged(_: *gtk.DirectoryList, _: *gobject.ParamSpec, self: *Self) callconv(.c) void {
        self.updateEmpty();
    }

    fn rootItemsChanged(_: *gio.ListModel, _: c_uint, _: c_uint, _: c_uint, self: *Self) callconv(.c) void {
        self.updateEmpty();
    }

    fn updateEmpty(self: *Self) void {
        const priv = self.private();
        const items = priv.root_items orelse return;
        const dir = priv.root_dir orelse return;
        const current = std.mem.span(priv.stack.getVisibleChildName() orelse "");
        if (std.mem.eql(u8, current, "preview")) return;
        const empty = items.as(gio.ListModel).getNItems() == 0 and dir.isLoading() == 0;
        priv.stack.setVisibleChildName(if (empty) "empty" else "list");
    }

    fn filterRef(self: *Self) *gtk.Filter {
        const o = self.private().filter.as(gobject.Object).ref();
        return @ptrCast(o);
    }

    fn sorterRef(self: *Self) *gtk.Sorter {
        const o = self.private().sorter.as(gobject.Object).ref();
        return @ptrCast(o);
    }

    fn filterFunc(item: *gobject.Object, _: ?*anyopaque) callconv(.c) c_int {
        const info = gobject.ext.cast(gio.FileInfo, item) orelse return 0;
        if (info.getIsHidden() != 0) return 0;
        return switch (kindOf(info)) {
            .dir => dir: {
                const name = std.mem.span(info.getName());
                for (skipped_dirs) |d| if (std.mem.eql(u8, d, name)) break :dir 0;
                break :dir 1;
            },
            .markdown, .pdf, .html => 1,
            .other => 0,
        };
    }

    fn sortFunc(a_: ?*const anyopaque, b_: ?*const anyopaque, _: ?*anyopaque) callconv(.c) c_int {
        const a: *gio.FileInfo = @ptrCast(@alignCast(@constCast(a_ orelse return 0)));
        const b: *gio.FileInfo = @ptrCast(@alignCast(@constCast(b_ orelse return 0)));
        const ad = a.getFileType() == .directory;
        const bd = b.getFileType() == .directory;
        if (ad != bd) return if (ad) -1 else 1;
        const an = std.mem.span(a.getDisplayName());
        const bn = std.mem.span(b.getDisplayName());
        return switch (std.ascii.orderIgnoreCase(an, bn)) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
    }

    fn createChildModel(item: *gobject.Object, ud: ?*anyopaque) callconv(.c) ?*gio.ListModel {
        const self: *Self = @ptrCast(@alignCast(ud orelse return null));
        const info = gobject.ext.cast(gio.FileInfo, item) orelse return null;
        if (info.getFileType() != .directory) return null;
        const file = infoFile(info) orelse return null;
        const dir = gtk.DirectoryList.new(attributes, file);
        const filtered = gtk.FilterListModel.new(dir.as(gio.ListModel), self.filterRef());
        const sorted = gtk.SortListModel.new(filtered.as(gio.ListModel), self.sorterRef());
        return sorted.as(gio.ListModel);
    }

    //---------------------------------------------------------------
    // Rows

    fn rowSetup(_: *gtk.SignalListItemFactory, object: *gobject.Object, _: *Self) callconv(.c) void {
        const item = gobject.ext.cast(gtk.ListItem, object) orelse return;
        const expander = gtk.TreeExpander.new();
        const box = gtk.Box.new(.horizontal, 8);
        const icon = gtk.Image.new();
        icon.as(gtk.Widget).addCssClass("file-icon");
        const label = gtk.Label.new("");
        label.setXalign(0);
        label.setEllipsize(.middle);
        label.setMaxWidthChars(1);
        label.as(gtk.Widget).setHexpand(1);
        box.append(icon.as(gtk.Widget));
        box.append(label.as(gtk.Widget));
        expander.setChild(box.as(gtk.Widget));
        item.setChild(expander.as(gtk.Widget));
    }

    fn rowBind(_: *gtk.SignalListItemFactory, object: *gobject.Object, _: *Self) callconv(.c) void {
        const item = gobject.ext.cast(gtk.ListItem, object) orelse return;
        const row = gobject.ext.cast(gtk.TreeListRow, item.getItem() orelse return) orelse return;
        const expander = gobject.ext.cast(gtk.TreeExpander, item.getChild() orelse return) orelse return;
        expander.setListRow(row);

        const info_obj = row.getItem() orelse return;
        defer info_obj.unref();
        const info = gobject.ext.cast(gio.FileInfo, info_obj) orelse return;

        const box = expander.getChild() orelse return;
        const icon_w = box.getFirstChild() orelse return;
        const label_w = icon_w.getNextSibling() orelse return;
        const icon = gobject.ext.cast(gtk.Image, icon_w) orelse return;
        const label = gobject.ext.cast(gtk.Label, label_w) orelse return;

        label.setLabel(info.getDisplayName());
        const kind = kindOf(info);
        icon.setFromIconName(switch (kind) {
            .dir => "folder-symbolic",
            .markdown => "text-x-generic-symbolic",
            .pdf => "x-office-document-symbolic",
            .html => "web-browser-symbolic",
            .other => "text-x-generic-symbolic",
        });
        inline for (.{ "dir", "markdown", "pdf", "html" }) |name| {
            if (std.mem.eql(u8, @tagName(kind), name))
                icon_w.addCssClass(name)
            else
                icon_w.removeCssClass(name);
        }
    }

    fn rowActivated(list_view: *gtk.ListView, position: c_uint, self: *Self) callconv(.c) void {
        const model = list_view.getModel() orelse return;
        const raw = model.as(gio.ListModel).getItem(position) orelse return;
        const row_obj: *gobject.Object = @ptrCast(@alignCast(raw));
        defer row_obj.unref();
        const row = gobject.ext.cast(gtk.TreeListRow, row_obj) orelse return;

        const info_obj = row.getItem() orelse return;
        defer info_obj.unref();
        const info = gobject.ext.cast(gio.FileInfo, info_obj) orelse return;
        const file = infoFile(info) orelse return;

        switch (kindOf(info)) {
            .dir => row.setExpanded(@intFromBool(row.getExpanded() == 0)),
            .markdown => if (info.getSize() > max_preview_bytes) self.openExternal(file) else self.showPreview(file),
            .pdf, .html, .other => self.openExternal(file),
        }
    }

    //---------------------------------------------------------------
    // Opening files

    fn openExternal(self: *Self, file: *gio.File) void {
        const launcher = gtk.FileLauncher.new(file);
        const window: ?*gtk.Window = if (self.as(gtk.Widget).getRoot()) |r| gobject.ext.cast(gtk.Window, r) else null;
        launcher.launch(window, null, launchDone, null);
    }

    fn launchDone(source: ?*gobject.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
        const launcher = gobject.ext.cast(gtk.FileLauncher, source orelse return) orelse return;
        defer launcher.unref();
        var err: ?*glib.Error = null;
        if (launcher.launchFinish(result, &err) == 0) {
            if (err) |e| {
                log.warn("could not open file: {s}", .{e.f_message orelse "?"});
                e.free();
            }
        }
    }

    fn showPreview(self: *Self, file: *gio.File) void {
        const priv = self.private();
        const same = if (priv.preview_file) |f| f.equal(file) != 0 else false;
        if (!same) {
            if (priv.preview_file) |f| f.unref();
            priv.preview_file = @ptrCast(file.as(gobject.Object).ref());
            if (priv.preview_text) |t| alloc().free(t);
            priv.preview_text = null;
        }

        const name = file.getBasename();
        defer if (name) |n| glib.free(n);
        priv.preview_title.setLabel(name orelse "");
        priv.stack.setVisibleChildName("preview");

        self.ensureWebView();
        self.startMonitor(file);
        self.loadPreview(file, same);
    }

    fn loadPreview(self: *Self, file: *gio.File, keep_scroll: bool) void {
        self.private().keep_scroll = keep_scroll;
        file.loadContentsAsync(null, previewLoaded, self.ref());
    }

    fn previewLoaded(source: ?*gobject.Object, result: *gio.AsyncResult, ud: ?*anyopaque) callconv(.c) void {
        const self: *Self = @ptrCast(@alignCast(ud orelse return));
        defer self.unref();
        const file = gobject.ext.cast(gio.File, source orelse return) orelse return;
        var contents: [*]u8 = undefined;
        var len: usize = 0;
        var err: ?*glib.Error = null;
        if (file.loadContentsFinish(result, &contents, &len, null, &err) == 0) {
            if (err) |e| {
                log.warn("could not read file: {s}", .{e.f_message orelse "?"});
                e.free();
            }
            return;
        }
        defer glib.free(contents);

        // Ignore results for a file that's no longer shown.
        const priv = self.private();
        const current = priv.preview_file orelse return;
        if (current.equal(file) == 0) return;

        if (priv.preview_text) |t| alloc().free(t);
        const text = contents[0..@min(len, max_preview_bytes)];
        priv.preview_text = alloc().dupe(u8, if (std.unicode.utf8ValidateSlice(text))
            text
        else
            "> [!CAUTION]\n> This file isn't valid UTF-8 text.\n") catch null;
        self.requestRender();
    }

    //---------------------------------------------------------------
    // Web view

    var sandbox_configured = false;

    fn previewPageUri(buf: []u8) ?[:0]const u8 {
        const res = state.resources_dir.app() orelse return null;
        var pbuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pbuf, "{s}/markdown-preview/preview.html", .{res}) catch return null;
        const file = gio.File.newForPath(path.ptr);
        defer file.unref();
        const uri = file.getUri();
        defer glib.free(uri);
        return std.fmt.bufPrintZ(buf, "{s}", .{std.mem.span(uri)}) catch null;
    }

    fn ensureWebView(self: *Self) void {
        const priv = self.private();
        if (priv.web_view != null) return;

        var ubuf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const uri = previewPageUri(&ubuf) orelse {
            const label = gtk.Label.new("Markdown preview files are missing (share/ghostty/markdown-preview).");
            label.setWrap(1);
            priv.preview_host.setChild(label.as(gtk.Widget));
            return;
        };

        // The web process is sandboxed (home is readable by default); also
        // allow our page's files and /tmp.
        // This must happen before the first web process starts.
        if (!sandbox_configured) {
            sandbox_configured = true;
            const ctx = webkit.webkit_web_context_get_default();
            if (state.resources_dir.app()) |res| {
                var rbuf: [std.fs.max_path_bytes]u8 = undefined;
                if (std.fmt.bufPrintZ(&rbuf, "{s}", .{res})) |r| {
                    webkit.webkit_web_context_add_path_to_sandbox(ctx, r.ptr, 1);
                } else |_| {}
            }
            webkit.webkit_web_context_add_path_to_sandbox(ctx, "/tmp", 1);
        }

        const widget = webkit.webkit_web_view_new();
        _ = widget.as(gobject.Object).refSink();
        const view = webkit.asView(widget);

        const settings = webkit.webkit_web_view_get_settings(view);
        webkit.webkit_settings_set_allow_file_access_from_file_urls(settings, 1);
        webkit.webkit_settings_set_javascript_can_open_windows_automatically(settings, 0);
        webkit.webkit_settings_set_enable_html5_local_storage(settings, 0);
        webkit.webkit_settings_set_enable_page_cache(settings, 0);
        const debug = std.posix.getenv("GHOSTTY_PREVIEW_DEBUG") != null;
        webkit.webkit_settings_set_enable_developer_extras(settings, @intFromBool(debug));
        webkit.webkit_settings_set_enable_write_console_messages_to_stdout(settings, @intFromBool(debug));

        const clear: gdk.RGBA = .{ .f_red = 0, .f_green = 0, .f_blue = 0, .f_alpha = 0 };
        webkit.webkit_web_view_set_background_color(view, &clear);

        const o = widget.as(gobject.Object);
        _ = gobject.signalConnectData(o, "decide-policy", @ptrCast(&decidePolicy), self, null, .{});
        _ = gobject.signalConnectData(o, "load-changed", @ptrCast(&loadChanged), self, null, .{});
        _ = gobject.signalConnectData(o, "context-menu", @ptrCast(&blockContextMenu), self, null, .{});
        _ = gobject.signalConnectData(o, "web-process-terminated", @ptrCast(&processTerminated), self, null, .{});

        priv.web_view = widget;
        priv.web_ready = false;
        priv.preview_host.setChild(widget);
        webkit.webkit_web_view_load_uri(view, uri.ptr);
    }

    fn destroyWebView(self: *Self) void {
        const priv = self.private();
        const widget = priv.web_view orelse return;
        _ = gobject.signalHandlersDisconnectMatched(widget.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
        priv.preview_host.setChild(null);
        widget.unref();
        priv.web_view = null;
        priv.web_ready = false;
    }

    fn loadChanged(_: *webkit.WebView, event: webkit.LoadEvent, self: *Self) callconv(.c) void {
        if (event != .finished) return;
        const priv = self.private();
        priv.web_ready = true;
        if (priv.render_pending) self.requestRender();
    }

    fn processTerminated(_: *webkit.WebView, _: c_int, self: *Self) callconv(.c) void {
        // Recreate on the next render.
        log.warn("markdown preview web process ended; restarting it", .{});
        _ = glib.idleAdd(recreateIdle, self.ref());
    }

    fn recreateIdle(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        defer self.unref();
        self.destroyWebView();
        if (self.private().open and self.private().preview_text != null) {
            self.ensureWebView();
            self.private().render_pending = true;
        }
        return 0;
    }

    fn blockContextMenu(_: *webkit.WebView, _: ?*anyopaque, _: ?*anyopaque, self: *Self) callconv(.c) c_int {
        _ = self;
        return 1;
    }

    fn requestRender(self: *Self) void {
        const priv = self.private();
        const text = priv.preview_text orelse return;
        const widget = priv.web_view orelse return;
        if (!priv.web_ready) {
            priv.render_pending = true;
            return;
        }
        priv.render_pending = false;

        // Base URL for relative links and images: the file's folder.
        var base_buf: [std.fs.max_path_bytes + 16]u8 = undefined;
        const base: []const u8 = base: {
            const file = priv.preview_file orelse break :base "";
            const parent = file.getParent() orelse break :base "";
            defer parent.unref();
            const uri = parent.getUri();
            defer glib.free(uri);
            break :base std.fmt.bufPrint(&base_buf, "{s}/", .{std.mem.span(uri)}) catch "";
        };

        const p = priv.palette;
        var accent_buf: [8]u8 = undefined;
        const accent = std.fmt.bufPrint(&accent_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ p.accent[0], p.accent[1], p.accent[2] }) catch "#4ea1ff";
        const opts = .{
            .base = base,
            .dark = p.dark,
            .fg = p.fg,
            .muted = p.muted,
            .border = p.border,
            .codeBg = p.code_bg,
            .accent = accent,
            .codeFont = std.mem.sliceTo(&p.code_font, 0),
            .keepScroll = priv.keep_scroll,
        };
        priv.keep_scroll = false;

        const script = std.fmt.allocPrint(
            alloc(),
            "window.ghosttyPreview.render({f},{f});",
            .{ std.json.fmt(text, .{}), std.json.fmt(opts, .{}) },
        ) catch return;
        defer alloc().free(script);
        webkit.webkit_web_view_evaluate_javascript(
            webkit.asView(widget),
            script.ptr,
            @intCast(script.len),
            null,
            null,
            null,
            null,
            null,
        );
    }

    /// Links clicked in the preview: Markdown files preview here, everything
    /// else opens in the default app or browser. The page never navigates.
    fn decidePolicy(
        _: *webkit.WebView,
        decision: *webkit.PolicyDecision,
        kind: webkit.PolicyDecisionType,
        self: *Self,
    ) callconv(.c) c_int {
        if (kind == .response) return 0;
        const priv = self.private();
        const action = webkit.webkit_navigation_policy_decision_get_navigation_action(decision);
        const nav = webkit.webkit_navigation_action_get_navigation_type(action);

        // Allow only the initial load of preview.html.
        if (!priv.web_ready and nav == .other and kind == .navigation_action) return 0;
        webkit.webkit_policy_decision_ignore(decision);
        if (nav != .link_clicked and kind != .new_window_action) return 1;

        const request = webkit.webkit_navigation_action_get_request(action);
        const uri = std.mem.span(webkit.webkit_uri_request_get_uri(request));
        self.openLink(uri);
        return 1;
    }

    fn openLink(self: *Self, uri: []const u8) void {
        if (std.mem.startsWith(u8, uri, "file://")) {
            // Drop any #fragment for local files.
            const end = std.mem.indexOfScalar(u8, uri, '#') orelse uri.len;
            var buf: [std.fs.max_path_bytes + 16]u8 = undefined;
            const z = std.fmt.bufPrintZ(&buf, "{s}", .{uri[0..end]}) catch return;
            const file = gio.File.newForUri(z.ptr);
            defer file.unref();
            const name = std.fs.path.extension(uri[0..end]);
            const md = std.ascii.eqlIgnoreCase(name, ".md") or std.ascii.eqlIgnoreCase(name, ".markdown");
            if (md) self.showPreview(file) else self.openExternal(file);
            return;
        }

        var buf: [4096]u8 = undefined;
        const z = std.fmt.bufPrintZ(&buf, "{s}", .{uri}) catch return;
        const launcher = gtk.UriLauncher.new(z.ptr);
        const window: ?*gtk.Window = if (self.as(gtk.Widget).getRoot()) |r| gobject.ext.cast(gtk.Window, r) else null;
        launcher.launch(window, null, uriLaunchDone, null);
    }

    fn uriLaunchDone(source: ?*gobject.Object, result: *gio.AsyncResult, _: ?*anyopaque) callconv(.c) void {
        const launcher = gobject.ext.cast(gtk.UriLauncher, source orelse return) orelse return;
        defer launcher.unref();
        var err: ?*glib.Error = null;
        if (launcher.launchFinish(result, &err) == 0) if (err) |e| {
            log.warn("could not open link: {s}", .{e.f_message orelse "?"});
            e.free();
        };
    }

    //---------------------------------------------------------------
    // Live reload

    fn startMonitor(self: *Self, file: *gio.File) void {
        self.stopMonitor();
        var err: ?*glib.Error = null;
        const monitor = file.monitorFile(.{ .watch_moves = true }, null, &err) orelse {
            if (err) |e| e.free();
            return;
        };
        _ = gio.FileMonitor.signals.changed.connect(monitor, *Self, fileChanged, self, .{});
        self.private().monitor = monitor;
    }

    fn stopMonitor(self: *Self) void {
        const priv = self.private();
        if (priv.reload_source) |src| _ = glib.Source.remove(src);
        priv.reload_source = null;
        if (priv.monitor) |m| {
            _ = m.cancel();
            _ = gobject.signalHandlersDisconnectMatched(m.as(gobject.Object), .{ .data = true }, 0, 0, null, null, self);
            m.unref();
        }
        priv.monitor = null;
    }

    fn fileChanged(_: *gio.FileMonitor, _: *gio.File, _: ?*gio.File, event: gio.FileMonitorEvent, self: *Self) callconv(.c) void {
        switch (event) {
            .changes_done_hint, .created, .moved_in, .renamed => {},
            else => return,
        }
        // Debounce bursts of events from one save.
        const priv = self.private();
        if (priv.reload_source) |src| _ = glib.Source.remove(src);
        priv.reload_source = glib.timeoutAdd(150, reloadTimeout, self);
    }

    fn reloadTimeout(ud: ?*anyopaque) callconv(.c) c_int {
        const self: *Self = @ptrCast(@alignCast(ud orelse return 0));
        const priv = self.private();
        priv.reload_source = null;
        if (priv.preview_file) |f| self.loadPreview(f, true);
        return 0;
    }

    fn backClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.stack.setVisibleChildName("list");
        self.updateEmpty();
    }

    fn openExternalClicked(_: *gtk.Button, self: *Self) callconv(.c) void {
        const file = self.private().preview_file orelse return;
        self.openExternal(file);
    }

    //---------------------------------------------------------------
    // Virtual methods

    fn dispose(self: *Self) callconv(.c) void {
        const priv = self.private();
        self.disconnectRootModel();
        self.stopMonitor();
        self.destroyWebView();
        if (priv.preview_file) |f| f.unref();
        priv.preview_file = null;
        gobject.Object.virtual_methods.dispose.call(Class.parent, self.as(Parent));
    }

    fn finalize(self: *Self) callconv(.c) void {
        const priv = self.private();
        priv.filter.unref();
        priv.sorter.unref();
        if (priv.root) |v| glib.free(@ptrCast(@constCast(v)));
        if (priv.shown_root) |v| alloc().free(v);
        if (priv.preview_text) |t| alloc().free(t);
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
            gobject.ext.registerProperties(class, &.{properties.root.impl});
            gobject.Object.virtual_methods.dispose.implement(class, &dispose);
            gobject.Object.virtual_methods.finalize.implement(class, &finalize);
        }

        pub const as = C.Class.as;
    };
};
