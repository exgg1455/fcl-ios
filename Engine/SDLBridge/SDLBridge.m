#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#include <ctype.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <objc/message.h>
#include <os/lock.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <SDL3/SDL.h>
#include <SDL3/SDL_vulkan.h>

typedef struct FCLWindowState {
    SDL_WindowFlags flags;
    char title[256];
    bool relativeMode;
    bool textInputActive;
} FCLWindowState;

static FCLWindowState windowState;
static bool windowCreated;
static SDL_InitFlags initializedFlags;

static SDL_Event eventQueue[2048];
static int eventHead;
static int eventCount;
static os_unfair_lock eventLock = OS_UNFAIR_LOCK_INIT;

static char textBuffers[256][8];
static int textBufferIndex;

static bool keyboardState[SDL_SCANCODE_COUNT];
static SDL_Keymod modifierState;
static SDL_MouseButtonFlags buttonState;
static float mouseX;
static float mouseY;
static int currentWidth;
static int currentHeight;

static __thread char errorBuffer[512];
static SDL_DisplayMode displayMode;
static SDL_PixelFormatDetails formatDetails;
static void *vulkanLibrary;
static void *rendererLibrary;
static int glAttributes[64];
static void *currentContext;
static int swapInterval = 1;

#define FCL_WINDOW ((SDL_Window *)&windowState)

static void *engineSymbol(const char *name) {
    return dlsym(RTLD_DEFAULT, name);
}

static int engineInteger(const char *name, int fallback) {
    int *value = engineSymbol(name);
    if (value && *value > 0) {
        return *value;
    }
    return fallback;
}

static void refreshWindowSize(void) {
    if (currentWidth <= 0 || currentHeight <= 0) {
        currentWidth = engineInteger("windowWidth", 1280);
        currentHeight = engineInteger("windowHeight", 720);
    }
}

static void setErrorText(const char *text) {
    snprintf(errorBuffer, sizeof(errorBuffer), "%s", text ? text : "");
}

static Uint64 nanosecondsNow(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return mach_absolute_time() * timebase.numer / timebase.denom;
}

static void pushEvent(SDL_Event *event) {
    event->common.timestamp = nanosecondsNow();
    os_unfair_lock_lock(&eventLock);
    if (eventCount < (int)(sizeof(eventQueue) / sizeof(eventQueue[0]))) {
        eventQueue[(eventHead + eventCount) % (int)(sizeof(eventQueue) / sizeof(eventQueue[0]))] = *event;
        eventCount++;
    }
    os_unfair_lock_unlock(&eventLock);
}

static void pushWindowEvent(SDL_EventType type, Sint32 first, Sint32 second) {
    SDL_Event event;
    memset(&event, 0, sizeof(event));
    event.type = type;
    event.window.windowID = 1;
    event.window.data1 = first;
    event.window.data2 = second;
    pushEvent(&event);
}

static id surfaceView(void) {
    Class controller = NSClassFromString(@"SurfaceViewController");
    if (!controller) {
        return nil;
    }
    SEL selector = sel_registerName("surface");
    if (![controller respondsToSelector:selector]) {
        return nil;
    }
    return ((id (*)(id, SEL))objc_msgSend)(controller, selector);
}

static CALayer *surfaceLayer(void) {
    __block CALayer *layer = nil;
    void (^read)(void) = ^{
        UIView *view = surfaceView();
        layer = view.layer;
    };
    if (NSThread.isMainThread) {
        read();
    } else {
        dispatch_sync(dispatch_get_main_queue(), read);
    }
    return layer;
}

static SDL_Scancode scancodeFromGLFW(int key) {
    if (key >= 65 && key <= 90) {
        return (SDL_Scancode)(SDL_SCANCODE_A + (key - 65));
    }
    if (key >= 49 && key <= 57) {
        return (SDL_Scancode)(SDL_SCANCODE_1 + (key - 49));
    }
    if (key >= 290 && key <= 301) {
        return (SDL_Scancode)(SDL_SCANCODE_F1 + (key - 290));
    }
    if (key >= 302 && key <= 313) {
        return (SDL_Scancode)(SDL_SCANCODE_F13 + (key - 302));
    }
    if (key >= 321 && key <= 329) {
        return (SDL_Scancode)(SDL_SCANCODE_KP_1 + (key - 321));
    }
    switch (key) {
        case 32: return SDL_SCANCODE_SPACE;
        case 39: return SDL_SCANCODE_APOSTROPHE;
        case 44: return SDL_SCANCODE_COMMA;
        case 45: return SDL_SCANCODE_MINUS;
        case 46: return SDL_SCANCODE_PERIOD;
        case 47: return SDL_SCANCODE_SLASH;
        case 48: return SDL_SCANCODE_0;
        case 59: return SDL_SCANCODE_SEMICOLON;
        case 61: return SDL_SCANCODE_EQUALS;
        case 91: return SDL_SCANCODE_LEFTBRACKET;
        case 92: return SDL_SCANCODE_BACKSLASH;
        case 93: return SDL_SCANCODE_RIGHTBRACKET;
        case 96: return SDL_SCANCODE_GRAVE;
        case 256: return SDL_SCANCODE_ESCAPE;
        case 257: return SDL_SCANCODE_RETURN;
        case 258: return SDL_SCANCODE_TAB;
        case 259: return SDL_SCANCODE_BACKSPACE;
        case 260: return SDL_SCANCODE_INSERT;
        case 261: return SDL_SCANCODE_DELETE;
        case 262: return SDL_SCANCODE_RIGHT;
        case 263: return SDL_SCANCODE_LEFT;
        case 264: return SDL_SCANCODE_DOWN;
        case 265: return SDL_SCANCODE_UP;
        case 266: return SDL_SCANCODE_PAGEUP;
        case 267: return SDL_SCANCODE_PAGEDOWN;
        case 268: return SDL_SCANCODE_HOME;
        case 269: return SDL_SCANCODE_END;
        case 280: return SDL_SCANCODE_CAPSLOCK;
        case 281: return SDL_SCANCODE_SCROLLLOCK;
        case 282: return SDL_SCANCODE_NUMLOCKCLEAR;
        case 283: return SDL_SCANCODE_PRINTSCREEN;
        case 284: return SDL_SCANCODE_PAUSE;
        case 320: return SDL_SCANCODE_KP_0;
        case 330: return SDL_SCANCODE_KP_PERIOD;
        case 331: return SDL_SCANCODE_KP_DIVIDE;
        case 332: return SDL_SCANCODE_KP_MULTIPLY;
        case 333: return SDL_SCANCODE_KP_MINUS;
        case 334: return SDL_SCANCODE_KP_PLUS;
        case 335: return SDL_SCANCODE_KP_ENTER;
        case 336: return SDL_SCANCODE_KP_EQUALS;
        case 340: return SDL_SCANCODE_LSHIFT;
        case 341: return SDL_SCANCODE_LCTRL;
        case 342: return SDL_SCANCODE_LALT;
        case 343: return SDL_SCANCODE_LGUI;
        case 344: return SDL_SCANCODE_RSHIFT;
        case 345: return SDL_SCANCODE_RCTRL;
        case 346: return SDL_SCANCODE_RALT;
        case 347: return SDL_SCANCODE_RGUI;
        case 348: return SDL_SCANCODE_APPLICATION;
        default: return SDL_SCANCODE_UNKNOWN;
    }
}

