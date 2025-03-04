/*
 * QEMU Cocoa CG display driver
 *
 * Copyright (c) 2008 Mike Kronenberg
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 * THE SOFTWARE.
 */

#define GL_SILENCE_DEPRECATION

#include "qemu/osdep.h"

#import <Cocoa/Cocoa.h>
#include <crt_externs.h>

#include "qemu/help-texts.h"
#include "qemu-main.h"
#include "ui/clipboard.h"
#include "ui/console.h"
#include "ui/input.h"
#include "ui/kbd-state.h"
#include "sysemu/sysemu.h"
#include "sysemu/runstate.h"
#include "sysemu/runstate-action.h"
#include "sysemu/cpu-throttle.h"
#include "qapi/error.h"
#include "qapi/qapi-commands-block.h"
#include "qapi/qapi-commands-machine.h"
#include "qapi/qapi-commands-misc.h"
#include "sysemu/blockdev.h"
#include "qemu-version.h"
#include "qemu/cutils.h"
#include "qemu/main-loop.h"
#include "qemu/module.h"
#include <Carbon/Carbon.h>
#include "hw/core/cpu.h"

#ifdef CONFIG_EGL
#include "ui/egl-context.h"
#endif

#ifndef MAC_OS_X_VERSION_10_13
#define MAC_OS_X_VERSION_10_13 101300
#endif

/* 10.14 deprecates NSOnState and NSOffState in favor of
 * NSControlStateValueOn/Off, which were introduced in 10.13.
 * Define for older versions
 */
#if MAC_OS_X_VERSION_MAX_ALLOWED < MAC_OS_X_VERSION_10_13
#define NSControlStateValueOn NSOnState
#define NSControlStateValueOff NSOffState
#endif

//#define DEBUG

#ifdef DEBUG
#define COCOA_DEBUG(...)  { (void) fprintf (stdout, __VA_ARGS__); }
#else
#define COCOA_DEBUG(...)  ((void) 0)
#endif

#define cgrect(nsrect) (*(CGRect *)&(nsrect))

#define UC_CTRL_KEY "\xe2\x8c\x83"
#define UC_ALT_KEY "\xe2\x8c\xa5"

typedef struct CocoaListener {
    DisplayChangeListener dcl;
    QEMUCursor *cursor;
    int mouse_x;
    int mouse_y;
    int mouse_on;
#ifdef CONFIG_OPENGL
    uint32_t gl_scanout_id;
    DisplayGLTextureBorrower gl_scanout_borrow;
    bool gl_scanout_y0_top;
#endif
} CocoaListener;

typedef struct {
    int width;
    int height;
} QEMUScreen;

static void cocoa_switch(DisplayChangeListener *dcl,
                         DisplaySurface *surface);

static void cocoa_cursor_update(void);

static NSWindow *normalWindow;
static CocoaListener *active_listener;
static CocoaListener *listeners;
static size_t listeners_count;
static DisplaySurface *surface;
static QemuMutex draw_mutex;
static CGImageRef cursor_cgimage;
static QKbdState *kbd;
static int cursor_hide = 1;
static int left_command_key_enabled = 1;
static bool swap_opt_cmd;

static NSTextField *pauseLabel;

static NSInteger cbchangecount = -1;
static QemuClipboardInfo *cbinfo;
static QemuEvent cbevent;

#ifdef CONFIG_OPENGL

static GLuint cursor_texture;
static bool gl_dirty;
static QEMUGLContext view_ctx;

#ifdef CONFIG_EGL
static EGLSurface egl_surface;
#endif

static void cocoa_gl_switch(DisplayChangeListener *dcl,
                            DisplaySurface *new_surface);

static void cocoa_gl_cursor_update(void);

static bool cocoa_gl_is_compatible_dcl(DisplayGLCtx *dgc,
                                       DisplayChangeListener *dcl);

static QEMUGLContext cocoa_gl_create_context(DisplayGLCtx *dgc,
                                             QEMUGLParams *params);

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx);

static int cocoa_gl_make_context_current(DisplayGLCtx *dgc, QEMUGLContext ctx);

static const DisplayGLCtxOps dgc_ops = {
    .dpy_gl_ctx_is_compatible_dcl = cocoa_gl_is_compatible_dcl,
    .dpy_gl_ctx_create            = cocoa_gl_create_context,
    .dpy_gl_ctx_destroy           = cocoa_gl_destroy_context,
    .dpy_gl_ctx_make_current      = cocoa_gl_make_context_current,
};

static DisplayGLCtx dgc = {
    .ops = &dgc_ops,
};

#endif

// Utility functions to run specified code block with iothread lock held
typedef void (^CodeBlock)(void);
typedef bool (^BoolCodeBlock)(void);

static void with_iothread_lock(CodeBlock block)
{
    bool locked = qemu_mutex_iothread_locked();
    if (!locked) {
        qemu_mutex_lock_iothread();
    }
    block();
    if (!locked) {
        qemu_mutex_unlock_iothread();
    }
}

static bool bool_with_iothread_lock(BoolCodeBlock block)
{
    bool locked = qemu_mutex_iothread_locked();
    bool val;

    if (!locked) {
        qemu_mutex_lock_iothread();
    }
    val = block();
    if (!locked) {
        qemu_mutex_unlock_iothread();
    }
    return val;
}

static int cocoa_keycode_to_qemu(int keycode)
{
    if (qemu_input_map_osx_to_qcode_len <= keycode) {
        error_report("(cocoa) warning unknown keycode 0x%x", keycode);
        return 0;
    }
    return qemu_input_map_osx_to_qcode[keycode];
}

/* Displays an alert dialog box with the specified message */
static void QEMU_Alert(NSString *message)
{
    NSAlert *alert;
    alert = [NSAlert new];
    [alert setMessageText: message];
    [alert runModal];
}

/* Handles any errors that happen with a device transaction */
static void handleAnyDeviceErrors(Error * err)
{
    if (err) {
        QEMU_Alert([NSString stringWithCString: error_get_pretty(err)
                                      encoding: NSASCIIStringEncoding]);
        error_free(err);
    }
}

static CGRect compute_cursor_clip_rect(int screen_height,
                                       int given_mouse_x, int given_mouse_y,
                                       int cursor_width, int cursor_height)
{
    CGRect rect;

    rect.origin.x = MAX(0, -given_mouse_x);
    rect.origin.y = 0;
    rect.size.width = MIN(cursor_width, cursor_width + given_mouse_x);
    rect.size.height = cursor_height - rect.origin.x;

    return rect;
}

/*
 ------------------------------------------------------
    QemuCocoaView
 ------------------------------------------------------
*/
@interface QemuCocoaView : NSView
{
    NSTrackingArea *trackingArea;
    QEMUScreen screen;
    /* The state surrounding mouse grabbing is potentially confusing.
     * isAbsoluteEnabled tracks qemu_input_is_absolute() [ie "is the emulated
     *   pointing device an absolute-position one?"], but is only updated on
     *   next refresh.
     * isMouseGrabbed tracks whether GUI events are directed to the guest;
     *   it controls whether special keys like Cmd get sent to the guest,
     *   and whether we capture the mouse when in non-absolute mode.
     */
    BOOL isMouseGrabbed;
    BOOL isAbsoluteEnabled;
    CFMachPortRef eventsTap;
}
- (void) grabMouse;
- (void) ungrabMouse;
- (void) setFullGrab:(id)sender;
- (void) handleMonitorInput:(NSEvent *)event;
- (bool) handleEvent:(NSEvent *)event;
- (bool) handleEventLocked:(NSEvent *)event;
- (void) notifyMouseModeChange;
- (BOOL) isMouseGrabbed;
- (void) raiseAllKeys;
@end

QemuCocoaView *cocoaView;

static CGEventRef handleTapEvent(CGEventTapProxy proxy, CGEventType type, CGEventRef cgEvent, void *userInfo)
{
    QemuCocoaView *cocoaView = userInfo;
    NSEvent *event = [NSEvent eventWithCGEvent:cgEvent];
    if ([cocoaView isMouseGrabbed] && [cocoaView handleEvent:event]) {
        COCOA_DEBUG("Global events tap: qemu handled the event, capturing!\n");
        return NULL;
    }
    COCOA_DEBUG("Global events tap: qemu did not handle the event, letting it through...\n");

    return cgEvent;
}

@implementation QemuCocoaView
- (id)initWithFrame:(NSRect)frameRect
{
    COCOA_DEBUG("QemuCocoaView: initWithFrame\n");

    self = [super initWithFrame:frameRect];
    if (self) {

        screen.width = frameRect.size.width;
        screen.height = frameRect.size.height;

    }
    return self;
}

- (void) dealloc
{
    COCOA_DEBUG("QemuCocoaView: dealloc\n");

    if (eventsTap) {
        CFRelease(eventsTap);
    }

    [super dealloc];
}

- (BOOL) isOpaque
{
    return YES;
}

- (void) removeTrackingRect
{
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
        [trackingArea release];
        trackingArea = nil;
    }
}

- (void) frameUpdated
{
    [self removeTrackingRect];

    if ([self window]) {
        NSTrackingAreaOptions options = NSTrackingActiveInKeyWindow |
                                        NSTrackingMouseEnteredAndExited |
                                        NSTrackingMouseMoved;
        trackingArea = [[NSTrackingArea alloc] initWithRect:[self frame]
                                                    options:options
                                                      owner:self
                                                   userInfo:nil];
        [self addTrackingArea:trackingArea];
        [self updateUIInfo];
    }
}

- (void) viewDidMoveToWindow
{
    [self resizeWindow];
    [self frameUpdated];
}

- (void) viewWillMoveToWindow:(NSWindow *)newWindow
{
    [self removeTrackingRect];
}

- (void) selectConsoleLocked:(unsigned int)index
{
    DisplaySurface *new_surface;

    if (index >= listeners_count) {
        return;
    }

    active_listener = &listeners[index];
    new_surface = qemu_console_surface(active_listener->dcl.con);
    qkbd_state_lift_all_keys(kbd);
    qkbd_state_free(kbd);
    kbd = qkbd_state_init(active_listener->dcl.con);

    if (display_opengl) {
#ifdef CONFIG_OPENGL
        cocoa_gl_cursor_update();
        cocoa_gl_switch(&active_listener->dcl, new_surface);
#else
        g_assert_not_reached();
#endif
    } else {
        cocoa_cursor_update();
        cocoa_switch(&active_listener->dcl, new_surface);
    }

    [self notifyMouseModeChange];
    [self updateUIInfoLocked];
}

