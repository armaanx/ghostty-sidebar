//! Small Markdown renderer for the file explorer preview. Parses common
//! Markdown (headings, paragraphs, emphasis, inline code, fenced code,
//! lists and task lists, block quotes, links, images as alt text, rules,
//! simple tables) and writes styled text straight into a GtkTextBuffer.
//! Single pass, no HTML or browser engine, so previews open instantly.
const std = @import("std");
const gobject = @import("gobject");
const gtk = @import("gtk");

extern fn g_object_set(object: *gobject.Object, first_property_name: [*:0]const u8, ...) void;

pub const Options = struct {
    /// Dark sidebar theme (light text) or light (paper).
    dark: bool = true,
    /// Link color.
    accent: [3]u8 = .{ 0x4e, 0xa1, 0xff },
};

const max_list_level = 5;

const Tags = struct {
    h: [6]*gtk.TextTag,
    bold: *gtk.TextTag,
    italic: *gtk.TextTag,
    strike: *gtk.TextTag,
    code: *gtk.TextTag,
    code_block: *gtk.TextTag,
    quote: *gtk.TextTag,
    link: *gtk.TextTag,
    muted: *gtk.TextTag,
    para: *gtk.TextTag,
    hr: *gtk.TextTag,
    check: *gtk.TextTag,
    gap: *gtk.TextTag,
    list: [max_list_level]*gtk.TextTag,
};

fn newTag(table: *gtk.TextTagTable) *gtk.TextTag {
    const tag = gtk.TextTag.new(null);
    _ = table.add(tag);
    // The table keeps its own reference.
    tag.unref();
    return tag;
}

fn obj(tag: *gtk.TextTag) *gobject.Object {
    return tag.as(gobject.Object);
}

const nul: ?*anyopaque = null;

fn makeTags(buffer: *gtk.TextBuffer, opts: Options) Tags {
    const table = buffer.getTagTable();
    const muted: [*:0]const u8 = if (opts.dark) "#9a9aa3" else "#6b6b75";
    const code_bg: [*:0]const u8 = if (opts.dark) "rgba(255,255,255,0.07)" else "rgba(0,0,0,0.06)";
    const block_bg: [*:0]const u8 = if (opts.dark) "rgba(255,255,255,0.05)" else "rgba(0,0,0,0.04)";
    var link_buf: [8:0]u8 = undefined;
    _ = std.fmt.bufPrintZ(&link_buf, "#{x:0>2}{x:0>2}{x:0>2}", .{ opts.accent[0], opts.accent[1], opts.accent[2] }) catch {};

    var t: Tags = undefined;
    const scales = [6]f64{ 1.6, 1.35, 1.18, 1.06, 1.0, 0.95 };
    for (&t.h, scales) |*h, sc| {
        h.* = newTag(table);
        g_object_set(obj(h.*), "weight", @as(c_int, 750), "scale", sc, "pixels-above-lines", @as(c_int, 10), "pixels-below-lines", @as(c_int, 6), nul);
    }
    t.bold = newTag(table);
    g_object_set(obj(t.bold), "weight", @as(c_int, 700), nul);
    t.italic = newTag(table);
    g_object_set(obj(t.italic), "style", @as(c_int, 2), nul); // PANGO_STYLE_ITALIC
    t.strike = newTag(table);
    g_object_set(obj(t.strike), "strikethrough", @as(c_int, 1), nul);
    t.code = newTag(table);
    g_object_set(obj(t.code), "family", @as([*:0]const u8, "monospace"), "background", code_bg, "scale", @as(f64, 0.92), nul);
    t.code_block = newTag(table);
    g_object_set(obj(t.code_block), "family", @as([*:0]const u8, "monospace"), "paragraph-background", block_bg, "left-margin", @as(c_int, 22), "right-margin", @as(c_int, 8), "scale", @as(f64, 0.9), "wrap-mode", @as(c_int, 0), nul); // GTK_WRAP_NONE
    t.quote = newTag(table);
    g_object_set(obj(t.quote), "left-margin", @as(c_int, 26), "foreground", muted, "style", @as(c_int, 2), nul);
    t.link = newTag(table);
    g_object_set(obj(t.link), "foreground", @as([*:0]const u8, &link_buf), "underline", @as(c_int, 1), nul);
    t.muted = newTag(table);
    g_object_set(obj(t.muted), "foreground", muted, nul);
    t.para = newTag(table);
    g_object_set(obj(t.para), "pixels-below-lines", @as(c_int, 8), nul);
    t.hr = newTag(table);
    g_object_set(obj(t.hr), "foreground", muted, "justification", @as(c_int, 2), "pixels-above-lines", @as(c_int, 6), "pixels-below-lines", @as(c_int, 6), nul); // GTK_JUSTIFY_CENTER
    t.check = newTag(table);
    g_object_set(obj(t.check), "foreground", @as([*:0]const u8, &link_buf), nul);
    // A short empty line that separates quotes, code blocks and tables.
    t.gap = newTag(table);
    g_object_set(obj(t.gap), "scale", @as(f64, 0.45), nul);
    for (&t.list, 0..) |*l, i| {
        l.* = newTag(table);
        const margin: c_int = 30 + @as(c_int, @intCast(i)) * 18;
        g_object_set(obj(l.*), "left-margin", margin, "indent", @as(c_int, -14), "pixels-below-lines", @as(c_int, 2), nul);
    }
    return t;
}

