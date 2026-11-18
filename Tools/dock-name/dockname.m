/*
 * Cell's helper inside every Wine process (DYLD_INSERT_LIBRARIES). It also makes see-through game windows (desktop
 * pets, idle games in a strip of the screen) see-through on the Mac too (apply_overlays). Before Wine starts, it gives the program the
 * settings Cell chose for it (its graphics engine and variables, see apply_program_settings) — also when Steam or a
 * launcher started it. Once Cocoa starts it does two more things:
 *
 * 1. Gives each Windows program its own name in the Dock and the app switcher (below).
 * 2. Fullscreen games: while a window covering its whole screen is in front, the Dock and the menu bar are hidden
 *    (the pointer reaching the screen's edge used to bring them up over the game and take the clicks), and the
 *    keyboard uses a Roman layout (a Chinese or Japanese input method swallowed the game's keys). Both come back
 *    as soon as the game isn't in front or isn't fullscreen.
 *
 * Gives each Windows program its own name in the Dock and the app switcher.
 *
 * Every Wine process is the same Mac program ("wine"), so macOS shows "wine" for all of them. Cell loads this
 * library into its Wine processes (DYLD_INSERT_LIBRARIES). When the Mac driver starts Cocoa in a process, the
 * library looks up the Windows program the process runs (the first argument ending in .exe) in the name list
 * Cell writes (CELL_DOCK_NAMES: a file of "program.exe<TAB>Name" lines) and tells LaunchServices that name.
 * Programs that aren't listed get their file name without ".exe" and Unreal's "-Win64-Shipping".
 *
 * CoreFoundation, CoreGraphics and the Objective-C runtime are linked (AppKit is reached through the runtime once the Mac
 * driver has loaded it). Per-program settings are applied before Cocoa starts.
 * Build: Tools/dock-name/build.sh (universal: Wine runs as x86_64 under Rosetta).
 */
#include <CoreFoundation/CoreFoundation.h>
#include <CoreGraphics/CGDirectDisplay.h>
#include <CoreGraphics/CGGeometry.h>
#include <objc/runtime.h>
#include <objc/message.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <crt_externs.h>
#include <math.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>
#include <spawn.h>
#include <netdb.h>

static char program[256];
static const char *program_path;
#define INPUT_TRACE(...) do { if (getenv("CELL_INPUT_TRACE")) fprintf(stderr, __VA_ARGS__); } while (0)

/* Winsock uses the host's system resolver. Read the layer's current map at lookup time so
 * changes affect subsequent requests without touching macOS or another Wine prefix. */
static int host_rewrite(const char *name, char target[256], int *retry, int *prefer_ipv4) {
    if (!name || !*name) return 0;
    const char *path = getenv("CELL_HOST_REWRITES");
    char fallback[PATH_MAX];
    if (!path) {
        const char *prefix = getenv("WINEPREFIX");
        size_t len = prefix ? strlen(prefix) : 0;
        if (len < 7 || strcmp(prefix + len - 7, "/prefix") ||
            snprintf(fallback, sizeof(fallback), "%.*s/host-rewrites.tsv", (int)(len - 7), prefix) >= (int)sizeof(fallback)) return 0;
        path = fallback;
    }
    FILE *file = fopen(path, "r");
    if (!file) return 0;
    size_t length = strlen(name);
    if (name[length - 1] == '.') length--;
    int found = 0;
    char line[550];
    while (fgets(line, sizeof(line), file)) {
        char *value = strchr(line, '\t');
        if (!value) continue;
        *value++ = 0;
        value[strcspn(value, "\r\n")] = 0;
        if (!strcmp(line, "#retry-original")) { *retry = !strcmp(value, "1"); continue; }
        if (!strcmp(line, "#prefer-ipv4")) { *prefer_ipv4 = !strcmp(value, "1"); continue; }
        if (strlen(line) == length && !strncasecmp(line, name, length) && *value && strlen(value) < 256) {
            strcpy(target, value);
            found = 1;
            break;
        }
    }
    fclose(file);
    return found;
}

static int resolve_address(const char *name, const char *service, const struct addrinfo *hints,
                           struct addrinfo **result, int prefer_ipv4) {
    if (prefer_ipv4 && (!hints || hints->ai_family == AF_UNSPEC)) {
        struct addrinfo ipv4 = {0};
        if (hints) ipv4 = *hints;
        ipv4.ai_family = AF_INET;
        if (!getaddrinfo(name, service, &ipv4, result)) return 0;
    }
    return getaddrinfo(name, service, hints, result);
}

static int cell_getaddrinfo(const char *name, const char *service, const struct addrinfo *hints, struct addrinfo **result) {
    char target[256];
    int retry = 0, prefer_ipv4 = 0;
    if ((!hints || !(hints->ai_flags & AI_NUMERICHOST)) && host_rewrite(name, target, &retry, &prefer_ipv4)) {
        int error = resolve_address(target, service, hints, result, prefer_ipv4);
        if (!error || !retry) return error;
    }
    return resolve_address(name, service, hints, result, prefer_ipv4);
}

__attribute__((used, section("__DATA,__interpose")))
static const struct { const void *replacement, *original; } cell_resolver = {
    (const void *)cell_getaddrinfo, (const void *)getaddrinfo
};

static const char *helpers[] = { "wineboot.exe", "winedevice.exe", "services.exe", "plugplay.exe", "explorer.exe", "rpcss.exe",
                                 "svchost.exe", "conhost.exe", "start.exe", "winemenubuilder.exe", "tabtip.exe", "rundll32.exe", 0 };

/* The file name of the Windows program, lower case ("steam.exe"), or nothing. */
static int find_program(void) {
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 1; i < argc && i < 8; i++) {
        const char *arg = argv[i];
        size_t length = arg ? strlen(arg) : 0;
        if (length < 5 || length > 1024 || strcasecmp(arg + length - 4, ".exe") != 0) continue;
        const char *name = arg;
        for (const char *p = arg; *p; p++) if (*p == '\\' || *p == '/') name = p + 1;
        size_t n = strlen(name);
        if (n == 0 || n >= sizeof(program)) return 0;
        program_path = arg;
        for (size_t k = 0; k <= n; k++) program[k] = (char)((name[k] >= 'A' && name[k] <= 'Z') ? name[k] + 32 : name[k]);
        for (int h = 0; helpers[h]; h++) if (strcmp(program, helpers[h]) == 0) return 0;
        return 1;
    }
    return 0;
}

/* Paradox Launcher v2 reads launcher-args.json beside its executable before Electron starts.
 * Install defaults at process startup so the same repair applies to newly installed versions
 * and launchers started by Steam or by a game's bootstrapper. Keep a preexisting vendor config. */
static void prepare_paradox_launcher(void) {
    if (strcmp(program, "paradox launcher.exe") || !program_path) return;
    const char *prefix = getenv("WINEPREFIX");
    if (!prefix || !*prefix) return;

    char path[PATH_MAX], drive[PATH_MAX], executable[PATH_MAX], root[PATH_MAX];
    const char *candidate = program_path;
    if (!strncasecmp(program_path, "C:\\", 3) || !strncasecmp(program_path, "C:/", 3)) {
        if (snprintf(path, sizeof(path), "%s/drive_c/%s", prefix, program_path + 3) >= (int)sizeof(path)) return;
        for (char *p = path + strlen(prefix); *p; p++) if (*p == '\\') *p = '/';
        candidate = path;
    }
    if (snprintf(drive, sizeof(drive), "%s/drive_c", prefix) >= (int)sizeof(drive) ||
        !realpath(candidate, executable) || !realpath(drive, root)) return;
    struct stat info;
    if (stat(executable, &info) || !S_ISREG(info.st_mode)) return;
    size_t root_length = strlen(root);
    if (strncmp(executable, root, root_length) || executable[root_length] != '/') return;
    const char *relative = executable + root_length + 1;
    const char *system = "Program Files/Paradox Interactive/launcher/";
    const char *system_x86 = "Program Files (x86)/Paradox Interactive/launcher/";
    const char *user = "/AppData/Local/Paradox Interactive/launcher-v2/";
    if (strncasecmp(relative, system, strlen(system)) &&
        strncasecmp(relative, system_x86, strlen(system_x86)) &&
        (strncasecmp(relative, "users/", 6) || !strcasestr(relative, user))) return;
    char *filename = strrchr(executable, '/');
    *filename = 0;
    const char *version = strrchr(executable, '/') + 1;
    if (strncasecmp(version, "launcher-v2.", 12)) return;

    char config[PATH_MAX], scratch[PATH_MAX];
    if (snprintf(config, sizeof(config), "%s/launcher-args.json", executable) >= (int)sizeof(config) ||
        snprintf(scratch, sizeof(scratch), "%s/.cell-launcher-args-XXXXXX", executable) >= (int)sizeof(scratch)) return;
    if (!lstat(config, &info)) return;
    int fd = mkstemp(scratch);
    if (fd < 0) return;
    static const char options[] = "{\"pdxlDisableHardwareAcceleration\":true,\"pdxlEnableInProcessGpu\":true}\n";
    ssize_t count = write(fd, options, sizeof(options) - 1);
    int closed = close(fd);
    if (count == sizeof(options) - 1 && !closed && !link(scratch, config))
        fprintf(stderr, "Cell: enabled software rendering for Paradox Launcher v2\n");
    unlink(scratch);
}

/* The Sims 4 can initialize its Retina drawable at desktop size, then switch the
 * Mac to its saved exclusive mode without resizing that drawable. Match the mode
 * to the actual primary display before the launcher hands control to the game. */