- (void) hideCursor
{
    if (!cursor_hide) {
        return;
    }
    [NSCursor hide];
}

- (void) unhideCursor
{
    if (!cursor_hide) {
        return;
    }
    [NSCursor unhide];
}

- (CGRect) convertCursorClipRectToDraw:(CGRect)rect
                          screenHeight:(int)screen_height
                                mouseX:(int)given_mouse_x
                                mouseY:(int)given_mouse_y
{
    CGFloat d = [self frame].size.height / (CGFloat)screen_height;

    rect.origin.x = (rect.origin.x + given_mouse_x) * d;
    rect.origin.y = (screen_height - rect.origin.y - given_mouse_y - rect.size.height) * d;
    rect.size.width *= d;
    rect.size.height *= d;

    return rect;
}

- (void) drawRect:(NSRect) rect
{
    COCOA_DEBUG("QemuCocoaView: drawRect\n");

#ifdef CONFIG_OPENGL
    if (display_opengl) {
        return;
    }
#endif

    // get CoreGraphic context
    CGContextRef viewContextRef = [[NSGraphicsContext currentContext] CGContext];

    CGContextSetInterpolationQuality (viewContextRef, kCGInterpolationNone);
    CGContextSetShouldAntialias (viewContextRef, NO);

    qemu_mutex_lock(&draw_mutex);

    // draw screen bitmap directly to Core Graphics context
    if (!surface) {
        // Draw request before any guest device has set up a framebuffer:
        // just draw an opaque black rectangle
        CGContextSetRGBFillColor(viewContextRef, 0, 0, 0, 1.0);
        CGContextFillRect(viewContextRef, NSRectToCGRect(rect));
    } else {
        int w = surface_width(surface);
        int h = surface_height(surface);
        int bitsPerPixel = PIXMAN_FORMAT_BPP(surface_format(surface));
        int stride = surface_stride(surface);

        CGDataProviderRef dataProviderRef = CGDataProviderCreateWithData(
            NULL,
            surface_data(surface),
            stride * h,
            NULL
        );
        CGImageRef imageRef = CGImageCreate(
            w, //width
            h, //height
            DIV_ROUND_UP(bitsPerPixel, 8) * 2, //bitsPerComponent
            bitsPerPixel, //bitsPerPixel
            stride, //bytesPerRow
            CGColorSpaceCreateWithName(kCGColorSpaceSRGB), //colorspace
            kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst, //bitmapInfo
            dataProviderRef, //provider
            NULL, //decode
            0, //interpolate
            kCGRenderingIntentDefault //intent
        );
        // selective drawing code (draws only dirty rectangles) (OS X >= 10.4)
        const NSRect *rectList;
        NSInteger rectCount;
        int i;
        CGImageRef clipImageRef;
        CGRect clipRect;
        CGFloat d = (CGFloat)h / [self frame].size.height;

        [self getRectsBeingDrawn:&rectList count:&rectCount];
        for (i = 0; i < rectCount; i++) {
            clipRect.origin.x = rectList[i].origin.x * d;
            clipRect.origin.y = (float)h - (rectList[i].origin.y + rectList[i].size.height) * d;
            clipRect.size.width = rectList[i].size.width * d;
            clipRect.size.height = rectList[i].size.height * d;
            clipImageRef = CGImageCreateWithImageInRect(
                                                        imageRef,
                                                        clipRect
                                                        );
            CGContextDrawImage (viewContextRef, cgrect(rectList[i]), clipImageRef);
            CGImageRelease (clipImageRef);
        }
        CGImageRelease (imageRef);
        CGDataProviderRelease(dataProviderRef);

        if (active_listener->mouse_on) {
            size_t cursor_width = CGImageGetWidth(cursor_cgimage);
            size_t cursor_height = CGImageGetHeight(cursor_cgimage);
            int mouse_x = active_listener->mouse_x;
            int mouse_y = active_listener->mouse_y;
            clipRect = compute_cursor_clip_rect(h, mouse_x, mouse_y,
                                                cursor_width,
                                                cursor_height);
            CGRect drawRect = [self convertCursorClipRectToDraw:clipRect
                                                   screenHeight:h
                                                         mouseX:mouse_x
                                                         mouseY:mouse_y];
            clipImageRef = CGImageCreateWithImageInRect(
                                                        cursor_cgimage,
                                                        clipRect
                                                        );
            CGContextDrawImage(viewContextRef, drawRect, clipImageRef);
            CGImageRelease (clipImageRef);
        }
    }

    qemu_mutex_unlock(&draw_mutex);
}

- (NSSize) computeUnzoomedSize
{
    CGFloat width = screen.width / [[self window] backingScaleFactor];
    CGFloat height = screen.height / [[self window] backingScaleFactor];

    return NSMakeSize(width, height);
}

- (NSSize) fixZoomedFullScreenSize:(NSSize)proposedSize
{
    NSSize size;

    size.width = (CGFloat)screen.width * proposedSize.height;
    size.height = (CGFloat)screen.height * proposedSize.width;

    if (size.width < size.height) {
        size.width /= screen.height;
        size.height = proposedSize.height;
    } else {
        size.width = proposedSize.width;
        size.height /= screen.width;
    }

    return size;
}

- (NSSize) screenSafeAreaSize
{
    NSSize size = [[[self window] screen] frame].size;
    NSEdgeInsets insets = [[[self window] screen] safeAreaInsets];
    size.width -= insets.left + insets.right;
    size.height -= insets.top + insets.bottom;
    return size;
}

- (void) resizeWindow
{
    [[self window] setContentAspectRatio:NSMakeSize(screen.width, screen.height)];

    if (([[self window] styleMask] & NSWindowStyleMaskResizable) == 0) {
        [[self window] setContentSize:[self computeUnzoomedSize]];
        [[self window] center];
    } else if (([[self window] styleMask] & NSWindowStyleMaskFullScreen) != 0) {
        [[self window] setContentSize:[self fixZoomedFullScreenSize:[self screenSafeAreaSize]]];
        [[self window] center];
    }
}

- (void) updateUIInfoLocked
{
    /* Must be called with the iothread lock, i.e. via updateUIInfo */
    NSSize frameSize;
    QemuUIInfo info;

    if ([self window]) {
        NSDictionary *description = [[[self window] screen] deviceDescription];
        CGDirectDisplayID display = [[description objectForKey:@"NSScreenNumber"] unsignedIntValue];
        NSSize screenSize = [[[self window] screen] frame].size;
        CGSize screenPhysicalSize = CGDisplayScreenSize(display);
        CVDisplayLinkRef displayLink;

        if (([[self window] styleMask] & NSWindowStyleMaskFullScreen) == 0) {
            frameSize = [self frame].size;
        } else {
            frameSize = [self screenSafeAreaSize];
        }

        if (!CVDisplayLinkCreateWithCGDisplay(display, &displayLink)) {
            CVTime period = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink);
            CVDisplayLinkRelease(displayLink);
            if (!(period.flags & kCVTimeIsIndefinite)) {
                update_displaychangelistener(&active_listener->dcl,
                                             1000 * period.timeValue / period.timeScale);
                info.refresh_rate = (int64_t)1000 * period.timeScale / period.timeValue;
            }
        }

        info.width_mm = frameSize.width / screenSize.width * screenPhysicalSize.width;
        info.height_mm = frameSize.height / screenSize.height * screenPhysicalSize.height;
    } else {
        frameSize = [self frame].size;
        info.width_mm = 0;
        info.height_mm = 0;
    }

    NSSize frameBackingSize = [self convertSizeToBacking:frameSize];

    info.xoff = 0;
    info.yoff = 0;
    info.width = frameBackingSize.width;
    info.height = frameBackingSize.height;

    dpy_set_ui_info(active_listener->dcl.con, &info, TRUE);
}

- (void) updateUIInfo
{
    if (!listeners) {
        return;
    }

    with_iothread_lock(^{
        [self updateUIInfoLocked];
    });
}

- (void) updateScreenWidth:(int)w height:(int)h
{
    COCOA_DEBUG("QemuCocoaView: updateScreenWidth:height:\n");

    if (w != screen.width || h != screen.height) {
        COCOA_DEBUG("updateScreenWidth:height: new size %d x %d\n", w, h);
        screen.width = w;
        screen.height = h;
        [self resizeWindow];
    }
}

- (void) setFullGrab:(id)sender
{
    COCOA_DEBUG("QemuCocoaView: setFullGrab\n");

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp) | CGEventMaskBit(kCGEventFlagsChanged);
    eventsTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                 mask, handleTapEvent, self);
    if (!eventsTap) {
        warn_report("Could not create event tap, system key combos will not be captured.\n");
        return;
    } else {
        COCOA_DEBUG("Global events tap created! Will capture system key combos.\n");
    }

    CFRunLoopRef runLoop = CFRunLoopGetCurrent();
    if (!runLoop) {
        warn_report("Could not obtain current CF RunLoop, system key combos will not be captured.\n");
        return;
    }

    CFRunLoopSourceRef tapEventsSrc = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventsTap, 0);
    if (!tapEventsSrc ) {
        warn_report("Could not obtain current CF RunLoop, system key combos will not be captured.\n");
        return;
    }

    CFRunLoopAddSource(runLoop, tapEventsSrc, kCFRunLoopDefaultMode);
    CFRelease(tapEventsSrc);
}

- (void) toggleKey: (int)keycode {
    qkbd_state_key_event(kbd, keycode, !qkbd_state_key_get(kbd, keycode));
}

