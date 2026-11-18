/*
 * Cell's web view bridge, also the layer's window helper: games whose window is as big as the screen are fitted to
 * it without a title bar (fit_to_screen).
 *
 * Microsoft Edge WebView2 (the web view inside Tauri apps, the new Epic Games Launcher and many other newer
 * programs) puts the page in a window that belongs to its own process (msedgewebview2.exe), placed inside the
 * app's window. On Windows any process may own a window inside another's. Wine's Mac driver can't show that:
 * each Mac window belongs to one process, so the page is drawn nowhere and the app shows an empty panel.
 *
 * This small program runs beside the Windows programs of a layer. Every quarter second it looks for a
 * Chromium window ("Chrome_WidgetWin_1") whose parent belongs to another process, lifts it out into a window
 * of its own (which the Mac driver can show) owned by the app's window, and from then on keeps it exactly
 * over the place it belongs: it follows the app's window when that moves or changes size, hides with it, and
 * comes to the front with it. Mouse and keyboard go to the page as before. It quits when no other program is
 * left in the layer. One copy per layer (a named mutex). No C runtime: kernel32 only, a few kilobytes.
 *
 * Build: python3 -I Tools/webview-bridge/build.py   (needs only Xcode's clang)
 */
typedef __WCHAR_TYPE__ wchar;
typedef int BOOL; typedef unsigned long DWORD; typedef void *HANDLE; typedef long long LPARAM;
typedef struct { long left, top, right, bottom; } RECT; typedef struct { long x, y; } POINT;
typedef struct { DWORD dwSize, cntUsage, th32ProcessID; unsigned long long th32DefaultHeapID; DWORD th32ModuleID, cntThreads,
                 th32ParentProcessID; long pcPriClassBase; DWORD dwFlags; wchar szExeFile[260]; } PROCESSENTRY32W;
__declspec(dllimport) void ExitProcess(unsigned code);
__declspec(dllimport) HANDLE LoadLibraryW(const wchar *name);
__declspec(dllimport) void *GetProcAddress(HANDLE module, const char *name);
__declspec(dllimport) void Sleep(DWORD ms);
__declspec(dllimport) HANDLE CreateMutexW(void *attributes, BOOL owner, const wchar *name);
__declspec(dllimport) DWORD GetLastError(void);
__declspec(dllimport) DWORD GetCurrentProcessId(void);
__declspec(dllimport) HANDLE CreateToolhelp32Snapshot(DWORD flags, DWORD pid);
__declspec(dllimport) BOOL Process32FirstW(HANDLE snapshot, PROCESSENTRY32W *entry);
__declspec(dllimport) BOOL Process32NextW(HANDLE snapshot, PROCESSENTRY32W *entry);
__declspec(dllimport) BOOL CloseHandle(HANDLE handle);
__declspec(dllimport) unsigned long long GetTickCount64(void);
int _fltused = 0;

static BOOL (*EnumWindows)(BOOL (*)(HANDLE, LPARAM), LPARAM);
static BOOL (*EnumChildWindows)(HANDLE, BOOL (*)(HANDLE, LPARAM), LPARAM);
static DWORD (*GetWindowThreadProcessId)(HANDLE, DWORD *);
static int (*GetClassNameW)(HANDLE, wchar *, int);
static HANDLE (*SetParent)(HANDLE, HANDLE);
static HANDLE (*GetParent)(HANDLE);
static HANDLE (*GetAncestor)(HANDLE, unsigned);
static HANDLE (*GetForegroundWindow)(void);
static BOOL (*SetForegroundWindow)(HANDLE);
static long long (*GetWindowLongPtrW)(HANDLE, int);
static long long (*SetWindowLongPtrW)(HANDLE, int, long long);
static BOOL (*SetWindowPos)(HANDLE, HANDLE, int, int, int, int, unsigned);
static BOOL (*GetClientRect)(HANDLE, RECT *);
static BOOL (*GetWindowRect)(HANDLE, RECT *);
static BOOL (*ClientToScreen)(HANDLE, POINT *);
static BOOL (*IsWindow)(HANDLE);
static BOOL (*IsWindowVisible)(HANDLE);
static BOOL (*IsIconic)(HANDLE);
static BOOL (*ShowWindow)(HANDLE, int);
static int (*GetSystemMetrics)(int);
static BOOL (*GetLayeredWindowAttributes)(HANDLE, DWORD *, unsigned char *, DWORD *);
static int (*GetWindowTextW)(HANDLE, wchar *, int);
static BOOL (*SetProcessDPIAware)(void);