const Writer = struct {
    buffer: *gtk.TextBuffer,

    fn offset(self: Writer) c_int {
        return self.buffer.getCharCount();
    }

    fn emit(self: Writer, text: []const u8, tags: []const *gtk.TextTag) void {
        if (text.len == 0) return;
        var end: gtk.TextIter = undefined;
        self.buffer.getEndIter(&end);
        const start_off = end.getOffset();
        self.buffer.insert(&end, @ptrCast(text.ptr), @intCast(text.len));
        if (tags.len > 0) self.applyFrom(start_off, tags);
    }

    fn applyFrom(self: Writer, start_off: c_int, tags: []const *gtk.TextTag) void {
        var s: gtk.TextIter = undefined;
        var e: gtk.TextIter = undefined;
        self.buffer.getIterAtOffset(&s, start_off);
        self.buffer.getEndIter(&e);
        for (tags) |tag| self.buffer.applyTag(tag, &s, &e);
    }
};

/// Render `text` (must be valid UTF-8) into `buffer`.
pub fn render(buffer: *gtk.TextBuffer, text: []const u8, opts: Options) void {
    const alloc = std.heap.c_allocator;
    const tags = makeTags(buffer, opts);
    const w: Writer = .{ .buffer = buffer };

    var para: std.ArrayListUnmanaged(u8) = .empty;
    defer para.deinit(alloc);

    var prev_kind: BlockKind = .none;
    var in_code = false;
    var fence: u8 = '`';
    var code_start: c_int = 0;

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimRight(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        // Fenced code blocks.
        if (in_code) {
            if (isFence(trimmed, fence)) {
                w.applyFrom(code_start, &.{tags.code_block});
                w.emit("\n", &.{tags.gap});
                in_code = false;
                continue;
            }
            w.emit(line, &.{});
            w.emit("\n", &.{});
            continue;
        }
        if (fenceChar(trimmed)) |c| {
            flushPara(w, &tags, &para);
            in_code = true;
            fence = c;
            w.emit("\n", &.{tags.gap});
            code_start = w.offset();
            continue;
        }

        if (trimmed.len == 0) {
            flushPara(w, &tags, &para);
            if (prev_kind == .quote or prev_kind == .table) w.emit("\n", &.{tags.gap});
            prev_kind = .none;
            continue;
        }
        if (trimmed[0] != '>' and trimmed[0] != '|') {
            if (prev_kind == .quote or prev_kind == .table) w.emit("\n", &.{tags.gap});
            prev_kind = .none;
        }

        // Setext headings: a "===" or "---" line under paragraph text.
        if (para.items.len > 0 and allChar(trimmed, '=')) {
            emitHeading(w, &tags, 1, para.items);
            para.clearRetainingCapacity();
            continue;
        }
        if (para.items.len > 0 and allChar(trimmed, '-') and trimmed.len >= 2) {
            emitHeading(w, &tags, 2, para.items);
            para.clearRetainingCapacity();
            continue;
        }

        // ATX headings.
        if (headingLevel(trimmed)) |lvl| {
            flushPara(w, &tags, &para);
            var content = std.mem.trim(u8, trimmed[lvl..], " \t");
            content = std.mem.trimRight(u8, content, "#");
            emitHeading(w, &tags, lvl, std.mem.trim(u8, content, " \t"));
            continue;
        }

        // Horizontal rule.
        if (isRule(trimmed)) {
            flushPara(w, &tags, &para);
            w.emit("────────────\n", &.{tags.hr});
            continue;
        }

        // Block quote.
        if (trimmed[0] == '>') {
            flushPara(w, &tags, &para);
            if (prev_kind != .quote) w.emit("\n", &.{tags.gap});
            defer prev_kind = .quote;
            var content = trimmed;
            while (content.len > 0 and (content[0] == '>' or content[0] == ' ')) content = content[1..];
            const start = w.offset();
            renderInline(w, &tags, content, &.{});
            w.emit("\n", &.{});
            w.applyFrom(start, &.{tags.quote});
            continue;
        }

        // List items.
        if (listItem(line)) |item| {
            flushPara(w, &tags, &para);
            const start = w.offset();
            var content = item.content;
            if (std.mem.startsWith(u8, content, "[ ] ")) {
                w.emit("☐  ", &.{tags.muted});
                content = content[4..];
            } else if (std.mem.startsWith(u8, content, "[x] ") or std.mem.startsWith(u8, content, "[X] ")) {
                w.emit("☑  ", &.{tags.check});
                content = content[4..];
            } else if (item.number) |n| {
                var nb: [16]u8 = undefined;
                w.emit(std.fmt.bufPrint(&nb, "{s}.  ", .{n}) catch "•  ", &.{tags.muted});
            } else {
                w.emit("•  ", &.{tags.muted});
            }
            renderInline(w, &tags, content, &.{});
            w.emit("\n", &.{});
            w.applyFrom(start, &.{tags.list[@min(item.level, max_list_level - 1)]});
            continue;
        }

        // Simple tables: show rows with cell separators, skip the ---- row.
        if (trimmed[0] == '|') {
            flushPara(w, &tags, &para);
            if (prev_kind != .table) w.emit("\n", &.{tags.gap});
            defer prev_kind = .table;
            if (isTableSeparator(trimmed)) continue;
            const start = w.offset();
            var cells = std.mem.splitScalar(u8, std.mem.trim(u8, trimmed, "|"), '|');
            var first = true;
            while (cells.next()) |cell| {
                if (!first) w.emit("  │  ", &.{tags.muted});
                renderInline(w, &tags, std.mem.trim(u8, cell, " \t"), &.{});
                first = false;
            }
            w.emit("\n", &.{});
            w.applyFrom(start, &.{tags.list[0]});
            continue;
        }

        // HTML comments on their own line.
        if (std.mem.startsWith(u8, trimmed, "<!--")) continue;

        // Paragraph text: join lines with spaces.
        if (para.items.len > 0) para.append(alloc, ' ') catch {};
        para.appendSlice(alloc, trimmed) catch {};
    }

    if (in_code) w.applyFrom(code_start, &.{tags.code_block});
    flushPara(w, &tags, &para);
}