// Does the work of sending input to the monitor
- (void) handleMonitorInput:(NSEvent *)event
{
    int keysym = 0;
    int control_key = 0;

    // if the control key is down
    if ([event modifierFlags] & NSEventModifierFlagControl) {
        control_key = 1;
    }

    /* translates Macintosh keycodes to QEMU's keysym */

    static const int without_control_translation[] = {
        [0 ... 0xff] = 0,   // invalid key

        [kVK_UpArrow]       = QEMU_KEY_UP,
        [kVK_DownArrow]     = QEMU_KEY_DOWN,
        [kVK_RightArrow]    = QEMU_KEY_RIGHT,
        [kVK_LeftArrow]     = QEMU_KEY_LEFT,
        [kVK_Home]          = QEMU_KEY_HOME,
        [kVK_End]           = QEMU_KEY_END,
        [kVK_PageUp]        = QEMU_KEY_PAGEUP,
        [kVK_PageDown]      = QEMU_KEY_PAGEDOWN,
        [kVK_ForwardDelete] = QEMU_KEY_DELETE,
        [kVK_Delete]        = QEMU_KEY_BACKSPACE,
    };

    static const int with_control_translation[] = {
        [0 ... 0xff] = 0,   // invalid key

        [kVK_UpArrow]       = QEMU_KEY_CTRL_UP,
        [kVK_DownArrow]     = QEMU_KEY_CTRL_DOWN,
        [kVK_RightArrow]    = QEMU_KEY_CTRL_RIGHT,
        [kVK_LeftArrow]     = QEMU_KEY_CTRL_LEFT,
        [kVK_Home]          = QEMU_KEY_CTRL_HOME,
        [kVK_End]           = QEMU_KEY_CTRL_END,
        [kVK_PageUp]        = QEMU_KEY_CTRL_PAGEUP,
        [kVK_PageDown]      = QEMU_KEY_CTRL_PAGEDOWN,
    };

    if (control_key != 0) { /* If the control key is being used */
        if ([event keyCode] < ARRAY_SIZE(with_control_translation)) {
            keysym = with_control_translation[[event keyCode]];
        }
    } else {
        if ([event keyCode] < ARRAY_SIZE(without_control_translation)) {
            keysym = without_control_translation[[event keyCode]];
        }
    }

    // if not a key that needs translating
    if (keysym == 0) {
        NSString *ks = [event characters];
        if ([ks length] > 0) {
            keysym = [ks characterAtIndex:0];
        }
    }

    if (keysym) {
        kbd_put_keysym_console(active_listener->dcl.con, keysym);
    }
}

- (bool) handleEvent:(NSEvent *)event
{
    if(!listeners) {
        return false;
    }
    return bool_with_iothread_lock(^{
        return [self handleEventLocked:event];
    });
}

- (bool) handleEventLocked:(NSEvent *)event
{
    /* Return true if we handled the event, false if it should be given to OSX */
    COCOA_DEBUG("QemuCocoaView: handleEvent\n");
    int buttons = 0;
    int keycode = 0;
    NSUInteger modifiers = [event modifierFlags];

    /*
     * Check -[NSEvent modifierFlags] here.
     *
     * There is a NSEventType for an event notifying the change of
     * -[NSEvent modifierFlags], NSEventTypeFlagsChanged but these operations
     * are performed for any events because a modifier state may change while
     * the application is inactive (i.e. no events fire) and we don't want to
     * wait for another modifier state change to detect such a change.
     *
     * NSEventModifierFlagCapsLock requires a special treatment. The other flags
     * are handled in similar manners.
     *
     * NSEventModifierFlagCapsLock
     * ---------------------------
     *
     * If CapsLock state is changed, "up" and "down" events will be fired in
     * sequence, effectively updates CapsLock state on the guest.
     *
     * The other flags
     * ---------------
     *
     * If a flag is not set, fire "up" events for all keys which correspond to
     * the flag. Note that "down" events are not fired here because the flags
     * checked here do not tell what exact keys are down.
     *
     * If one of the keys corresponding to a flag is down, we rely on
     * -[NSEvent keyCode] of an event whose -[NSEvent type] is
     * NSEventTypeFlagsChanged to know the exact key which is down, which has
     * the following two downsides:
     * - It does not work when the application is inactive as described above.
     * - It malfactions *after* the modifier state is changed while the
     *   application is inactive. It is because -[NSEvent keyCode] does not tell
     *   if the key is up or down, and requires to infer the current state from
     *   the previous state. It is still possible to fix such a malfanction by
     *   completely leaving your hands from the keyboard, which hopefully makes
     *   this implementation usable enough.
     */
    if (!!(modifiers & NSEventModifierFlagCapsLock) !=
        qkbd_state_modifier_get(kbd, QKBD_MOD_CAPSLOCK)) {
        qkbd_state_key_event(kbd, Q_KEY_CODE_CAPS_LOCK, true);
        qkbd_state_key_event(kbd, Q_KEY_CODE_CAPS_LOCK, false);
    }

    if (!(modifiers & NSEventModifierFlagShift)) {
        qkbd_state_key_event(kbd, Q_KEY_CODE_SHIFT, false);
        qkbd_state_key_event(kbd, Q_KEY_CODE_SHIFT_R, false);
    }
    if (!(modifiers & NSEventModifierFlagControl)) {
        qkbd_state_key_event(kbd, Q_KEY_CODE_CTRL, false);
        qkbd_state_key_event(kbd, Q_KEY_CODE_CTRL_R, false);
    }
    if (!(modifiers & NSEventModifierFlagOption)) {
        if (swap_opt_cmd) {
            qkbd_state_key_event(kbd, Q_KEY_CODE_META_L, false);
            qkbd_state_key_event(kbd, Q_KEY_CODE_META_R, false);
        } else {
            qkbd_state_key_event(kbd, Q_KEY_CODE_ALT, false);
            qkbd_state_key_event(kbd, Q_KEY_CODE_ALT_R, false);
        }
    }
    if (!(modifiers & NSEventModifierFlagCommand)) {
        if (swap_opt_cmd) {
            qkbd_state_key_event(kbd, Q_KEY_CODE_ALT, false);
            qkbd_state_key_event(kbd, Q_KEY_CODE_ALT_R, false);
        } else {
            qkbd_state_key_event(kbd, Q_KEY_CODE_META_L, false);
            qkbd_state_key_event(kbd, Q_KEY_CODE_META_R, false);
        }
    }

    switch ([event type]) {
        case NSEventTypeFlagsChanged:
            switch ([event keyCode]) {
                case kVK_Shift:
                    if (!!(modifiers & NSEventModifierFlagShift)) {
                        [self toggleKey:Q_KEY_CODE_SHIFT];
                    }
                    return true;

                case kVK_RightShift:
                    if (!!(modifiers & NSEventModifierFlagShift)) {
                        [self toggleKey:Q_KEY_CODE_SHIFT_R];
                    }
                    return true;

                case kVK_Control:
                    if (!!(modifiers & NSEventModifierFlagControl)) {
                        [self toggleKey:Q_KEY_CODE_CTRL];
                    }
                    return true;

                case kVK_RightControl:
                    if (!!(modifiers & NSEventModifierFlagControl)) {
                        [self toggleKey:Q_KEY_CODE_CTRL_R];
                    }
                    return true;

                case kVK_Option:
                    if (!!(modifiers & NSEventModifierFlagOption)) {
                        if (swap_opt_cmd) {
                            [self toggleKey:Q_KEY_CODE_META_L];
                        } else {
                            [self toggleKey:Q_KEY_CODE_ALT];
                        }
                    }
                    return true;

                case kVK_RightOption:
                    if (!!(modifiers & NSEventModifierFlagOption)) {
                        if (swap_opt_cmd) {
                            [self toggleKey:Q_KEY_CODE_META_R];
                        } else {
                            [self toggleKey:Q_KEY_CODE_ALT_R];
                        }
                    }
                    return true;

                /* Don't pass command key changes to guest unless mouse is grabbed */
                case kVK_Command:
                    if (isMouseGrabbed &&
                        !!(modifiers & NSEventModifierFlagCommand) &&
                        left_command_key_enabled) {
                        if (swap_opt_cmd) {
                            [self toggleKey:Q_KEY_CODE_ALT];
                        } else {
                            [self toggleKey:Q_KEY_CODE_META_L];
                        }
                    }
                    return true;

                case kVK_RightCommand:
                    if (isMouseGrabbed &&
                        !!(modifiers & NSEventModifierFlagCommand)) {
                        if (swap_opt_cmd) {
                            [self toggleKey:Q_KEY_CODE_ALT_R];
                        } else {
                            [self toggleKey:Q_KEY_CODE_META_R];
                        }
                    }
                    return true;

                default:
                    return true;
            }
        case NSEventTypeKeyDown:
            keycode = cocoa_keycode_to_qemu([event keyCode]);

            // forward command key combos to the host UI unless the mouse is grabbed
            if (!isMouseGrabbed && ([event modifierFlags] & NSEventModifierFlagCommand)) {
                return false;
            }

            // default

            // handle control + alt Key Combos (ctrl+alt+[1..9,g] is reserved for QEMU)
            if (([event modifierFlags] & NSEventModifierFlagControl) && ([event modifierFlags] & NSEventModifierFlagOption)) {
                NSString *keychar = [event charactersIgnoringModifiers];
                if ([keychar length] == 1) {
                    char key = [keychar characterAtIndex:0];
                    switch (key) {

                        // enable graphic console
                        case '1' ... '9':
                            [self selectConsoleLocked:key - '0' - 1]; /* ascii math */
                            return true;

                        // release the mouse grab
                        case 'g':
                            [self ungrabMouse];
                            return true;
                    }
                }
            }

            if (qemu_console_is_graphic(active_listener->dcl.con)) {
                qkbd_state_key_event(kbd, keycode, true);
            } else {
                [self handleMonitorInput: event];
            }
            return true;
        case NSEventTypeKeyUp:
            keycode = cocoa_keycode_to_qemu([event keyCode]);

            // don't pass the guest a spurious key-up if we treated this
            // command-key combo as a host UI action
            if (!isMouseGrabbed && ([event modifierFlags] & NSEventModifierFlagCommand)) {
                return true;
            }

            if (qemu_console_is_graphic(active_listener->dcl.con)) {
                qkbd_state_key_event(kbd, keycode, false);
            }
            return true;
        case NSEventTypeScrollWheel:
            /*
             * Send wheel events to the guest regardless of window focus.
             * This is in-line with standard Mac OS X UI behaviour.
             */

            /*
             * We shouldn't have got a scroll event when deltaY and delta Y
             * are zero, hence no harm in dropping the event
             */
            if ([event deltaY] != 0 || [event deltaX] != 0) {
            /* Determine if this is a scroll up or scroll down event */
                if ([event deltaY] != 0) {
                  buttons = ([event deltaY] > 0) ?
                    INPUT_BUTTON_WHEEL_UP : INPUT_BUTTON_WHEEL_DOWN;
                } else if ([event deltaX] != 0) {
                  buttons = ([event deltaX] > 0) ?
                    INPUT_BUTTON_WHEEL_LEFT : INPUT_BUTTON_WHEEL_RIGHT;
                }

                qemu_input_queue_btn(active_listener->dcl.con, buttons, true);
                qemu_input_event_sync();
                qemu_input_queue_btn(active_listener->dcl.con, buttons, false);
                qemu_input_event_sync();
            }

            /*
             * Since deltaX/deltaY also report scroll wheel events we prevent mouse
             * movement code from executing.
             */
            return true;
        default:
            return false;
    }
}

