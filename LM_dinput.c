/*
 * 32-bit dinput.dll shim for MM8. Hides joysticks so the engine cannot
 * exclusive-acquire the pad (that steal kills XInput and OS remappers).
 * Mouse/keyboard DirectInput is forwarded unchanged.
 */
#define WIN32_LEAN_AND_MEAN
#define _CRT_SECURE_NO_WARNINGS
#include <windows.h>
#include <string.h>

typedef long HRESULT;
#define S_OK 0
#define DIDEVTYPE_JOYSTICK 4

typedef HRESULT (__stdcall *CreateFn)(HINSTANCE, DWORD, void **, void *);
typedef HRESULT (__stdcall *CreateExFn)(HINSTANCE, DWORD, void *, void **, void *);
typedef HRESULT (__stdcall *EnumFn)(void *, DWORD, void *, void *, DWORD);
typedef BOOL (__stdcall *EnumCb)(const void *, void *);
typedef HRESULT (__stdcall *VoidFn)(void);

static HMODULE g_real;
static CreateFn g_createA, g_createW;
static CreateExFn g_createEx;
static EnumFn g_enum;
static void *g_vt[32];
static int g_hooked;

static void load_real(void) {
    wchar_t path[MAX_PATH];
    if (g_real) return;
    GetSystemDirectoryW(path, MAX_PATH);
    wcscat(path, L"\\dinput.dll");
    g_real = LoadLibraryW(path);
    if (!g_real) return;
    g_createA = (CreateFn)GetProcAddress(g_real, "DirectInputCreateA");
    g_createW = (CreateFn)GetProcAddress(g_real, "DirectInputCreateW");
    g_createEx = (CreateExFn)GetProcAddress(g_real, "DirectInputCreateEx");
}

typedef struct {
    EnumCb cb;
    void *ref;
} Wrap;

static BOOL __stdcall filter_cb(const void *inst, void *ref) {
    const unsigned char *p = (const unsigned char *)inst;
    DWORD size, type;
    Wrap *w = (Wrap *)ref;
    if (!inst) return 1;
    size = *(DWORD *)p;
    if (size < 40) return w->cb(inst, w->ref);
    type = *(DWORD *)(p + 36);
    if ((type & 0xFF) == DIDEVTYPE_JOYSTICK)
        return 1;
    return w->cb(inst, w->ref);
}

static HRESULT __stdcall hook_enum(void *this, DWORD devType, void *cb, void *ref, DWORD flags) {
    Wrap w;
    if ((devType & 0xFF) == DIDEVTYPE_JOYSTICK)
        return S_OK;
    if (!cb) return g_enum(this, devType, cb, ref, flags);
    w.cb = (EnumCb)cb;
    w.ref = ref;
    return g_enum(this, devType, filter_cb, &w, flags);
}

static void patch_vt(void *iface) {
    void **vt;
    if (!iface) return;
    vt = *(void ***)iface;
    if (!vt) return;
    if (!g_hooked) {
        memcpy(g_vt, vt, sizeof(g_vt));
        g_enum = (EnumFn)vt[4];
        if (g_enum) g_vt[4] = (void *)hook_enum;
        g_hooked = 1;
    }
    *(void **)iface = g_vt;
}

static HRESULT wrap_create(CreateFn fn, HINSTANCE h, DWORD ver, void **out, void *unk) {
    HRESULT hr;
    load_real();
    if (!fn) return (HRESULT)0x80004001;
    hr = fn(h, ver, out, unk);
    if (hr == S_OK && out && *out) patch_vt(*out);
    return hr;
}

__declspec(dllexport) HRESULT __stdcall DirectInputCreateA(HINSTANCE h, DWORD ver, void **out, void *unk) {
    load_real();
    return wrap_create(g_createA, h, ver, out, unk);
}

__declspec(dllexport) HRESULT __stdcall DirectInputCreateW(HINSTANCE h, DWORD ver, void **out, void *unk) {
    load_real();
    return wrap_create(g_createW, h, ver, out, unk);
}

__declspec(dllexport) HRESULT __stdcall DirectInputCreateEx(HINSTANCE h, DWORD ver, void *riid, void **out, void *unk) {
    HRESULT hr;
    load_real();
    if (!g_createEx) return (HRESULT)0x80004001;
    hr = g_createEx(h, ver, riid, out, unk);
    if (hr == S_OK && out && *out) patch_vt(*out);
    return hr;
}

__declspec(dllexport) HRESULT __stdcall DllCanUnloadNow(void) {
    VoidFn fn;
    load_real();
    fn = g_real ? (VoidFn)GetProcAddress(g_real, "DllCanUnloadNow") : NULL;
    return fn ? fn() : S_OK;
}

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, LPVOID res) {
    (void)inst; (void)res;
    if (reason == DLL_PROCESS_ATTACH)
        DisableThreadLibraryCalls(inst);
    return TRUE;
}