#define GWL_STYLE (-16)
#define GWLP_HWNDPARENT (-8)
#define WS_CHILD 0x40000000LL
#define WS_POPUP 0x80000000LL
#define SWP_NOSIZE 0x1
#define SWP_NOMOVE 0x2
#define SWP_NOZORDER 0x4
#define SWP_NOACTIVATE 0x10
#define SWP_FRAMECHANGED 0x20
#define SWP_SHOWWINDOW 0x40
#define GA_ROOT 2

#define CAPACITY 32
static struct { HANDLE view, host, top; BOOL hidden; } views[CAPACITY];
static int count;

static int same(const wchar *a, const wchar *b) { while (*a && *a == *b) { a++; b++; } return *a == *b; }
static wchar lower(wchar c) { return c >= 'A' && c <= 'Z' ? c + 32 : c; }
static int same_name(const wchar *a, const wchar *b) { while (*a && lower(*a) == lower(*b)) { a++; b++; } return lower(*a) == lower(*b); }

/* Where the view belongs on screen: its old parent's client area. */
static BOOL place(int i, RECT *area) {
    POINT origin = {0, 0};
    if (!ClientToScreen(views[i].host, &origin) || !GetClientRect(views[i].host, area)) return 0;
    area->left = origin.x; area->top = origin.y;
    return area->right > 0 && area->bottom > 0;
}

static BOOL each_child(HANDLE hwnd, LPARAM unused) {
    wchar name[64]; DWORD pid = 0, parent_pid = 0;
    if (count >= CAPACITY || !GetClassNameW(hwnd, name, 64) || !same(name, L"Chrome_WidgetWin_1")) return 1;
    HANDLE parent = GetParent(hwnd);
    if (!parent) return 1;
    GetWindowThreadProcessId(hwnd, &pid);
    GetWindowThreadProcessId(parent, &parent_pid);
    if (!pid || !parent_pid || pid == parent_pid) return 1;
    int i = count++;
    views[i].view = hwnd; views[i].host = parent; views[i].top = GetAncestor(parent, GA_ROOT); views[i].hidden = 0;
    RECT area = {0, 0, 0, 0};
    BOOL placed = place(i, &area);
    long long style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    SetParent(hwnd, 0);
    SetWindowLongPtrW(hwnd, GWL_STYLE, (style & ~WS_CHILD) | WS_POPUP);
    SetWindowLongPtrW(hwnd, GWLP_HWNDPARENT, (long long)views[i].top);   /* owned: stays above the app's window, hides with it */
    if (placed) SetWindowPos(hwnd, 0, area.left, area.top, area.right, area.bottom, SWP_FRAMECHANGED | SWP_SHOWWINDOW | SWP_NOACTIVATE | SWP_NOZORDER);
    return 1;
}

#define WS_CAPTION 0x00C00000LL
#define WS_THICKFRAME 0x00040000LL
#define WS_SYSMENU 0x00080000LL
#define WS_MINIMIZEBOX 0x00020000LL
#define WS_MAXIMIZEBOX 0x00010000LL

static const wchar *helpers[];
static DWORD helper_pids[64]; static int helper_count;

/* A game's window whose picture is as big as the screen is meant to fill it. On Windows its title bar may hang over
   the top edge; on a Mac the window was pushed under the menu bar and partly off the screen, and clicks missed (Draw &
   Guess, a windowed game sized to the whole screen). Like "borderless" tools on Windows: no title bar or frame, placed
   exactly over the screen. */