- (void) handleMouseEvent:(NSEvent *)event
{
    if (!isMouseGrabbed) {
        return;
    }

    with_iothread_lock(^{
        QemuConsole *con = active_listener->dcl.con;

        if (isAbsoluteEnabled) {
            CGFloat d = (CGFloat)screen.height / [self frame].size.height;
            NSPoint p = [event locationInWindow];
            // Note that the origin for Cocoa mouse coords is bottom left, not top left.
            qemu_input_queue_abs(con, INPUT_AXIS_X, p.x * d, 0, screen.width);
            qemu_input_queue_abs(con, INPUT_AXIS_Y, screen.height - p.y * d, 0, screen.height);
        } else {
            CGFloat d = (CGFloat)screen.height / [self convertSizeToBacking:[self frame].size].height;
            qemu_input_queue_rel(con, INPUT_AXIS_X, [event deltaX] * d);
            qemu_input_queue_rel(con, INPUT_AXIS_Y, [event deltaY] * d);
        }

        qemu_input_event_sync();
    });
}

- (void) handleMouseEvent:(NSEvent *)event button:(InputButton)button down:(bool)down
{
    if (!isMouseGrabbed) {
        return;
    }

    with_iothread_lock(^{
        qemu_input_queue_btn(active_listener->dcl.con, button, down);
    });

    [self handleMouseEvent:event];
}

- (void) mouseExited:(NSEvent *)event
{
    if (isAbsoluteEnabled && isMouseGrabbed) {
        [self ungrabMouse];
    }
}

- (void) mouseEntered:(NSEvent *)event
{
    if (isAbsoluteEnabled && !isMouseGrabbed) {
        [self grabMouse];
    }
}

- (void) mouseMoved:(NSEvent *)event
{
    [self handleMouseEvent:event];
}

- (void) mouseDown:(NSEvent *)event
{
    [self handleMouseEvent:event button:INPUT_BUTTON_LEFT down:true];
}

- (void) rightMouseDown:(NSEvent *)event
{
    [self handleMouseEvent:event button:INPUT_BUTTON_RIGHT down:true];
}

- (void) otherMouseDown:(NSEvent *)event
{
    [self handleMouseEvent:event button:INPUT_BUTTON_MIDDLE down:true];
}

- (void) mouseDragged:(NSEvent *)event
{
    [self handleMouseEvent:event];
}

- (void) rightMouseDragged:(NSEvent *)event
{
    [self handleMouseEvent:event];
}

- (void) otherMouseDragged:(NSEvent *)event
{
    [self handleMouseEvent:event];
}

- (void) mouseUp:(NSEvent *)event
{
    if (!isMouseGrabbed) {
        [self grabMouse];
    }

    [self handleMouseEvent:event button:INPUT_BUTTON_LEFT down:false];
}

- (void) rightMouseUp:(NSEvent *)event
{
    [self handleMouseEvent:event button:INPUT_BUTTON_RIGHT down:false];
}

- (void) otherMouseUp:(NSEvent *)event
{
    [self handleMouseEvent:event button:INPUT_BUTTON_MIDDLE down:false];
}

- (void) grabMouse
{
    COCOA_DEBUG("QemuCocoaView: grabMouse\n");

    if (!listeners) {
        return;
    }

    if (qemu_name)
        [normalWindow setTitle:[NSString stringWithFormat:@"QEMU %s - (Press  " UC_CTRL_KEY " " UC_ALT_KEY " G  to release Mouse)", qemu_name]];
    else
        [normalWindow setTitle:@"QEMU - (Press  " UC_CTRL_KEY " " UC_ALT_KEY " G  to release Mouse)"];
    [self hideCursor];
    CGAssociateMouseAndMouseCursorPosition(isAbsoluteEnabled);
    isMouseGrabbed = TRUE; // while isMouseGrabbed = TRUE, QemuCocoaApp sends all events to [cocoaView handleEvent:]
}

- (void) ungrabMouse
{
    COCOA_DEBUG("QemuCocoaView: ungrabMouse\n");

    if (qemu_name)
        [normalWindow setTitle:[NSString stringWithFormat:@"QEMU %s", qemu_name]];
    else
        [normalWindow setTitle:@"QEMU"];
    [self unhideCursor];
    CGAssociateMouseAndMouseCursorPosition(TRUE);
    isMouseGrabbed = FALSE;
    [self raiseAllButtons];
}

- (void) notifyMouseModeChange {
    bool tIsAbsoluteEnabled = bool_with_iothread_lock(^{
        return qemu_input_is_absolute(active_listener->dcl.con);
    });

    if (tIsAbsoluteEnabled == isAbsoluteEnabled) {
        return;
    }

    isAbsoluteEnabled = tIsAbsoluteEnabled;

    if (isMouseGrabbed) {
        if (isAbsoluteEnabled) {
            [self ungrabMouse];
        } else {
            CGAssociateMouseAndMouseCursorPosition(isAbsoluteEnabled);
        }
    }
}
- (BOOL) isMouseGrabbed {return isMouseGrabbed;}

/*
 * Makes the target think all down keys are being released.
 * This prevents a stuck key problem, since we will not see
 * key up events for those keys after we have lost focus.
 */
- (void) raiseAllKeys
{
    with_iothread_lock(^{
        qkbd_state_lift_all_keys(kbd);
    });
}

- (void) raiseAllButtons
{
    with_iothread_lock(^{
        qemu_input_queue_btn(active_listener->dcl.con, INPUT_BUTTON_LEFT, false);
        qemu_input_queue_btn(active_listener->dcl.con, INPUT_BUTTON_RIGHT, false);
        qemu_input_queue_btn(active_listener->dcl.con, INPUT_BUTTON_MIDDLE, false);
    });
}
@end



/*
 ------------------------------------------------------
    QemuCocoaAppController
 ------------------------------------------------------
*/
@interface QemuCocoaAppController : NSObject
                                       <NSWindowDelegate, NSApplicationDelegate>
{
}
- (void)doToggleFullScreen:(id)sender;
- (void)showQEMUDoc:(id)sender;
- (void)zoomToFit:(id) sender;
- (void)displayConsole:(id)sender;
- (void)pauseQEMU:(id)sender;
- (void)resumeQEMU:(id)sender;
- (void)displayPause;
- (void)removePause;
- (void)restartQEMU:(id)sender;
- (void)powerDownQEMU:(id)sender;
- (void)ejectDeviceMedia:(id)sender;
- (void)changeDeviceMedia:(id)sender;
- (BOOL)verifyQuit;
- (void)openDocumentation:(NSString *)filename;
- (IBAction) do_about_menu_item: (id) sender;
- (void)adjustSpeed:(id)sender;
@end

