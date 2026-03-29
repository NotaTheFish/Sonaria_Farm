// sonaria_wrd_executor_api.dll
// Обёртка над wearedevs_exploit_api.dll: штатные initialize/isAttached в оригинале часто падают;
// production-режим — только execute. Эта DLL даёт стабильный API для stocker/injector.exe.
//
// Сборка: stocker/build_wrd_executor_api.ps1
//
// Опционально (переменные окружения процесса Roblox / инжектора):
//   SONARIA_WRD_BACKEND_PATH  — полный путь к backend DLL (если задан, остальное игнорируется)
//   SONARIA_WRD_BACKEND_DLL   — только имя файла (по умолчанию wearedevs_exploit_api.dll)
// Поиск backend: SONARIA_WRD_BACKEND_PATH → каталог обёртки → родитель каталога (build → stocker) → PATH

#include <windows.h>

namespace {

HMODULE g_self = nullptr;
CRITICAL_SECTION g_cs{};
HMODULE g_backend = nullptr;

using ExecuteFn = void(__cdecl*)(const char*);

ExecuteFn g_execute = nullptr;

void BackendDllName(wchar_t* name, size_t name_words) {
    const DWORD cap = static_cast<DWORD>(name_words);
    DWORD n = GetEnvironmentVariableW(L"SONARIA_WRD_BACKEND_DLL", name, cap);
    if (n == 0 || n >= cap) {
        wcscpy_s(name, name_words, L"wearedevs_exploit_api.dll");
    }
}

bool ResolveExecuteExports() {
    static const char* kCandidates[] = {
        "_execute@4",
        "execute",
        "Execute",
        "_SendLuaScript@4",
        "SendLuaScript",
        "_ExecuteScript@4",
        "ExecuteScript",
    };
    for (const char* n : kCandidates) {
        FARPROC p = GetProcAddress(g_backend, n);
        if (p) {
            g_execute = reinterpret_cast<ExecuteFn>(p);
            return true;
        }
    }
    return false;
}

bool TryLoadBackend(const wchar_t* path) {
    HMODULE m = LoadLibraryW(path);
    if (!m) {
        return false;
    }
    g_backend = m;
    if (ResolveExecuteExports()) {
        return true;
    }
    FreeLibrary(g_backend);
    g_backend = nullptr;
    g_execute = nullptr;
    return false;
}

bool EnsureBackendUnlocked() {
    if (g_backend && g_execute) {
        return true;
    }
    if (g_backend && !g_execute) {
        FreeLibrary(g_backend);
        g_backend = nullptr;
    }

    wchar_t envPath[MAX_PATH];
    const DWORD ev = GetEnvironmentVariableW(L"SONARIA_WRD_BACKEND_PATH", envPath, static_cast<DWORD>(sizeof(envPath) / sizeof(envPath[0])));
    if (ev > 0 && ev < sizeof(envPath) / sizeof(envPath[0])) {
        return TryLoadBackend(envPath);
    }

    wchar_t name[260];
    BackendDllName(name, sizeof(name) / sizeof(name[0]));

    wchar_t dir[MAX_PATH];
    if (!GetModuleFileNameW(g_self, dir, MAX_PATH)) {
        return false;
    }
    wchar_t* slash = wcsrchr(dir, L'\\');
    if (!slash) {
        return false;
    }
    *(slash + 1) = L'\0';

    wchar_t try1[MAX_PATH];
    wcscpy_s(try1, dir);
    wcscat_s(try1, name);
    if (TryLoadBackend(try1)) {
        return true;
    }

    wchar_t try2[MAX_PATH];
    wcscpy_s(try2, dir);
    wcscat_s(try2, L"..\\");
    wcscat_s(try2, name);
    if (TryLoadBackend(try2)) {
        return true;
    }

    return TryLoadBackend(name);
}

bool EnsureBackend() {
    EnterCriticalSection(&g_cs);
    const bool ok = EnsureBackendUnlocked();
    LeaveCriticalSection(&g_cs);
    return ok;
}

}  // namespace

extern "C" {

// Совместимо с автоопределением cdecl в injector (имена без ведущего '_')
__declspec(dllexport) void __cdecl initialize(void) {
    // Намеренно пусто: вызов реального initialize в WRD часто AV внутри DLL.
}

__declspec(dllexport) int __cdecl isAttached(void) {
    // Считаем, что execute-only сценарий допустим; инжектор не уйдёт в таймаут attach.
    return 1;
}

__declspec(dllexport) void __cdecl execute(const char* script) {
    if (!script) {
        return;
    }
    if (!EnsureBackend()) {
        OutputDebugStringA("[sonaria_wrd_executor_api] execute: backend DLL or execute export not found\n");
        return;
    }
    EnterCriticalSection(&g_cs);
    if (g_execute) {
        g_execute(script);
    }
    LeaveCriticalSection(&g_cs);
}

}  // extern "C"

BOOL WINAPI DllMain(HINSTANCE hinst, DWORD reason, LPVOID) {
    switch (reason) {
        case DLL_PROCESS_ATTACH:
            g_self = reinterpret_cast<HMODULE>(hinst);
            DisableThreadLibraryCalls(hinst);
            InitializeCriticalSection(&g_cs);
            break;
        case DLL_PROCESS_DETACH:
            EnterCriticalSection(&g_cs);
            g_execute = nullptr;
            if (g_backend) {
                FreeLibrary(g_backend);
                g_backend = nullptr;
            }
            LeaveCriticalSection(&g_cs);
            DeleteCriticalSection(&g_cs);
            break;
        default:
            break;
    }
    return TRUE;
}
