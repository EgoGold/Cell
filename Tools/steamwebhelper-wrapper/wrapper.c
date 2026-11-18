/*
 * Cell's steamwebhelper.exe launcher.
 *
 * Steam ignores most of its -cef-* options, so it can't be told to draw its web UI inside the browser
 * process. Under Wine on macOS that is what keeps the window from staying black or blank: Chromium's
 * GPU path only gets OpenGL ES 2.0 through ANGLE, falls back to software drawing, and a separate GPU
 * process can't draw into another process's window there.
 *
 * Cell renames Valve's steamwebhelper.exe to steamwebhelper_real.exe and puts this program in its
 * place. It starts the real one with the same command line plus extra Chromium switches: the value of
 * CELL_WEBHELPER_FLAGS, or "--in-process-gpu --disable-gpu" (what CrossOver passes). It waits and
 * returns the real exit code. No C runtime: kernel32 only, so it is a few kilobytes.
 *
 * Quitting from the Dock: on macOS the web helper owns Steam's windows, so "Quit" in the Dock ends the
 * web helper only, and Steam immediately starts a new one ("Steam comes back"). When the real web helper
 * ends normally after running a while but Steam is still alive a few seconds later, the user quit it:
 * the launcher then asks Steam to quit as well (steam.exe -shutdown, like Steam ▸ Exit).
 *
 * Closing the window: Steam's close button only hides its window (on Windows it lives on in the taskbar's
 * tray), which on a Mac looks like Steam won't quit. While the real web helper runs, the launcher looks at
 * Steam's windows every two seconds. Once the main "Steam" window was open and every Steam window has been
 * closed for eight seconds, no game runs (RunningAppID) and nothing downloads (Apps\<id>\Updating), it asks
 * Steam to quit the same way. Minimized windows still count as open.
 *
 * Build: python3 Tools/steamwebhelper-wrapper/build.py  (needs only Xcode's clang)
 */
typedef __WCHAR_TYPE__ wchar;
typedef int BOOL;
typedef unsigned long DWORD;
typedef void *HANDLE;

typedef struct {
    DWORD cb; wchar *lpReserved; wchar *lpDesktop; wchar *lpTitle;
    DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
    unsigned short wShowWindow, cbReserved2; unsigned char *lpReserved2;
    HANDLE hStdInput, hStdOutput, hStdError;
} STARTUPINFOW;

typedef struct { HANDLE hProcess, hThread; DWORD dwProcessId, dwThreadId; } PROCESS_INFORMATION;

__declspec(dllimport) DWORD GetModuleFileNameW(HANDLE module, wchar *buffer, DWORD size);
__declspec(dllimport) wchar *GetCommandLineW(void);
__declspec(dllimport) DWORD GetEnvironmentVariableW(const wchar *name, wchar *buffer, DWORD size);
__declspec(dllimport) void GetStartupInfoW(STARTUPINFOW *info);
__declspec(dllimport) BOOL CreateProcessW(const wchar *application, wchar *commandLine, void *processAttributes,
                                          void *threadAttributes, BOOL inheritHandles, DWORD flags, void *environment,
                                          const wchar *directory, STARTUPINFOW *startup, PROCESS_INFORMATION *info);
__declspec(dllimport) DWORD WaitForSingleObject(HANDLE handle, DWORD milliseconds);
__declspec(dllimport) BOOL GetExitCodeProcess(HANDLE process, DWORD *code);
__declspec(dllimport) void ExitProcess(unsigned code);
__declspec(dllimport) HANDLE OpenProcess(DWORD access, BOOL inherit, DWORD pid);
__declspec(dllimport) BOOL CloseHandle(HANDLE handle);
__declspec(dllimport) unsigned long long GetTickCount64(void);
__declspec(dllimport) HANDLE LoadLibraryW(const wchar *name);
__declspec(dllimport) void *GetProcAddress(HANDLE module, const char *name);

#define SYNCHRONIZE_ACCESS 0x00100000
#define WAIT_TIMEOUT_RESULT 0x102

#define PATH_CAPACITY 2048
#define COMMAND_CAPACITY 32768
#define FLAGS_CAPACITY 4096

static wchar path[PATH_CAPACITY];
static wchar command[COMMAND_CAPACITY];
static wchar flags[FLAGS_CAPACITY];
static wchar steam_path[PATH_CAPACITY];
static wchar shutdown_command[PATH_CAPACITY + 32];
static STARTUPINFOW steam_startup;
static PROCESS_INFORMATION steam_process;
static STARTUPINFOW startup;
static PROCESS_INFORMATION process;

/* Copies `source` to `destination` (never past `last`), returns the new end. */
static wchar *append(wchar *destination, const wchar *source, wchar *last) {
    while (*source && destination < last) *destination++ = *source++;
    *destination = 0;
    return destination;
}