static SDL_Keymod modifierForScancode(SDL_Scancode scancode) {
    switch (scancode) {
        case SDL_SCANCODE_LSHIFT: return SDL_KMOD_LSHIFT;
        case SDL_SCANCODE_RSHIFT: return SDL_KMOD_RSHIFT;
        case SDL_SCANCODE_LCTRL: return SDL_KMOD_LCTRL;
        case SDL_SCANCODE_RCTRL: return SDL_KMOD_RCTRL;
        case SDL_SCANCODE_LALT: return SDL_KMOD_LALT;
        case SDL_SCANCODE_RALT: return SDL_KMOD_RALT;
        case SDL_SCANCODE_LGUI: return SDL_KMOD_LGUI;
        case SDL_SCANCODE_RGUI: return SDL_KMOD_RGUI;
        default: return SDL_KMOD_NONE;
    }
}

static int encodeUTF8(unsigned int codepoint, char *output) {
    if (codepoint < 0x80) {
        output[0] = (char)codepoint;
        return 1;
    }
    if (codepoint < 0x800) {
        output[0] = (char)(0xC0 | (codepoint >> 6));
        output[1] = (char)(0x80 | (codepoint & 0x3F));
        return 2;
    }
    if (codepoint < 0x10000) {
        output[0] = (char)(0xE0 | (codepoint >> 12));
        output[1] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
        output[2] = (char)(0x80 | (codepoint & 0x3F));
        return 3;
    }
    output[0] = (char)(0xF0 | (codepoint >> 18));
    output[1] = (char)(0x80 | ((codepoint >> 12) & 0x3F));
    output[2] = (char)(0x80 | ((codepoint >> 6) & 0x3F));
    output[3] = (char)(0x80 | (codepoint & 0x3F));
    return 4;
}

static Uint8 buttonFromGLFW(int button) {
    switch (button) {
        case 0: return SDL_BUTTON_LEFT;
        case 1: return SDL_BUTTON_RIGHT;
        case 2: return SDL_BUTTON_MIDDLE;
        default: return (Uint8)(button + 1);
    }
}

static void inputHook(int type, int first, int second, int third, int fourth, double firstFloat, double secondFloat) {
    SDL_Event event;
    memset(&event, 0, sizeof(event));
    switch (type) {
        case 1: {
            if (first < 32 || first == 127) {
                return;
            }
            char *buffer = textBuffers[textBufferIndex];
            textBufferIndex = (textBufferIndex + 1) % 256;
            int length = encodeUTF8((unsigned int)first, buffer);
            buffer[length] = 0;
            event.type = SDL_EVENT_TEXT_INPUT;
            event.text.windowID = 1;
            event.text.text = buffer;
            pushEvent(&event);
            break;
        }
        case 2: {
            SDL_Scancode scancode = scancodeFromGLFW(first);
            if (scancode == SDL_SCANCODE_UNKNOWN) {
                return;
            }
            bool down = third != 0;
            keyboardState[scancode] = down;
            SDL_Keymod modifier = modifierForScancode(scancode);
            if (modifier != SDL_KMOD_NONE) {
                if (down) {
                    modifierState |= modifier;
                } else {
                    modifierState &= ~modifier;
                }
            }
            if (scancode == SDL_SCANCODE_CAPSLOCK && down) {
                modifierState ^= SDL_KMOD_CAPS;
            }
            event.type = down ? SDL_EVENT_KEY_DOWN : SDL_EVENT_KEY_UP;
            event.key.windowID = 1;
            event.key.which = 1;
            event.key.scancode = scancode;
            event.key.key = SDL_GetKeyFromScancode(scancode, modifierState, true);
            event.key.mod = modifierState;
            event.key.raw = (Uint16)second;
            event.key.down = down;
            event.key.repeat = third == 2;
            pushEvent(&event);
            break;
        }
        case 3: {
            float x = (float)firstFloat;
            float y = (float)secondFloat;
            event.type = SDL_EVENT_MOUSE_MOTION;
            event.motion.windowID = 1;
            event.motion.which = 1;
            event.motion.state = buttonState;
            event.motion.x = x;
            event.motion.y = y;
            event.motion.xrel = x - mouseX;
            event.motion.yrel = y - mouseY;
            mouseX = x;
            mouseY = y;
            pushEvent(&event);
            break;
        }
        case 4: {
            Uint8 button = buttonFromGLFW(first);
            bool down = second != 0;
            if (down) {
                buttonState |= SDL_BUTTON_MASK(button);
            } else {
                buttonState &= ~SDL_BUTTON_MASK(button);
            }
            event.type = down ? SDL_EVENT_MOUSE_BUTTON_DOWN : SDL_EVENT_MOUSE_BUTTON_UP;
            event.button.windowID = 1;
            event.button.which = 1;
            event.button.button = button;
            event.button.down = down;
            event.button.clicks = 1;
            event.button.x = mouseX;
            event.button.y = mouseY;
            pushEvent(&event);
            break;
        }
        case 5: {
            event.type = SDL_EVENT_MOUSE_WHEEL;
            event.wheel.windowID = 1;
            event.wheel.which = 1;
            event.wheel.x = (float)firstFloat;
            event.wheel.y = (float)secondFloat;
            event.wheel.direction = SDL_MOUSEWHEEL_NORMAL;
            event.wheel.mouse_x = mouseX;
            event.wheel.mouse_y = mouseY;
            event.wheel.integer_x = (Sint32)firstFloat;
            event.wheel.integer_y = (Sint32)secondFloat;
            pushEvent(&event);
            break;
        }
        case 6: {
            if (first <= 0 || second <= 0) {
                return;
            }
            currentWidth = first;
            currentHeight = second;
            pushWindowEvent(SDL_EVENT_WINDOW_RESIZED, first, second);
            pushWindowEvent(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, first, second);
            break;
        }
        default:
            break;
    }
}

static void installInputHook(void) {
    void (**hook)(int, int, int, int, int, double, double) = engineSymbol("FCL_inputHook");
    if (hook) {
        *hook = inputHook;
    }
    void (*setInputReady)(bool) = engineSymbol("CallbackBridge_nativeSetInputReady");
    if (setInputReady) {
        setInputReady(true);
    }
}

