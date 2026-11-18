/*
 * Cell's engine probe.
 *
 * Checks, without showing anything on screen, whether a Wine engine and graphics engine pair can really
 * draw: it creates a DXGI factory, a Direct3D 11 device, a swap chain on a hidden window, presents one
 * frame, and tries a Direct3D 12 device. Cell runs it once per pair (in a scratch prefix) and never
 * uses a pair whose Direct3D 11 device can't be created — that is what made games crash on start.
 *
 * Results go, one line per step, to the file named by CELL_PROBE_OUT. Each line is written as soon
 * as the step finishes, so a crash inside a graphics engine still tells how far it got:
 *
 *   probe 1
 *   factory <hresult>
 *   adapter <vendor id> <device id> <description>
 *   d3d11 <hresult> <feature level>
 *   window <1 or 0>
 *   swapchain <hresult>
 *   present <hresult>
 *   d3d12 <hresult>
 *   text <width> <height> <dialog units>   (0 0: the engine can't show text in Windows dialogs)
 *   done
 *
 * No C runtime: kernel32 only (everything else through LoadLibraryW/GetProcAddress), built by
 * Tools/engine-probe/build.py with Xcode's clang.
 */
typedef __WCHAR_TYPE__ wchar;
typedef int BOOL;
typedef unsigned long DWORD;
typedef void *HANDLE;
typedef long HRESULT;
typedef unsigned long long SIZE_T;

typedef struct { unsigned long Data1; unsigned short Data2, Data3; unsigned char Data4[8]; } GUID;

__declspec(dllimport) HANDLE LoadLibraryW(const wchar *name);
__declspec(dllimport) void *GetProcAddress(HANDLE module, const char *name);
__declspec(dllimport) DWORD GetEnvironmentVariableW(const wchar *name, wchar *buffer, DWORD size);
__declspec(dllimport) HANDLE CreateFileW(const wchar *name, DWORD access, DWORD share, void *security, DWORD creation,
                                         DWORD flags, HANDLE templateFile);
__declspec(dllimport) BOOL WriteFile(HANDLE file, const void *buffer, DWORD size, DWORD *written, void *overlapped);
__declspec(dllimport) BOOL CloseHandle(HANDLE handle);
__declspec(dllimport) void ExitProcess(unsigned code);

#define GENERIC_WRITE 0x40000000
#define CREATE_ALWAYS 2
#define INVALID_HANDLE ((HANDLE)(long long)-1)

/* clang may turn struct zeroing into memset calls even when freestanding. */
void *memset(void *destination, int value, SIZE_T count) {
    unsigned char *bytes = destination;
    while (count--) *bytes++ = (unsigned char)value;
    return destination;
}

static HANDLE output = INVALID_HANDLE;
static char line[512];
static int length;

static void put(const char *text) {
    while (*text && length < (int)sizeof(line) - 2) line[length++] = *text++;
}

static void put_hex(unsigned long value, int digits) {
    static const char hex[] = "0123456789abcdef";
    put("0x");
    for (int shift = (digits - 1) * 4; shift >= 0; shift -= 4) {
        if (length < (int)sizeof(line) - 2) line[length++] = hex[(value >> shift) & 0xF];
    }
}

static void put_wide(const wchar *text, int maximum) {
    for (int i = 0; i < maximum && text[i]; i++) {
        wchar c = text[i];
        if (length < (int)sizeof(line) - 2) line[length++] = (c >= 32 && c < 127) ? (char)c : '?';
    }
}

static void end_line(void) {
    line[length++] = '\n';
    DWORD written = 0;
    if (output != INVALID_HANDLE) WriteFile(output, line, (DWORD)length, &written, 0);
    length = 0;
}

static void report(const char *step, HRESULT result) {
    put(step);
    put(" ");
    put_hex((unsigned long)result, 8);
    end_line();
}

/* COM: the method at `index` of an object's vtable. */
#define METHOD(object, index) ((*(void ***)(object))[index])

typedef HRESULT (*CreateDXGIFactory1Function)(const GUID *iid, void **factory);
typedef HRESULT (*EnumAdaptersFunction)(void *factory, unsigned index, void **adapter);
typedef HRESULT (*GetDescFunction)(void *adapter, void *description);
typedef HRESULT (*D3D11CreateDeviceFunction)(void *adapter, int driverType, HANDLE software, unsigned flags,
                                             const int *levels, unsigned count, unsigned sdkVersion,
                                             void **device, int *level, void **context);