/* Finds `name` (e.g. L"-steampid=") in `text`; returns what follows it, or 0. */
static const wchar *find(const wchar *text, const wchar *name) {
    for (; *text; text++) {
        const wchar *a = text, *b = name;
        while (*b && *a == *b) { a++; b++; }
        if (!*b) return a;
    }
    return 0;
}

static DWORD steam_pid;

/* Steam's -steampid=<n> and -steampath="<path>" from our command line. */
static int read_steam(const wchar *line) {
    const wchar *pid_text = find(line, L"-steampid=");
    const wchar *path_text = find(line, L"-steampath=");
    if (!pid_text || !path_text) return 0;
    DWORD pid = 0;
    while (*pid_text >= '0' && *pid_text <= '9') pid = pid * 10 + (DWORD)(*pid_text++ - '0');
    if (!pid) return 0;
    wchar end = ' ';
    if (*path_text == '"') { end = '"'; path_text++; }
    int length = 0;
    while (path_text[length] && path_text[length] != end && length < PATH_CAPACITY - 1) { steam_path[length] = path_text[length]; length++; }
    steam_path[length] = 0;
    if (length < 5) return 0;
    steam_pid = pid;
    return 1;
}

/* Asks Steam to quit like Steam ▸ Exit (it saves and doesn't come back). */
static void request_steam_shutdown(void) {
    wchar *last = shutdown_command + PATH_CAPACITY + 31;
    wchar *cursor = append(shutdown_command, L"\"", last);
    cursor = append(cursor, steam_path, last);
    append(cursor, L"\" -shutdown", last);
    steam_startup.cb = sizeof(steam_startup);
    if (CreateProcessW(steam_path, shutdown_command, 0, 0, 0, 0, 0, 0, &steam_startup, &steam_process)) {
        WaitForSingleObject(steam_process.hProcess, 15000);
        CloseHandle(steam_process.hProcess);
        CloseHandle(steam_process.hThread);
    }
}

/* Is Steam still running a few seconds after its web helper quit normally? Then the user quit it. */
static void quit_steam_if_user_quit(void) {
    HANDLE steam = OpenProcess(SYNCHRONIZE_ACCESS, 0, steam_pid);
    if (!steam) return;
    DWORD alive = WaitForSingleObject(steam, 4000);
    CloseHandle(steam);
    if (alive != WAIT_TIMEOUT_RESULT) return;          /* Steam is quitting itself: nothing to do. */
    request_steam_shutdown();
}

/* Window and registry functions, loaded only when needed (the launcher imports kernel32 alone). */
typedef BOOL (*EnumWindows_t)(BOOL (*)(HANDLE, long long), long long);
typedef DWORD (*GetWindowThreadProcessId_t)(HANDLE, DWORD *);
typedef BOOL (*IsWindowVisible_t)(HANDLE);
typedef HANDLE (*GetWindow_t)(HANDLE, unsigned);
typedef int (*InternalGetWindowText_t)(HANDLE, wchar *, int);
typedef long (*RegOpenKeyExW_t)(HANDLE, const wchar *, DWORD, DWORD, HANDLE *);
typedef long (*RegEnumKeyExW_t)(HANDLE, DWORD, wchar *, DWORD *, DWORD *, wchar *, DWORD *, void *);
typedef long (*RegGetValueW_t)(HANDLE, const wchar *, const wchar *, DWORD, DWORD *, void *, DWORD *);
typedef long (*RegCloseKey_t)(HANDLE);
static EnumWindows_t enum_windows;
static GetWindowThreadProcessId_t window_process;
static IsWindowVisible_t is_visible;
static GetWindow_t get_window;
static InternalGetWindowText_t window_text;
static RegOpenKeyExW_t open_key;
static RegEnumKeyExW_t enum_key;
static RegGetValueW_t get_value;
static RegCloseKey_t close_key;
#define CURRENT_USER ((HANDLE)(long long)(int)0x80000001)
#define READ_ACCESS 0x20019
#define DWORD_TYPE 0x10

static int load_functions(void) {
    HANDLE user = LoadLibraryW(L"user32.dll"), registry = LoadLibraryW(L"advapi32.dll");
    if (!user || !registry) return 0;
    enum_windows = (EnumWindows_t)GetProcAddress(user, "EnumWindows");
    window_process = (GetWindowThreadProcessId_t)GetProcAddress(user, "GetWindowThreadProcessId");
    is_visible = (IsWindowVisible_t)GetProcAddress(user, "IsWindowVisible");
    get_window = (GetWindow_t)GetProcAddress(user, "GetWindow");
    window_text = (InternalGetWindowText_t)GetProcAddress(user, "InternalGetWindowText");
    open_key = (RegOpenKeyExW_t)GetProcAddress(registry, "RegOpenKeyExW");
    enum_key = (RegEnumKeyExW_t)GetProcAddress(registry, "RegEnumKeyExW");
    get_value = (RegGetValueW_t)GetProcAddress(registry, "RegGetValueW");
    close_key = (RegCloseKey_t)GetProcAddress(registry, "RegCloseKey");
    return enum_windows && window_process && is_visible && get_window && window_text && open_key && enum_key && get_value && close_key;
}