static void refreshDisplayMode(void) {
    refreshWindowSize();
    displayMode.displayID = 1;
    displayMode.format = SDL_PIXELFORMAT_XRGB8888;
    displayMode.w = currentWidth;
    displayMode.h = currentHeight;
    displayMode.pixel_density = 1.0f;
    int framesPerSecond = (int)UIScreen.mainScreen.maximumFramesPerSecond;
    if (framesPerSecond <= 0) {
        framesPerSecond = 60;
    }
    displayMode.refresh_rate = (float)framesPerSecond;
    displayMode.refresh_rate_numerator = framesPerSecond;
    displayMode.refresh_rate_denominator = 1;
}

static void setEngineWindowHint(int hint, int value) {
    void (*setHint)(int, int) = engineSymbol("pojavSetWindowHint");
    if (setHint) {
        setHint(hint, value);
    }
}

bool SDL_Init(SDL_InitFlags flags) {
    initializedFlags |= flags;
    return true;
}

bool SDL_InitSubSystem(SDL_InitFlags flags) {
    initializedFlags |= flags;
    return true;
}

void SDL_QuitSubSystem(SDL_InitFlags flags) {
    initializedFlags &= ~flags;
}

SDL_InitFlags SDL_WasInit(SDL_InitFlags flags) {
    return flags == 0 ? initializedFlags : (initializedFlags & flags);
}

void SDL_Quit(void) {
    initializedFlags = 0;
}

bool SDL_SetAppMetadata(const char *appname, const char *appversion, const char *appidentifier) {
    return true;
}

bool SDL_SetAppMetadataProperty(const char *name, const char *value) {
    return true;
}

const char *SDL_GetAppMetadataProperty(const char *name) {
    return NULL;
}

bool SDL_SetHint(const char *name, const char *value) {
    return true;
}

bool SDL_SetHintWithPriority(const char *name, const char *value, SDL_HintPriority priority) {
    return true;
}

const char *SDL_GetHint(const char *name) {
    return NULL;
}

bool SDL_GetHintBoolean(const char *name, bool default_value) {
    return default_value;
}

bool SDL_ResetHint(const char *name) {
    return true;
}

void SDL_ResetHints(void) {
}

const char *SDL_GetError(void) {
    return errorBuffer;
}

bool SDL_ClearError(void) {
    errorBuffer[0] = 0;
    return true;
}

bool SDL_SetError(const char *fmt, ...) {
    va_list arguments;
    va_start(arguments, fmt);
    vsnprintf(errorBuffer, sizeof(errorBuffer), fmt ? fmt : "", arguments);
    va_end(arguments);
    return false;
}

bool SDL_OutOfMemory(void) {
    setErrorText("Out of memory");
    return false;
}

const char *SDL_GetPlatform(void) {
    return "iOS";
}

int SDL_GetVersion(void) {
    return SDL_VERSION;
}

const char *SDL_GetRevision(void) {
    return "FoldCraftLauncher SDL bridge";
}

Uint64 SDL_GetTicksNS(void) {
    static Uint64 start;
    if (start == 0) {
        start = nanosecondsNow();
    }
    return nanosecondsNow() - start;
}

Uint64 SDL_GetTicks(void) {
    return SDL_GetTicksNS() / 1000000;
}

Uint64 SDL_GetPerformanceCounter(void) {
    return nanosecondsNow();
}

Uint64 SDL_GetPerformanceFrequency(void) {
    return 1000000000ULL;
}

void SDL_Delay(Uint32 ms) {
    usleep(ms * 1000);
}

void SDL_DelayNS(Uint64 ns) {
    usleep((useconds_t)(ns / 1000));
}

void SDL_DelayPrecise(Uint64 ns) {
    usleep((useconds_t)(ns / 1000));
}

void *SDL_malloc(size_t size) {
    return malloc(size);
}

void *SDL_calloc(size_t nmemb, size_t size) {
    return calloc(nmemb, size);
}

void *SDL_realloc(void *mem, size_t size) {
    return realloc(mem, size);
}

void SDL_free(void *mem) {
    free(mem);
}

void SDL_SetLogPriorities(SDL_LogPriority priority) {
}

void SDL_SetLogPriority(int category, SDL_LogPriority priority) {
}

void SDL_ResetLogPriorities(void) {
}

void SDL_SetLogOutputFunction(SDL_LogOutputFunction callback, void *userdata) {
}

int SDL_GetNumVideoDrivers(void) {
    return 1;
}

const char *SDL_GetVideoDriver(int index) {
    return index == 0 ? "uikit" : NULL;
}

const char *SDL_GetCurrentVideoDriver(void) {
    return "uikit";
}

SDL_DisplayID *SDL_GetDisplays(int *count) {
    SDL_DisplayID *displays = malloc(sizeof(SDL_DisplayID) * 2);
    displays[0] = 1;
    displays[1] = 0;
    if (count) {
        *count = 1;
    }
    return displays;
}

SDL_DisplayID SDL_GetPrimaryDisplay(void) {
    return 1;
}

SDL_PropertiesID SDL_GetDisplayProperties(SDL_DisplayID displayID) {
    return 0;
}

const char *SDL_GetDisplayName(SDL_DisplayID displayID) {
    return "Built-in Display";
}

bool SDL_GetDisplayBounds(SDL_DisplayID displayID, SDL_Rect *rect) {
    refreshWindowSize();
    if (rect) {
        rect->x = 0;
        rect->y = 0;
        rect->w = currentWidth;
        rect->h = currentHeight;
    }
    return true;
}

bool SDL_GetDisplayUsableBounds(SDL_DisplayID displayID, SDL_Rect *rect) {
    return SDL_GetDisplayBounds(displayID, rect);
}

SDL_DisplayOrientation SDL_GetNaturalDisplayOrientation(SDL_DisplayID displayID) {
    return SDL_ORIENTATION_LANDSCAPE;
}

SDL_DisplayOrientation SDL_GetCurrentDisplayOrientation(SDL_DisplayID displayID) {
    return SDL_ORIENTATION_LANDSCAPE;
}

float SDL_GetDisplayContentScale(SDL_DisplayID displayID) {
    return 1.0f;
}

SDL_DisplayMode **SDL_GetFullscreenDisplayModes(SDL_DisplayID displayID, int *count) {
    refreshDisplayMode();
    SDL_DisplayMode **modes = malloc(sizeof(SDL_DisplayMode *) * 2);
    modes[0] = &displayMode;
    modes[1] = NULL;
    if (count) {
        *count = 1;
    }
    return modes;
}

bool SDL_GetClosestFullscreenDisplayMode(SDL_DisplayID displayID, int w, int h, float refresh_rate, bool include_high_density_modes, SDL_DisplayMode *closest) {
    refreshDisplayMode();
    if (closest) {
        *closest = displayMode;
    }
    return true;
}