@implementation QemuCocoaAppController
- (id) init
{
    COCOA_DEBUG("QemuCocoaAppController: init\n");

    self = [super init];
    if (self) {

        // create a view and add it to the window
        cocoaView = [[QemuCocoaView alloc] initWithFrame:NSMakeRect(0.0, 0.0, 640.0, 480.0)];
        if(!cocoaView) {
            error_report("(cocoa) can't create a view");
            exit(1);
        }

        // create a window
        normalWindow = [[NSWindow alloc] initWithContentRect:[cocoaView frame]
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        if(!normalWindow) {
            error_report("(cocoa) can't create window");
            exit(1);
        }
        [normalWindow setAcceptsMouseMovedEvents:YES];
        [normalWindow setCollectionBehavior:NSWindowCollectionBehaviorFullScreenPrimary];
        [normalWindow setTitle:qemu_name ? [NSString stringWithFormat:@"QEMU %s", qemu_name] : @"QEMU"];
        [normalWindow setContentView:cocoaView];
        [normalWindow makeKeyAndOrderFront:self];
        [normalWindow center];
        [normalWindow setDelegate: self];

        /* Used for displaying pause on the screen */
        pauseLabel = [NSTextField new];
        [pauseLabel setBezeled:YES];
        [pauseLabel setDrawsBackground:YES];
        [pauseLabel setBackgroundColor: [NSColor whiteColor]];
        [pauseLabel setEditable:NO];
        [pauseLabel setSelectable:NO];
        [pauseLabel setStringValue: @"Paused"];
        [pauseLabel setFont: [NSFont fontWithName: @"Helvetica" size: 90]];
        [pauseLabel setTextColor: [NSColor blackColor]];
        [pauseLabel sizeToFit];
    }
    return self;
}

- (void) dealloc
{
    COCOA_DEBUG("QemuCocoaAppController: dealloc\n");

    if (cocoaView)
        [cocoaView release];
    [super dealloc];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification
{
    COCOA_DEBUG("QemuCocoaAppController: applicationWillTerminate\n");

    with_iothread_lock(^{
        shutdown_action = SHUTDOWN_ACTION_POWEROFF;
        qemu_system_shutdown_request(SHUTDOWN_CAUSE_HOST_UI);
    });

    /*
     * Sleep here, because returning will cause OSX to kill us
     * immediately; the QEMU main loop will handle the shutdown
     * request and terminate the process.
     */
    [NSThread sleepForTimeInterval:INFINITY];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)theApplication
{
    return YES;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:
                                                         (NSApplication *)sender
{
    COCOA_DEBUG("QemuCocoaAppController: applicationShouldTerminate\n");
    return [self verifyQuit];
}

- (void)windowDidChangeScreen:(NSNotification *)notification
{
    [cocoaView updateUIInfo];
}

- (void)windowDidEnterFullScreen:(NSNotification *)notification
{
    [cocoaView grabMouse];
}

- (void)windowDidExitFullScreen:(NSNotification *)notification
{
    [cocoaView resizeWindow];
    [cocoaView ungrabMouse];
}

- (void)windowDidResize:(NSNotification *)notification
{
    [cocoaView frameUpdated];
}

/* Called when the user clicks on a window's close button */
- (BOOL)windowShouldClose:(id)sender
{
    COCOA_DEBUG("QemuCocoaAppController: windowShouldClose\n");
    [NSApp terminate: sender];
    /* If the user allows the application to quit then the call to
     * NSApp terminate will never return. If we get here then the user
     * cancelled the quit, so we should return NO to not permit the
     * closing of this window.
     */
    return NO;
}

- (NSSize) window:(NSWindow *)window willUseFullScreenContentSize:(NSSize)proposedSize
{
    if (([normalWindow styleMask] & NSWindowStyleMaskResizable) == 0) {
        return [cocoaView computeUnzoomedSize];
    }

    return [cocoaView fixZoomedFullScreenSize:proposedSize];
}

- (NSApplicationPresentationOptions) window:(NSWindow *)window
                                     willUseFullScreenPresentationOptions:(NSApplicationPresentationOptions)proposedOptions;

{
    return (proposedOptions & ~(NSApplicationPresentationAutoHideDock | NSApplicationPresentationAutoHideMenuBar)) |
           NSApplicationPresentationHideDock | NSApplicationPresentationHideMenuBar;
}

/*
 * Called when QEMU goes into the background. Note that
 * [-NSWindowDelegate windowDidResignKey:] is used here instead of
 * [-NSApplicationDelegate applicationWillResignActive:] because it cannot
 * detect that the window loses focus when the deck is clicked on macOS 13.2.1.
 */
- (void) windowDidResignKey: (NSNotification *)aNotification
{
    COCOA_DEBUG("%s\n", __func__);
    [cocoaView ungrabMouse];
    [cocoaView raiseAllKeys];
}

/* We abstract the method called by the Enter Fullscreen menu item
 * because Mac OS 10.7 and higher disables it. This is because of the
 * menu item's old selector's name toggleFullScreen:
 */
- (void) doToggleFullScreen:(id)sender
{
    [normalWindow toggleFullScreen:sender];
}

- (void) setFullGrab:(id)sender
{
    COCOA_DEBUG("QemuCocoaAppController: setFullGrab\n");

    [cocoaView setFullGrab:sender];
}

/* Tries to find then open the specified filename */
- (void) openDocumentation: (NSString *) filename
{
    /* Where to look for local files */
    NSString *path_array[] = {@"../share/doc/qemu/", @"../doc/qemu/", @"docs/"};
    NSString *full_file_path;
    NSURL *full_file_url;

    /* iterate thru the possible paths until the file is found */
    int index;
    for (index = 0; index < ARRAY_SIZE(path_array); index++) {
        full_file_path = [[NSBundle mainBundle] executablePath];
        full_file_path = [full_file_path stringByDeletingLastPathComponent];
        full_file_path = [NSString stringWithFormat: @"%@/%@%@", full_file_path,
                          path_array[index], filename];
        full_file_url = [NSURL fileURLWithPath: full_file_path
                                   isDirectory: false];
        if ([[NSWorkspace sharedWorkspace] openURL: full_file_url] == YES) {
            return;
        }
    }

    /* If none of the paths opened a file */
    NSBeep();
    QEMU_Alert(@"Failed to open file");
}

- (void)showQEMUDoc:(id)sender
{
    COCOA_DEBUG("QemuCocoaAppController: showQEMUDoc\n");

    [self openDocumentation: @"index.html"];
}

/* Toggles the flag which stretches video to fit host window size */
- (void)zoomToFit:(id) sender
{
    if (([normalWindow styleMask] & NSWindowStyleMaskResizable) == 0) {
        [normalWindow setStyleMask:[normalWindow styleMask] | NSWindowStyleMaskResizable];
        [sender setState: NSControlStateValueOn];
    } else {
        [normalWindow setStyleMask:[normalWindow styleMask] & ~NSWindowStyleMaskResizable];
        [cocoaView resizeWindow];
        [sender setState: NSControlStateValueOff];
    }
}

/* Displays the console on the screen */
- (void)displayConsole:(id)sender
{
    with_iothread_lock(^{
        [cocoaView selectConsoleLocked:[sender tag]];
    });
}

/* Pause the guest */
- (void)pauseQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_stop(NULL);
    });
    [sender setEnabled: NO];
    [[[sender menu] itemWithTitle: @"Resume"] setEnabled: YES];
    [self displayPause];
}

/* Resume running the guest operating system */
- (void)resumeQEMU:(id) sender
{
    with_iothread_lock(^{
        qmp_cont(NULL);
    });
    [sender setEnabled: NO];
    [[[sender menu] itemWithTitle: @"Pause"] setEnabled: YES];
    [self removePause];
}

/* Displays the word pause on the screen */
- (void)displayPause
{
    /* Coordinates have to be calculated each time because the window can change its size */
    int xCoord, yCoord, width, height;
    xCoord = ([normalWindow frame].size.width - [pauseLabel frame].size.width)/2;
    yCoord = [normalWindow frame].size.height - [pauseLabel frame].size.height - ([pauseLabel frame].size.height * .5);
    width = [pauseLabel frame].size.width;
    height = [pauseLabel frame].size.height;
    [pauseLabel setFrame: NSMakeRect(xCoord, yCoord, width, height)];
    [cocoaView addSubview: pauseLabel];
}

/* Removes the word pause from the screen */
- (void)removePause
{
    [pauseLabel removeFromSuperview];
}

/* Restarts QEMU */
- (void)restartQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_system_reset(NULL);
    });
}

/* Powers down QEMU */
- (void)powerDownQEMU:(id)sender
{
    with_iothread_lock(^{
        qmp_system_powerdown(NULL);
    });
}

/* Ejects the media.
 * Uses sender's tag to figure out the device to eject.
 */
- (void)ejectDeviceMedia:(id)sender
{
    NSString * drive;
    drive = [sender representedObject];
    if(drive == nil) {
        NSBeep();
        QEMU_Alert(@"Failed to find drive to eject!");
        return;
    }

    __block Error *err = NULL;
    with_iothread_lock(^{
        qmp_eject([drive cStringUsingEncoding: NSASCIIStringEncoding],
                  NULL, false, false, &err);
    });
    handleAnyDeviceErrors(err);
}

/* Displays a dialog box asking the user to select an image file to load.
 * Uses sender's represented object value to figure out which drive to use.
 */
- (void)changeDeviceMedia:(id)sender
{
    /* Find the drive name */
    NSString * drive;
    drive = [sender representedObject];
    if(drive == nil) {
        NSBeep();
        QEMU_Alert(@"Could not find drive!");
        return;
    }

    /* Display the file open dialog */
    NSOpenPanel * openPanel;
    openPanel = [NSOpenPanel openPanel];
    [openPanel setCanChooseFiles: YES];
    [openPanel setAllowsMultipleSelection: NO];
    if([openPanel runModal] == NSModalResponseOK) {
        NSString * file = [[[openPanel URLs] objectAtIndex: 0] path];
        if(file == nil) {
            NSBeep();
            QEMU_Alert(@"Failed to convert URL to file path!");
            return;
        }

        __block Error *err = NULL;
        with_iothread_lock(^{
            qmp_blockdev_change_medium([drive cStringUsingEncoding:
                                                  NSASCIIStringEncoding],
                                       NULL,
                                       [file cStringUsingEncoding:
                                                 NSASCIIStringEncoding],
                                       "raw",
                                       true, false,
                                       false, 0,
                                       &err);
        });
        handleAnyDeviceErrors(err);
    }
}

/* Verifies if the user really wants to quit */
- (BOOL)verifyQuit
{
    NSAlert *alert = [NSAlert new];
    [alert autorelease];
    [alert setMessageText: @"Are you sure you want to quit QEMU?"];
    [alert addButtonWithTitle: @"Cancel"];
    [alert addButtonWithTitle: @"Quit"];
    if([alert runModal] == NSAlertSecondButtonReturn) {
        return YES;
    } else {
        return NO;
    }
}

/* The action method for the About menu item */
- (IBAction) do_about_menu_item: (id) sender
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    char *icon_path_c = get_relocated_path(CONFIG_QEMU_ICONDIR "/hicolor/512x512/apps/qemu.png");
    NSString *icon_path = [NSString stringWithUTF8String:icon_path_c];
    g_free(icon_path_c);
    NSImage *icon = [[NSImage alloc] initWithContentsOfFile:icon_path];
    NSString *version = @"QEMU emulator version " QEMU_FULL_VERSION;
    NSString *copyright = @QEMU_COPYRIGHT;
    NSDictionary *options;
    if (icon) {
        options = @{
            NSAboutPanelOptionApplicationIcon : icon,
            NSAboutPanelOptionApplicationVersion : version,
            @"Copyright" : copyright,
        };
        [icon release];
    } else {
        options = @{
            NSAboutPanelOptionApplicationVersion : version,
            @"Copyright" : copyright,
        };
    }
    [NSApp orderFrontStandardAboutPanelWithOptions:options];
    [pool release];
}

/* Used by the Speed menu items */
- (void)adjustSpeed:(id)sender
{
    int throttle_pct; /* throttle percentage */
    NSMenu *menu;

    menu = [sender menu];
    if (menu != nil)
    {
        /* Unselect the currently selected item */
        for (NSMenuItem *item in [menu itemArray]) {
            if (item.state == NSControlStateValueOn) {
                [item setState: NSControlStateValueOff];
                break;
            }
        }
    }

    // check the menu item
    [sender setState: NSControlStateValueOn];

    // get the throttle percentage
    throttle_pct = [sender tag];

    with_iothread_lock(^{
        cpu_throttle_set(throttle_pct);
    });
    COCOA_DEBUG("cpu throttling at %d%c\n", cpu_throttle_get_percentage(), '%');
}

@end

@interface QemuApplication : NSApplication
@end

@implementation QemuApplication
- (void)sendEvent:(NSEvent *)event
{
    COCOA_DEBUG("QemuApplication: sendEvent\n");
    if (![cocoaView handleEvent:event]) {
        [super sendEvent: event];
    }
}
@end