static void fit_to_screen(HANDLE hwnd) {
    if (!IsWindowVisible(hwnd) || IsIconic(hwnd) || GetParent(hwnd)) return;
    long long style = GetWindowLongPtrW(hwnd, GWL_STYLE);
    if ((style & WS_CHILD) || (style & WS_CAPTION) != WS_CAPTION) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    for (int i = 0; i < helper_count; i++) if (helper_pids[i] == pid) return;
    RECT client;
    int width = GetSystemMetrics(0), height = GetSystemMetrics(1);
    if (!GetClientRect(hwnd, &client) || width <= 0 || client.right + 2 < width || client.bottom + 2 < height) return;
    SetWindowLongPtrW(hwnd, GWL_STYLE, style & ~(WS_CAPTION | WS_THICKFRAME | WS_SYSMENU | WS_MINIMIZEBOX | WS_MAXIMIZEBOX));
    SetWindowPos(hwnd, 0, 0, 0, width, height, SWP_FRAMECHANGED | SWP_NOZORDER | SWP_NOACTIVATE);
}

/* See-through game windows. A window that is layered but has no layered-window settings lets Windows' desktop
   composition show the game's own transparency (DwmExtendFrameIntoClientArea): desktop-pet and idle games that live
   in a strip of the screen (Maltese's Fluffy Onsen). Wine's Mac driver can't, and showed black instead. Their titles
   (and whether clicks should pass through, WS_EX_TRANSPARENT) go to C:\windows\temp\cell-overlays.txt; Cell's Mac
   helper in the game makes those windows see-through. */
#define WS_EX_LAYERED 0x80000LL
#define WS_EX_TRANSPARENT 0x20LL
static char overlays[4096], written[4096];
static int overlay_length;
__declspec(dllimport) HANDLE CreateFileW(const wchar *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
__declspec(dllimport) BOOL WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) int WideCharToMultiByte(unsigned, DWORD, const wchar *, int, char *, int, const char *, BOOL *);

static void note_overlay(HANDLE hwnd) {
    if (!IsWindowVisible(hwnd) || GetParent(hwnd)) return;
    long long ex = GetWindowLongPtrW(hwnd, -20);
    if (!(ex & WS_EX_LAYERED)) return;
    DWORD key = 0, flags = 0; unsigned char alpha = 0;
    if (GetLayeredWindowAttributes && GetLayeredWindowAttributes(hwnd, &key, &alpha, &flags)) return;   /* a classic layered window */
    wchar title[128];
    int n = GetWindowTextW(hwnd, title, 128);
    if (n <= 0) return;
    int room = (int)sizeof(overlays) - overlay_length - 8;
    if (room <= 0) return;
    int bytes = WideCharToMultiByte(65001, 0, title, n, overlays + overlay_length, room, 0, 0);
    if (bytes <= 0) return;
    overlay_length += bytes;
    overlays[overlay_length++] = '\t';
    overlays[overlay_length++] = (ex & WS_EX_TRANSPARENT) ? '1' : '0';
    overlays[overlay_length++] = '\n';
}

static void write_overlays(void) {
    overlays[overlay_length] = 0;
    int same_text = 1;
    for (int i = 0; i <= overlay_length; i++) if (overlays[i] != written[i]) { same_text = 0; break; }
    if (same_text) return;
    for (int i = 0; i <= overlay_length; i++) written[i] = overlays[i];
    HANDLE file = CreateFileW(L"C:\\windows\\temp\\cell-overlays.txt", 0x40000000, 3, 0, 2, 0, 0);
    if (file == (HANDLE)-1) return;
    DWORD done = 0;
    WriteFile(file, overlays, overlay_length, &done, 0);
    CloseHandle(file);
}

static BOOL each_top(HANDLE hwnd, LPARAM unused) {
    EnumChildWindows(hwnd, each_child, 0);
    fit_to_screen(hwnd);
    note_overlay(hwnd);
    return 1;
}