typedef HRESULT (*CreateSwapChainFunction)(void *factory, void *device, void *description, void **swapChain);
typedef HRESULT (*PresentFunction)(void *swapChain, unsigned interval, unsigned flags);
typedef unsigned long (*ReleaseFunction)(void *object);
typedef HRESULT (*D3D12CreateDeviceFunction)(void *adapter, int level, const GUID *iid, void **device);
typedef HANDLE (*CreateWindowExWFunction)(DWORD exStyle, const wchar *className, const wchar *title, DWORD style,
                                          int x, int y, int width, int height, HANDLE parent, HANDLE menu,
                                          HANDLE instance, void *parameter);
typedef BOOL (*DestroyWindowFunction)(HANDLE window);
typedef HANDLE (*GetDCFunction)(HANDLE window);
typedef int (*ReleaseDCFunction)(HANDLE window, HANDLE dc);
typedef long (*GetDialogBaseUnitsFunction)(void);
typedef HANDLE (*CreateFontWFunction)(int, int, int, int, int, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, DWORD, const wchar *);
typedef HANDLE (*SelectObjectFunction)(HANDLE dc, HANDLE object);
typedef BOOL (*DeleteObjectFunction)(HANDLE object);
typedef struct { long cx, cy; } TextSize;
typedef BOOL (*GetTextExtentPoint32WFunction)(HANDLE dc, const wchar *text, int count, TextSize *size);

static const GUID IID_IDXGIFactory1 = {0x770aae78, 0xf26f, 0x4dba, {0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87}};
static const GUID IID_ID3D12Device = {0x189819f1, 0x1db6, 0x4b57, {0xbe, 0x54, 0x18, 0x21, 0x33, 0x9b, 0x85, 0xf7}};

/* DXGI_ADAPTER_DESC1: Description[128], VendorId, DeviceId, SubSysId, Revision, three SIZE_T, LUID, Flags. */
typedef struct {
    wchar description[128];
    unsigned vendor, device, subsystem, revision;
    SIZE_T video, system, shared;
    unsigned luidLow; long luidHigh;
    unsigned flags;
} AdapterDescription;

/* DXGI_SWAP_CHAIN_DESC */
typedef struct {
    unsigned width, height, refreshNumerator, refreshDenominator, format, scanline, scaling;
    unsigned sampleCount, sampleQuality;
    unsigned usage, bufferCount;
    HANDLE window;
    BOOL windowed;
    unsigned effect, flags;
} SwapChainDescription;

static void release(void *object) {
    if (object) ((ReleaseFunction)METHOD(object, 2))(object);
}

