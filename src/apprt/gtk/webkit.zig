//! Minimal hand-written bindings for the parts of WebKitGTK 6.0 used by the
//! file explorer's Markdown preview. zig-gobject doesn't generate WebKit.
const gdk = @import("gdk");
const gio = @import("gio");
const gtk = @import("gtk");

pub const WebView = opaque {};
pub const WebContext = opaque {};
pub const Settings = opaque {};
pub const PolicyDecision = opaque {};
pub const NavigationAction = opaque {};
pub const URIRequest = opaque {};

pub const LoadEvent = enum(c_int) { started = 0, redirected = 1, committed = 2, finished = 3 };
pub const PolicyDecisionType = enum(c_int) { navigation_action = 0, new_window_action = 1, response = 2 };
pub const NavigationType = enum(c_int) {
    link_clicked = 0,
    form_submitted = 1,
    back_forward = 2,
    reload = 3,
    form_resubmitted = 4,
    other = 5,
};

pub extern fn webkit_web_view_new() *gtk.Widget;
pub extern fn webkit_web_view_get_settings(view: *WebView) *Settings;
pub extern fn webkit_web_view_load_uri(view: *WebView, uri: [*:0]const u8) void;
pub extern fn webkit_web_view_set_background_color(view: *WebView, rgba: *const gdk.RGBA) void;
pub extern fn webkit_web_view_evaluate_javascript(
    view: *WebView,
    script: [*]const u8,
    length: isize,
    world_name: ?[*:0]const u8,
    source_uri: ?[*:0]const u8,
    cancellable: ?*gio.Cancellable,
    callback: ?gio.AsyncReadyCallback,
    user_data: ?*anyopaque,
) void;

pub extern fn webkit_web_context_get_default() *WebContext;
pub extern fn webkit_web_context_add_path_to_sandbox(ctx: *WebContext, path: [*:0]const u8, read_only: c_int) void;

pub extern fn webkit_settings_set_enable_developer_extras(s: *Settings, v: c_int) void;
pub extern fn webkit_settings_set_enable_write_console_messages_to_stdout(s: *Settings, v: c_int) void;
pub extern fn webkit_settings_set_allow_file_access_from_file_urls(s: *Settings, v: c_int) void;
pub extern fn webkit_settings_set_javascript_can_open_windows_automatically(s: *Settings, v: c_int) void;
pub extern fn webkit_settings_set_enable_html5_local_storage(s: *Settings, v: c_int) void;
pub extern fn webkit_settings_set_enable_page_cache(s: *Settings, v: c_int) void;

pub extern fn webkit_policy_decision_ignore(d: *PolicyDecision) void;
pub extern fn webkit_navigation_policy_decision_get_navigation_action(d: *PolicyDecision) *NavigationAction;
pub extern fn webkit_navigation_action_get_navigation_type(a: *NavigationAction) NavigationType;
pub extern fn webkit_navigation_action_get_request(a: *NavigationAction) *URIRequest;
pub extern fn webkit_uri_request_get_uri(r: *URIRequest) [*:0]const u8;

pub fn asView(widget: *gtk.Widget) *WebView {
    return @ptrCast(widget);
}