const BlockKind = enum { none, quote, table };

fn flushPara(w: Writer, tags: *const Tags, para: *std.ArrayListUnmanaged(u8)) void {
    if (para.items.len == 0) return;
    const start = w.offset();
    renderInline(w, tags, para.items, &.{});
    w.emit("\n", &.{});
    w.applyFrom(start, &.{tags.para});
    para.clearRetainingCapacity();
}

fn emitHeading(w: Writer, tags: *const Tags, level: usize, content: []const u8) void {
    const start = w.offset();
    renderInline(w, tags, content, &.{});
    w.emit("\n", &.{});
    w.applyFrom(start, &.{tags.h[@min(level, 6) - 1]});
}

fn fenceChar(s: []const u8) ?u8 {
    if (std.mem.startsWith(u8, s, "```")) return '`';
    if (std.mem.startsWith(u8, s, "~~~")) return '~';
    return null;
}

fn isFence(s: []const u8, c: u8) bool {
    return s.len >= 3 and s[0] == c and s[1] == c and s[2] == c;
}

fn allChar(s: []const u8, c: u8) bool {
    if (s.len == 0) return false;
    for (s) |ch| if (ch != c) return false;
    return true;
}

fn headingLevel(s: []const u8) ?usize {
    var n: usize = 0;
    while (n < s.len and s[n] == '#') n += 1;
    if (n == 0 or n > 6) return null;
    if (n < s.len and s[n] != ' ' and s[n] != '\t') return null;
    return n;
}