const SDL_DisplayMode *SDL_GetDesktopDisplayMode(SDL_DisplayID displayID) {
    refreshDisplayMode();
    return &displayMode;
}

const SDL_DisplayMode *SDL_GetCurrentDisplayMode(SDL_DisplayID displayID) {
    refreshDisplayMode();
    return &displayMode;
}

SDL_DisplayID SDL_GetDisplayForPoint(const SDL_Point *point) {
    return 1;
}

SDL_DisplayID SDL_GetDisplayForRect(const SDL_Rect *rect) {
    return 1;
}

SDL_DisplayID SDL_GetDisplayForWindow(SDL_Window *window) {
    return 1;
}

float SDL_GetWindowPixelDensity(SDL_Window *window) {
    return 1.0f;
}

float SDL_GetWindowDisplayScale(SDL_Window *window) {
    return 1.0f;
}

bool SDL_SetWindowFullscreenMode(SDL_Window *window, const SDL_DisplayMode *mode) {
    return true;
}

const SDL_DisplayMode *SDL_GetWindowFullscreenMode(SDL_Window *window) {
    return NULL;
}

SDL_PixelFormat SDL_GetWindowPixelFormat(SDL_Window *window) {
    return SDL_PIXELFORMAT_XRGB8888;
}

SDL_Window *SDL_CreateWindow(const char *title, int w, int h, SDL_WindowFlags flags) {
    windowState.flags = flags | SDL_WINDOW_FULLSCREEN | SDL_WINDOW_INPUT_FOCUS | SDL_WINDOW_MOUSE_FOCUS;
    windowState.flags &= ~(SDL_WINDOW_HIDDEN | SDL_WINDOW_MINIMIZED);
    snprintf(windowState.title, sizeof(windowState.title), "%s", title ? title : "");
    windowCreated = true;
    currentWidth = 0;
    currentHeight = 0;
    refreshWindowSize();
    if (flags & SDL_WINDOW_OPENGL) {
        setEngineWindowHint(0x00022001, 0x00030001);
    } else if (flags & SDL_WINDOW_VULKAN) {
        setEngineWindowHint(0x00022001, 0);
    }
    installInputHook();
    pushWindowEvent(SDL_EVENT_WINDOW_SHOWN, 0, 0);
    pushWindowEvent(SDL_EVENT_WINDOW_FOCUS_GAINED, 0, 0);
    pushWindowEvent(SDL_EVENT_WINDOW_MOUSE_ENTER, 0, 0);
    pushWindowEvent(SDL_EVENT_WINDOW_PIXEL_SIZE_CHANGED, currentWidth, currentHeight);
    return FCL_WINDOW;
}

SDL_WindowID SDL_GetWindowID(SDL_Window *window) {
    return 1;
}

SDL_Window *SDL_GetWindowFromID(SDL_WindowID id) {
    return windowCreated ? FCL_WINDOW : NULL;
}

SDL_Window **SDL_GetWindows(int *count) {
    SDL_Window **windows = malloc(sizeof(SDL_Window *) * 2);
    windows[0] = windowCreated ? FCL_WINDOW : NULL;
    windows[1] = NULL;
    if (count) {
        *count = windowCreated ? 1 : 0;
    }
    return windows;
}

SDL_WindowFlags SDL_GetWindowFlags(SDL_Window *window) {
    return windowState.flags;
}

bool SDL_SetWindowTitle(SDL_Window *window, const char *title) {
    snprintf(windowState.title, sizeof(windowState.title), "%s", title ? title : "");
    return true;
}

const char *SDL_GetWindowTitle(SDL_Window *window) {
    return windowState.title;
}

bool SDL_SetWindowIcon(SDL_Window *window, SDL_Surface *icon) {
    return true;
}

bool SDL_SetWindowPosition(SDL_Window *window, int x, int y) {
    return true;
}

bool SDL_GetWindowPosition(SDL_Window *window, int *x, int *y) {
    if (x) {
        *x = 0;
    }
    if (y) {
        *y = 0;
    }
    return true;
}

bool SDL_SetWindowSize(SDL_Window *window, int w, int h) {
    return true;
}

bool SDL_GetWindowSize(SDL_Window *window, int *w, int *h) {
    refreshWindowSize();
    if (w) {
        *w = currentWidth;
    }
    if (h) {
        *h = currentHeight;
    }
    return true;
}

bool SDL_GetWindowSizeInPixels(SDL_Window *window, int *w, int *h) {
    return SDL_GetWindowSize(window, w, h);
}

bool SDL_GetWindowSafeArea(SDL_Window *window, SDL_Rect *rect) {
    refreshWindowSize();
    if (rect) {
        rect->x = 0;
        rect->y = 0;
        rect->w = currentWidth;
        rect->h = currentHeight;
    }
    return true;
}

bool SDL_GetWindowBordersSize(SDL_Window *window, int *top, int *left, int *bottom, int *right) {
    if (top) *top = 0;
    if (left) *left = 0;
    if (bottom) *bottom = 0;
    if (right) *right = 0;
    return true;
}

bool SDL_SetWindowMinimumSize(SDL_Window *window, int min_w, int min_h) {
    return true;
}

bool SDL_SetWindowMaximumSize(SDL_Window *window, int max_w, int max_h) {
    return true;
}

bool SDL_SetWindowBordered(SDL_Window *window, bool bordered) {
    return true;
}

bool SDL_SetWindowResizable(SDL_Window *window, bool resizable) {
    return true;
}

bool SDL_SetWindowAlwaysOnTop(SDL_Window *window, bool on_top) {
    return true;
}

bool SDL_ShowWindow(SDL_Window *window) {
    return true;
}

bool SDL_HideWindow(SDL_Window *window) {
    return true;
}

bool SDL_RaiseWindow(SDL_Window *window) {
    return true;
}

bool SDL_MaximizeWindow(SDL_Window *window) {
    return true;
}

bool SDL_MinimizeWindow(SDL_Window *window) {
    return true;
}

bool SDL_RestoreWindow(SDL_Window *window) {
    return true;
}

bool SDL_SetWindowFullscreen(SDL_Window *window, bool fullscreen) {
    return true;
}

bool SDL_SyncWindow(SDL_Window *window) {
    return true;
}

bool SDL_SetWindowKeyboardGrab(SDL_Window *window, bool grabbed) {
    return true;
}

bool SDL_SetWindowMouseGrab(SDL_Window *window, bool grabbed) {
    return true;
}

bool SDL_GetWindowKeyboardGrab(SDL_Window *window) {
    return false;
}

bool SDL_GetWindowMouseGrab(SDL_Window *window) {
    return windowState.relativeMode;
}

