/*
 * Pad overlay for Might and Magic Merge (MM8.exe).
 * DualShock / generic pads via winmm; Xbox via XInput. MM8 stays on XP SP2.
 */
#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <mmsystem.h>
#include <shellapi.h>
#include <tlhelp32.h>
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>

#define BTN_DPAD_UP 0x0001
#define BTN_DPAD_DOWN 0x0002
#define BTN_DPAD_LEFT 0x0004
#define BTN_DPAD_RIGHT 0x0008
#define BTN_START 0x0010
#define BTN_BACK 0x0020
#define BTN_L3 0x0040
#define BTN_R3 0x0080
#define BTN_LB 0x0100
#define BTN_RB 0x0200
#define BTN_A 0x1000
#define BTN_B 0x2000
#define BTN_X 0x4000
#define BTN_Y 0x8000

#define WM_TRAY (WM_APP + 1)
#define TRAY_ID 1

typedef struct {
    DWORD dwPacketNumber;
    WORD wButtons;
    BYTE bLeftTrigger, bRightTrigger;
    SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} XINPUT_STATE;
typedef DWORD (WINAPI *PFN_XInputGetState)(DWORD, XINPUT_STATE *);

typedef struct {
    DWORD pid;
    HWND hwnd;
} FindCtx;

typedef struct {
    int connected;
    WORD buttons;
    BYTE lt, rt;
    SHORT lx, ly, rx, ry;
    char name[80];
} Pad;

typedef struct {
    unsigned int magic;
    unsigned int seq;
    unsigned short buttons;
    unsigned char lt, rt;
    short lx, ly, rx, ry;
    unsigned int connected;
} PadShared;

static wchar_t g_dir[MAX_PATH];
static char g_log_path[MAX_PATH];
static HWND g_hwnd;
static NOTIFYICONDATAA g_nid;
static int g_saw_game;
static int g_key_on[256];
static int g_lmb, g_rmb;
static PFN_XInputGetState g_xinput;
static PadShared *g_share;
static char g_tray_tip[128];
static DWORD g_last_log;
static char g_last_status[160];

/* The log is read back by the in-game bug report; keep it short. */
#define LOG_MAX_BYTES (64 * 1024)

static void log_msg(const char *fmt, ...) {
    FILE *f;
    va_list ap;
    SYSTEMTIME st;
    GetLocalTime(&st);
    f = fopen(g_log_path, "a");
    if (!f) return;
    fprintf(f, "%02d:%02d:%02d ", st.wHour, st.wMinute, st.wSecond);
    va_start(ap, fmt);
    vfprintf(f, fmt, ap);
    va_end(ap);
    fputc('\n', f);
    fclose(f);
}

static DWORD find_pid(const wchar_t *exe) {
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    PROCESSENTRY32W pe;
    DWORD pid = 0;
    if (snap == INVALID_HANDLE_VALUE) return 0;
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, exe) == 0) {
                pid = pe.th32ProcessID;
                break;
            }
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

static BOOL CALLBACK find_cb(HWND hwnd, LPARAM lp) {
    FindCtx *ctx = (FindCtx *)lp;
    DWORD pid = 0;
    RECT r;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid != ctx->pid) return TRUE;
    if (!IsWindowVisible(hwnd) || GetWindow(hwnd, GW_OWNER) != NULL) return TRUE;
    GetClientRect(hwnd, &r);
    if (r.right > 80 && r.bottom > 60) {
        ctx->hwnd = hwnd;
        return FALSE;
    }
    return TRUE;
}

static HWND find_game(void) {
    FindCtx ctx;
    HWND fg;
    DWORD fg_pid = 0;
    ctx.pid = find_pid(L"MM8.exe");
    ctx.hwnd = NULL;
    if (!ctx.pid) return NULL;
    fg = GetForegroundWindow();
    GetWindowThreadProcessId(fg, &fg_pid);
    if (fg && fg_pid == ctx.pid) return fg;
    EnumWindows(find_cb, (LPARAM)&ctx);
    return ctx.hwnd;
}

