//! Document explorer panel shown beside the terminal. Lists the active
//! tab's working directory as a tree, filtered to documents (Markdown, PDF,
//! HTML). Markdown files preview inside the panel; other files open in the
//! default app.
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
const md_render = @import("../md_render.zig");

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
        md_opts: md_render.Options = .{},

        filter: *gtk.CustomFilter = undefined,
        sorter: *gtk.CustomSorter = undefined,
        root_dir: ?*gtk.DirectoryList = null,
        root_items: ?*gtk.FilterListModel = null,

        stack: *gtk.Stack = undefined,
        list_view: *gtk.ListView = undefined,
        root_label: *gtk.Label = undefined,
        preview_title: *gtk.Label = undefined,
        text_view: *gtk.TextView = undefined,
        preview_scroller: *gtk.ScrolledWindow = undefined,

        /// File being previewed and its contents (for re-rendering).
        preview_file: ?*gio.File = null,
        preview_text: ?[]u8 = null,

        pub var offset: c_int = 0;
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

        const text_view = gtk.TextView.new();
        text_view.setEditable(0);
        text_view.setCursorVisible(0);
        text_view.setWrapMode(.word_char);
        text_view.setLeftMargin(16);
        text_view.setRightMargin(16);
        text_view.setTopMargin(12);
        text_view.setBottomMargin(24);
        text_view.as(gtk.Widget).addCssClass("markdown-preview");
        priv.text_view = text_view;
        const pscroller = gtk.ScrolledWindow.new();
        pscroller.setPolicy(.never, .automatic);
        pscroller.setChild(text_view.as(gtk.Widget));
        pscroller.as(gtk.Widget).setVexpand(1);
        priv.preview_scroller = pscroller;
        preview.append(pscroller.as(gtk.Widget));
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
        if (open) self.applyRoot();
    }

    /// Colors used by the Markdown preview. Re-renders an open preview.
    pub fn setStyle(self: *Self, dark: bool, accent: [3]u8) void {
        const priv = self.private();
        const changed = priv.md_opts.dark != dark or !std.mem.eql(u8, &priv.md_opts.accent, &accent);
        priv.md_opts = .{ .dark = dark, .accent = accent };
        if (changed) if (priv.preview_text) |text| self.renderPreview(text);
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
        if (priv.preview_file) |f| f.unref();
        priv.preview_file = @ptrCast(file.as(gobject.Object).ref());

        const name = file.getBasename();
        defer if (name) |n| glib.free(n);
        priv.preview_title.setLabel(name orelse "");
        priv.stack.setVisibleChildName("preview");
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
        priv.preview_text = alloc().dupe(u8, contents[0..len]) catch null;
        if (priv.preview_text) |t| self.renderPreview(t);
    }

    fn renderPreview(self: *Self, text: []const u8) void {
        const priv = self.private();
        const buffer = gtk.TextBuffer.new(null);
        defer buffer.unref();
        if (std.unicode.utf8ValidateSlice(text)) {
            md_render.render(buffer, text, priv.md_opts);
        } else {
            const msg = "This file isn't valid UTF-8 text.";
            buffer.setText(msg, msg.len);
        }
        priv.text_view.setBuffer(buffer);
        priv.preview_scroller.getVadjustment().setValue(0);
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