bool SDL_SetWindowRelativeMouseMode(SDL_Window *window, bool enabled) {
    if (windowState.relativeMode == enabled) {
        return true;
    }
    windowState.relativeMode = enabled;
    void (*setGrabbing)(void *, void *, unsigned char, float, float) = engineSymbol("Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing");
    if (setGrabbing) {
        setGrabbing(NULL, NULL, enabled ? 1 : 0, 0, 0);
    }
    return true;
}

bool SDL_GetWindowRelativeMouseMode(SDL_Window *window) {
    return windowState.relativeMode;
}

bool SDL_SetWindowMouseRect(SDL_Window *window, const SDL_Rect *rect) {
    return true;
}

bool SDL_SetWindowOpacity(SDL_Window *window, float opacity) {
    return true;
}

bool SDL_FlashWindow(SDL_Window *window, SDL_FlashOperation operation) {
    return true;
}

void SDL_DestroyWindow(SDL_Window *window) {
    windowCreated = false;
}

bool SDL_ScreenSaverEnabled(void) {
    return false;
}

bool SDL_EnableScreenSaver(void) {
    return true;
}

bool SDL_DisableScreenSaver(void) {
    return true;
}

SDL_Window *SDL_GetKeyboardFocus(void) {
    return windowCreated ? FCL_WINDOW : NULL;
}

SDL_Window *SDL_GetMouseFocus(void) {
    return windowCreated ? FCL_WINDOW : NULL;
}

bool SDL_GL_LoadLibrary(const char *path) {
    setEngineWindowHint(0x00022001, 0x00030001);
    return true;
}

SDL_FunctionPointer SDL_GL_GetProcAddress(const char *proc) {
    if (!proc) {
        return NULL;
    }
    if (!rendererLibrary) {
        const char *renderer = getenv("RENDERER");
        if (!renderer || strcmp(renderer, "auto") == 0) {
            renderer = "libmobileglues.dylib";
        }
        char path[512];
        snprintf(path, sizeof(path), "%s/%s", NSBundle.mainBundle.privateFrameworksPath.UTF8String, renderer);
        rendererLibrary = dlopen(path, RTLD_NOW | RTLD_GLOBAL);
    }
    void *function = rendererLibrary ? dlsym(rendererLibrary, proc) : NULL;
    if (!function) {
        function = dlsym(RTLD_DEFAULT, proc);
    }
    return (SDL_FunctionPointer)function;
}

SDL_FunctionPointer SDL_EGL_GetProcAddress(const char *proc) {
    return SDL_GL_GetProcAddress(proc);
}

void SDL_GL_UnloadLibrary(void) {
}

bool SDL_GL_ExtensionSupported(const char *extension) {
    return false;
}

void SDL_GL_ResetAttributes(void) {
    memset(glAttributes, 0, sizeof(glAttributes));
}

bool SDL_GL_SetAttribute(SDL_GLAttr attr, int value) {
    if ((int)attr >= 0 && (int)attr < 64) {
        glAttributes[attr] = value;
    }
    if (attr == SDL_GL_CONTEXT_MAJOR_VERSION) {
        setEngineWindowHint(0x00022002, value);
    } else if (attr == SDL_GL_CONTEXT_MINOR_VERSION) {
        setEngineWindowHint(0x00022003, value);
    }
    return true;
}

bool SDL_GL_GetAttribute(SDL_GLAttr attr, int *value) {
    if (!value) {
        return false;
    }
    *value = ((int)attr >= 0 && (int)attr < 64) ? glAttributes[attr] : 0;
    return true;
}

SDL_GLContext SDL_GL_CreateContext(SDL_Window *window) {
    setEngineWindowHint(0x00022001, 0x00030001);
    void *(*createContext)(void *) = engineSymbol("pojavCreateContext");
    if (!createContext) {
        setErrorText("Renderer bridge is unavailable");
        return NULL;
    }
    void *context = createContext(NULL);
    if (!context) {
        setErrorText("Unable to create OpenGL context");
        return NULL;
    }
    SDL_GL_MakeCurrent(window, (SDL_GLContext)context);
    return (SDL_GLContext)context;
}

bool SDL_GL_MakeCurrent(SDL_Window *window, SDL_GLContext context) {
    void (*makeCurrent)(void *) = engineSymbol("pojavMakeCurrent");
    if (makeCurrent) {
        makeCurrent((void *)context);
    }
    currentContext = (void *)context;
    return true;
}

SDL_Window *SDL_GL_GetCurrentWindow(void) {
    return currentContext ? FCL_WINDOW : NULL;
}

SDL_GLContext SDL_GL_GetCurrentContext(void) {
    return (SDL_GLContext)currentContext;
}

bool SDL_GL_SetSwapInterval(int interval) {
    swapInterval = interval;
    void (*setInterval)(int) = engineSymbol("pojavSwapInterval");
    if (setInterval) {
        setInterval(interval);
    }
    return true;
}

bool SDL_GL_GetSwapInterval(int *interval) {
    if (interval) {
        *interval = swapInterval;
    }
    return true;
}

bool SDL_GL_SwapWindow(SDL_Window *window) {
    void (*swapBuffers)(void) = engineSymbol("pojavSwapBuffers");
    if (swapBuffers) {
        swapBuffers();
    }
    return true;
}

bool SDL_GL_DestroyContext(SDL_GLContext context) {
    if (currentContext == (void *)context) {
        currentContext = NULL;
    }
    return true;
}

bool SDL_Vulkan_LoadLibrary(const char *path) {
    if (vulkanLibrary) {
        return true;
    }
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (path) {
        [candidates addObject:@(path)];
    }
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    [candidates addObject:[bundle stringByAppendingPathComponent:@"lwjgl_natives/libMoltenVK.dylib"]];
    [candidates addObject:[bundle stringByAppendingPathComponent:@"Frameworks/libMoltenVK.dylib"]];
    for (NSString *candidate in candidates) {
        vulkanLibrary = dlopen(candidate.UTF8String, RTLD_NOW | RTLD_LOCAL);
        if (vulkanLibrary) {
            return true;
        }
    }
    setErrorText(dlerror());
    return false;
}

SDL_FunctionPointer SDL_Vulkan_GetVkGetInstanceProcAddr(void) {
    if (!vulkanLibrary && !SDL_Vulkan_LoadLibrary(NULL)) {
        return NULL;
    }
    return (SDL_FunctionPointer)dlsym(vulkanLibrary, "vkGetInstanceProcAddr");
}

void SDL_Vulkan_UnloadLibrary(void) {
}

char const * const *SDL_Vulkan_GetInstanceExtensions(Uint32 *count) {
    static const char *const extensions[] = { "VK_KHR_surface", "VK_EXT_metal_surface" };
    if (count) {
        *count = 2;
    }
    return extensions;
}