static void prepare_sims_fullscreen(void) {
    if (strcmp(program, "ts4_x64.exe") && strcmp(program, "ts4_dx9_x64.exe")) return;
    const char *path = getenv("CELL_SIMS_DISPLAY_OPTIONS");
    if (!path || !*path) return;
    CGDisplayModeRef display = CGDisplayCopyDisplayMode(CGMainDisplayID());
    if (!display) return;
    size_t width = CGDisplayModeGetPixelWidth(display), height = CGDisplayModeGetPixelHeight(display);
    size_t points = CGDisplayModeGetWidth(display);
    CGDisplayModeRelease(display);
    if (width <= points || width < 640 || height < 480) return;

    int input = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    if (input < 0) return;
    struct stat before, after;
    if (fstat(input, &before) || !S_ISREG(before.st_mode) || before.st_size <= 0 || before.st_size > 131072) {
        close(input);
        return;
    }
    FILE *source = fdopen(input, "r");
    if (!source) { close(input); return; }
    char scratch[PATH_MAX];
    if (snprintf(scratch, sizeof(scratch), "%s.cell-XXXXXX", path) >= (int)sizeof(scratch)) {
        fclose(source);
        return;
    }
    int target = mkstemp(scratch);
    if (target < 0) { fclose(source); return; }
    FILE *output = fdopen(target, "w");
    if (!output) { close(target); fclose(source); unlink(scratch); return; }
    char *line = NULL;
    size_t capacity = 0;
    int fullscreen = 0, windowed = 0, mode_keys = 0, dimensions = 0, changed = 0, okay = 1;
    ssize_t length;
    while (okay && (length = getline(&line, &capacity, source)) >= 0) {
        char key[32], tail;
        unsigned value = 0;
        size_t wanted = 0;
        if (sscanf(line, " %31[a-zA-Z] = %u %c", key, &value, &tail) == 2) {
            if (!strcasecmp(key, "fullscreen") && !(mode_keys & 1)) { fullscreen = value == 1; mode_keys |= 1; }
            else if (!strcasecmp(key, "windowedfullscreen") && !(mode_keys & 2)) { windowed = value != 0; mode_keys |= 2; }
            else if (!strcasecmp(key, "fullscreen") || !strcasecmp(key, "windowedfullscreen")) { okay = 0; break; }
            else if (!strcasecmp(key, "resolutionwidth")) {
                if (dimensions & 1) { okay = 0; break; }
                dimensions |= 1; wanted = width;
            } else if (!strcasecmp(key, "resolutionheight")) {
                if (dimensions & 2) { okay = 0; break; }
                dimensions |= 2; wanted = height;
            }
        }
        if (wanted && value != wanted) {
            const char *ending = length >= 2 && line[length - 2] == '\r' && line[length - 1] == '\n' ? "\r\n"
                : length && line[length - 1] == '\n' ? "\n" : "";
            okay = fprintf(output, "%s = %zu%s", key, wanted, ending) > 0;
            changed = 1;
        } else okay = fwrite(line, 1, (size_t)length, output) == (size_t)length;
    }
    free(line);
    okay = okay && !ferror(source);
    fclose(source);
    if (fchmod(target, before.st_mode & 0777)) okay = 0;
    if (fclose(output)) okay = 0;
    // Do not clobber a settings file changed by another process during startup.
    if (okay && changed && fullscreen && !windowed && mode_keys == 3 && dimensions == 3 && !lstat(path, &after) &&
        before.st_dev == after.st_dev && before.st_ino == after.st_ino && before.st_size == after.st_size &&
        before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec && before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec &&
        !rename(scratch, path)) {
        fprintf(stderr, "Cell: matched Sims 4 exclusive fullscreen to the Retina display (%zux%zu)\n", width, height);
    }
    unlink(scratch);
}

/* The name from Cell's list, or a tidied file name. Returns a CFString the caller releases. */
static CFStringRef display_name(void) {
    const char *list = getenv("CELL_DOCK_NAMES");
    FILE *file = list ? fopen(list, "r") : NULL;
    if (file) {
        char line[1024];
        while (fgets(line, sizeof(line), file)) {
            char *tab = strchr(line, '\t');
            if (!tab) continue;
            *tab = 0;
            if (strcasecmp(line, program) != 0) continue;
            char *name = tab + 1;
            name[strcspn(name, "\r\n")] = 0;
            fclose(file);
            return *name ? CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8) : NULL;
        }
        fclose(file);
    }
    char name[256];
    strncpy(name, program, sizeof(name) - 1);
    name[sizeof(name) - 1] = 0;
    size_t n = strlen(name);
    if (n > 4) name[n - 4] = 0;
    char *shipping = strstr(name, "-win64-shipping");
    if (!shipping) shipping = strstr(name, "-win32-shipping");
    if (shipping) *shipping = 0;
    /* The list holds the real spelling; without it, take the spelling from the command line. */
    int argc = *_NSGetArgc();
    char **argv = *_NSGetArgv();
    for (int i = 1; i < argc && i < 8; i++) {
        const char *arg = argv[i], *base = arg;
        if (!arg) continue;
        for (const char *p = arg; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
        if (strncasecmp(base, name, strlen(name)) == 0) { memcpy(name, base, strlen(name)); break; }
    }
    return *name ? CFStringCreateWithCString(NULL, name, kCFStringEncodingUTF8) : NULL;
}


/* ---- Fullscreen games (see the top of the file) ---- */

#define HIDE_DOCK (1UL << 1)
#define AUTOHIDE_DOCK (1UL << 0)
#define HIDE_MENU_BAR (1UL << 3)
#define AUTOHIDE_MENU_BAR (1UL << 2)

static SEL sel(const char *name) { return sel_registerName(name); }
static id sendObject(id target, const char *name) { return target ? ((id (*)(id, SEL))objc_msgSend)(target, sel(name)) : nil; }
static BOOL sendBool(id target, const char *name) { return target ? ((BOOL (*)(id, SEL))objc_msgSend)(target, sel(name)) : NO; }
static CGRect sendRect(id target, const char *name) {
    if (!target) { CGRect none = {{0, 0}, {0, 0}}; return none; }
#if defined(__x86_64__)
    return ((CGRect (*)(id, SEL))objc_msgSend_stret)(target, sel(name));
#else
    return ((CGRect (*)(id, SEL))objc_msgSend)(target, sel(name));
#endif
}
static int responds(id target, const char *name) {
    return target && class_respondsToSelector(object_getClass(target), sel(name));
}

static int covers(CGRect window, CGRect screen) {
    return screen.size.width > 0 && window.origin.x <= screen.origin.x + 1 && window.origin.y <= screen.origin.y + 1
        && window.origin.x + window.size.width >= screen.origin.x + screen.size.width - 1
        && window.origin.y + window.size.height >= screen.origin.y + screen.size.height - 1;
}

static int changed_options;     /* the Dock and menu bar are hidden by this library */
static id roman_context;        /* the input context limited to Roman layouts */

static void set_options(id app, unsigned long options) {
    @try { ((void (*)(id, SEL, unsigned long))objc_msgSend)(app, sel("setPresentationOptions:"), options); }
    @catch (id ignored) { }
}

static void limit_input(id context) {
    if (context == roman_context) return;
    if (roman_context) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(roman_context, sel("setAllowedInputSourceLocales:"), nil); } @catch (id ignored) { }
        CFRelease((CFTypeRef)roman_context);
        roman_context = nil;
    }
    if (!context) return;
    id *roman = (id *)dlsym(RTLD_DEFAULT, "NSAllRomanInputSourcesLocaleIdentifier");
    Class array = objc_getClass("NSArray");
    if (!roman || !*roman || !array) return;
    @try {
        id locales = ((id (*)(id, SEL, id))objc_msgSend)((id)array, sel("arrayWithObject:"), *roman);
        ((void (*)(id, SEL, id))objc_msgSend)(context, sel("setAllowedInputSourceLocales:"), locales);
        roman_context = (id)CFRetain((CFTypeRef)context);
    } @catch (id ignored) { }
}

/* ---- See-through game windows (Cell's Windows helper lists them, see Tools/webview-bridge) ---- */

static char overlay_path[1024];
static char overlay_text[4096];
static struct timespec overlay_stamp;

static void read_overlays(void) {
    if (!overlay_path[0]) {
        const char *prefix = getenv("WINEPREFIX");
        if (!prefix) return;
        snprintf(overlay_path, sizeof(overlay_path), "%s/drive_c/windows/temp/cell-overlays.txt", prefix);
    }
    struct stat info;
    if (stat(overlay_path, &info) != 0) { overlay_text[0] = 0; return; }
    if (info.st_mtimespec.tv_sec == overlay_stamp.tv_sec && info.st_mtimespec.tv_nsec == overlay_stamp.tv_nsec) return;
    overlay_stamp = info.st_mtimespec;
    FILE *file = fopen(overlay_path, "r");
    if (!file) return;
    size_t n = fread(overlay_text, 1, sizeof(overlay_text) - 1, file);
    overlay_text[n] = 0;
    fclose(file);
}

/* -1 = not listed; 0 = see-through; 1 = see-through and clicks pass through. */
static int overlay_state(const char *title) {
    if (!title || !*title) return -1;
    size_t length = strlen(title);
    for (const char *line = overlay_text; *line; ) {
        const char *tab = strchr(line, '\t'), *end = strchr(line, '\n');
        if (!end) end = line + strlen(line);
        if (tab && tab < end && (size_t)(tab - line) == length && strncmp(line, title, length) == 0) return tab[1] == '1';
        line = *end ? end + 1 : end;
    }
    return -1;
}

static void clear_layers(id layer, int depth) {
    if (!layer || depth > 8) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(layer, sel("setOpaque:"), NO);
    ((void (*)(id, SEL, const void *))objc_msgSend)(layer, sel("setBackgroundColor:"), NULL);
    id sublayers = sendObject(layer, "sublayers");
    long count = sublayers ? ((long (*)(id, SEL))objc_msgSend)(sublayers, sel("count")) : 0;
    for (long i = 0; i < count; i++) clear_layers(((id (*)(id, SEL, long))objc_msgSend)(sublayers, sel("objectAtIndex:"), i), depth + 1);
}

static void apply_overlays(id app) {
    read_overlays();
    if (!overlay_text[0]) return;
    id windows = sendObject(app, "windows");
    long count = windows ? ((long (*)(id, SEL))objc_msgSend)(windows, sel("count")) : 0;
    for (long i = 0; i < count; i++) {
        id window = ((id (*)(id, SEL, long))objc_msgSend)(windows, sel("objectAtIndex:"), i);
        id title = sendObject(window, "title");
        const char *name = title ? ((const char *(*)(id, SEL))objc_msgSend)(title, sel("UTF8String")) : NULL;
        int state = overlay_state(name);
        if (state < 0) continue;
        if (sendBool(window, "isOpaque")) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel("setOpaque:"), NO);
            Class color = objc_getClass("NSColor");
            if (color) ((void (*)(id, SEL, id))objc_msgSend)(window, sel("setBackgroundColor:"), sendObject((id)color, "clearColor"));
            ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel("setHasShadow:"), NO);
        }
        id content = sendObject(window, "contentView");
        clear_layers(sendObject(content, "layer"), 0);
        BOOL through = state == 1;
        if (sendBool(window, "ignoresMouseEvents") != through)
            ((void (*)(id, SEL, BOOL))objc_msgSend)(window, sel("setIgnoresMouseEvents:"), through);
    }
}

