/* A small Windows program that checks system DNS inside Wine without signing in. */
typedef unsigned long DWORD;
typedef void *HANDLE;
__declspec(dllimport) HANDLE LoadLibraryA(const char *);
__declspec(dllimport) void *GetProcAddress(HANDLE, const char *);
__declspec(dllimport) HANDLE GetStdHandle(DWORD);
__declspec(dllimport) int WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) void ExitProcess(unsigned);

static void print(const char *text) {
    DWORD length = 0, written = 0;
    while (text[length]) ++length;
    WriteFile(GetStdHandle((DWORD)-11), text, length, &written, 0);
}

void start(void) {
    HANDLE sockets = LoadLibraryA("ws2_32.dll");
    if (!sockets) ExitProcess(2);
    int (*startup)(unsigned short, void *) = GetProcAddress(sockets, "WSAStartup");
    int (*lookup)(const char *, const char *, const void *, void **) = GetProcAddress(sockets, "getaddrinfo");
    void (*free_result)(void *) = GetProcAddress(sockets, "freeaddrinfo");
    unsigned long long startup_data[64];
    if (!startup || !lookup || !free_result || startup(0x0202, startup_data)) ExitProcess(2);

    const char *hosts[] = {"store.steampowered.com", "thatgamecompany.helpshift.com"};
    for (unsigned i = 0; i < sizeof(hosts) / sizeof(hosts[0]); ++i) {
        void *addresses = 0;
        int status = lookup(hosts[i], "443", 0, &addresses);
        print(hosts[i]);
        print(status == 0 && addresses ? " resolved\n" : " could not be resolved\n");
        if (addresses) free_result(addresses);
    }
    ExitProcess(0);
}