fn isRule(s: []const u8) bool {
    var marker: u8 = 0;
    var count: usize = 0;
    for (s) |ch| {
        if (ch == ' ') continue;
        if (ch != '-' and ch != '*' and ch != '_') return false;
        if (marker == 0) marker = ch;
        if (ch != marker) return false;
        count += 1;
    }
    return count >= 3;
}

fn isTableSeparator(s: []const u8) bool {
    var dash = false;
    for (s) |ch| switch (ch) {
        '|', ':', ' ', '\t' => {},
        '-' => dash = true,
        else => return false,
    };
    return dash;
}

const ListItem = struct {
    level: usize,
    number: ?[]const u8,
    content: []const u8,
};

fn listItem(line: []const u8) ?ListItem {
    var indent: usize = 0;
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {
        indent += if (line[i] == '\t') 4 else 1;
    }
    const rest = line[i..];
    if (rest.len >= 2 and (rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        return .{ .level = indent / 2, .number = null, .content = std.mem.trim(u8, rest[2..], " \t") };
    }
    var d: usize = 0;
    while (d < rest.len and d < 9 and std.ascii.isDigit(rest[d])) d += 1;
    if (d > 0 and d + 1 < rest.len and (rest[d] == '.' or rest[d] == ')') and rest[d + 1] == ' ') {
        return .{ .level = indent / 2, .number = rest[0..d], .content = std.mem.trim(u8, rest[d + 2 ..], " \t") };
    }
    return null;
}

//---------------------------------------------------------------
// Inline formatting

const Style = struct {
    bold: bool = false,
    italic: bool = false,
    strike: bool = false,
};

fn styleTags(buf: *[12]*gtk.TextTag, tags: *const Tags, base: []const *gtk.TextTag, st: Style) []const *gtk.TextTag {
    var n: usize = 0;
    for (base) |t| {
        if (n == buf.len) break;
        buf[n] = t;
        n += 1;
    }
    if (st.bold and n < buf.len) {
        buf[n] = tags.bold;
        n += 1;
    }
    if (st.italic and n < buf.len) {
        buf[n] = tags.italic;
        n += 1;
    }
    if (st.strike and n < buf.len) {
        buf[n] = tags.strike;
        n += 1;
    }
    return buf[0..n];
}

fn isWordChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c >= 0x80;
}

/// True if `marker` appears again after `from`, right after a non-space.
fn hasCloser(s: []const u8, from: usize, marker: []const u8) bool {
    var i = from;
    while (i + marker.len <= s.len) : (i += 1) {
        if (std.mem.eql(u8, s[i .. i + marker.len], marker) and i > from and s[i - 1] != ' ') return true;
    }
    return false;
}

