#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#include <libproc.h>
#include <signal.h>
#include <unistd.h>

/* An independent event loop keeps Command-Q working when the game's UI thread is stuck.
 * Carbon registers this one shortcut without Accessibility or Input Monitoring permission. */
static pid_t game_pid;
static uint64_t birth_seconds, birth_microseconds;
static NSString *requests;
static EventHotKeyRef hotkey;
static dispatch_source_t lifetime, timer;
static id activation_observer;

static BOOL same_process(void) {
    struct proc_bsdinfo info = {0};
    return proc_pidinfo(game_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
        && info.pbi_start_tvsec == birth_seconds && info.pbi_start_tvusec == birth_microseconds;
}

static BOOL game_in_front(void) {
    return NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier == game_pid;
}

static void unregister_shortcut(void) {
    if (hotkey) { UnregisterEventHotKey(hotkey); hotkey = NULL; }
}

static OSStatus pressed(EventHandlerCallRef next, EventRef event, void *context) {
    (void)next; (void)context;
    EventHotKeyID identifier = {0};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                          sizeof(identifier), NULL, &identifier) != noErr
        || identifier.signature != 0x43454c4c || identifier.id != 1) return eventNotHandledErr;
    // Activation notifications can lag behind a fast app switch. Never kill a background game.
    if (!same_process() || !game_in_front()) { unregister_shortcut(); return noErr; }
    NSString *file = [requests stringByAppendingPathComponent:[NSString stringWithFormat:@"%d.request", game_pid]];
    NSString *stamp = [NSString stringWithFormat:@"%.6f\n", NSDate.date.timeIntervalSince1970];
    [stamp writeToFile:file atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    fprintf(stderr, "Cell: Command-Q force quit game PID %d\n", game_pid);
    if (kill(game_pid, SIGKILL) == 0) { unregister_shortcut(); exit(0); }
    return noErr;
}

static void update_shortcut(void) {
    if (!same_process()) { unregister_shortcut(); exit(0); }
    if (!game_in_front()) { unregister_shortcut(); return; }
    if (hotkey) return;
    EventHotKeyID identifier = {0x43454c4c, 1};
    OSStatus status = RegisterEventHotKey(kVK_ANSI_Q, cmdKey, identifier, GetApplicationEventTarget(), 0, &hotkey);
    if (status != noErr) fprintf(stderr, "Cell: Command-Q registration failed (%d)\n", (int)status);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 3 || (game_pid = (pid_t)strtol(argv[1], NULL, 10)) <= 1) return 2;
        struct proc_bsdinfo info = {0};
        if (proc_pidinfo(game_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
        birth_seconds = info.pbi_start_tvsec; birth_microseconds = info.pbi_start_tvusec;
        requests = [NSString stringWithUTF8String:argv[2]];
        if (!requests.length) return 2;
        [NSApplication.sharedApplication setActivationPolicy:NSApplicationActivationPolicyAccessory];
        EventTypeSpec type = {kEventClassKeyboard, kEventHotKeyPressed};
        if (InstallEventHandler(GetApplicationEventTarget(), pressed, 1, &type, NULL, NULL) != noErr) return 3;
        activation_observer = [NSWorkspace.sharedWorkspace.notificationCenter
            addObserverForName:NSWorkspaceDidActivateApplicationNotification object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(NSNotification *note) { (void)note; update_shortcut(); }];
        lifetime = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, game_pid, DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        if (lifetime) {
            dispatch_source_set_event_handler(lifetime, ^{ unregister_shortcut(); exit(0); });
            dispatch_resume(lifetime);
        }
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 4, NSEC_PER_SEC / 20);
        dispatch_source_set_event_handler(timer, ^{ update_shortcut(); });
        dispatch_resume(timer);
        [NSApplication.sharedApplication run];
    }
    return 0;
}