static void create_initial_menus(void)
{
    // Add menus
    NSMenu      *menu;
    NSMenuItem  *menuItem;

    [NSApp setMainMenu:[[NSMenu alloc] init]];
    [NSApp setServicesMenu:[[NSMenu alloc] initWithTitle:@"Services"]];

    // Application menu
    menu = [[NSMenu alloc] initWithTitle:@""];
    [menu addItemWithTitle:@"About QEMU" action:@selector(do_about_menu_item:) keyEquivalent:@""]; // About QEMU
    [menu addItem:[NSMenuItem separatorItem]]; //Separator
    menuItem = [menu addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:[NSApp servicesMenu]];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:@"Hide QEMU" action:@selector(hide:) keyEquivalent:@"h"]; //Hide QEMU
    menuItem = (NSMenuItem *)[menu addItemWithTitle:@"Hide Others" action:@selector(hideOtherApplications:) keyEquivalent:@"h"]; // Hide Others
    [menuItem setKeyEquivalentModifierMask:(NSEventModifierFlagOption|NSEventModifierFlagCommand)];
    [menu addItemWithTitle:@"Show All" action:@selector(unhideAllApplications:) keyEquivalent:@""]; // Show All
    [menu addItem:[NSMenuItem separatorItem]]; //Separator
    [menu addItemWithTitle:@"Quit QEMU" action:@selector(terminate:) keyEquivalent:@"q"];
    menuItem = [[NSMenuItem alloc] initWithTitle:@"Apple" action:nil keyEquivalent:@""];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    [NSApp performSelector:@selector(setAppleMenu:) withObject:menu]; // Workaround (this method is private since 10.4+)

    // Machine menu
    menu = [[NSMenu alloc] initWithTitle: @"Machine"];
    [menu setAutoenablesItems: NO];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Pause" action: @selector(pauseQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Resume" action: @selector(resumeQEMU:) keyEquivalent: @""] autorelease];
    [menu addItem: menuItem];
    [menuItem setEnabled: NO];
    [menu addItem: [NSMenuItem separatorItem]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Reset" action: @selector(restartQEMU:) keyEquivalent: @""] autorelease]];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle: @"Power Down" action: @selector(powerDownQEMU:) keyEquivalent: @""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle: @"Machine" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // View menu
    menu = [[NSMenu alloc] initWithTitle:@"View"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Enter Fullscreen" action:@selector(doToggleFullScreen:) keyEquivalent:@"f"] autorelease]]; // Fullscreen
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Zoom To Fit" action:@selector(zoomToFit:) keyEquivalent:@""] autorelease]];
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // Speed menu
    menu = [[NSMenu alloc] initWithTitle:@"Speed"];

    // Add the rest of the Speed menu items
    int p, percentage, throttle_pct;
    for (p = 10; p >= 0; p--)
    {
        percentage = p * 10 > 1 ? p * 10 : 1; // prevent a 0% menu item

        menuItem = [[[NSMenuItem alloc]
                   initWithTitle: [NSString stringWithFormat: @"%d%%", percentage] action:@selector(adjustSpeed:) keyEquivalent:@""] autorelease];

        if (percentage == 100) {
            [menuItem setState: NSControlStateValueOn];
        }

        /* Calculate the throttle percentage */
        throttle_pct = -1 * percentage + 100;

        [menuItem setTag: throttle_pct];
        [menu addItem: menuItem];
    }
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Speed" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];

    // Window menu
    menu = [[NSMenu alloc] initWithTitle:@"Window"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"Minimize" action:@selector(performMiniaturize:) keyEquivalent:@"m"] autorelease]]; // Miniaturize
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
    [NSApp setWindowsMenu:menu];

    // Help menu
    menu = [[NSMenu alloc] initWithTitle:@"Help"];
    [menu addItem: [[[NSMenuItem alloc] initWithTitle:@"QEMU Documentation" action:@selector(showQEMUDoc:) keyEquivalent:@"?"] autorelease]]; // QEMU Help
    menuItem = [[[NSMenuItem alloc] initWithTitle:@"Window" action:nil keyEquivalent:@""] autorelease];
    [menuItem setSubmenu:menu];
    [[NSApp mainMenu] addItem:menuItem];
}

/* Returns a name for a given console */
static NSString * getConsoleName(QemuConsole * console)
{
    g_autofree char *label = qemu_console_get_label(console);

    return [NSString stringWithUTF8String:label];
}

/* Add an entry to the View menu for each console */
static void add_console_menu_entries(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    size_t index;

    menu = [[[NSApp mainMenu] itemWithTitle:@"View"] submenu];

    [menu addItem:[NSMenuItem separatorItem]];

    for (index = 0; index < listeners_count; index++) {
        menuItem = [[[NSMenuItem alloc] initWithTitle: getConsoleName(listeners[index].dcl.con)
                                               action: @selector(displayConsole:) keyEquivalent: @""] autorelease];
        [menuItem setTag: index];
        [menu addItem: menuItem];
    }
}

/* Make menu items for all removable devices.
 * Each device is given an 'Eject' and 'Change' menu item.
 */
static void addRemovableDevicesMenuItems(void)
{
    NSMenu *menu;
    NSMenuItem *menuItem;
    BlockInfoList *currentDevice, *pointerToFree;
    NSString *deviceName;

    currentDevice = qmp_query_block(NULL);
    pointerToFree = currentDevice;

    menu = [[[NSApp mainMenu] itemWithTitle:@"Machine"] submenu];

    // Add a separator between related groups of menu items
    [menu addItem:[NSMenuItem separatorItem]];

    // Set the attributes to the "Removable Media" menu item
    NSString *titleString = @"Removable Media";
    NSMutableAttributedString *attString=[[NSMutableAttributedString alloc] initWithString:titleString];
    NSColor *newColor = [NSColor blackColor];
    NSFontManager *fontManager = [NSFontManager sharedFontManager];
    NSFont *font = [fontManager fontWithFamily:@"Helvetica"
                                          traits:NSBoldFontMask|NSItalicFontMask
                                          weight:0
                                            size:14];
    [attString addAttribute:NSFontAttributeName value:font range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSForegroundColorAttributeName value:newColor range:NSMakeRange(0, [titleString length])];
    [attString addAttribute:NSUnderlineStyleAttributeName value:[NSNumber numberWithInt: 1] range:NSMakeRange(0, [titleString length])];

    // Add the "Removable Media" menu item
    menuItem = [NSMenuItem new];
    [menuItem setAttributedTitle: attString];
    [menuItem setEnabled: NO];
    [menu addItem: menuItem];

    /* Loop through all the block devices in the emulator */
    while (currentDevice) {
        deviceName = [[NSString stringWithFormat: @"%s", currentDevice->value->device] retain];

        if(currentDevice->value->removable) {
            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Change %s...", currentDevice->value->device]
                                                  action: @selector(changeDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];

            menuItem = [[NSMenuItem alloc] initWithTitle: [NSString stringWithFormat: @"Eject %s", currentDevice->value->device]
                                                  action: @selector(ejectDeviceMedia:)
                                           keyEquivalent: @""];
            [menu addItem: menuItem];
            [menuItem setRepresentedObject: deviceName];
            [menuItem autorelease];
        }
        currentDevice = currentDevice->next;
    }
    qapi_free_BlockInfoList(pointerToFree);
}

static void cocoa_mouse_mode_change_notify(Notifier *notifier, void *data)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [cocoaView notifyMouseModeChange];
    });
}

static Notifier mouse_mode_change_notifier = {
    .notify = cocoa_mouse_mode_change_notify
};

@interface QemuCocoaPasteboardTypeOwner : NSObject<NSPasteboardTypeOwner>
@end

@implementation QemuCocoaPasteboardTypeOwner

- (void)pasteboard:(NSPasteboard *)sender provideDataForType:(NSPasteboardType)type
{
    if (type != NSPasteboardTypeString) {
        return;
    }

    with_iothread_lock(^{
        QemuClipboardInfo *info = qemu_clipboard_info_ref(cbinfo);
        qemu_event_reset(&cbevent);
        qemu_clipboard_request(info, QEMU_CLIPBOARD_TYPE_TEXT);

        while (info == cbinfo &&
               info->types[QEMU_CLIPBOARD_TYPE_TEXT].available &&
               info->types[QEMU_CLIPBOARD_TYPE_TEXT].data == NULL) {
            qemu_mutex_unlock_iothread();
            qemu_event_wait(&cbevent);
            qemu_mutex_lock_iothread();
        }

        if (info == cbinfo) {
            NSData *data = [[NSData alloc] initWithBytes:info->types[QEMU_CLIPBOARD_TYPE_TEXT].data
                                           length:info->types[QEMU_CLIPBOARD_TYPE_TEXT].size];
            [sender setData:data forType:NSPasteboardTypeString];
            [data release];
        }

        qemu_clipboard_info_unref(info);
    });
}

@end

static QemuCocoaPasteboardTypeOwner *cbowner;

static void cocoa_clipboard_notify(Notifier *notifier, void *data);
static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type);

static QemuClipboardPeer cbpeer = {
    .name = "cocoa",
    .notifier = { .notify = cocoa_clipboard_notify },
    .request = cocoa_clipboard_request
};

static void cocoa_clipboard_update_info(QemuClipboardInfo *info)
{
    if (info->owner == &cbpeer || info->selection != QEMU_CLIPBOARD_SELECTION_CLIPBOARD) {
        return;
    }

    if (info != cbinfo) {
        NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
        qemu_clipboard_info_unref(cbinfo);
        cbinfo = qemu_clipboard_info_ref(info);
        cbchangecount = [[NSPasteboard generalPasteboard] declareTypes:@[NSPasteboardTypeString] owner:cbowner];
        [pool release];
    }

    qemu_event_set(&cbevent);
}

static void cocoa_clipboard_notify(Notifier *notifier, void *data)
{
    QemuClipboardNotify *notify = data;

    switch (notify->type) {
    case QEMU_CLIPBOARD_UPDATE_INFO:
        cocoa_clipboard_update_info(notify->info);
        return;
    case QEMU_CLIPBOARD_RESET_SERIAL:
        /* ignore */
        return;
    }
}

static void cocoa_clipboard_request(QemuClipboardInfo *info,
                                    QemuClipboardType type)
{
    NSAutoreleasePool *pool;
    NSData *text;

    switch (type) {
    case QEMU_CLIPBOARD_TYPE_TEXT:
        pool = [[NSAutoreleasePool alloc] init];
        text = [[NSPasteboard generalPasteboard] dataForType:NSPasteboardTypeString];
        if (text) {
            qemu_clipboard_set_data(&cbpeer, info, type,
                                    [text length], [text bytes], true);
        }
        [pool release];
        break;
    default:
        break;
    }
}

/*
 * The startup process for the OSX/Cocoa UI is complicated, because
 * OSX insists that the UI runs on the initial main thread, and so we
 * need to start a second thread which runs the qemu_default_main():
 * in main():
 *  in cocoa_display_init():
 *   assign cocoa_main to qemu_main
 *   create application, menus, etc
 *  in cocoa_main():
 *   create qemu-main thread
 *   enter OSX run loop
 */