/* A borderless window exactly as big as its screen belongs at the screen's origin. macOS sometimes pushes one down
 * below the menu bar (Little Nightmares: 33 points lower, its bottom cut off, the menu bar showing above it); it is
 * put back, which also lets the fullscreen handling below hide the menu bar. Games with a recorded placement bug
 * can also recover nearly screen-sized windows that started substantially outside the display. */
static void unshift_fullscreen_windows(id app) {
    Class wine = objc_getClass("WineWindow");
    const char *placement = getenv("CELL_REPOSITION_OFFSCREEN");
    int recover_offscreen = placement && !strcmp(placement, program);
    const unsigned long titled_style = 1; /* NSWindowStyleMaskTitled */
    id windows = sendObject(app, "windows");
    long count = windows ? ((long (*)(id, SEL))objc_msgSend)(windows, sel("count")) : 0;
    for (long i = 0; i < count; i++) {
        id window = ((id (*)(id, SEL, long))objc_msgSend)(windows, sel("objectAtIndex:"), i);
        if (!wine || !((BOOL (*)(id, SEL, Class))objc_msgSend)(window, sel("isKindOfClass:"), wine)) continue;
        if (!sendBool(window, "isVisible")) continue;
        unsigned long style = ((unsigned long (*)(id, SEL))objc_msgSend)(window, sel("styleMask"));
        if (style != 0 && (!recover_offscreen || (style & titled_style))) continue;
        id display = sendObject(window, "screen");
        CGRect frame = sendRect(window, "frame"), screen = sendRect(display, "frame");
        if (screen.size.width <= 0) continue;
        double drop = screen.origin.y - frame.origin.y;
        int below_menu = style == 0 && fabs(frame.size.width - screen.size.width) <= 0.5
            && fabs(frame.size.height - screen.size.height) <= 0.5 && fabs(frame.origin.x - screen.origin.x) <= 0.5
            && drop >= 0.5 && drop <= 80;
        if (below_menu) {
            frame.origin = screen.origin;
        } else if (recover_offscreen && fabs(frame.size.width - screen.size.width) <= 1
                   && frame.size.height >= screen.size.height * 0.9 && frame.size.height <= screen.size.height + 1) {
            double visible_width = fmin(frame.origin.x + frame.size.width, screen.origin.x + screen.size.width)
                - fmax(frame.origin.x, screen.origin.x);
            double visible_height = fmin(frame.origin.y + frame.size.height, screen.origin.y + screen.size.height)
                - fmax(frame.origin.y, screen.origin.y);
            if (visible_width > frame.size.width * 2 / 3 && visible_height > frame.size.height * 2 / 3) continue;
            CGRect work_area = sendRect(display, "visibleFrame");
            if (work_area.size.width < frame.size.width || work_area.size.height < frame.size.height) work_area = screen;
            frame.origin = CGPointMake(work_area.origin.x, work_area.origin.y + work_area.size.height - frame.size.height);
        } else continue;
        ((void (*)(id, SEL, CGRect, BOOL))objc_msgSend)(window, sel("setFrame:display:"), frame, YES);
    }
}

static BOOL focus_active;
static BOOL focus_pending;
static long focus_window;
static long last_focus_window;
static BOOL tried_key_restore;
static CFAbsoluteTime focus_changed_at;

static int steam_game_id(const char *id);

static int focus_recovery_enabled(void) {
    const char *enabled = getenv("CELL_FOCUS_RECOVERY"), *owner = getenv("CELL_FOCUS_RECOVERY_PROGRAM");
    if (enabled && owner && !strcasecmp(owner, program)) return !strcmp(enabled, "1");
    // Steam sets its game ID before launching titles that Cell hasn't discovered yet.
    if (!strcmp(program, "steam.exe") || !strncmp(program, "steamwebhelper", 14) ||
        !strcmp(program, "steamservice.exe") || !strncmp(program, "gameoverlayui", 13) ||
        !strncmp(program, "easteam", 7) || !strcmp(program, "eadesktop.exe") ||
        !strcmp(program, "eabackgroundservice.exe")) return 0;
    return steam_game_id(getenv("SteamAppId")) || steam_game_id(getenv("SteamGameId"));
}

static BOOL eligible_focus_window(id window) {
    Class wine = objc_getClass("WineWindow");
    return wine && window && ((BOOL (*)(id, SEL, Class))objc_msgSend)(window, sel("isKindOfClass:"), wine)
        && sendBool(window, "isVisible") && !sendBool(window, "isMiniaturized") && sendBool(window, "isOnActiveSpace")
        && !sendBool(window, "disabled") && !sendBool(window, "noForeground");
}

static void release_capture_for_switch(void) {
    Class cls = objc_getClass("WineApplicationController");
    id controller = cls ? sendObject((id)cls, "sharedController") : nil;
    if (responds(controller, "stopClippingCursor") && sendBool(controller, "clippingCursor")) {
        sendBool(controller, "stopClippingCursor");
        INPUT_TRACE("Cell released cursor clip on deactivation\n");
    }
}

/* AppKit can return to a Space without another key notification. Track both application
 * activation and the window's arrival in the active Space. Wine owns the new cursor clip. */
static void capture_focus_changed(CFNotificationCenterRef center, void *observer, CFNotificationName notification,
                                  const void *object, CFDictionaryRef info) {
    @try {
        if (CFEqual(notification, CFSTR("NSApplicationWillResignActiveNotification"))) {
            focus_active = focus_pending = NO;
            focus_window = 0;
            tried_key_restore = NO;
            release_capture_for_switch();
        } else if (CFEqual(notification, CFSTR("NSApplicationDidResignActiveNotification"))) {
            focus_active = focus_pending = NO;
            focus_window = 0;
            tried_key_restore = NO;
            release_capture_for_switch();
        } else if (!focus_active) {
            focus_active = focus_pending = YES;
            tried_key_restore = NO;
            focus_changed_at = CFAbsoluteTimeGetCurrent();
        }
    } @catch (id ignored) { }
}

static void recover_focus(id app) {
    if (!sendBool(app, "isActive")) {
        if (focus_active) release_capture_for_switch();
        focus_active = focus_pending = NO;
        focus_window = 0;
        tried_key_restore = NO;
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    id key = sendObject(app, "keyWindow");
    long number = eligible_focus_window(key) && sendBool(key, "isKeyWindow")
        ? ((long (*)(id, SEL))objc_msgSend)(key, sel("windowNumber")) : 0;
    if (!focus_active || focus_window != number) {
        focus_active = focus_pending = YES;
        focus_window = number;
        focus_changed_at = now;
    }
    if (!focus_pending || now - focus_changed_at < 0.10) return;
    const char *replay = getenv("CELL_REPLAY_MAC_FOCUS");
    if (replay && !strcmp(replay, "0")) return;  /* Older drivers translate this event into a fake menu click. */
    if (!number) {
        if (key || !last_focus_window || tried_key_restore || now - focus_changed_at < 0.25 || sendObject(app, "modalWindow")) return;
        tried_key_restore = YES;
        id previous = ((id (*)(id, SEL, long))objc_msgSend)(app, sel("windowWithWindowNumber:"), last_focus_window);
        if (eligible_focus_window(previous) && sendBool(previous, "canBecomeKeyWindow")) {
            ((void (*)(id, SEL))objc_msgSend)(previous, sel("makeKeyWindow"));
            INPUT_TRACE("Cell restored Cocoa key window=%ld\n", last_focus_window);
        }
        return;
    }
    Class cls = objc_getClass("WineApplicationController");
    if (!cls) return;
    id controller = sendObject((id)cls, "sharedController");
    if (!responds(controller, "windowGotFocus:")) return;
    focus_pending = NO;
    last_focus_window = number;
    ((void (*)(id, SEL, id))objc_msgSend)(controller, sel("windowGotFocus:"), key);
    INPUT_TRACE("Cell posted foreground restore for window=%ld\n", number);
}

static void start_game_fullscreen(id window) {
    static BOOL complete;
    static long candidate;
    static CFAbsoluteTime candidate_since;
    const char *mode = getenv("CELL_START_FULLSCREEN"), *owner = getenv("CELL_START_FULLSCREEN_PROGRAM");
    if (complete || !mode || strcmp(mode, "1") || !owner || strcasecmp(owner, program) || !eligible_focus_window(window)) return;
    unsigned long style = ((unsigned long (*)(id, SEL))objc_msgSend)(window, sel("styleMask"));
    CGRect frame = sendRect(window, "frame"), screen = sendRect(sendObject(window, "screen"), "frame");
    if ((style & (1UL << 14)) || covers(frame, screen)) { complete = YES; return; }
    unsigned long behavior = ((unsigned long (*)(id, SEL))objc_msgSend)(window, sel("collectionBehavior"));
    // Wine advertises FullScreenPrimary for resizable, top-level game windows. Leave utility windows,
    // fixed-size splash screens and owned dialogs to the program that created them.
    if (!(behavior & (1UL << 7)) || sendObject(window, "parentWindow") || sendBool(window, "isSheet")
        || frame.size.width < 320 || frame.size.height < 240) return;
    long number = ((long (*)(id, SEL))objc_msgSend)(window, sel("windowNumber"));
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (number != candidate) { candidate = number; candidate_since = now; return; }
    if (now - candidate_since < 0.75) return;
    complete = YES;
    ((void (*)(id, SEL, id))objc_msgSend)(window, sel("toggleFullScreen:"), nil);
    INPUT_TRACE("Cell requested macOS fullscreen for window=%ld\n", number);
}

static void watch_windows(CFRunLoopTimerRef timer, void *info) {
    Class application = objc_getClass("NSApplication");
    id app = application ? sendObject((id)application, "sharedApplication") : nil;
    if (!app) return;
    @try {
        if (focus_recovery_enabled()) recover_focus(app);
        if (getenv("CELL_NO_FULLSCREEN_HELP")) return;
        apply_overlays(app);
        unshift_fullscreen_windows(app);
        id key = sendBool(app, "isActive") ? sendObject(app, "keyWindow") : nil;
        start_game_fullscreen(key);
        unsigned long style = key ? ((unsigned long (*)(id, SEL))objc_msgSend)(key, sel("styleMask")) : 0;
        int fullscreen = key && sendBool(key, "isVisible") && ((style & (1UL << 14))
            || covers(sendRect(key, "frame"), sendRect(sendObject(key, "screen"), "frame")));
        unsigned long options = ((unsigned long (*)(id, SEL))objc_msgSend)(app, sel("presentationOptions"));
        if (fullscreen) {
            unsigned long wanted = (options & ~(AUTOHIDE_DOCK | AUTOHIDE_MENU_BAR)) | HIDE_DOCK | HIDE_MENU_BAR;
            if (wanted != options) { set_options(app, wanted); changed_options = 1; }
            id responder = sendObject(key, "firstResponder");
            limit_input(responds(responder, "inputContext") ? sendObject(responder, "inputContext") : nil);
        } else {
            if (changed_options) {
                set_options(app, options & ~(HIDE_DOCK | HIDE_MENU_BAR));
                changed_options = 0;
            }
            limit_input(nil);
        }
    } @catch (id ignored) { }
}

static void start_watching(void) {
    if (getenv("CELL_NO_FULLSCREEN_HELP") && !focus_recovery_enabled()) return;
    CFRunLoopTimerRef timer = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent() + 1, 0.15, 0, 0, watch_windows, NULL);
    if (timer) CFRunLoopAddTimer(CFRunLoopGetMain(), timer, kCFRunLoopCommonModes);
}

