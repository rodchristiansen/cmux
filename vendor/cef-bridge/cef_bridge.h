// CEF bridge API for cmux (OWL-style OSR architecture).
//
// Uses offscreen rendering (OSR) with IOSurface delivery for
// compositor-safe rendering. Input events translated from NSEvent
// in Swift and forwarded via these functions.
#ifndef CEF_BRIDGE_H
#define CEF_BRIDGE_H

#ifdef __cplusplus
extern "C" {
#endif

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define CEF_BRIDGE_OK             0
#define CEF_BRIDGE_ERR_NOT_INIT  -1
#define CEF_BRIDGE_ERR_INVALID   -2
#define CEF_BRIDGE_ERR_FAILED    -3

typedef void* cef_bridge_browser_t;

// -------------------------------------------------------------------
// Callback types
// -------------------------------------------------------------------

/// Called per-frame with an IOSurfaceRef (macOS).
/// The surface is from a pool. Set it as CALayer.contents
/// synchronously before returning.
typedef void (*cef_bridge_accelerated_paint_callback)(
    cef_bridge_browser_t browser,
    void* io_surface_ref,
    int width, int height,
    void* user_data
);

/// Fallback: called per-frame with a BGRA pixel buffer.
typedef void (*cef_bridge_paint_callback)(
    cef_bridge_browser_t browser,
    const void* buffer,
    int width, int height,
    void* user_data
);

/// CEF asks for the view rectangle (DIP coordinates).
typedef void (*cef_bridge_get_rect_callback)(
    cef_bridge_browser_t browser,
    int* width, int* height,
    void* user_data
);

/// CEF asks for screen info (scale factor).
typedef void (*cef_bridge_screen_info_callback)(
    cef_bridge_browser_t browser,
    float* device_scale_factor,
    void* user_data
);

/// Title changed.
typedef void (*cef_bridge_title_callback)(
    cef_bridge_browser_t browser,
    const char* title,
    void* user_data
);

/// URL changed.
typedef void (*cef_bridge_url_callback)(
    cef_bridge_browser_t browser,
    const char* url,
    void* user_data
);

/// Loading state changed.
typedef void (*cef_bridge_loading_state_callback)(
    cef_bridge_browser_t browser,
    bool is_loading,
    bool can_go_back,
    bool can_go_forward,
    void* user_data
);

/// Cursor type changed.
typedef void (*cef_bridge_cursor_callback)(
    cef_bridge_browser_t browser,
    int cursor_type,
    void* user_data
);

/// Popup request. Return true to allow.
typedef bool (*cef_bridge_popup_callback)(
    cef_bridge_browser_t browser,
    const char* target_url,
    void* user_data
);

// -------------------------------------------------------------------
// Client callbacks struct
// -------------------------------------------------------------------

typedef struct {
    // Rendering (OSR)
    cef_bridge_accelerated_paint_callback  on_accelerated_paint;
    cef_bridge_paint_callback              on_paint;
    cef_bridge_get_rect_callback           on_get_view_rect;
    cef_bridge_screen_info_callback        on_get_screen_info;
    cef_bridge_cursor_callback             on_cursor_change;

    // Navigation/display
    cef_bridge_title_callback              on_title_change;
    cef_bridge_url_callback                on_url_change;
    cef_bridge_loading_state_callback      on_loading_state_change;
    cef_bridge_popup_callback              on_popup_request;

    void*                                  user_data;
} cef_bridge_client_callbacks;

// -------------------------------------------------------------------
// Lifecycle
// -------------------------------------------------------------------

int cef_bridge_initialize(
    const char* framework_path,
    const char* helper_path,
    const char* cache_root
);

void cef_bridge_do_message_loop_work(void);
void cef_bridge_shutdown(void);
bool cef_bridge_is_initialized(void);

// -------------------------------------------------------------------
// Browser (OSR mode)
// -------------------------------------------------------------------

/// Create a browser in OSR mode. No NSView is created by CEF.
/// Rendering goes through on_accelerated_paint/on_paint callbacks.
cef_bridge_browser_t cef_bridge_browser_create(
    const char* initial_url,
    int width,
    int height,
    const cef_bridge_client_callbacks* callbacks
);

void cef_bridge_browser_destroy(cef_bridge_browser_t browser);

// Navigation
int cef_bridge_browser_load_url(cef_bridge_browser_t browser, const char* url);
int cef_bridge_browser_go_back(cef_bridge_browser_t browser);
int cef_bridge_browser_go_forward(cef_bridge_browser_t browser);
int cef_bridge_browser_reload(cef_bridge_browser_t browser);
int cef_bridge_browser_stop(cef_bridge_browser_t browser);

// Page control
int cef_bridge_browser_set_zoom(cef_bridge_browser_t browser, double level);

// JavaScript
int cef_bridge_browser_execute_js(cef_bridge_browser_t browser, const char* script);

// DevTools
int cef_bridge_browser_show_devtools(cef_bridge_browser_t browser);
int cef_bridge_browser_close_devtools(cef_bridge_browser_t browser);

// Visibility
void cef_bridge_browser_set_hidden(cef_bridge_browser_t browser, bool hidden);
void cef_bridge_browser_notify_resized(cef_bridge_browser_t browser);
void cef_bridge_browser_invalidate(cef_bridge_browser_t browser);

// Find
int cef_bridge_browser_find(cef_bridge_browser_t browser, const char* text, bool forward, bool case_sensitive);
int cef_bridge_browser_stop_finding(cef_bridge_browser_t browser);

// -------------------------------------------------------------------
// Input event forwarding (NSEvent → CEF)
// -------------------------------------------------------------------

void cef_bridge_browser_send_mouse_click(
    cef_bridge_browser_t browser,
    int x, int y,
    int button_type,    // 0=left, 1=middle, 2=right
    bool mouse_up,
    int click_count,
    uint32_t modifiers
);

void cef_bridge_browser_send_mouse_move(
    cef_bridge_browser_t browser,
    int x, int y,
    bool mouse_leave,
    uint32_t modifiers
);

void cef_bridge_browser_send_mouse_wheel(
    cef_bridge_browser_t browser,
    int x, int y,
    int delta_x, int delta_y,
    uint32_t modifiers
);

void cef_bridge_browser_send_key_event(
    cef_bridge_browser_t browser,
    int event_type,           // 0=RAWKEYDOWN, 1=KEYUP, 2=CHAR
    int windows_key_code,
    int native_key_code,
    uint32_t modifiers,
    uint16_t character,
    uint16_t unmodified_character,
    bool is_system_key
);

void cef_bridge_browser_send_focus(cef_bridge_browser_t browser, bool focus);

// -------------------------------------------------------------------
// Utility
// -------------------------------------------------------------------

void cef_bridge_free_string(char* str);
char* cef_bridge_get_version(void);

#ifdef __cplusplus
}
#endif

#endif // CEF_BRIDGE_H