static void *call_qemu_main(void *opaque)
{
    int status;

    COCOA_DEBUG("Second thread: calling qemu_default_main()\n");
    qemu_mutex_lock_iothread();
    status = qemu_default_main();
    qemu_mutex_unlock_iothread();
    COCOA_DEBUG("Second thread: qemu_default_main() returned, exiting\n");
#ifdef CONFIG_OPENGL
    qemu_gl_fini_shader(dgc.gls);
    if (view_ctx) {
        cocoa_gl_destroy_context(&dgc, view_ctx);
    }
#endif
    [cbowner release];
    exit(status);
}

static int cocoa_main()
{
    QemuThread thread;

    COCOA_DEBUG("Entered %s()\n", __func__);

    qemu_mutex_unlock_iothread();
    qemu_thread_create(&thread, "qemu_main", call_qemu_main,
                       NULL, QEMU_THREAD_DETACHED);

    // Start the main event loop
    COCOA_DEBUG("Main thread: entering OSX run loop\n");
    [NSApp run];
    COCOA_DEBUG("Main thread: left OSX run loop, which should never happen\n");

    abort();
}



#pragma mark qemu
static void cocoa_update(DisplayChangeListener *dcl,
                         int x, int y, int w, int h)
{
    DisplaySurface *updated = surface;

    if (container_of(dcl, CocoaListener, dcl) != active_listener) {
        return;
    }

    COCOA_DEBUG("qemu_cocoa: cocoa_update\n");

    dispatch_async(dispatch_get_main_queue(), ^{
        qemu_mutex_lock(&draw_mutex);
        if (updated != surface) {
            qemu_mutex_unlock(&draw_mutex);
            return;
        }
        int full_height = surface_height(surface);
        qemu_mutex_unlock(&draw_mutex);

        CGFloat d = [cocoaView frame].size.height / full_height;
        NSRect rect = NSMakeRect(x * d, (full_height - y - h) * d, w * d, h * d);
        [cocoaView setNeedsDisplayInRect:rect];
    });
}

static void cocoa_switch(DisplayChangeListener *dcl,
                         DisplaySurface *new_surface)
{
    COCOA_DEBUG("qemu_cocoa: cocoa_switch\n");

    if (container_of(dcl, CocoaListener, dcl) != active_listener) {
        return;
    }

    qemu_mutex_lock(&draw_mutex);
    surface = new_surface;
    qemu_mutex_unlock(&draw_mutex);

    dispatch_async(dispatch_get_main_queue(), ^{
        qemu_mutex_lock(&draw_mutex);
        int w = surface_width(surface);
        int h = surface_height(surface);
        qemu_mutex_unlock(&draw_mutex);

        [cocoaView updateScreenWidth:w height:h];
    });
}

static void cocoa_refresh(DisplayChangeListener *dcl)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];

    COCOA_DEBUG("qemu_cocoa: cocoa_refresh\n");

    if (container_of(dcl, CocoaListener, dcl) != active_listener) {
        return;
    }

    graphic_hw_update(dcl->con);

    if (cbchangecount != [[NSPasteboard generalPasteboard] changeCount]) {
        qemu_clipboard_info_unref(cbinfo);
        cbinfo = qemu_clipboard_info_new(&cbpeer, QEMU_CLIPBOARD_SELECTION_CLIPBOARD);
        if ([[NSPasteboard generalPasteboard] availableTypeFromArray:@[NSPasteboardTypeString]]) {
            cbinfo->types[QEMU_CLIPBOARD_TYPE_TEXT].available = true;
        }
        qemu_clipboard_update(cbinfo);
        cbchangecount = [[NSPasteboard generalPasteboard] changeCount];
        qemu_event_set(&cbevent);
    }

    [pool release];
}

static void cocoa_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    qemu_mutex_lock(&draw_mutex);
    int full_height = surface_height(surface);
    int old_x = listener->mouse_x;
    int old_y = listener->mouse_y;
    listener->mouse_x = x;
    listener->mouse_y = y;
    listener->mouse_on = on;
    qemu_mutex_unlock(&draw_mutex);

    if (listener == active_listener && cursor_cgimage) {
        size_t cursor_width = CGImageGetWidth(cursor_cgimage);
        size_t cursor_height = CGImageGetHeight(cursor_cgimage);

        dispatch_async(dispatch_get_main_queue(), ^{
            CGRect clip_rect = compute_cursor_clip_rect(full_height,
                                                        old_x, old_y,
                                                        cursor_width,
                                                        cursor_height);
            CGRect draw_rect =
                [cocoaView convertCursorClipRectToDraw:clip_rect
                                          screenHeight:full_height
                                                mouseX:old_x
                                                mouseY:old_y];
            [cocoaView setNeedsDisplayInRect:draw_rect];

            clip_rect = compute_cursor_clip_rect(full_height, x, y,
                                                        cursor_width,
                                                        cursor_height);
            draw_rect =
                [cocoaView convertCursorClipRectToDraw:clip_rect
                                          screenHeight:full_height
                                                mouseX:x
                                                mouseY:y];
            [cocoaView setNeedsDisplayInRect:draw_rect];
        });
    }
}

static void cocoa_cursor_update()
{
    CGImageRef old_image = cursor_cgimage;
    CGImageRef new_image;

    if (active_listener->cursor) {
        CGDataProviderRef provider = CGDataProviderCreateWithData(
            NULL,
            active_listener->cursor->data,
            active_listener->cursor->width * active_listener->cursor->height * 4,
            NULL
        );

        new_image = CGImageCreate(
            active_listener->cursor->width, //width
            active_listener->cursor->height, //height
            8, //bitsPerComponent
            32, //bitsPerPixel
            active_listener->cursor->width * 4, //bytesPerRow
            CGColorSpaceCreateWithName(kCGColorSpaceSRGB), //colorspace
            kCGBitmapByteOrder32Little | kCGImageAlphaFirst, //bitmapInfo
            provider, //provider
            NULL, //decode
            0, //interpolate
            kCGRenderingIntentDefault //intent
        );

        CGDataProviderRelease(provider);
    } else {
        new_image = NULL;
    }

    qemu_mutex_lock(&draw_mutex);
    cursor_cgimage = new_image;
    qemu_mutex_unlock(&draw_mutex);

    CGImageRelease(old_image);
}

static void cocoa_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->cursor = cursor;

    if (listener == active_listener) {
        int full_height = surface_height(surface);
        int width = cursor->width;
        int height = cursor->height;
        int x = listener->mouse_x;
        int y = listener->mouse_y;
        size_t old_width;
        size_t old_height;

        if (cursor_cgimage) {
            old_width = CGImageGetWidth(cursor_cgimage);
            old_height = CGImageGetHeight(cursor_cgimage);
        } else {
            old_width = 0;
            old_height = 0;
        }

        cocoa_cursor_update();

        dispatch_async(dispatch_get_main_queue(), ^{
            CGFloat d = [cocoaView frame].size.height / full_height;
            NSRect rect;

            rect.origin.x = d * x;
            rect.origin.y = d * (full_height - y - old_height);
            rect.size.width = d * old_width;
            rect.size.height = d * old_height;
            [cocoaView setNeedsDisplayInRect:rect];

            rect.size.width = d * width;
            rect.size.height = d * height;
            [cocoaView setNeedsDisplayInRect:rect];
        });
    }
}

static const DisplayChangeListenerOps dcl_ops = {
    .dpy_name          = "cocoa",
    .dpy_gfx_update = cocoa_update,
    .dpy_gfx_switch = cocoa_switch,
    .dpy_refresh = cocoa_refresh,
    .dpy_mouse_set = cocoa_mouse_set,
    .dpy_cursor_define = cocoa_cursor_define,
};

#ifdef CONFIG_OPENGL

static void with_view_ctx(CodeBlock block)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        block();
        return;
    }
#endif

    [(NSOpenGLContext *)view_ctx lock];
    [(NSOpenGLContext *)view_ctx makeCurrentContext];
    block();
    [(NSOpenGLContext *)view_ctx unlock];
}

static NSOpenGLPixelFormat *cocoa_gl_create_ns_pixel_format(int bpp)
{
    NSOpenGLPixelFormatAttribute attributes[] = {
        NSOpenGLPFAOpenGLProfile,
        NSOpenGLProfileVersion4_1Core,
        NSOpenGLPFAColorSize,
        bpp,
        NSOpenGLPFADoubleBuffer,
        0,
    };

    return [[NSOpenGLPixelFormat alloc] initWithAttributes:attributes];
}

static int cocoa_gl_make_context_current(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        EGLSurface current_surface = ctx == EGL_NO_CONTEXT ? EGL_NO_SURFACE : egl_surface;
        return eglMakeCurrent(qemu_egl_display, current_surface, current_surface, ctx);
    }
#endif

    if (ctx) {
        [(NSOpenGLContext *)ctx makeCurrentContext];
    } else {
        [NSOpenGLContext clearCurrentContext];
    }

    return 0;
}

static QEMUGLContext cocoa_gl_create_context(DisplayGLCtx *dgc,
                                             QEMUGLParams *params)
{
    NSOpenGLPixelFormat *format;
    NSOpenGLContext *ctx;
    int bpp;

#ifdef CONFIG_EGL
    if (egl_surface) {
        eglMakeCurrent(qemu_egl_display, egl_surface, egl_surface, view_ctx);
        return qemu_egl_create_context(dgc, params);
    }
#endif

    bpp = PIXMAN_FORMAT_BPP(surface_format(surface));
    format = cocoa_gl_create_ns_pixel_format(bpp);
    ctx = [[NSOpenGLContext alloc] initWithFormat:format shareContext:view_ctx];
    [format release];

    return (QEMUGLContext)ctx;
}

static void cocoa_gl_destroy_context(DisplayGLCtx *dgc, QEMUGLContext ctx)
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglDestroyContext(qemu_egl_display, ctx);
        return;
    }
#endif

    [(NSOpenGLContext *)ctx release];
}

static void cocoa_gl_flush()
{
#ifdef CONFIG_EGL
    if (egl_surface) {
        eglSwapBuffers(qemu_egl_display, egl_surface);
        return;
    }
#endif

    [[NSOpenGLContext currentContext] flushBuffer];

    dispatch_async(dispatch_get_main_queue(), ^{
        [(NSOpenGLContext *)view_ctx update];
    });
}

static void cocoa_gl_update(DisplayChangeListener *dcl,
                            int x, int y, int w, int h)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != active_listener) {
        return;
    }

    with_view_ctx(^{
        surface_gl_update_texture(dgc.gls, surface, x, y, w, h);
        gl_dirty = true;
    });
}