typedef CFTypeRef (*GetASN)(void);
typedef OSStatus (*SetInformationItem)(int, CFTypeRef, CFStringRef, CFTypeRef, CFDictionaryRef *);

static void rename_application(CFNotificationCenterRef center, void *observer, CFNotificationName notification,
                               const void *object, CFDictionaryRef info) {
    CFNotificationCenterRemoveEveryObserver(center, observer);
    start_watching();
    CFBundleRef services = CFBundleGetBundleWithIdentifier(CFSTR("com.apple.LaunchServices"));
    if (!services) return;
    GetASN current = (GetASN)CFBundleGetFunctionPointerForName(services, CFSTR("_LSGetCurrentApplicationASN"));
    SetInformationItem set = (SetInformationItem)CFBundleGetFunctionPointerForName(services, CFSTR("_LSSetApplicationInformationItem"));
    CFStringRef *key = (CFStringRef *)CFBundleGetDataPointerForName(services, CFSTR("_kLSDisplayNameKey"));
    if (!current || !set || !key || !*key) return;
    CFTypeRef asn = current();
    CFStringRef name = asn ? display_name() : NULL;
    if (name) {
        set(-2, asn, *key, name, NULL);   /* -2: the current session */
        CFRelease(name);
    }
}

/* ---- Per-program settings (Cell's ProgramSettings) ----
 * Runs before Wine itself starts in this process, so variables such as WINEDLLPATH_PREPEND (the graphics
 * engine's libraries) take effect for whoever started the program: Cell, Steam's window, or a launcher.
 * A program Cell started itself with everything chosen (CELL_PLANNED_PROGRAM) is left as it is. */
static void apply_program_settings(void) {
    const char *table = getenv("CELL_PROGRAM_SETTINGS");
    const char *planned = getenv("CELL_PLANNED_PROGRAM");
    if (!table || (planned && strcasecmp(planned, program) == 0)) return;
    FILE *file = fopen(table, "r");
    if (!file) return;
    static char line[16384];
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        char *field = strtok(line, "\t");
        if (!field || strcasecmp(field, program) != 0) continue;
        while ((field = strtok(NULL, "\t"))) {
            char *equals = strchr(field, '=');
            if (!equals || equals == field) continue;
            *equals = 0;
            if (!strcmp(field, "WINEDLLPATH_PREPEND") && !equals[1]) unsetenv(field);
            else setenv(field, equals + 1, 1);
        }
        break;
    }
    fclose(file);
}

/* ---- The Mac's GPU as Windows games know GPUs (Vulkan) ----
 * Windows games know AMD, NVIDIA and Intel graphics cards; an Apple GPU is "unknown" to them: Sky: Children of the
 * Light rates every GPU it doesn't know 0 and stops ("Sky does not support this Apple GPU device"). Apple's own
 * D3DMetal already shows the Mac's GPU to DirectX games as an AMD card ("AMD Compatibility Mode", 1002:66AF); Vulkan
 * games now see the same card: Wine looks up MoltenVK's functions through dlsym in win32u.so, and the device
 * properties functions it gets report AMD's vendor and device ID and an AMD driver version. The name stays the real
 * one. CELL_VULKAN_GPU=vendor:device:driver (hex) chooses other values, CELL_VULKAN_GPU=apple keeps Apple's (DXVK,
 * which has its own vendor handling, gets that). */
static uint32_t gpu_vendor = 0x1002, gpu_device = 0x66AF, gpu_driver = (2u << 22) | 302u;    /* driver 2.0.302 */

typedef void *(*proc_address_function)(void *, const char *);
typedef void (*properties_function)(void *, void *);
static proc_address_function real_instance_proc_address;
static properties_function real_properties, real_properties2, real_properties2_khr;

static void present_gpu(void *properties) {
    uint32_t *p = properties;   /* VkPhysicalDeviceProperties: apiVersion, driverVersion, vendorID, deviceID, … */
    if (p && p[2] == 0x106B) { p[1] = gpu_driver; p[2] = gpu_vendor; p[3] = gpu_device; }
}
/* VkPhysicalDeviceProperties2: sType, pNext, then the properties. */
static void cell_properties(void *device, void *properties) { real_properties(device, properties); present_gpu(properties); }
static void cell_properties2(void *device, void *properties) {
    real_properties2(device, properties);
    if (properties) present_gpu((char *)properties + 16);
}
static void cell_properties2_khr(void *device, void *properties) {
    real_properties2_khr(device, properties);
    if (properties) present_gpu((char *)properties + 16);
}
static void *cell_instance_proc_address(void *instance, const char *name);

static void *wrap_vulkan(const char *name, void *function) {
    if (!function || !name) return function;
    if (strcmp(name, "vkGetInstanceProcAddr") == 0) { real_instance_proc_address = function; return (void *)cell_instance_proc_address; }
    if (strcmp(name, "vkGetPhysicalDeviceProperties") == 0) { real_properties = function; return (void *)cell_properties; }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2") == 0) { real_properties2 = function; return (void *)cell_properties2; }
    if (strcmp(name, "vkGetPhysicalDeviceProperties2KHR") == 0) { real_properties2_khr = function; return (void *)cell_properties2_khr; }
    return function;
}
static void *cell_instance_proc_address(void *instance, const char *name) {
    return wrap_vulkan(name, real_instance_proc_address(instance, name));
}
static void *cell_dlsym(void *handle, const char *name) {
    void *function = dlsym(handle, name);
    return (name && name[0] == 'v' && name[1] == 'k') ? wrap_vulkan(name, function) : function;
}

/* Points one library's calls of dlsym at cell_dlsym (its symbol pointers, as fishhook does). */
static void rebind_import(const struct mach_header_64 *header, intptr_t slide, const char *symbol, void *replacement) {
    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysymtab = NULL;
    const struct segment_command_64 *linkedit = NULL;
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        else if (command->cmd == LC_DYSYMTAB) dysymtab = (const void *)command;
        else if (command->cmd == LC_SEGMENT_64 && strcmp(((const struct segment_command_64 *)command)->segname, SEG_LINKEDIT) == 0)
            linkedit = (const void *)command;
    }
    if (!symtab || !dysymtab || !linkedit) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    const uint32_t *indirect = (const void *)(base + dysymtab->indirectsymoff);
    command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        const struct section_64 *section = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            uint32_t type = section->flags & SECTION_TYPE;
            if (type != S_LAZY_SYMBOL_POINTERS && type != S_NON_LAZY_SYMBOL_POINTERS) continue;
            void **pointers = (void **)((uintptr_t)slide + section->addr);
            for (uint64_t k = 0; k < section->size / sizeof(void *); k++) {
                uint32_t index = indirect[section->reserved1 + k];
                if (index & (INDIRECT_SYMBOL_ABS | INDIRECT_SYMBOL_LOCAL) || index >= symtab->nsyms) continue;
                if (strcmp(strings + symbols[index].n_un.n_strx, symbol) != 0) continue;
                if (vm_protect(mach_task_self(), (vm_address_t)&pointers[k], sizeof(void *), 0,
                               VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) continue;
                pointers[k] = replacement;
            }
        }
    }
}

static void rebind_dlsym(const struct mach_header_64 *header, intptr_t slide) {
    rebind_import(header, slide, "_dlsym", (void *)cell_dlsym);
}

/* Some interleaved movies fill decodebin's automatic queues before Wine services the other stream.
 * Enable only for a demonstrated affected program. Keep explicit, bounded limits; never drop media.
 * Resolve through winegstreamer's existing dependencies, so programs without GStreamer acquire none. */
static void *(*real_gst_make)(const char *, const char *);
static void (*real_gobject_set)(void *, const char *, ...);
static unsigned media_queue_mb;
static void *cell_gst_make(const char *factory, const char *name) {
    void *element = real_gst_make(factory, name);
    if (element && factory && strcmp(factory, "decodebin") == 0)
        real_gobject_set(element, "max-size-buffers", 512u, "max-size-bytes", media_queue_mb * 1024u * 1024u,
                         "max-size-time", (uint64_t)10000000000ULL, (void *)0);
    return element;
}

static void bridge_media_queues(const struct mach_header_64 *header, intptr_t slide, const char *path) {
    const char *choice = getenv("CELL_MEDIA_QUEUE_MB");
    if (!choice) return;
    char *end = NULL;
    unsigned long mb = strtoul(choice, &end, 10);
    if (!end || *end || mb < 1 || mb > 128) return;
    void *module = dlopen(path, RTLD_LAZY | RTLD_NOLOAD);
    if (!module) return;
    real_gst_make = dlsym(module, "gst_element_factory_make");
    real_gobject_set = dlsym(module, "g_object_set");
    if (real_gst_make && real_gobject_set) {
        media_queue_mb = (unsigned)mb;
        rebind_import(header, slide, "_gst_element_factory_make", (void *)cell_gst_make);
    }
    dlclose(module);
}

