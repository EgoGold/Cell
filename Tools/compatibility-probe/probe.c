/* Hidden-window input and temporary-directory regression probe.
 * Posts messages only to its own hidden window. Does not synthesize desktop input.
 * Build: python3 Tools/compatibility-probe/build.py
 * Run under Wine with CELL_PROBE_OUT set to a writable Windows path.
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


__declspec(dllimport) DWORD GetLastError(void);
__declspec(dllimport) BOOL CreateDirectoryW(const wchar *, void *);
__declspec(dllimport) BOOL RemoveDirectoryW(const wchar *);
__declspec(dllimport) BOOL DeleteFileW(const wchar *);
typedef struct { HANDLE hwnd; unsigned msg; unsigned long long wp; long long lp; DWORD time; int x,y; DWORD extra; } MSG;
static int pointers;
static long long (*oldproc)(HANDLE,unsigned,unsigned long long,long long);
static void *user;
static long long window_proc(HANDLE h,unsigned m,unsigned long long w,long long l) {
    if(m>=0x245 && m<=0x247) {
        unsigned type=0,count=0; unsigned long long info[12];
        BOOL (*getType)(unsigned,unsigned*)=GetProcAddress(user,"GetPointerType");
        BOOL (*getInfo)(unsigned,void*)=GetProcAddress(user,"GetPointerInfo");
        report("pointer-info-ok", getInfo((unsigned)(w&65535),info));
        BOOL (*getFrame)(unsigned,unsigned*,void*)=GetProcAddress(user,"GetPointerFrameInfo");
        report("pointer-type-ok",getType((unsigned)(w&65535),&type)); report("pointer-type",type);
        if (getFrame) { report("frame-count-ok",getFrame((unsigned)(w&65535),&count,0)); report("frame-count",count);
        report("frame-info-ok",getFrame((unsigned)(w&65535),&count,info)); } else report("frame-api-absent",1);
        pointers++;
    }
    return oldproc(h,m,w,l);
}
void start(void) {
    wchar path[2048];
    GetEnvironmentVariableW(L"CELL_PROBE_OUT",path,2048);
    output=CreateFileW(path,GENERIC_WRITE,3,0,CREATE_ALWAYS,0,0);
    user=LoadLibraryW(L"user32.dll");
    BOOL (*enable)(BOOL)=GetProcAddress(user,"EnableMouseInPointer");
    HANDLE (*create)(DWORD,const wchar*,const wchar*,DWORD,int,int,int,int,HANDLE,HANDLE,HANDLE,void*)=GetProcAddress(user,"CreateWindowExW");
    long long (*setproc)(HANDLE,int,long long)=GetProcAddress(user,"SetWindowLongPtrW");
    BOOL (*post)(HANDLE,unsigned,unsigned long long,long long)=GetProcAddress(user,"PostMessageW");
    BOOL (*peek)(MSG*,HANDLE,unsigned,unsigned,unsigned)=GetProcAddress(user,"PeekMessageW");
    long long (*dispatch)(MSG*)=GetProcAddress(user,"DispatchMessageW");
    BOOL (*destroy)(HANDLE)=GetProcAddress(user,"DestroyWindow");
    HANDLE h=create(0,L"STATIC",L"Cell hidden compatibility test",0,0,0,64,64,0,0,0,0);
    report("window",h!=0);
    oldproc=(void*)setproc(h,-4,(long long)window_proc);
    report("enable-first",enable(1)); report("enable-error",GetLastError()); report("enable-repeat",enable(1)); report("repeat-error",GetLastError());
    post(h,0x201,1,0x00100010); post(h,0x202,0,0x00100010);
    MSG msg; int iterations=0;
    while(iterations++<100 && peek(&msg,0,0,0,1)) dispatch(&msg);
    report("pointer-messages",pointers); destroy(h);
    const wchar *dir=L"\\\\?\\C:\\windows\\temp\\cell-directory-probe-20261112";
    const wchar *file=L"\\\\?\\C:\\windows\\temp\\cell-directory-probe-20261112\\test.tmp";
    report("create-directory",CreateDirectoryW(dir,0));
    HANDLE f=CreateFileW(file,GENERIC_WRITE,3,0,CREATE_ALWAYS,0,0); report("create-file",f!=INVALID_HANDLE); CloseHandle(f);
    report("delete-file",DeleteFileW(file));
    report("remove-directory",RemoveDirectoryW(dir)); report("last-error",GetLastError());
    CloseHandle(output); ExitProcess(0);
}