void start(void) {
    static wchar path[1024];
    if (GetEnvironmentVariableW(L"CELL_PROBE_OUT", path, 1024)) {
        output = CreateFileW(path, GENERIC_WRITE, 1 /* share read */, 0, CREATE_ALWAYS, 0x80, 0);
    }
    put("probe 1");
    end_line();

    /* DXGI factory and the first adapter: shows whose dxgi.dll is loaded (Apple GPU vs. Wine's stand-in). */
    void *factory = 0, *adapter = 0;
    HANDLE dxgi = LoadLibraryW(L"dxgi.dll");
    CreateDXGIFactory1Function createFactory = dxgi ? (CreateDXGIFactory1Function)GetProcAddress(dxgi, "CreateDXGIFactory1") : 0;
    HRESULT result = createFactory ? createFactory(&IID_IDXGIFactory1, &factory) : (HRESULT)0x8007007E;
    report("factory", result);
    if (result >= 0 && factory) {
        result = ((EnumAdaptersFunction)METHOD(factory, 7))(factory, 0, &adapter);   /* IDXGIFactory::EnumAdapters */
        if (result >= 0 && adapter) {
            AdapterDescription description;
            memset(&description, 0, sizeof(description));
            if (((GetDescFunction)METHOD(adapter, 8))(adapter, &description) >= 0) {   /* IDXGIAdapter::GetDesc */
                put("adapter ");
                put_hex(description.vendor, 4);
                put(" ");
                put_hex(description.device, 8);
                put(" ");
                put_wide(description.description, 128);
                end_line();
            }
        }
    }

    /* Direct3D 11 device on that adapter (driver type UNKNOWN when an adapter is given). */
    void *device = 0, *context = 0;
    int level = 0;
    static const int levels[] = {0xb100, 0xb000, 0xa100, 0xa000};
    HANDLE d3d11 = LoadLibraryW(L"d3d11.dll");
    D3D11CreateDeviceFunction createDevice = d3d11 ? (D3D11CreateDeviceFunction)GetProcAddress(d3d11, "D3D11CreateDevice") : 0;
    result = createDevice ? createDevice(adapter, adapter ? 0 : 1, 0, 0, levels, 4, 7, &device, &level, &context)
                          : (HRESULT)0x8007007E;
    put("d3d11 ");
    put_hex((unsigned long)result, 8);
    put(" ");
    put_hex((unsigned long)level, 4);
    end_line();

    /* A swap chain on a hidden window, and one frame. */
    if (result >= 0 && device && factory) {
        HANDLE user32 = LoadLibraryW(L"user32.dll");
        CreateWindowExWFunction createWindow = user32 ? (CreateWindowExWFunction)GetProcAddress(user32, "CreateWindowExW") : 0;
        DestroyWindowFunction destroyWindow = user32 ? (DestroyWindowFunction)GetProcAddress(user32, "DestroyWindow") : 0;
        /* WS_POPUP without WS_VISIBLE: nothing appears on screen or in the Dock. */
        HANDLE window = createWindow ? createWindow(0, L"STATIC", L"Cell engine probe", 0x80000000, 0, 0, 64, 64, 0, 0, 0, 0) : 0;
        put(window ? "window 1" : "window 0");
        end_line();
        if (window) {
            SwapChainDescription description;
            memset(&description, 0, sizeof(description));
            description.width = 64;
            description.height = 64;
            description.refreshNumerator = 60;
            description.refreshDenominator = 1;
            description.format = 28;             /* DXGI_FORMAT_R8G8B8A8_UNORM */
            description.sampleCount = 1;
            description.usage = 0x20;            /* DXGI_USAGE_RENDER_TARGET_OUTPUT */
            description.bufferCount = 2;
            description.window = window;
            description.windowed = 1;
            description.effect = 0;              /* DXGI_SWAP_EFFECT_DISCARD */
            void *swapChain = 0;
            result = ((CreateSwapChainFunction)METHOD(factory, 10))(factory, device, &description, &swapChain);
            report("swapchain", result);
            if (result >= 0 && swapChain) {
                report("present", ((PresentFunction)METHOD(swapChain, 8))(swapChain, 0, 0));
                release(swapChain);
            }
            if (destroyWindow) destroyWindow(window);
        }
    }
    release(context);
    release(device);
    release(adapter);
    release(factory);

    /* Direct3D 12 on the default adapter (D3DMetal provides it; other engines may not). */
    HANDLE d3d12 = LoadLibraryW(L"d3d12.dll");
    D3D12CreateDeviceFunction create12 = d3d12 ? (D3D12CreateDeviceFunction)GetProcAddress(d3d12, "D3D12CreateDevice") : 0;
    void *device12 = 0;
    report("d3d12", create12 ? create12(0, 0xb000, &IID_ID3D12Device, &device12) : (HRESULT)0x8007007E);
    release(device12);

    /* Text: Windows dialogs size themselves from the UI font. An engine built without its font renderer
     * measures every text as 0x0, so message boxes and launchers shrink to an empty title bar. */
    HANDLE user = LoadLibraryW(L"user32.dll"), gdi = LoadLibraryW(L"gdi32.dll");
    GetDCFunction getDC = user ? (GetDCFunction)GetProcAddress(user, "GetDC") : 0;
    ReleaseDCFunction releaseDC = user ? (ReleaseDCFunction)GetProcAddress(user, "ReleaseDC") : 0;
    GetDialogBaseUnitsFunction baseUnits = user ? (GetDialogBaseUnitsFunction)GetProcAddress(user, "GetDialogBaseUnits") : 0;
    CreateFontWFunction createFont = gdi ? (CreateFontWFunction)GetProcAddress(gdi, "CreateFontW") : 0;
    SelectObjectFunction selectObject = gdi ? (SelectObjectFunction)GetProcAddress(gdi, "SelectObject") : 0;
    DeleteObjectFunction deleteObject = gdi ? (DeleteObjectFunction)GetProcAddress(gdi, "DeleteObject") : 0;
    GetTextExtentPoint32WFunction measure = gdi ? (GetTextExtentPoint32WFunction)GetProcAddress(gdi, "GetTextExtentPoint32W") : 0;
    if (getDC && createFont && selectObject && measure) {
        HANDLE dc = getDC(0);
        HANDLE font = createFont(-12, 0, 0, 0, 400, 0, 0, 0, 1, 0, 0, 0, 0, L"MS Shell Dlg");
        HANDLE previous = selectObject(dc, font);
        TextSize size;
        size.cx = size.cy = 0;
        if (!measure(dc, L"Cell", 7, &size)) size.cx = size.cy = 0;
        put("text ");
        put_hex((unsigned long)size.cx, 4);
        put(" ");
        put_hex((unsigned long)size.cy, 4);
        put(" ");
        put_hex(baseUnits ? (unsigned long)baseUnits() : 0, 8);
        end_line();
        selectObject(dc, previous);
        if (deleteObject) deleteObject(font);
        if (releaseDC) releaseDC(0, dc);
    }

    put("done");
    end_line();
    if (output != INVALID_HANDLE) CloseHandle(output);
    ExitProcess(0);
}