static void cocoa_gl_cursor_render()
{
    if (!active_listener->mouse_on) {
        return;
    }

    NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];
    CGFloat d = size.height / surface_height(surface);

    glViewport(
        d * active_listener->mouse_x,
        size.height - d * (active_listener->mouse_y + active_listener->cursor->height),
        d * active_listener->cursor->width,
        d * active_listener->cursor->height
    );
    glBindTexture(GL_TEXTURE_2D, cursor_texture);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    qemu_gl_run_texture_blit(dgc.gls, false);
    glDisable(GL_BLEND);
}

static void cocoa_gl_switch(DisplayChangeListener *dcl,
                            DisplaySurface *new_surface)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != active_listener) {
        return;
    }

    with_view_ctx(^{
        surface_gl_destroy_texture(dgc.gls, surface);
        surface_gl_create_texture(dgc.gls, new_surface);
    });

    cocoa_switch(dcl, new_surface);
    gl_dirty = true;
}

static void cocoa_gl_refresh(DisplayChangeListener *dcl)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    if (listener != active_listener) {
        return;
    }

    cocoa_refresh(dcl);

    if (gl_dirty) {
        gl_dirty = false;

        with_view_ctx(^{
            NSSize size = [cocoaView convertSizeToBacking:[cocoaView frame].size];

            if (listener->gl_scanout_borrow) {
                bool y0_top;
                GLint texture =
                    listener->gl_scanout_borrow(listener->gl_scanout_id,
                                                &y0_top, NULL, NULL);

                glBindFramebuffer(GL_FRAMEBUFFER_EXT, 0);
                glViewport(0, 0, size.width, size.height);
                glBindTexture(GL_TEXTURE_2D, texture);
                qemu_gl_run_texture_blit(dgc.gls, y0_top);
            } else {
                surface_gl_setup_viewport(dgc.gls, surface,
                                          size.width, size.height);
                glBindTexture(GL_TEXTURE_2D, surface->texture);
                surface_gl_render_texture(dgc.gls, surface);
            }

            cocoa_gl_cursor_render();
            cocoa_gl_flush();
        });
    }
}

static void cocoa_gl_scanout_disable(DisplayChangeListener *dcl)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->gl_scanout_borrow = NULL;

    if (listener == active_listener) {
        gl_dirty = surface != NULL;
    }
}

static void cocoa_gl_cursor_update()
{
    if (active_listener->cursor) {
        with_view_ctx(^{
            glBindTexture(GL_TEXTURE_2D, cursor_texture);
            glPixelStorei(GL_UNPACK_ROW_LENGTH_EXT,
                          active_listener->cursor->width);
            glTexImage2D(GL_TEXTURE_2D, 0,
                         epoxy_is_desktop_gl() ? GL_RGBA : GL_BGRA,
                         active_listener->cursor->width,
                         active_listener->cursor->height,
                         0, GL_BGRA, GL_UNSIGNED_BYTE,
                         active_listener->cursor->data);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
        });
    }

    gl_dirty = true;
}

static void cocoa_gl_cursor_define(DisplayChangeListener *dcl, QEMUCursor *cursor)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->cursor = cursor;

    if (listener == active_listener) {
        cocoa_gl_cursor_update();
    }
}

static void cocoa_gl_scanout_texture(DisplayChangeListener *dcl,
                                     uint32_t backing_id,
                                     DisplayGLTextureBorrower backing_borrow,
                                     uint32_t x, uint32_t y,
                                     uint32_t w, uint32_t h)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->gl_scanout_id = backing_id;
    listener->gl_scanout_borrow = backing_borrow;
    gl_dirty = true;
}

static void cocoa_gl_scanout_flush(DisplayChangeListener *dcl,
                                   uint32_t x, uint32_t y,
                                   uint32_t w, uint32_t h)
{
    if (container_of(dcl, CocoaListener, dcl) == active_listener) {
        gl_dirty = true;
    }
}

static void cocoa_gl_mouse_set(DisplayChangeListener *dcl, int x, int y, int on)
{
    CocoaListener *listener = container_of(dcl, CocoaListener, dcl);

    listener->mouse_x = x;
    listener->mouse_y = y;
    listener->mouse_on = on;

    if (listener == active_listener) {
        gl_dirty = true;
    }
}

static const DisplayChangeListenerOps dcl_gl_ops = {
    .dpy_name               = "cocoa-gl",
    .dpy_gfx_update         = cocoa_gl_update,
    .dpy_gfx_switch         = cocoa_gl_switch,
    .dpy_gfx_check_format   = console_gl_check_format,
    .dpy_refresh            = cocoa_gl_refresh,
    .dpy_mouse_set          = cocoa_gl_mouse_set,
    .dpy_cursor_define      = cocoa_gl_cursor_define,

    .dpy_gl_scanout_disable = cocoa_gl_scanout_disable,
    .dpy_gl_scanout_texture = cocoa_gl_scanout_texture,
    .dpy_gl_update          = cocoa_gl_scanout_flush,
};

static bool cocoa_gl_is_compatible_dcl(DisplayGLCtx *dgc,
                                       DisplayChangeListener *dcl)
{
    return dcl->ops == &dcl_gl_ops;
}

#endif

static void cocoa_display_early_init(DisplayOptions *o)
{
    assert(o->type == DISPLAY_TYPE_COCOA);
    if (o->has_gl && o->gl) {
        display_opengl = 1;
    }
}

static void cocoa_display_init(DisplayState *ds, DisplayOptions *opts)
{
    NSAutoreleasePool * pool = [[NSAutoreleasePool alloc] init];
    const DisplayChangeListenerOps *ops;
    size_t index;

    COCOA_DEBUG("qemu_cocoa: cocoa_display_init\n");

    qemu_main = cocoa_main;

    // Pull this console process up to being a fully-fledged graphical
    // app with a menubar and Dock icon
    ProcessSerialNumber psn = { 0, kCurrentProcess };
    TransformProcessType(&psn, kProcessTransformToForegroundApplication);

    [QemuApplication sharedApplication];

    // Create an Application controller
    QemuCocoaAppController *controller = [[QemuCocoaAppController alloc] init];
    [NSApp setDelegate:controller];

    qemu_mutex_init(&draw_mutex);

    if (display_opengl) {
#ifdef CONFIG_OPENGL
        if (opts->gl == DISPLAYGL_MODE_ES) {
#ifdef CONFIG_EGL
            if (qemu_egl_init_dpy_cocoa(DISPLAYGL_MODE_ES)) {
                exit(1);
            }
            view_ctx = qemu_egl_init_ctx();
            if (!view_ctx) {
                exit(1);
            }
            [cocoaView setWantsLayer:YES];
            egl_surface = qemu_egl_init_surface(view_ctx, [cocoaView layer]);
            if (!egl_surface) {
                exit(1);
            }
#else
            error_report("OpenGLES without EGL is not supported - exiting");
            exit(1);
#endif
        } else {
            NSOpenGLPixelFormat *format = cocoa_gl_create_ns_pixel_format(32);
            NSOpenGLView *view = [[NSOpenGLView alloc] initWithFrame:[cocoaView frame]
                                                         pixelFormat:format];
            [format release];
            [cocoaView addSubview:view];
            view_ctx = [view openGLContext];
            [view release];
#ifdef CONFIG_EGL
            egl_surface = EGL_NO_SURFACE;
#endif
            cocoa_gl_make_context_current(&dgc, view_ctx);
        }

        dgc.gls = qemu_gl_init_shader();
        glGenTextures(1, &cursor_texture);

        // register vga output callbacks
        ops = &dcl_gl_ops;
#else
        error_report("OpenGL is not enabled - exiting");
        exit(1);
#endif
    } else {
        // register vga output callbacks
        ops = &dcl_ops;
    }

    while (qemu_console_lookup_by_index(listeners_count)) {
        listeners_count++;
    }

    if (listeners_count) {
        QemuConsole *con = qemu_console_lookup_first_graphic_console();
        listeners = g_new0(CocoaListener, listeners_count);
        active_listener = listeners + qemu_console_get_index(con);

        for (index = 0; index < listeners_count; index++) {
            listeners[index].dcl.con = qemu_console_lookup_by_index(index);
            listeners[index].dcl.ops = ops;

            if (display_opengl) {
                qemu_console_set_display_gl_ctx(listeners[index].dcl.con,
                                                &dgc);
            }

            // register vga output callbacks
            register_displaychangelistener(&listeners[index].dcl);
        }

        kbd = qkbd_state_init(active_listener->dcl.con);

        qemu_add_mouse_mode_change_notifier(&mouse_mode_change_notifier);
        [cocoaView notifyMouseModeChange];
    }

    create_initial_menus();

    /*
     * Create the menu entries which depend on QEMU state (for consoles
     * and removeable devices). These make calls back into QEMU functions,
     * which is OK because at this point we know that the second thread
     * holds the iothread lock and is synchronously waiting for us to
     * finish.
     */
    add_console_menu_entries();
    addRemovableDevicesMenuItems();

    /* if fullscreen mode is to be used */
    if (opts->has_full_screen && opts->full_screen) {
        [normalWindow toggleFullScreen: nil];
    }
    if (opts->u.cocoa.has_full_grab && opts->u.cocoa.full_grab) {
        [controller setFullGrab: nil];
    }

    if (opts->has_show_cursor && opts->show_cursor) {
        cursor_hide = 0;
    }
    if (opts->u.cocoa.has_swap_opt_cmd) {
        swap_opt_cmd = opts->u.cocoa.swap_opt_cmd;
    }

    if (opts->u.cocoa.has_left_command_key && !opts->u.cocoa.left_command_key) {
        left_command_key_enabled = 0;
    }

    [cocoaView updateUIInfo];

    qemu_event_init(&cbevent, false);
    cbowner = [[QemuCocoaPasteboardTypeOwner alloc] init];
    qemu_clipboard_peer_register(&cbpeer);

    [pool release];
}

static QemuDisplay qemu_display_cocoa = {
    .type       = DISPLAY_TYPE_COCOA,
    .early_init = cocoa_display_early_init,
    .init       = cocoa_display_init,
};

static void register_cocoa(void)
{
    qemu_display_register(&qemu_display_cocoa);
}

type_init(register_cocoa);

#ifdef CONFIG_OPENGL
module_dep("ui-opengl");
#endif