/* ---- Pointer input (Unity 6 and other programs that call EnableMouseInPointer) ----
 * Windows 8+ can deliver the mouse as "pointer" messages (WM_POINTERDOWN/UP/UPDATE/WHEEL + GetPointerInfo) instead
 * of WM_LBUTTONDOWN and friends; a program asks for that once with EnableMouseInPointer(TRUE). Unity 6 does, and then
 * reads clicks and hover only from pointer messages. Wine has the function only as a stub that fails ("Call not
 * implemented"), so the pointer moved over the game but nothing could be clicked (Draw & Guess, R.E.P.O., Sweet Home).
 * Here the call succeeds, and each mouse message the program takes from its queue is first sent to the window as
 * the matching pointer message, with GetPointerInfo describing it; the mouse message itself still follows, as in
 * Proton. Wine's functions are reached through win32u's system call table (PeekMessage, GetMessage,
 * EnableMouseInPointer, IsMouseInPointerEnabled) and user32's GetPointerInfo stub is pointed at ours.
 * CELL_POINTER_INPUT=off leaves Wine's behaviour. Wine runs as x86_64 (Rosetta), so this part is x86_64 only. */
#if defined(__x86_64__)
typedef struct { uint64_t hwnd; uint32_t message, pad; uint64_t wparam; int64_t lparam; uint32_t time; int32_t x, y; uint32_t extra; } wine_message;
typedef struct {                        /* POINTER_INFO, 96 bytes */
    uint32_t type, id, frame, flags;
    uint64_t device, target;
    int32_t pixel[2], himetric[2], pixel_raw[2], himetric_raw[2];
    uint32_t time, history;
    int32_t data;
    uint32_t keys;
    uint64_t counter;
    uint32_t change, pad;
} pointer_info;
_Static_assert(sizeof(pointer_info) == 96, "POINTER_INFO is 96 bytes");

typedef int (*peek_function)(wine_message *, uint64_t, uint32_t, uint32_t, uint32_t);
typedef int (*get_function)(wine_message *, uint64_t, uint32_t, uint32_t);
typedef int64_t (*message_call_function)(uint64_t, uint32_t, uint64_t, int64_t, void *, uint32_t, int);
typedef int32_t (*protect_function)(void *, void **, size_t *, uint32_t, uint32_t *);
typedef int32_t (*counter_function)(int64_t *, int64_t *);

static peek_function real_peek;
static get_function real_get;
static message_call_function real_message_call;
static int (*real_enable_pointer)(int);
static int (*real_pointer_enabled)(void);
static volatile int pointer_mode = -1;  /* -1: not asked yet, 0: asked off, 1: on */

static uint8_t *thread_block(void) { uint8_t *teb; __asm__ volatile ("movq %%gs:0x30, %0" : "=r" (teb)); return teb; }
static void set_last_error(uint32_t code) { *(uint32_t *)(thread_block() + 0x68) = code; }

/* The last pointer frame of each Windows thread (GetPointerInfo answers from it). */
static struct { volatile uint64_t thread; pointer_info info; } frames[64];
static pointer_info *thread_frame(int create) {
    uint64_t thread = *(uint64_t *)(thread_block() + 0x48);
    for (int i = 0; i < 64; i++) if (frames[i].thread == thread) return &frames[i].info;
    if (!create) return NULL;
    for (int i = 0; i < 64; i++) if (__sync_bool_compare_and_swap(&frames[i].thread, 0, thread)) return &frames[i].info;
    frames[thread % 64].thread = thread;
    return &frames[thread % 64].info;
}

/* Runs as Windows code (user32's GetPointerInfo jumps here): no calls, only memory. */
__attribute__((ms_abi, no_builtin)) static int cell_get_pointer_info(uint32_t id, pointer_info *info) {
    pointer_info *frame = thread_frame(0);
    if (!id || !info || !frame || !frame->frame || frame->id != id) { set_last_error(87); return 0; }
    const uint64_t *from = (const uint64_t *)frame;
    uint64_t *to = (uint64_t *)info;
    for (int i = 0; i < 12; i++) to[i] = from[i];
    return 1;
}

__attribute__((ms_abi, no_builtin)) static int cell_get_pointer_type(uint32_t id, uint32_t *type) {
    pointer_info *frame = thread_frame(0);
    if (!type || !frame || !frame->frame || frame->id != id) { set_last_error(87); return 0; }
    *type = 4; /* PT_MOUSE */
    return 1;
}

__attribute__((ms_abi, no_builtin)) static int cell_get_pointer_frame(uint32_t id, uint32_t *count, pointer_info *info) {
    pointer_info *frame = thread_frame(0);
    if (!count || (!info && *count) || !frame || !frame->frame || frame->id != id) { set_last_error(87); return 0; }
    uint32_t capacity = *count;
    *count = 1;
    if (!capacity) return 1;
    return cell_get_pointer_info(id, info);
}

static uint8_t *loaded_module(const char *wanted);
static uint8_t *pe_export_depth(uint8_t *base, const char *wanted, int depth) {
    if (depth > 8) return NULL;
    if (!base || base[0] != 'M' || base[1] != 'Z') return NULL;
    uint8_t *nt = base + *(int32_t *)(base + 0x3c);
    if (memcmp(nt, "PE\0\0", 4) != 0 || *(uint16_t *)(nt + 24) != 0x20b) return NULL;
    uint32_t rva = *(uint32_t *)(nt + 24 + 112), size = *(uint32_t *)(nt + 24 + 116);
    if (!rva) return NULL;
    uint8_t *directory = base + rva;
    uint32_t count = *(uint32_t *)(directory + 24);
    uint32_t *functions = (uint32_t *)(base + *(uint32_t *)(directory + 28));
    uint32_t *names = (uint32_t *)(base + *(uint32_t *)(directory + 32));
    uint16_t *ordinals = (uint16_t *)(base + *(uint32_t *)(directory + 36));
    for (uint32_t i = 0; i < count; i++) {
        if (strcmp((const char *)base + names[i], wanted) != 0) continue;
        uint32_t function = functions[ordinals[i]];
        if (function >= rva && function < rva + size) {
            const char *forward = (const char *)base + function, *dot = strchr(forward, '.');
            if (!dot || dot - forward > 120 || dot[1] == '#') return NULL;
            char module[128];
            snprintf(module, sizeof(module), "%.*s.dll", (int)(dot-forward), forward);
            return pe_export_depth(loaded_module(module), dot+1, depth+1);
        }
        return base + function;
    }
    return NULL;
}

static uint8_t *pe_export(uint8_t *base, const char *wanted) { return pe_export_depth(base, wanted, 0); }

/* user32.dll from the process's loaded modules (PEB → loader data → in load order). */
static uint8_t *loaded_module(const char *wanted) {
    uint8_t *peb = *(uint8_t **)(thread_block() + 0x60);
    uint8_t *loader = peb ? *(uint8_t **)(peb + 0x18) : NULL;
    if (!loader) return NULL;
    uint8_t *head = loader + 0x10, *entry = *(uint8_t **)head;
    size_t length = strlen(wanted);
    for (int n = 0; entry && entry != head && n < 4096; n++, entry = *(uint8_t **)entry) {
        uint16_t bytes = *(uint16_t *)(entry + 0x58);
        const uint16_t *name = *(const uint16_t **)(entry + 0x60);
        if (!name || bytes != length * 2) continue;
        size_t k = 0;
        while (k < length && (name[k] | 0x20) == (uint16_t)(wanted[k] | 0x20)) k++;
        if (k == length) return *(uint8_t **)(entry + 0x30);
    }
    return NULL;
}

static int patch_pointer_query(const char *name, uint64_t target) {
    protect_function protect = (protect_function)dlsym(RTLD_DEFAULT, "NtProtectVirtualMemory");
    uint8_t *function = pe_export(loaded_module("user32.dll"), name);
    if (!protect || !function) { INPUT_TRACE("Cell missing query %s protect=%p function=%p\n", name, protect, function); return 0; }
    void *address = function;
    size_t size = 12;
    uint32_t old = 0;
    if (protect((void *)-1, &address, &size, 0x40 /* PAGE_EXECUTE_READWRITE */, &old) != 0) return 0;
    uint8_t code[12] = { 0x48, 0xb8 };                          /* movabs rax, target; jmp rax */
    memcpy(code + 2, &target, 8);
    code[10] = 0xff; code[11] = 0xe0;
    memcpy(function, code, sizeof(code));
    address = function; size = 12;
    protect((void *)-1, &address, &size, old, &old);
    return 1;
}

static int answer_pointer_queries(void) {
    // A game may query the type or whole frame before asking for the individual pointer.
    return patch_pointer_query("GetPointerInfo", (uint64_t)cell_get_pointer_info)
        && patch_pointer_query("GetPointerType", (uint64_t)cell_get_pointer_type)
        && (!pe_export(loaded_module("user32.dll"), "GetPointerFrameInfo")
            || patch_pointer_query("GetPointerFrameInfo", (uint64_t)cell_get_pointer_frame));
}

static int cell_enable_mouse_in_pointer(int enable) {
    INPUT_TRACE("Cell pointer enable %d, mode %d\n", enable, pointer_mode);
    if (pointer_mode >= 2) return real_enable_pointer(enable);
    if (pointer_mode >= 0) {
        if (pointer_mode == !!enable) return 1; /* repeated requests for the same state succeed */
        set_last_error(5 /* access denied */); return 0;
    }
    // New Wine versions implement this themselves. Never duplicate their pointer messages.
    if (real_enable_pointer(enable)) { pointer_mode = enable ? 3 : 2; return 1; }
    if (*(uint32_t *)(thread_block() + 0x68) != 120 /* call not implemented */) return 0;
    if (!__sync_bool_compare_and_swap(&pointer_mode, -1, enable ? 1 : 0)) return cell_enable_mouse_in_pointer(enable);
    if (enable && !answer_pointer_queries()) {
        pointer_mode = -1;
        set_last_error(0x78 /* call not implemented, as before */);
        return 0;
    }
    return 1;
}
static int cell_is_mouse_in_pointer_enabled(void) {
    return pointer_mode >= 2 ? real_pointer_enabled() : pointer_mode == 1;
}