fn renderInline(w: Writer, tags: *const Tags, s: []const u8, base: []const *gtk.TextTag) void {
    var st: Style = .{};
    var tag_buf: [12]*gtk.TextTag = undefined;
    var run_start: usize = 0;
    var i: usize = 0;

    while (i < s.len) {
        const c = s[i];

        // Characters that may start markup.
        const special = switch (c) {
            '\\', '`', '*', '_', '~', '[', '!', '<', '&' => true,
            else => false,
        };
        if (!special) {
            i += 1;
            continue;
        }

        // Flush plain text before handling markup.
        const flush = struct {
            fn f(wr: Writer, tg: *const Tags, b: []const *gtk.TextTag, stl: Style, text: []const u8, buf: *[12]*gtk.TextTag) void {
                wr.emit(text, styleTags(buf, tg, b, stl));
            }
        }.f;

        // Backslash escape.
        if (c == '\\' and i + 1 < s.len and (std.ascii.isPrint(s[i + 1]) and !std.ascii.isAlphanumeric(s[i + 1]) and s[i + 1] != ' ')) {
            flush(w, tags, base, st, s[run_start..i], &tag_buf);
            run_start = i + 1;
            i += 2;
            continue;
        }

        // Inline code.
        if (c == '`') {
            var n: usize = 0;
            while (i + n < s.len and s[i + n] == '`') n += 1;
            const marker = s[i .. i + n];
            if (std.mem.indexOfPos(u8, s, i + n, marker)) |close| {
                flush(w, tags, base, st, s[run_start..i], &tag_buf);
                var cbuf: [12]*gtk.TextTag = undefined;
                const code_tags = styleTags(&cbuf, tags, base, .{});
                var all: [13]*gtk.TextTag = undefined;
                @memcpy(all[0..code_tags.len], code_tags);
                all[code_tags.len] = tags.code;
                w.emit(std.mem.trim(u8, s[i + n .. close], " "), all[0 .. code_tags.len + 1]);
                i = close + n;
                run_start = i;
                continue;
            }
            i += n;
            continue;
        }

        // Bold / italic / strike markers.
        if (c == '*' or c == '_' or c == '~') {
            const double = i + 1 < s.len and s[i + 1] == c;
            const len: usize = if (double) 2 else 1;
            if (c == '~' and !double) {
                i += 1;
                continue;
            }
            const marker = s[i .. i + len];
            const prev: u8 = if (i > 0) s[i - 1] else ' ';
            const next: u8 = if (i + len < s.len) s[i + len] else ' ';

            const active = if (c == '~') st.strike else if (double) st.bold else st.italic;
            const can_open = next != ' ' and (c != '_' or !isWordChar(prev)) and hasCloser(s, i + len, marker);
            const can_close = prev != ' ' and (c != '_' or !isWordChar(next));

            if ((active and can_close) or (!active and can_open)) {
                flush(w, tags, base, st, s[run_start..i], &tag_buf);
                if (c == '~') st.strike = !st.strike else if (double) st.bold = !st.bold else st.italic = !st.italic;
                i += len;
                run_start = i;
                continue;
            }
            i += len;
            continue;
        }

        // Links and images: [text](url), ![alt](url)
        if (c == '[' or (c == '!' and i + 1 < s.len and s[i + 1] == '[')) {
            const image = c == '!';
            const open = if (image) i + 1 else i;
            if (std.mem.indexOfScalarPos(u8, s, open + 1, ']')) |close| {
                if (close + 1 < s.len and s[close + 1] == '(') {
                    if (std.mem.indexOfScalarPos(u8, s, close + 2, ')')) |paren| {
                        flush(w, tags, base, st, s[run_start..i], &tag_buf);
                        const label = s[open + 1 .. close];
                        if (image) {
                            w.emit("▣ ", &.{tags.muted});
                            w.emit(if (label.len > 0) label else "image", &.{tags.muted});
                        } else {
                            var lbuf: [12]*gtk.TextTag = undefined;
                            const lt = styleTags(&lbuf, tags, base, st);
                            var all: [13]*gtk.TextTag = undefined;
                            @memcpy(all[0..lt.len], lt);
                            all[lt.len] = tags.link;
                            renderInline(w, tags, label, all[0 .. lt.len + 1]);
                        }
                        i = paren + 1;
                        run_start = i;
                        continue;
                    }
                }
            }
            i += 1;
            continue;
        }

        // Autolinks <https://...> and inline HTML tags (dropped).
        if (c == '<') {
            if (std.mem.indexOfScalarPos(u8, s, i + 1, '>')) |close| {
                const inner = s[i + 1 .. close];
                const is_url = std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://");
                const is_tag = inner.len > 0 and (std.ascii.isAlphabetic(inner[0]) or inner[0] == '/');
                if (is_url or is_tag) {
                    flush(w, tags, base, st, s[run_start..i], &tag_buf);
                    if (is_url) w.emit(inner, &.{tags.link});
                    i = close + 1;
                    run_start = i;
                    continue;
                }
            }
            i += 1;
            continue;
        }

        // A few HTML entities.
        if (c == '&') {
            const entities = [_]struct { []const u8, []const u8 }{
                .{ "&amp;", "&" },   .{ "&lt;", "<" },   .{ "&gt;", ">" },
                .{ "&quot;", "\"" }, .{ "&nbsp;", " " }, .{ "&#39;", "'" },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, s[i..], e[0])) {
                    flush(w, tags, base, st, s[run_start..i], &tag_buf);
                    w.emit(e[1], styleTags(&tag_buf, tags, base, st));
                    i += e[0].len;
                    run_start = i;
                    matched = true;
                    break;
                }
            }
            if (!matched) i += 1;
            continue;
        }

        i += 1;
    }

    w.emit(s[run_start..], styleTags(&tag_buf, tags, base, st));
}