static void load_xinput(void) {
    HMODULE mod = LoadLibraryA("xinput1_4.dll");
    if (!mod) mod = LoadLibraryA("xinput1_3.dll");
    if (!mod) mod = LoadLibraryA("xinput9_1_0.dll");
    if (mod)
        g_xinput = (PFN_XInputGetState)GetProcAddress(mod, "XInputGetState");
    log_msg("xinput=%s", g_xinput ? "ok" : "missing");
}

static void send_vk(WORD vk, int down) {
    INPUT in;
    WORD scan = (WORD)MapVirtualKeyW(vk, MAPVK_VK_TO_VSC);
    memset(&in, 0, sizeof(in));
    in.type = INPUT_KEYBOARD;
    in.ki.wVk = vk;
    in.ki.wScan = scan;
    if (!down) in.ki.dwFlags = KEYEVENTF_KEYUP;
    SendInput(1, &in, sizeof(INPUT));
}

static void release_keys(void) {
    int i;
    for (i = 0; i < 256; i++) {
        if (g_key_on[i]) {
            send_vk((WORD)i, 0);
            g_key_on[i] = 0;
        }
    }
}

static void set_mouse(int lmb, int rmb) {
    INPUT in;
    if (lmb != g_lmb) {
        memset(&in, 0, sizeof(in));
        in.type = INPUT_MOUSE;
        in.mi.dwFlags = lmb ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP;
        SendInput(1, &in, sizeof(INPUT));
        g_lmb = lmb;
    }
    if (rmb != g_rmb) {
        memset(&in, 0, sizeof(in));
        in.type = INPUT_MOUSE;
        in.mi.dwFlags = rmb ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP;
        SendInput(1, &in, sizeof(INPUT));
        g_rmb = rmb;
    }
}

static SHORT joy_axis(DWORD v) {
    int n = (int)v - 32767;
    if (n > 32767) n = 32767;
    if (n < -32767) n = -32767;
    return (SHORT)n;
}

static int is_playstation(UINT mid, UINT pid, const char *name) {
    if (mid == 0x054C) return 1;
    if (name && (strstr(name, "Wireless Controller") || strstr(name, "DualShock")
        || strstr(name, "DualSense") || strstr(name, "PS4") || strstr(name, "PS5")))
        return 1;
    (void)pid;
    return 0;
}

static int read_xinput(Pad *pad) {
    XINPUT_STATE st;
    int i;
    if (!g_xinput) return 0;
    for (i = 0; i < 4; i++) {
        memset(&st, 0, sizeof(st));
        if (g_xinput(i, &st) != 0) continue;
        pad->connected = 1;
        pad->buttons = st.wButtons;
        pad->lt = st.bLeftTrigger;
        pad->rt = st.bRightTrigger;
        pad->lx = st.sThumbLX;
        pad->ly = st.sThumbLY;
        pad->rx = st.sThumbRX;
        pad->ry = st.sThumbRY;
        snprintf(pad->name, sizeof(pad->name), "XInput slot %d", i);
        return 1;
    }
    return 0;
}