enum { MK_L = 0x1, MK_R = 0x2, MK_SHIFT_KEY = 0x4, MK_CONTROL_KEY = 0x8, MK_M = 0x10, MK_X1 = 0x20, MK_X2 = 0x40 };

/* Sends the pointer message that matches a mouse message the program just took from its queue. */
static void send_pointer_message(const wine_message *message) {
    uint32_t keys = (uint32_t)(message->wparam & 0xffff), change = 0, kind = message->message, bit = 0;
    int down = 0, wheel = 0;
    uint16_t x_button = (uint16_t)(message->wparam >> 16);
    switch (kind) {
    case 0x200: break;                                                          /* WM_MOUSEMOVE */
    case 0x201: case 0x203: change = 1; bit = MK_L; down = 1; break;            /* left down / double click */
    case 0x202: change = 2; bit = MK_L; break;
    case 0x204: case 0x206: change = 3; bit = MK_R; down = 1; break;
    case 0x205: change = 4; bit = MK_R; break;
    case 0x207: case 0x209: change = 5; bit = MK_M; down = 1; break;
    case 0x208: change = 6; bit = MK_M; break;
    case 0x20b: case 0x20d: change = x_button == 2 ? 9 : 7; bit = x_button == 2 ? MK_X2 : MK_X1; down = 1; break;
    case 0x20c: change = x_button == 2 ? 10 : 8; bit = x_button == 2 ? MK_X2 : MK_X1; break;
    case 0x20a: wheel = 1; break;                                               /* WM_MOUSEWHEEL */
    case 0x20e: wheel = 2; break;                                               /* WM_MOUSEHWHEEL */
    default: return;
    }
    if (change) keys = down ? (keys | bit) : (keys & ~bit);
    uint32_t buttons = (keys & MK_L ? 0x10 : 0) | (keys & MK_R ? 0x20 : 0) | (keys & MK_M ? 0x40 : 0)
                     | (keys & MK_X1 ? 0x80 : 0) | (keys & MK_X2 ? 0x100 : 0);
    uint32_t flags = 0x2 /* in range */ | 0x2000 /* primary */ | buttons | (buttons ? 0x4 /* in contact */ : 0);
    uint32_t pointer_message = 0x245;                                           /* WM_POINTERUPDATE */
    int16_t delta = 0;
    if (wheel) {
        delta = (int16_t)(message->wparam >> 16);
        pointer_message = wheel == 1 ? 0x24e : 0x24f;                           /* WM_POINTERWHEEL / HWHEEL */
        flags |= wheel == 1 ? 0x80000 : 0x100000;
    } else if (change && down && !(buttons & ~(bit == MK_L ? 0x10u : bit == MK_R ? 0x20u : bit == MK_M ? 0x40u : bit == MK_X1 ? 0x80u : 0x100u))) {
        pointer_message = 0x246;                                                /* WM_POINTERDOWN: the first button */
        flags |= 0x10000;
    } else if (change && !down && !buttons) {
        pointer_message = 0x247;                                                /* WM_POINTERUP: the last button */
        flags |= 0x40000;
    } else flags |= 0x20000;

    static counter_function counter;
    static int looked;
    if (!looked) { counter = (counter_function)dlsym(RTLD_DEFAULT, "NtQueryPerformanceCounter"); looked = 1; }
    int64_t now = 0, frequency = 0;
    if (counter) counter(&now, &frequency);

    pointer_info *frame = thread_frame(1);
    uint32_t number = frame->frame + 1;
    frame->type = 4;                                                            /* PT_MOUSE */
    frame->id = 1;
    frame->frame = number ? number : 1;
    frame->flags = flags;
    frame->device = 0;
    frame->target = message->hwnd;
    frame->pixel[0] = frame->himetric[0] = frame->pixel_raw[0] = frame->himetric_raw[0] = message->x;
    frame->pixel[1] = frame->himetric[1] = frame->pixel_raw[1] = frame->himetric_raw[1] = message->y;
    frame->time = message->time;
    frame->history = 1;
    frame->data = delta;
    frame->keys = (keys & MK_SHIFT_KEY ? 0x4 : 0) | (keys & MK_CONTROL_KEY ? 0x8 : 0);
    frame->counter = (uint64_t)now;
    frame->change = change;
    uint64_t wparam = 1 | ((uint64_t)(wheel ? (uint16_t)delta : (uint16_t)(flags & 0xffff)) << 16);
    int64_t lparam = (int64_t)(uint32_t)(((uint32_t)(uint16_t)message->y << 16) | (uint16_t)message->x);
    real_message_call(message->hwnd, pointer_message, wparam, lparam, NULL, 0x2b1 /* NtUserSendMessage */, 0);
}

static int cell_peek_message(wine_message *message, uint64_t window, uint32_t first, uint32_t last, uint32_t flags) {
    int taken = real_peek(message, window, first, last, flags);
    if (taken && pointer_mode == 1 && (flags & 1 /* PM_REMOVE */) && message->message >= 0x200 && message->message <= 0x20e)
        send_pointer_message(message);
    return taken;
}
static int cell_get_message(wine_message *message, uint64_t window, uint32_t first, uint32_t last) {
    int taken = real_get(message, window, first, last);
    if (taken > 0 && pointer_mode == 1 && message->message >= 0x200 && message->message <= 0x20e) send_pointer_message(message);
    return taken;
}

/* Finds Wine's system call table in win32u.so (the array that points at the NtUser functions) and puts the four
 * wrappers in it. Any surprise leaves everything as it was. */