typedef struct FCLMetalSurfaceCreateInfo {
    int structureType;
    const void *next;
    unsigned int flags;
    const void *layer;
} FCLMetalSurfaceCreateInfo;

bool SDL_Vulkan_CreateSurface(SDL_Window *window, VkInstance instance, const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface) {
    typedef void *(*InstanceProcedure)(VkInstance, const char *);
    typedef int (*CreateMetalSurface)(VkInstance, const FCLMetalSurfaceCreateInfo *, const struct VkAllocationCallbacks *, VkSurfaceKHR *);
    InstanceProcedure getProcedure = (InstanceProcedure)SDL_Vulkan_GetVkGetInstanceProcAddr();
    if (!getProcedure) {
        setErrorText("Vulkan loader is unavailable");
        return false;
    }
    CreateMetalSurface createSurface = (CreateMetalSurface)getProcedure(instance, "vkCreateMetalSurfaceEXT");
    if (!createSurface) {
        setErrorText("vkCreateMetalSurfaceEXT is unavailable");
        return false;
    }
    CALayer *layer = surfaceLayer();
    if (![layer isKindOfClass:CAMetalLayer.class]) {
        setErrorText("Game surface is not backed by a Metal layer");
        return false;
    }
    FCLMetalSurfaceCreateInfo information = { 1000217000, NULL, 0, (__bridge const void *)layer };
    int result = createSurface(instance, &information, allocator, surface);
    if (result != 0) {
        snprintf(errorBuffer, sizeof(errorBuffer), "vkCreateMetalSurfaceEXT failed with %d", result);
        return false;
    }
    return true;
}

void SDL_Vulkan_DestroySurface(VkInstance instance, VkSurfaceKHR surface, const struct VkAllocationCallbacks *allocator) {
    typedef void *(*InstanceProcedure)(VkInstance, const char *);
    typedef void (*DestroySurface)(VkInstance, VkSurfaceKHR, const struct VkAllocationCallbacks *);
    InstanceProcedure getProcedure = (InstanceProcedure)SDL_Vulkan_GetVkGetInstanceProcAddr();
    if (!getProcedure) {
        return;
    }
    DestroySurface destroySurface = (DestroySurface)getProcedure(instance, "vkDestroySurfaceKHR");
    if (destroySurface) {
        destroySurface(instance, surface, allocator);
    }
}

bool SDL_Vulkan_GetPresentationSupport(VkInstance instance, VkPhysicalDevice physicalDevice, Uint32 queueFamilyIndex) {
    return true;
}

SDL_MetalView SDL_Metal_CreateView(SDL_Window *window) {
    return (SDL_MetalView)(__bridge void *)surfaceView();
}

void SDL_Metal_DestroyView(SDL_MetalView view) {
}

void *SDL_Metal_GetLayer(SDL_MetalView view) {
    return (__bridge void *)surfaceLayer();
}

void SDL_PumpEvents(void) {
}

bool SDL_PollEvent(SDL_Event *event) {
    bool available = false;
    os_unfair_lock_lock(&eventLock);
    if (eventCount > 0) {
        available = true;
        if (event) {
            *event = eventQueue[eventHead];
            eventHead = (eventHead + 1) % (int)(sizeof(eventQueue) / sizeof(eventQueue[0]));
            eventCount--;
        }
    }
    os_unfair_lock_unlock(&eventLock);
    return available;
}

bool SDL_WaitEventTimeout(SDL_Event *event, Sint32 timeoutMS) {
    Uint64 deadline = SDL_GetTicks() + (Uint64)(timeoutMS < 0 ? 0 : timeoutMS);
    while (true) {
        if (SDL_PollEvent(event)) {
            return true;
        }
        if (timeoutMS >= 0 && SDL_GetTicks() >= deadline) {
            return false;
        }
        usleep(1000);
    }
}

bool SDL_WaitEvent(SDL_Event *event) {
    return SDL_WaitEventTimeout(event, -1);
}

bool SDL_PushEvent(SDL_Event *event) {
    if (!event) {
        return false;
    }
    SDL_Event copy = *event;
    pushEvent(&copy);
    return true;
}

static void removeEvents(Uint32 minimumType, Uint32 maximumType) {
    os_unfair_lock_lock(&eventLock);
    int capacity = (int)(sizeof(eventQueue) / sizeof(eventQueue[0]));
    int kept = 0;
    for (int index = 0; index < eventCount; index++) {
        SDL_Event candidate = eventQueue[(eventHead + index) % capacity];
        if (candidate.type < minimumType || candidate.type > maximumType) {
            eventQueue[(eventHead + kept) % capacity] = candidate;
            kept++;
        }
    }
    eventCount = kept;
    os_unfair_lock_unlock(&eventLock);
}

void SDL_FlushEvent(Uint32 type) {
    removeEvents(type, type);
}

void SDL_FlushEvents(Uint32 minType, Uint32 maxType) {
    removeEvents(minType, maxType);
}

bool SDL_HasEvent(Uint32 type) {
    return SDL_HasEvents(type, type);
}

bool SDL_HasEvents(Uint32 minType, Uint32 maxType) {
    bool found = false;
    os_unfair_lock_lock(&eventLock);
    int capacity = (int)(sizeof(eventQueue) / sizeof(eventQueue[0]));
    for (int index = 0; index < eventCount && !found; index++) {
        Uint32 type = eventQueue[(eventHead + index) % capacity].type;
        found = type >= minType && type <= maxType;
    }
    os_unfair_lock_unlock(&eventLock);
    return found;
}

SDL_Window *SDL_GetWindowFromEvent(const SDL_Event *event) {
    return windowCreated ? FCL_WINDOW : NULL;
}

void SDL_SetEventEnabled(Uint32 type, bool enabled) {
}

bool SDL_EventEnabled(Uint32 type) {
    return true;
}

Uint32 SDL_RegisterEvents(int numevents) {
    static Uint32 nextEvent = SDL_EVENT_USER;
    Uint32 first = nextEvent;
    nextEvent += (Uint32)numevents;
    return first;
}

void SDL_SetEventFilter(SDL_EventFilter filter, void *userdata) {
}

bool SDL_AddEventWatch(SDL_EventFilter filter, void *userdata) {
    return true;
}

void SDL_RemoveEventWatch(SDL_EventFilter filter, void *userdata) {
}

bool SDL_HasMouse(void) {
    return true;
}

SDL_MouseButtonFlags SDL_GetMouseState(float *x, float *y) {
    if (x) {
        *x = mouseX;
    }
    if (y) {
        *y = mouseY;
    }
    return buttonState;
}

SDL_MouseButtonFlags SDL_GetGlobalMouseState(float *x, float *y) {
    return SDL_GetMouseState(x, y);
}