static int read_winmm(Pad *pad) {
    JOYINFOEX j;
    JOYCAPSA caps;
    UINT n, i, b;
    int ps;
    n = joyGetNumDevs();
    for (i = 0; i < n && i < 16; i++) {
        memset(&j, 0, sizeof(j));
        j.dwSize = sizeof(j);
        j.dwFlags = JOY_RETURNALL;
        if (joyGetPosEx(i, &j) != JOYERR_NOERROR) continue;
        memset(&caps, 0, sizeof(caps));
        joyGetDevCapsA(i, &caps, sizeof(caps));
        ps = is_playstation(caps.wMid, caps.wPid, caps.szPname);
        pad->connected = 1;
        pad->lx = joy_axis(j.dwXpos);
        pad->ly = (SHORT)(-joy_axis(j.dwYpos));
        pad->rx = joy_axis(j.dwZpos);
        pad->ry = (SHORT)(-joy_axis(j.dwRpos));
        pad->lt = 0;
        pad->rt = 0;
        pad->buttons = 0;
        b = j.dwButtons;
        if (ps) {
            /* DS4: 1 Square 2 Cross 3 Circle 4 Triangle 5 L1 6 R1 7 L2 8 R2 9 Share 10 Options 11 L3 12 R3 */
            if (b & 2) pad->buttons |= BTN_A;
            if (b & 4) pad->buttons |= BTN_B;
            if (b & 1) pad->buttons |= BTN_X;
            if (b & 8) pad->buttons |= BTN_Y;
            if (b & 16) pad->buttons |= BTN_LB;
            if (b & 32) pad->buttons |= BTN_RB;
            if (b & 64) pad->lt = 255;
            if (b & 128) pad->rt = 255;
            if (b & 256) pad->buttons |= BTN_BACK;
            if (b & 512) pad->buttons |= BTN_START;
            if (b & 1024) pad->buttons |= BTN_L3;
            if (b & 2048) pad->buttons |= BTN_R3;
            snprintf(pad->name, sizeof(pad->name), "PS %s", caps.szPname);
        } else {
            if (b & 1) pad->buttons |= BTN_A;
            if (b & 2) pad->buttons |= BTN_B;
            if (b & 4) pad->buttons |= BTN_X;
            if (b & 8) pad->buttons |= BTN_Y;
            if (b & 16) pad->buttons |= BTN_LB;
            if (b & 32) pad->buttons |= BTN_RB;
            if (b & 64) pad->buttons |= BTN_BACK;
            if (b & 128) pad->buttons |= BTN_START;
            if (b & 256) pad->buttons |= BTN_L3;
            if (b & 512) pad->buttons |= BTN_R3;
            snprintf(pad->name, sizeof(pad->name), "%s", caps.szPname[0] ? caps.szPname : "joystick");
        }
        if (j.dwPOV != JOY_POVCENTERED && j.dwPOV != (DWORD)-1) {
            if (j.dwPOV > 31500 || j.dwPOV < 4500) pad->buttons |= BTN_DPAD_UP;
            if (j.dwPOV > 4500 && j.dwPOV < 13500) pad->buttons |= BTN_DPAD_RIGHT;
            if (j.dwPOV > 13500 && j.dwPOV < 22500) pad->buttons |= BTN_DPAD_DOWN;
            if (j.dwPOV > 22500 && j.dwPOV < 31500) pad->buttons |= BTN_DPAD_LEFT;
        }
        if (j.dwUpos > 40000) pad->lt = 255;
        if (j.dwVpos > 40000) pad->rt = 255;
        return 1;
    }
    return 0;
}

static void read_pad(Pad *pad) {
    memset(pad, 0, sizeof(*pad));
    if (!read_xinput(pad))
        read_winmm(pad);
}