static void bridge_pointer_input(const struct mach_header_64 *header, intptr_t slide) {
    const char *choice = getenv("CELL_POINTER_INPUT");
    if (choice && strcasecmp(choice, "off") == 0) return;
    const struct symtab_command *symtab = NULL;
    const struct segment_command_64 *linkedit = NULL, *text = NULL;
    const struct load_command *command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd == LC_SYMTAB) symtab = (const void *)command;
        else if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const void *)command;
            if (strcmp(segment->segname, SEG_LINKEDIT) == 0) linkedit = segment;
            else if (strcmp(segment->segname, SEG_TEXT) == 0) text = segment;
        }
    }
    if (!symtab || !linkedit || !text) return;
    uintptr_t base = (uintptr_t)slide + linkedit->vmaddr - linkedit->fileoff;
    const struct nlist_64 *symbols = (const void *)(base + symtab->symoff);
    const char *strings = (const char *)(base + symtab->stroff);
    static const char *names[] = { "_NtUserEnableMouseInPointer", "_NtUserIsMouseInPointerEnabled", "_NtUserPeekMessage",
                                   "_NtUserGetMessage", "_NtUserMessageCall" };
    uintptr_t found[5] = { 0 };
    for (uint32_t i = 0; i < symtab->nsyms; i++) {
        if ((symbols[i].n_type & N_TYPE) != N_SECT || !(symbols[i].n_type & N_EXT)) continue;
        const char *name = strings + symbols[i].n_un.n_strx;
        for (int k = 0; k < 5; k++) if (!found[k] && strcmp(name, names[k]) == 0) found[k] = symbols[i].n_value + (uintptr_t)slide;
    }
    for (int k = 0; k < 5; k++) if (!found[k]) { INPUT_TRACE("Cell missing win32u symbol %s\n", names[k]); return; }
    INPUT_TRACE("Cell found pointer symbols\n");
    uintptr_t text_start = (uintptr_t)slide + text->vmaddr, text_end = text_start + text->vmsize;
    void *replacements[4] = { (void *)cell_enable_mouse_in_pointer, (void *)cell_is_mouse_in_pointer_enabled,
                              (void *)cell_peek_message, (void *)cell_get_message };
    command = (const void *)(header + 1);
    for (uint32_t i = 0; i < header->ncmds; i++, command = (const void *)((const char *)command + command->cmdsize)) {
        if (command->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *segment = (const void *)command;
        if (strcmp(segment->segname, "__DATA_CONST") != 0 && strcmp(segment->segname, SEG_DATA) != 0) continue;
        const struct section_64 *section = (const void *)(segment + 1);
        for (uint32_t s = 0; s < segment->nsects; s++, section++) {
            if ((section->flags & SECTION_TYPE) == S_ZEROFILL) continue;
            uintptr_t *slots = (uintptr_t *)((uintptr_t)slide + section->addr);
            uint64_t count = section->size / sizeof(uintptr_t);
            for (uint64_t k = 1; k + 1 < count; k++) {
                if (slots[k] != found[0]) continue;
                /* The table: a run of pointers into win32u's code around this slot. */
                uint64_t first = k, last = k;
                while (first > 0 && slots[first - 1] >= text_start && slots[first - 1] < text_end) first--;
                while (last + 1 < count && slots[last + 1] >= text_start && slots[last + 1] < text_end) last++;
                if (last - first < 100) { INPUT_TRACE("Cell short function table %llu\n", (unsigned long long)(last-first)); continue; }
                uintptr_t *where[4] = { 0 };
                for (uint64_t j = first; j <= last; j++)
                    for (int f = 0; f < 4; f++) if (slots[j] == found[f]) where[f] = &slots[j];
                if (!where[0] || !where[1] || !where[2] || !where[3]) return;
                INPUT_TRACE("Cell installing pointer bridge\n");
                real_peek = (peek_function)found[2];
                real_get = (get_function)found[3];
                real_message_call = (message_call_function)found[4];
                real_enable_pointer = (int (*)(int))found[0];
                real_pointer_enabled = (int (*)(void))found[1];
                for (int f = 0; f < 4; f++) {
                    vm_protect(mach_task_self(), (vm_address_t)where[f], sizeof(void *), 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                    *where[f] = (uintptr_t)replacements[f];
                }
                return;
            }
        }
    }
}
#endif

static void on_image(const struct mach_header *header, intptr_t slide) {
    Dl_info info;
    if (header->magic != MH_MAGIC_64 || !dladdr(header, &info) || !info.dli_fname) return;
    size_t length = strlen(info.dli_fname);
    if (length >= 17 && strcmp(info.dli_fname + length - 17, "/winegstreamer.so") == 0) {
        bridge_media_queues((const void *)header, slide, info.dli_fname);
        return;
    }
    if (length < 10 || strcmp(info.dli_fname + length - 10, "/win32u.so") != 0) return;
    INPUT_TRACE("Cell loaded win32u\n");
    if (gpu_vendor) rebind_dlsym((const void *)header, slide);
#if defined(__x86_64__)
    bridge_pointer_input((const void *)header, slide);
#endif
}

static void present_vulkan_gpu(void) {
    const char *choice = getenv("CELL_VULKAN_GPU");
    unsigned vendor, device, driver;
    if (choice && strcasecmp(choice, "apple") == 0) gpu_vendor = 0;
    else if (choice && sscanf(choice, "%x:%x:%x", &vendor, &device, &driver) == 3) { gpu_vendor = vendor; gpu_device = device; gpu_driver = driver; }
    _dyld_register_func_for_add_image(on_image);
}

/* ---- Modifier keys after switching apps ----
 * Wine's Mac driver learns about modifier keys only from events its own app receives. Holding Command (Cell maps it
 * to Ctrl) and switching to another app with it (Cmd-Tab, a shortcut) sent the key's release to the other app, so
 * Wine kept Ctrl held: the next plain click in Steam's library was a Ctrl-click and picked several games. When this
 * app stops being the active one, every Wine window is told that no modifier is held (Wine sends the key-ups) and
 * the driver's remembered "last modifier change" is replaced, so becoming active again doesn't bring them back. */
static void release_modifiers(CFNotificationCenterRef center, void *observer, CFNotificationName notification,
                              const void *object, CFDictionaryRef info) {
    Class controllerClass = objc_getClass("WineApplicationController"), windowClass = objc_getClass("WineWindow");
    Class eventClass = objc_getClass("NSEvent"), processClass = objc_getClass("NSProcessInfo");
    Class application = objc_getClass("NSApplication");
    if (!controllerClass || !windowClass || !eventClass || !processClass || !application) return;
    @try {
        id controller = sendObject((id)controllerClass, "sharedController");
        id app = sendObject((id)application, "sharedApplication");
        id windows = sendObject(app, "windows");
        if (!responds(controller, "setLastFlagsChanged:") || !windows) return;
        double now = ((double (*)(id, SEL))objc_msgSend)(sendObject((id)processClass, "processInfo"), sel("systemUptime"));
        BOOL gaining = !CFEqual(notification, CFSTR("NSApplicationDidResignActiveNotification"));
        unsigned long physical = ((unsigned long (*)(id, SEL))objc_msgSend)((id)eventClass, sel("modifierFlags"));
        unsigned long flags = gaining ? physical : (physical & (1UL << 16)); /* retain Caps Lock */
        long count = ((long (*)(id, SEL))objc_msgSend)(windows, sel("count"));
        id released = nil;
        for (long i = 0; i < count; i++) {
            id window = ((id (*)(id, SEL, long))objc_msgSend)(windows, sel("objectAtIndex:"), i);
            if (!((BOOL (*)(id, SEL, Class))objc_msgSend)(window, sel("isKindOfClass:"), windowClass)) continue;
            long number = ((long (*)(id, SEL))objc_msgSend)(window, sel("windowNumber"));
            CGPoint origin = { 0, 0 };
            id event = ((id (*)(id, SEL, unsigned long, CGPoint, unsigned long, double, long, id, id, id, BOOL, unsigned short))objc_msgSend)(
                (id)eventClass, sel("keyEventWithType:location:modifierFlags:timestamp:windowNumber:context:characters:charactersIgnoringModifiers:isARepeat:keyCode:"),
                12 /* NSEventTypeFlagsChanged */, origin, flags, now, number, nil, (id)CFSTR(""), (id)CFSTR(""), NO, 0x37);
            if (!event) continue;
            ((void (*)(id, SEL, id))objc_msgSend)(window, sel("flagsChanged:"), event);
            // The previous process can exit while holding a modifier. This window's local flags may
            // already be zero, while wineserver's shared key state is still down. Reconcile on focus.
            if (gaining && !(physical & (0xFUL << 17)) && responds(window, "postKey:pressed:modifiers:event:")) {
                static const unsigned short keys[] = { 0x38, 0x3c, 0x3b, 0x3e, 0x3a, 0x3d, 0x37, 0x36 };
                for (unsigned k = 0; k < sizeof(keys) / sizeof(keys[0]); k++)
                    ((void (*)(id, SEL, unsigned short, BOOL, unsigned long, id))objc_msgSend)(
                        window, sel("postKey:pressed:modifiers:event:"), keys[k], NO, flags, event);
            }
            released = event;
        }
        if (released) ((void (*)(id, SEL, id))objc_msgSend)(controller, sel("setLastFlagsChanged:"), released);
    } @catch (id ignored) { }
}

/* The shortcut lives in another process: even a blocked Cocoa event loop cannot swallow Command-Q.
 * Do not let a game bootstrap's inherited variables turn Steam or its browser into a force-quit target. */
static int steam_game_id(const char *id) {
    if (!id || *id < '1' || *id > '9') return 0;
    char *end;
    unsigned long value = strtoul(id, &end, 10);
    return !*end && value <= 0xffffff; /* regular Steam AppID, not an encoded shortcut or mod */
}

static int steam_program_path(char resolved[PATH_MAX]) {
    const char *prefix = getenv("WINEPREFIX");
    const char *path = program_path;
    if (!path) return 0;
    char mapped[PATH_MAX];
    if (prefix && path[0] && path[1] == ':' && (path[2] == '\\' || path[2] == '/')) {
        char drive = path[0] >= 'A' && path[0] <= 'Z' ? path[0] + ('a' - 'A') : path[0];
        if (drive < 'a' || drive > 'z') return 0;
        int size = snprintf(mapped, sizeof(mapped), "%s/dosdevices/%c:/%s", prefix, drive, path + 3);
        if (size < 0 || size >= (int)sizeof(mapped)) return 0;
        for (char *p = mapped + strlen(prefix); *p; p++) if (*p == '\\') *p = '/';
        path = mapped;
    }
    return realpath(path, resolved) != NULL;
}

static void route_steam_compatibility_launch(void) {
    const char *runtime = getenv("CELL_WINE_ENGINE_ID");
    const char *path = getenv("CELL_STEAM_COMPAT_ROUTES"), *helper = getenv("CELL_STEAM_COMPAT_HELPER");
    const char *prefix = getenv("WINEPREFIX");
    const char *game = getenv("SteamAppId");
    if (!steam_game_id(game)) game = getenv("SteamGameId");
    if (!steam_game_id(game)) game = NULL;
    char old_engine[PATH_MAX], old_path[PATH_MAX], old_helper[PATH_MAX], resolved[PATH_MAX];
    if (!runtime) {
        // Steam might have started before the new Cell build. Its child uses the same loader path.
        uint32_t size = sizeof(old_engine);
        if (_NSGetExecutablePath(old_engine, &size)) return;
        char *id = strstr(old_engine, "/Runtimes/");
        if (!id) return;
        id += strlen("/Runtimes/");
        char *end = strchr(id, '/');
        if (!end) return;
        *end = 0;
        runtime = id;
    }
    if (!path && prefix) {
        size_t size = strlen(prefix);
        if (size < 7 || strcmp(prefix + size - 7, "/prefix") || size >= PATH_MAX - 26) return;
        snprintf(old_path, sizeof(old_path), "%.*s/steam-compatibility.tsv", (int)(size - 7), prefix);
        path = old_path;
    }
    if (!path || (!game && !steam_program_path(resolved))) return;

    char app[37] = {0}, line[PATH_MAX + 512], matched_game[16], minimum[24] = {0};
    FILE *file = fopen(path, "r");
    if (!file) return;
    while (fgets(line, sizeof(line), file)) {
        line[strcspn(line, "\r\n")] = 0;
        if (line[0] == '#') {
            if (strlen(line + 1) < sizeof(old_helper)) { strcpy(old_helper, line + 1); helper = old_helper; }
            continue;
        }
        char *save, *engine = strtok_r(line, "\t", &save), *id = strtok_r(NULL, "\t", &save);
        char *name = strtok_r(NULL, "\t", &save), *uuid = strtok_r(NULL, "\t", &save), *folder = strtok_r(NULL, "\t", &save);
        char *version = strtok_r(NULL, "\t", &save);
        if (!engine || !steam_game_id(id) || !name || !uuid || strcmp(engine, runtime) || strcmp(name, program)) continue;
        if (game ? strcmp(game, id) : !folder || strncasecmp(resolved, folder, strlen(folder)) || resolved[strlen(folder)] != '/') continue;
        if (strlen(uuid) != 36 || strspn(uuid, "0123456789abcdefABCDEF-") != 36) continue;
        memcpy(app, uuid, 36);
        if (version && strlen(version) < sizeof(minimum) && strspn(version, "0123456789.") == strlen(version)) strcpy(minimum, version);
        snprintf(matched_game, sizeof(matched_game), "%s", id);
        break;
    }
    fclose(file);
    if (!app[0] || !helper || helper[0] != '/') return;

    char *args[] = {(char *)helper, "launch", "--app", app, "--from-steam-compatibility", NULL, NULL, NULL};
    if (minimum[0]) { args[5] = "--require-wine"; args[6] = minimum; }
    /* The host launcher needs the same Cell library location and no Wine-specific injection. */
    char *home = NULL;
    const char *custom = getenv("CELL_HOME"), *legacy = getenv("CHAMBER_HOME");
    if (custom && *custom) asprintf(&home, "CELL_HOME=%s", custom);
    else if (legacy && *legacy) asprintf(&home, "CHAMBER_HOME=%s", legacy);
    char resources[PATH_MAX + 40];
    const char *helpers_dir = strstr(helper, "/Contents/Helpers/cell");
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL, NULL, NULL};
    size_t used = 1;
    if (home) env[used++] = home;
    if (helpers_dir && !strcmp(helpers_dir, "/Contents/Helpers/cell")) {
        snprintf(resources, sizeof(resources), "CELL_PACKAGED_RESOURCES=%.*s/Contents/Resources", (int)(helpers_dir - helper), helper);
        env[used++] = resources;
    }
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t files;
    posix_spawnattr_init(&attr);
    posix_spawn_file_actions_init(&files);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_addinherit_np(&files, STDOUT_FILENO);
    posix_spawn_file_actions_addinherit_np(&files, STDERR_FILENO);
    pid_t host;
    int result = posix_spawn(&host, helper, &files, &attr, args, env);
    posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attr);
    free(home);
    if (!result) {
        fprintf(stderr, "Cell: rerouted Steam game %s to its compatibility engine\n", matched_game);
        _exit(0);
    }
}