SDL_MouseButtonFlags SDL_GetRelativeMouseState(float *x, float *y) {
    if (x) {
        *x = 0;
    }
    if (y) {
        *y = 0;
    }
    return buttonState;
}

void SDL_WarpMouseInWindow(SDL_Window *window, float x, float y) {
    mouseX = x;
    mouseY = y;
    double *cursorX = engineSymbol("cursorX");
    double *cursorY = engineSymbol("cursorY");
    if (cursorX && cursorY) {
        *cursorX = x;
        *cursorY = y;
    }
}

bool SDL_WarpMouseGlobal(float x, float y) {
    SDL_WarpMouseInWindow(NULL, x, y);
    return true;
}

bool SDL_CaptureMouse(bool enabled) {
    return true;
}

static int cursorPlaceholder;

SDL_Cursor *SDL_CreateSystemCursor(SDL_SystemCursor id) {
    return (SDL_Cursor *)&cursorPlaceholder;
}

SDL_Cursor *SDL_CreateColorCursor(SDL_Surface *surface, int hot_x, int hot_y) {
    return (SDL_Cursor *)&cursorPlaceholder;
}

SDL_Cursor *SDL_CreateCursor(const Uint8 *data, const Uint8 *mask, int w, int h, int hot_x, int hot_y) {
    return (SDL_Cursor *)&cursorPlaceholder;
}

bool SDL_SetCursor(SDL_Cursor *cursor) {
    return true;
}

SDL_Cursor *SDL_GetCursor(void) {
    return (SDL_Cursor *)&cursorPlaceholder;
}

SDL_Cursor *SDL_GetDefaultCursor(void) {
    return (SDL_Cursor *)&cursorPlaceholder;
}

void SDL_DestroyCursor(SDL_Cursor *cursor) {
}

bool SDL_ShowCursor(void) {
    return true;
}

bool SDL_HideCursor(void) {
    return true;
}

bool SDL_CursorVisible(void) {
    return true;
}

bool SDL_HasKeyboard(void) {
    return true;
}

const bool *SDL_GetKeyboardState(int *numkeys) {
    if (numkeys) {
        *numkeys = SDL_SCANCODE_COUNT;
    }
    return keyboardState;
}

void SDL_ResetKeyboard(void) {
    memset(keyboardState, 0, sizeof(keyboardState));
    modifierState = SDL_KMOD_NONE;
}

SDL_Keymod SDL_GetModState(void) {
    return modifierState;
}

void SDL_SetModState(SDL_Keymod modstate) {
    modifierState = modstate;
}

SDL_Keycode SDL_GetKeyFromScancode(SDL_Scancode scancode, SDL_Keymod modstate, bool key_event) {
    if (scancode >= SDL_SCANCODE_A && scancode <= SDL_SCANCODE_Z) {
        return (SDL_Keycode)('a' + (scancode - SDL_SCANCODE_A));
    }
    if (scancode >= SDL_SCANCODE_1 && scancode <= SDL_SCANCODE_9) {
        return (SDL_Keycode)('1' + (scancode - SDL_SCANCODE_1));
    }
    switch (scancode) {
        case SDL_SCANCODE_0: return '0';
        case SDL_SCANCODE_RETURN: return SDLK_RETURN;
        case SDL_SCANCODE_ESCAPE: return SDLK_ESCAPE;
        case SDL_SCANCODE_BACKSPACE: return SDLK_BACKSPACE;
        case SDL_SCANCODE_TAB: return SDLK_TAB;
        case SDL_SCANCODE_SPACE: return SDLK_SPACE;
        case SDL_SCANCODE_MINUS: return '-';
        case SDL_SCANCODE_EQUALS: return '=';
        case SDL_SCANCODE_LEFTBRACKET: return '[';
        case SDL_SCANCODE_RIGHTBRACKET: return ']';
        case SDL_SCANCODE_BACKSLASH: return '\\';
        case SDL_SCANCODE_SEMICOLON: return ';';
        case SDL_SCANCODE_APOSTROPHE: return '\'';
        case SDL_SCANCODE_GRAVE: return '`';
        case SDL_SCANCODE_COMMA: return ',';
        case SDL_SCANCODE_PERIOD: return '.';
        case SDL_SCANCODE_SLASH: return '/';
        case SDL_SCANCODE_DELETE: return SDLK_DELETE;
        case SDL_SCANCODE_UNKNOWN: return SDLK_UNKNOWN;
        default: return SDL_SCANCODE_TO_KEYCODE(scancode);
    }
}

SDL_Scancode SDL_GetScancodeFromKey(SDL_Keycode key, SDL_Keymod *modstate) {
    if (modstate) {
        *modstate = SDL_KMOD_NONE;
    }
    for (int scancode = 0; scancode < SDL_SCANCODE_COUNT; scancode++) {
        if (SDL_GetKeyFromScancode((SDL_Scancode)scancode, SDL_KMOD_NONE, false) == key) {
            return (SDL_Scancode)scancode;
        }
    }
    return SDL_SCANCODE_UNKNOWN;
}

static const char *nameForScancode(SDL_Scancode scancode) {
    static char letterNames[SDL_SCANCODE_COUNT][4];
    switch (scancode) {
        case SDL_SCANCODE_RETURN: return "Return";
        case SDL_SCANCODE_ESCAPE: return "Escape";
        case SDL_SCANCODE_BACKSPACE: return "Backspace";
        case SDL_SCANCODE_TAB: return "Tab";
        case SDL_SCANCODE_SPACE: return "Space";
        case SDL_SCANCODE_CAPSLOCK: return "CapsLock";
        case SDL_SCANCODE_DELETE: return "Delete";
        case SDL_SCANCODE_INSERT: return "Insert";
        case SDL_SCANCODE_HOME: return "Home";
        case SDL_SCANCODE_END: return "End";
        case SDL_SCANCODE_PAGEUP: return "PageUp";
        case SDL_SCANCODE_PAGEDOWN: return "PageDown";
        case SDL_SCANCODE_RIGHT: return "Right";
        case SDL_SCANCODE_LEFT: return "Left";
        case SDL_SCANCODE_DOWN: return "Down";
        case SDL_SCANCODE_UP: return "Up";
        case SDL_SCANCODE_LCTRL: return "Left Ctrl";
        case SDL_SCANCODE_LSHIFT: return "Left Shift";
        case SDL_SCANCODE_LALT: return "Left Option";
        case SDL_SCANCODE_LGUI: return "Left Command";
        case SDL_SCANCODE_RCTRL: return "Right Ctrl";
        case SDL_SCANCODE_RSHIFT: return "Right Shift";
        case SDL_SCANCODE_RALT: return "Right Option";
        case SDL_SCANCODE_RGUI: return "Right Command";
        default: break;
    }
    if (scancode >= SDL_SCANCODE_F1 && scancode <= SDL_SCANCODE_F12) {
        snprintf(letterNames[scancode], sizeof(letterNames[scancode]), "F%d", (int)(scancode - SDL_SCANCODE_F1 + 1));
        return letterNames[scancode];
    }
    SDL_Keycode key = SDL_GetKeyFromScancode(scancode, SDL_KMOD_NONE, false);
    if (key >= 32 && key < 127 && scancode < SDL_SCANCODE_COUNT) {
        letterNames[scancode][0] = (char)toupper((int)key);
        letterNames[scancode][1] = 0;
        return letterNames[scancode];
    }
    return "";
}