static DWORD helper_pid;
static int open_windows, main_window_open;

/* Counts Steam's visible top-level windows (Steam's own and its web helper's); minimized ones count too. */
static BOOL count_window(HANDLE window, long long unused) {
    DWORD pid = 0;
    window_process(window, &pid);
    if ((pid != helper_pid && pid != steam_pid) || !is_visible(window) || get_window(window, 4 /* GW_OWNER */)) return 1;
    wchar title[16];
    int length = window_text(window, title, 16);
    if (length <= 0) return 1;                        /* untitled helper windows */
    open_windows++;
    if (length == 5 && title[0] == 'S' && title[1] == 't' && title[2] == 'e' && title[3] == 'a' && title[4] == 'm') main_window_open = 1;
    return 1;
}

static DWORD steam_value(const wchar *key, const wchar *name) {
    DWORD value = 0, size = sizeof(value);
    if (get_value(CURRENT_USER, key, name, DWORD_TYPE, 0, &value, &size) != 0) return 0;
    return value;
}

/* A game runs, or Steam is downloading or updating something. */
static int steam_busy(void) {
    if (steam_value(L"Software\\Valve\\Steam", L"RunningAppID")) return 1;
    HANDLE apps = 0;
    if (open_key(CURRENT_USER, L"Software\\Valve\\Steam\\Apps", 0, READ_ACCESS, &apps) != 0) return 0;
    int busy = 0;
    wchar name[64], key[128];
    for (DWORD index = 0; !busy && index < 100000; index++) {
        DWORD length = 64;
        if (enum_key(apps, index, name, &length, 0, 0, 0, 0) != 0) break;
        wchar *end = append(key, L"Software\\Valve\\Steam\\Apps\\", key + 127);
        append(end, name, key + 127);
        if (steam_value(key, L"Updating")) busy = 1;
    }
    close_key(apps);
    return busy;
}

/* Waits for the real web helper; asks Steam to quit once its window was closed and nothing needs it. */
static void watch_windows(HANDLE helper) {
    int watching = steam_pid && load_functions();
    int seen_main_window = 0;
    unsigned long long closed_since = 0;
    for (;;) {
        if (WaitForSingleObject(helper, 2000) != WAIT_TIMEOUT_RESULT) return;
        if (!watching) continue;
        open_windows = 0;
        main_window_open = 0;
        enum_windows(count_window, 0);
        if (main_window_open) seen_main_window = 1;
        if (!seen_main_window || open_windows) { closed_since = 0; continue; }
        if (!closed_since) { closed_since = GetTickCount64(); continue; }
        if (GetTickCount64() - closed_since < 8000) continue;
        if (steam_busy()) { closed_since = GetTickCount64(); continue; }
        request_steam_shutdown();
        watching = 0;
    }
}

void start(void) {
    DWORD length = GetModuleFileNameW(0, path, PATH_CAPACITY);
    if (length < 5 || length > PATH_CAPACITY - 16) ExitProcess(87);
    /* ...\steamwebhelper.exe -> ...\steamwebhelper_real.exe */
    append(path + length - 4, L"_real.exe", path + PATH_CAPACITY - 1);

    wchar *last = command + COMMAND_CAPACITY - 1;
    const wchar *original = GetCommandLineW();
    wchar *end = append(command, original, last);
    DWORD custom = GetEnvironmentVariableW(L"CELL_WEBHELPER_FLAGS", flags, FLAGS_CAPACITY);
    end = append(end, L" ", last);
    append(end, custom > 0 && custom < FLAGS_CAPACITY ? flags : L"--in-process-gpu --disable-gpu", last);

    GetStartupInfoW(&startup);
    startup.cb = sizeof(startup);
    if (!CreateProcessW(path, command, 0, 0, 1, 0, 0, 0, &startup, &process)) ExitProcess(2);
    unsigned long long started = GetTickCount64();
    int knows_steam = read_steam(original);
    helper_pid = process.dwProcessId;
    watch_windows(process.hProcess);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    /* Crashes (non-zero) are left to Steam, which restarts its web helper; so are quick restarts. */
    if (knows_steam && code == 0 && GetTickCount64() - started > 15000) quit_steam_if_user_quit();
    ExitProcess(code);
}