static void tray_tip(const char *text) {
    if (strcmp(g_tray_tip, text) == 0) return;
    snprintf(g_tray_tip, sizeof(g_tray_tip), "%s", text);
    memset(&g_nid, 0, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = TRAY_ID;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    snprintf(g_nid.szTip, sizeof(g_nid.szTip), "%s", text);
    Shell_NotifyIconA(NIM_MODIFY, &g_nid);
}

/* Only publishes the pad state. LM_Gamepad.lua reads it from the shared
 * memory and does the keyboard/mouse side inside the game. */
static void poll_pad(void) {
    HWND game = find_game();
    Pad pad;
    DWORD now = GetTickCount();

    if (find_pid(L"MM8.exe")) g_saw_game = 1;
    if (g_saw_game && !find_pid(L"MM8.exe")) {
        log_msg("MM8 exited");
        PostQuitMessage(0);
        return;
    }

    read_pad(&pad);
    if (g_share) {
        g_share->magic = 0x44504D4C;
        g_share->seq++;
        g_share->buttons = pad.buttons;
        g_share->lt = pad.lt;
        g_share->rt = pad.rt;
        g_share->lx = pad.lx;
        g_share->ly = pad.ly;
        g_share->rx = pad.rx;
        g_share->ry = pad.ry;
        g_share->connected = pad.connected ? 1u : 0u;
    }
    if (now - g_last_log > 2000) {
        g_last_log = now;
        char status[160];
        snprintf(status, sizeof(status), "pad=%s game=%s",
            pad.connected ? pad.name : "none", game ? "found" : "none");
        if (strcmp(status, g_last_status) != 0) {
            snprintf(g_last_status, sizeof(g_last_status), "%s", status);
            log_msg("%s", status);
        }
        tray_tip(pad.connected ? pad.name : "Merge pad: no controller");
    }
}

static void ensure_game(void) {
    wchar_t path[MAX_PATH];
    if (find_pid(L"MM8.exe")) return;
    _snwprintf(path, MAX_PATH, L"%s\\MM8.exe", g_dir);
    if (GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        log_msg("MM8.exe missing");
        return;
    }
    log_msg("starting MM8.exe");
    ShellExecuteW(NULL, L"open", path, NULL, g_dir, SW_SHOWNORMAL);
}

static LRESULT CALLBACK wnd_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    if (msg == WM_TIMER) {
        poll_pad();
        return 0;
    }
    if (msg == WM_DESTROY) {
        Shell_NotifyIconA(NIM_DELETE, &g_nid);
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show) {
    WNDCLASSA wc;
    MSG msg;
    wchar_t *slash;
    char dir_utf8[MAX_PATH];
    (void)prev; (void)cmd; (void)show;
    GetModuleFileNameW(NULL, g_dir, MAX_PATH);
    slash = wcsrchr(g_dir, L'\\');
    if (slash) *slash = 0;
    WideCharToMultiByte(CP_ACP, 0, g_dir, -1, dir_utf8, MAX_PATH, NULL, NULL);
    snprintf(g_log_path, sizeof(g_log_path), "%s\\LM_MMMerge.log", dir_utf8);
    {
        FILE *f = fopen(g_log_path, "rb");
        if (f) {
            long n;
            fseek(f, 0, SEEK_END);
            n = ftell(f);
            fclose(f);
            if (n > LOG_MAX_BYTES) remove(g_log_path);
        }
    }
    log_msg("overlay start");
    {
        HANDLE h = CreateFileMappingA(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0,
            (DWORD)sizeof(PadShared), "Local\\LM_MMMergePad");
        if (h)
            g_share = (PadShared *)MapViewOfFile(h, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(PadShared));
        log_msg("share=%s", g_share ? "ok" : "fail");
    }

    memset(&wc, 0, sizeof(wc));
    wc.lpfnWndProc = wnd_proc;
    wc.hInstance = inst;
    wc.lpszClassName = "LM_MMMergePad";
    wc.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    RegisterClassA(&wc);
    g_hwnd = CreateWindowExA(0, "LM_MMMergePad", "LM_MMMerge", WS_POPUP,
        0, 0, 0, 0, NULL, NULL, inst, NULL);
    ShowWindow(g_hwnd, SW_HIDE);

    memset(&g_nid, 0, sizeof(g_nid));
    g_nid.cbSize = sizeof(g_nid);
    g_nid.hWnd = g_hwnd;
    g_nid.uID = TRAY_ID;
    g_nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_nid.uCallbackMessage = WM_TRAY;
    g_nid.hIcon = LoadIcon(NULL, IDI_APPLICATION);
    snprintf(g_nid.szTip, sizeof(g_nid.szTip), "Merge pad");
    Shell_NotifyIconA(NIM_ADD, &g_nid);

    load_xinput();
    ensure_game();
    SetTimer(g_hwnd, 1, 16, NULL);
    while (GetMessage(&msg, NULL, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessage(&msg);
    }
    release_keys();
    set_mouse(0, 0);
    Shell_NotifyIconA(NIM_DELETE, &g_nid);
    return 0;
}