const char *SDL_GetScancodeName(SDL_Scancode scancode) {
    return nameForScancode(scancode);
}

const char *SDL_GetKeyName(SDL_Keycode key) {
    return nameForScancode(SDL_GetScancodeFromKey(key, NULL));
}

bool SDL_StartTextInput(SDL_Window *window) {
    windowState.textInputActive = true;
    return true;
}

bool SDL_StartTextInputWithProperties(SDL_Window *window, SDL_PropertiesID props) {
    windowState.textInputActive = true;
    return true;
}

bool SDL_TextInputActive(SDL_Window *window) {
    return windowState.textInputActive;
}

bool SDL_StopTextInput(SDL_Window *window) {
    windowState.textInputActive = false;
    return true;
}

bool SDL_ClearComposition(SDL_Window *window) {
    return true;
}

bool SDL_SetTextInputArea(SDL_Window *window, const SDL_Rect *rect, int cursor) {
    return true;
}

bool SDL_HasScreenKeyboardSupport(void) {
    return false;
}

bool SDL_ScreenKeyboardShown(SDL_Window *window) {
    return false;
}

bool SDL_SetClipboardText(const char *text) {
    NSString *value = text ? @(text) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIPasteboard.generalPasteboard.string = value;
    });
    return true;
}

char *SDL_GetClipboardText(void) {
    __block NSString *value = nil;
    void (^read)(void) = ^{
        value = UIPasteboard.generalPasteboard.string;
    };
    if (NSThread.isMainThread) {
        read();
    } else {
        dispatch_sync(dispatch_get_main_queue(), read);
    }
    return strdup(value ? value.UTF8String : "");
}

bool SDL_HasClipboardText(void) {
    return UIPasteboard.generalPasteboard.hasStrings;
}

bool SDL_ShowMessageBox(const SDL_MessageBoxData *messageboxdata, int *buttonid) {
    if (messageboxdata) {
        NSLog(@"[SDLBridge] %s: %s", messageboxdata->title ? messageboxdata->title : "", messageboxdata->message ? messageboxdata->message : "");
    }
    if (buttonid) {
        *buttonid = (messageboxdata && messageboxdata->numbuttons > 0) ? messageboxdata->buttons[0].buttonID : -1;
    }
    return true;
}

bool SDL_ShowSimpleMessageBox(SDL_MessageBoxFlags flags, const char *title, const char *message, SDL_Window *window) {
    NSLog(@"[SDLBridge] %s: %s", title ? title : "", message ? message : "");
    return true;
}

bool SDL_OpenURL(const char *url) {
    if (!url) {
        return false;
    }
    NSURL *address = [NSURL URLWithString:@(url)];
    if (!address) {
        return false;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIApplication.sharedApplication openURL:address options:@{} completionHandler:nil];
    });
    return true;
}

SDL_Surface *SDL_CreateSurfaceFrom(int width, int height, SDL_PixelFormat format, void *pixels, int pitch) {
    SDL_Surface *surface = calloc(1, sizeof(SDL_Surface));
    surface->format = format;
    surface->w = width;
    surface->h = height;
    surface->pitch = pitch;
    surface->pixels = pixels;
    surface->refcount = 1;
    return surface;
}

SDL_Surface *SDL_CreateSurface(int width, int height, SDL_PixelFormat format) {
    SDL_Surface *surface = calloc(1, sizeof(SDL_Surface));
    surface->format = format;
    surface->w = width;
    surface->h = height;
    surface->pitch = width * 4;
    surface->refcount = 1;
    return surface;
}

void SDL_DestroySurface(SDL_Surface *surface) {
    free(surface);
}

bool SDL_AddSurfaceAlternateImage(SDL_Surface *surface, SDL_Surface *image) {
    return true;
}

const SDL_PixelFormatDetails *SDL_GetPixelFormatDetails(SDL_PixelFormat format) {
    memset(&formatDetails, 0, sizeof(formatDetails));
    formatDetails.format = format;
    formatDetails.bits_per_pixel = 32;
    formatDetails.bytes_per_pixel = 4;
    formatDetails.Rbits = 8;
    formatDetails.Gbits = 8;
    formatDetails.Bbits = 8;
    switch (format) {
        case SDL_PIXELFORMAT_ABGR8888:
            formatDetails.Rmask = 0x000000FF;
            formatDetails.Gmask = 0x0000FF00;
            formatDetails.Bmask = 0x00FF0000;
            formatDetails.Amask = 0xFF000000;
            formatDetails.Abits = 8;
            formatDetails.Rshift = 0;
            formatDetails.Gshift = 8;
            formatDetails.Bshift = 16;
            formatDetails.Ashift = 24;
            break;
        case SDL_PIXELFORMAT_ARGB8888:
            formatDetails.Rmask = 0x00FF0000;
            formatDetails.Gmask = 0x0000FF00;
            formatDetails.Bmask = 0x000000FF;
            formatDetails.Amask = 0xFF000000;
            formatDetails.Abits = 8;
            formatDetails.Rshift = 16;
            formatDetails.Gshift = 8;
            formatDetails.Bshift = 0;
            formatDetails.Ashift = 24;
            break;
        default:
            formatDetails.bits_per_pixel = 24;
            formatDetails.Rmask = 0x00FF0000;
            formatDetails.Gmask = 0x0000FF00;
            formatDetails.Bmask = 0x000000FF;
            formatDetails.Rshift = 16;
            formatDetails.Gshift = 8;
            formatDetails.Bshift = 0;
            break;
    }
    return &formatDetails;
}

const char *SDL_GetPixelFormatName(SDL_PixelFormat format) {
    return "SDL_PIXELFORMAT_XRGB8888";
}

SDL_PowerState SDL_GetPowerInfo(int *seconds, int *percent) {
    if (seconds) {
        *seconds = -1;
    }
    if (percent) {
        *percent = -1;
    }
    return SDL_POWERSTATE_UNKNOWN;
}

int SDL_GetNumLogicalCPUCores(void) {
    return (int)NSProcessInfo.processInfo.activeProcessorCount;
}

int SDL_GetSystemRAM(void) {
    return (int)(NSProcessInfo.processInfo.physicalMemory / 1048576ULL);
}