static void follow(void) {
    HANDLE foreground = GetForegroundWindow();
    for (int i = 0; i < count; i++) {
        if (!IsWindow(views[i].view) || !IsWindow(views[i].host)) {
            /* The page or its place is gone: forget it (a page left without its app is closed by WebView2 itself). */
            views[i] = views[--count]; i--;
            continue;
        }
        RECT area = {0, 0, 0, 0}, now;
        BOOL shown = IsWindowVisible(views[i].host) && !IsIconic(views[i].top) && place(i, &area);
        if (!shown) {
            if (!views[i].hidden) { ShowWindow(views[i].view, 0); views[i].hidden = 1; }
            continue;
        }
        if (views[i].hidden) { ShowWindow(views[i].view, 8); views[i].hidden = 0; }   /* SW_SHOWNA */
        GetWindowRect(views[i].view, &now);
        if (now.left != area.left || now.top != area.top || now.right - now.left != area.right || now.bottom - now.top != area.bottom)
            SetWindowPos(views[i].view, 0, area.left, area.top, area.right, area.bottom, SWP_NOACTIVATE | SWP_NOZORDER);
        /* The app's window was brought to the front (clicked in the Dock, Cmd-Tab): the page comes with it. When
           the page fills the window it also takes the keyboard, like on Windows. */
        if (foreground == views[i].top) {
            RECT whole;
            GetClientRect(views[i].top, &whole);
            BOOL fills = area.right * 10 >= whole.right * 8 && area.bottom * 10 >= whole.bottom * 8;
            if (fills) SetForegroundWindow(views[i].view);
            else SetWindowPos(views[i].view, 0, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);   /* HWND_TOP */
        }
    }
}

static const wchar *helpers[] = { L"steam.exe", L"steamwebhelper.exe", L"steamwebhelper_real.exe", L"wineboot.exe", L"winedevice.exe", L"services.exe", L"plugplay.exe", L"explorer.exe", L"rpcss.exe",
                                  L"svchost.exe", L"conhost.exe", L"start.exe", L"tabtip.exe", L"cell-webview-bridge.exe", 0 };

/* Whether anything but Wine's own helpers (and this program) still runs. */
static BOOL programs_running(void) {
    HANDLE snapshot = CreateToolhelp32Snapshot(2, 0);
    if (snapshot == (HANDLE)-1) return 1;
    static PROCESSENTRY32W entry;
    entry.dwSize = sizeof(entry);
    BOOL found = 0;
    DWORD self = GetCurrentProcessId();
    helper_count = 0;
    for (BOOL more = Process32FirstW(snapshot, &entry); more; more = Process32NextW(snapshot, &entry)) {
        if (entry.th32ProcessID == self) continue;
        int helper = 0;
        for (int i = 0; helpers[i]; i++) if (same_name(entry.szExeFile, helpers[i])) helper = 1;
        if (helper && helper_count < 64) helper_pids[helper_count++] = entry.th32ProcessID;
        /* Steam itself keeps the session busy but is never resized. */
        if (!helper || same_name(entry.szExeFile, L"steam.exe")) found = 1;
    }
    CloseHandle(snapshot);
    return found;
}

void start(void) {
    CreateMutexW(0, 0, L"CellWebViewBridge");
    if (GetLastError() == 183) ExitProcess(0);   /* already running in this layer */
    HANDLE u = LoadLibraryW(L"user32.dll");
#define F(n) n = (void *)GetProcAddress(u, #n)
    F(EnumWindows); F(EnumChildWindows); F(GetWindowThreadProcessId); F(GetClassNameW); F(SetParent); F(GetParent); F(GetAncestor);
    F(GetForegroundWindow); F(SetForegroundWindow); F(GetWindowLongPtrW); F(SetWindowLongPtrW); F(SetWindowPos); F(GetClientRect);
    F(GetWindowRect); F(ClientToScreen); F(IsWindow); F(IsWindowVisible); F(IsIconic); F(ShowWindow);
    F(GetSystemMetrics); F(SetProcessDPIAware); F(GetLayeredWindowAttributes); F(GetWindowTextW);
    if (SetProcessDPIAware) SetProcessDPIAware();   /* real pixels, like the games that fill the screen */
    programs_running();                              /* learns which processes are helpers */
    int idle = 0;
    unsigned long long looked = 0, checked = GetTickCount64();
    for (;;) {
        unsigned long long now = GetTickCount64();
        if (now - looked >= 100) { overlay_length = 0; EnumWindows(each_top, 0); write_overlays(); looked = now; }
        follow();
        if (now - checked >= 2000) {
            checked = now;
            idle = programs_running() ? 0 : idle + 1;
            if (idle >= 5) ExitProcess(0);
        }
        Sleep(count ? 16 : 250);
    }
}