static void start_game_hotkey(void) {
    static int started;
    if (started) return;
    const char *steam_helpers[] = { "steam.exe", "steamwebhelper.exe", "steamwebhelper_real.exe", "steamservice.exe",
                                   "gameoverlayui.exe", "gameoverlayui64.exe", "eadesktop.exe", "easteamlauncher.exe",
                                   "easteamauthhelper.exe", "eabackgroundservice.exe", NULL };
    for (int i = 0; steam_helpers[i]; i++) if (!strcmp(program, steam_helpers[i])) return;
    const char *mode = getenv("CELL_GAME_FORCE_QUIT"), *owner = getenv("CELL_GAME_FORCE_QUIT_PROGRAM");
    int game = 0;
    if (mode && owner && !strcasecmp(owner, program)) game = !strcmp(mode, "1");
    else {
        // Steam supplies this even for games installed after Cell last refreshed its library.
        game = steam_game_id(getenv("SteamAppId")) || steam_game_id(getenv("SteamGameId"));
    }
    const char *helper = getenv("CELL_GAME_HOTKEY_HELPER"), *requests = getenv("CELL_GAME_QUIT_REQUESTS");
    char helper_path[2048], requests_path[2048];
    // A Steam client already running before an update has the older environment. Its new children still
    // load this library from Support, where the companion is installed beside it.
    Dl_info library;
    if ((!helper || !requests) && dladdr((const void *)start_game_hotkey, &library) && library.dli_fname) {
        const char *slash = strrchr(library.dli_fname, '/');
        size_t directory = slash ? (size_t)(slash - library.dli_fname) : 0;
        if (directory && directory + 32 < sizeof(helper_path)) {
            snprintf(helper_path, sizeof(helper_path), "%.*s/cell-game-hotkey", (int)directory, library.dli_fname);
            snprintf(requests_path, sizeof(requests_path), "%.*s/ForceQuitRequests", (int)directory, library.dli_fname);
            if (!helper) helper = helper_path;
            if (!requests) requests = requests_path;
        }
    }
    if (!game || !helper || !requests || access(helper, X_OK)) return;
    started = 1;
    char pid[32]; snprintf(pid, sizeof(pid), "%d", getpid());
    char *arguments[] = { (char *)helper, pid, (char *)requests, NULL };
    char **current = *_NSGetEnviron(); size_t count = 0;
    while (current[count]) count++;
    char **environment = calloc(count + 1, sizeof(char *));
    if (!environment) return;
    size_t used = 0;
    for (size_t i = 0; i < count; i++) if (strncmp(current[i], "DYLD_", 5)) environment[used++] = current[i];
    posix_spawnattr_t attributes; posix_spawn_file_actions_t files;
    posix_spawnattr_init(&attributes); posix_spawn_file_actions_init(&files);
    // A companion must not keep Wine's private sockets open after the game dies.
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    posix_spawn_file_actions_addinherit_np(&files, STDOUT_FILENO);
    posix_spawn_file_actions_addinherit_np(&files, STDERR_FILENO);
    pid_t child;
    int error = posix_spawn(&child, helper, &files, &attributes, arguments, environment);
    if (error) fprintf(stderr, "Cell: unable to start game shortcut (%d)\n", error);
    posix_spawn_file_actions_destroy(&files); posix_spawnattr_destroy(&attributes); free(environment);
}

typedef void (*post_key_function)(id, SEL, unsigned short, BOOL, unsigned long, id);
static post_key_function original_post_key;
static unsigned short mapped_keys[128];

static void post_mapped_key(id window, SEL selector, unsigned short code, BOOL pressed, unsigned long flags, id event) {
    if (code < 128 && mapped_keys[code]) code = mapped_keys[code] - 1;
    original_post_key(window, selector, code, pressed, flags, event);
}

static void install_key_map(void) {
    const char *map = getenv("CELL_KEY_MAP"), *owner = getenv("CELL_KEY_MAP_PROGRAM");
    if (!map || !*map || !owner || strcasecmp(owner, program) || original_post_key) return;
    while (*map) {
        unsigned from, to;
        int consumed = 0;
        if (sscanf(map, "%u:%u%n", &from, &to, &consumed) != 2 || from >= 128 || to >= 128) return;
        mapped_keys[from] = to + 1;
        map += consumed;
        if (!*map) break;
        if (*map++ != ',') return;
    }
    Class window = objc_getClass("WineWindow");
    Method method = window ? class_getInstanceMethod(window, sel("postKey:pressed:modifiers:event:")) : NULL;
    if (!method) return;
    original_post_key = (post_key_function)method_getImplementation(method);
    method_setImplementation(method, (IMP)post_mapped_key);
}

static void cocoa_started(CFNotificationCenterRef center, void *observer, CFNotificationName notification,
                          const void *object, CFDictionaryRef info) {
    rename_application(center, observer, notification, object, info);
    install_key_map();
    start_game_hotkey();
    static int resign_observer;
    CFNotificationCenterAddObserver(center, &resign_observer, release_modifiers, CFSTR("NSApplicationDidResignActiveNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &resign_observer, release_modifiers, CFSTR("NSApplicationDidBecomeActiveNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, &resign_observer, release_modifiers, CFSTR("NSWindowDidBecomeKeyNotification"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    if (focus_recovery_enabled()) {
        const CFStringRef notifications[] = { CFSTR("NSApplicationWillResignActiveNotification"),
            CFSTR("NSApplicationDidResignActiveNotification"), CFSTR("NSApplicationDidBecomeActiveNotification") };
        for (unsigned i = 0; i < sizeof(notifications) / sizeof(notifications[0]); i++)
            CFNotificationCenterAddObserver(center, &resign_observer, capture_focus_changed, notifications[i],
                                            NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}

/* ---- The program's own name for the process (Activity Monitor, ps, top) ----
 * macOS names a process after the file it was started from, so every Windows program was "wine64". Before Wine
 * starts, the process starts itself again from a hard link of the Wine loader named after the program ("Steam",
 * "Left 4 Dead 2", "winedevice"), in the loader's own folder so Wine finds its libraries as before. Same file, same
 * arguments, environment and open files; a child Wine starts from such a link is renamed the same way.
 * CELL_PROCESS_NAMES=off keeps "wine64". */
static void utf8_truncate(char *text, size_t limit) {
    size_t length = strlen(text);
    if (length <= limit) return;
    length = limit;
    while (length > 0 && ((unsigned char)text[length] & 0xC0) == 0x80) length--;   /* don't cut a character */
    text[length] = 0;
}

static int process_title(char *out, size_t size, int listed) {
    out[0] = 0;
    if (listed) {
        CFStringRef name = display_name();
        if (name) { CFStringGetCString(name, out, (CFIndex)size, kCFStringEncodingUTF8); CFRelease(name); }
    } else {
        int argc = *_NSGetArgc();
        char **argv = *_NSGetArgv();
        for (int i = 1; i < argc && i < 8 && !out[0]; i++) {
            const char *arg = argv[i], *base = arg;
            size_t length = arg ? strlen(arg) : 0;
            if (length < 5 || strcasecmp(arg + length - 4, ".exe") != 0) continue;
            for (const char *p = arg; *p; p++) if (*p == '\\' || *p == '/') base = p + 1;
            snprintf(out, size, "%.*s", (int)(strlen(base) - 4), base);
        }
    }
    for (char *p = out; *p; p++) if (*p == '/' || *p == ':' || *p == '\n') *p = '-';
    if (out[0] == '.') out[0] = '_';
    utf8_truncate(out, 32);         /* the kernel keeps 32 bytes */
    return out[0] && strcmp(out, "wine") != 0 && strcmp(out, "wine64") != 0 && strcmp(out, "wineserver") != 0
        && strncmp(out, "wine-", 5) != 0 && strncmp(out, "wine64-", 7) != 0;
}

static void use_own_process_name(int listed) {
    const char *choice = getenv("CELL_PROCESS_NAMES");
    if (choice && strcasecmp(choice, "off") == 0) return;
    char executable[1024], loader[1100], named[1200], temporary[1200], title[256];
    uint32_t size = sizeof(executable);
    if (_NSGetExecutablePath(executable, &size) != 0) return;
    char *slash = strrchr(executable, '/');
    if (!slash || !process_title(title, sizeof(title), listed)) return;
    if (strcmp(slash + 1, title) == 0) return;                                   /* already named */
    struct stat self, wine;
    if (stat(executable, &self) != 0) return;
    *slash = 0;
    snprintf(loader, sizeof(loader), "%s/wine64", executable);
    if (stat(loader, &wine) != 0 || wine.st_ino != self.st_ino || wine.st_dev != self.st_dev) {
        snprintf(loader, sizeof(loader), "%s/wine", executable);
        if (stat(loader, &wine) != 0 || wine.st_ino != self.st_ino || wine.st_dev != self.st_dev) return;   /* not Wine's loader */
    }
    snprintf(named, sizeof(named), "%s/%s", executable, title);
    struct stat existing;
    if (stat(named, &existing) == 0) {
        if (existing.st_ino != self.st_ino || existing.st_dev != self.st_dev) return;   /* some other file has the name */
    } else {
        snprintf(temporary, sizeof(temporary), "%s/.cell-name-%d", executable, getpid());
        unlink(temporary);
        if (link(loader, temporary) != 0) return;                               /* read-only engine: keep the name */
        if (rename(temporary, named) != 0) { unlink(temporary); return; }
        if (stat(named, &existing) != 0 || existing.st_ino != self.st_ino) return;
    }
    execve(named, *_NSGetArgv(), *_NSGetEnviron());                             /* returns only if it failed */
}

__attribute__((constructor)) static void start(void) {
    int listed = find_program();
    use_own_process_name(listed);
    if (!listed) return;
    route_steam_compatibility_launch();
    prepare_paradox_launcher();
    apply_program_settings();
    prepare_sims_fullscreen();
    present_vulkan_gpu();
    static int observer;
    CFNotificationCenterAddObserver(CFNotificationCenterGetLocalCenter(), &observer, cocoa_started,
                                    CFSTR("NSApplicationWillFinishLaunchingNotification"), NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}
