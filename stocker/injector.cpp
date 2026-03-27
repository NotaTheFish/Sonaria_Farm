// injector.cpp
// Компилировать из корня репозитория:
//   cl /std:c++17 /EHsc /O2 stocker\injector.cpp /Fe:stocker\build\injector.exe /link user32.lib kernel32.lib

#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <unordered_map>

namespace fs = std::filesystem;

namespace {
constexpr DWORD kDefaultResponseTimeoutMs = 3000;

std::string Trim(std::string s) {
    auto not_space = [](unsigned char ch) { return !std::isspace(ch); };
    s.erase(s.begin(), std::find_if(s.begin(), s.end(), not_space));
    s.erase(std::find_if(s.rbegin(), s.rend(), not_space).base(), s.end());
    return s;
}

std::string TrimQuotes(std::string s) {
    s = Trim(std::move(s));
    if (s.size() >= 2 && ((s.front() == '"' && s.back() == '"') || (s.front() == '\'' && s.back() == '\''))) {
        return s.substr(1, s.size() - 2);
    }
    return s;
}

std::string JsonEscape(const std::string& s) {
    std::ostringstream out;
    for (unsigned char c : s) {
        switch (c) {
            case '\\':
                out << "\\\\";
                break;
            case '"':
                out << "\\\"";
                break;
            case '\n':
                out << "\\n";
                break;
            case '\r':
                out << "\\r";
                break;
            case '\t':
                out << "\\t";
                break;
            default:
                out << static_cast<char>(c);
                break;
        }
    }
    return out.str();
}

void PrintJsonResult(bool ok, DWORD pid, const std::string& message, const std::string& extra_json = "") {
    std::cout << "{"
              << "\"ok\":" << (ok ? "true" : "false")
              << ",\"pid\":" << pid
              << ",\"message\":\"" << JsonEscape(message) << "\"";
    if (!extra_json.empty()) {
        std::cout << "," << extra_json;
    }
    std::cout << "}" << std::endl;
}

std::unordered_map<std::string, std::string> LoadDotEnv(const fs::path& env_path) {
    std::unordered_map<std::string, std::string> env_values;
    std::ifstream in(env_path);
    if (!in) {
        return env_values;
    }
    std::string line;
    while (std::getline(in, line)) {
        auto cleaned = Trim(line);
        if (cleaned.empty() || cleaned[0] == '#') {
            continue;
        }
        const auto eq_pos = cleaned.find('=');
        if (eq_pos == std::string::npos || eq_pos == 0) {
            continue;
        }
        auto key = Trim(cleaned.substr(0, eq_pos));
        auto value = TrimQuotes(cleaned.substr(eq_pos + 1));
        env_values[key] = value;
    }
    return env_values;
}

std::string GetSetting(
    const char* key,
    const std::unordered_map<std::string, std::string>& dot_env,
    const std::string& fallback = ""
) {
    const char* from_env = std::getenv(key);
    if (from_env && *from_env) {
        return TrimQuotes(from_env);
    }
    auto it = dot_env.find(key);
    if (it != dot_env.end() && !it->second.empty()) {
        return TrimQuotes(it->second);
    }
    return fallback;
}

DWORD FindRobloxPid() {
    DWORD pid = 0;
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) {
        return 0;
    }
    PROCESSENTRY32 pe;
    pe.dwSize = sizeof(pe);
    if (Process32First(snap, &pe)) {
        do {
            if (_stricmp(pe.szExeFile, "RobloxPlayerBeta.exe") == 0) {
                pid = pe.th32ProcessID;
                break;
            }
        } while (Process32Next(snap, &pe));
    }
    CloseHandle(snap);
    return pid;
}

bool InjectDllByPath(DWORD pid, const std::string& dll_path, std::string& error) {
    HANDLE h_process = OpenProcess(
        PROCESS_CREATE_THREAD | PROCESS_QUERY_INFORMATION | PROCESS_VM_OPERATION | PROCESS_VM_WRITE | PROCESS_VM_READ,
        FALSE,
        pid
    );
    if (!h_process) {
        error = "OpenProcess failed: " + std::to_string(GetLastError());
        return false;
    }

    const size_t bytes = dll_path.size() + 1;
    LPVOID remote_mem = VirtualAllocEx(h_process, nullptr, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    if (!remote_mem) {
        error = "VirtualAllocEx failed: " + std::to_string(GetLastError());
        CloseHandle(h_process);
        return false;
    }

    SIZE_T written = 0;
    if (!WriteProcessMemory(h_process, remote_mem, dll_path.c_str(), bytes, &written) || written != bytes) {
        error = "WriteProcessMemory failed: " + std::to_string(GetLastError());
        VirtualFreeEx(h_process, remote_mem, 0, MEM_RELEASE);
        CloseHandle(h_process);
        return false;
    }

    auto load_library = reinterpret_cast<LPTHREAD_START_ROUTINE>(
        GetProcAddress(GetModuleHandleA("kernel32.dll"), "LoadLibraryA")
    );
    if (!load_library) {
        error = "GetProcAddress(LoadLibraryA) failed.";
        VirtualFreeEx(h_process, remote_mem, 0, MEM_RELEASE);
        CloseHandle(h_process);
        return false;
    }

    HANDLE h_thread = CreateRemoteThread(h_process, nullptr, 0, load_library, remote_mem, 0, nullptr);
    if (!h_thread) {
        error = "CreateRemoteThread failed: " + std::to_string(GetLastError());
        VirtualFreeEx(h_process, remote_mem, 0, MEM_RELEASE);
        CloseHandle(h_process);
        return false;
    }

    const DWORD wait_res = WaitForSingleObject(h_thread, kDefaultResponseTimeoutMs);
    if (wait_res != WAIT_OBJECT_0) {
        error = "WaitForSingleObject timed out or failed: " + std::to_string(GetLastError());
        CloseHandle(h_thread);
        VirtualFreeEx(h_process, remote_mem, 0, MEM_RELEASE);
        CloseHandle(h_process);
        return false;
    }

    DWORD remote_module = 0;
    GetExitCodeThread(h_thread, &remote_module);
    CloseHandle(h_thread);
    VirtualFreeEx(h_process, remote_mem, 0, MEM_RELEASE);
    CloseHandle(h_process);
    if (remote_module == 0) {
        error = "LoadLibraryA returned null in remote process.";
        return false;
    }
    return true;
}
}  // namespace

int main(int argc, char* argv[]) {
    if (argc < 3) {
        PrintJsonResult(false, 0, "Usage: injector.exe <PID|0|auto> <script.lua> [json_args]");
        return 1;
    }

    const fs::path exe_path = fs::path(argv[0]).lexically_normal();
    const fs::path exe_dir = exe_path.has_parent_path() ? exe_path.parent_path() : fs::current_path();
    const fs::path repo_root = fs::weakly_canonical(exe_dir / ".." / "..");
    const auto dot_env = LoadDotEnv(repo_root / ".env");

    DWORD pid = 0;
    std::string pid_arg = argv[1];
    std::transform(pid_arg.begin(), pid_arg.end(), pid_arg.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (pid_arg == "auto" || pid_arg == "0") {
        pid = FindRobloxPid();
    } else {
        pid = static_cast<DWORD>(std::strtoul(argv[1], nullptr, 10));
    }
    if (pid == 0) {
        PrintJsonResult(false, 0, "Roblox process not found.");
        return 1;
    }

    std::string dll_raw = GetSetting("INJECT_DLL_PATH", dot_env, "stocker/inject.dll");
    fs::path dll_path = fs::path(dll_raw);
    if (!dll_path.is_absolute()) {
        dll_path = repo_root / dll_path;
    }
    dll_path = fs::weakly_canonical(dll_path);
    if (!fs::exists(dll_path)) {
        PrintJsonResult(false, pid, "Cannot open inject DLL.", "\"inject_dll\":\"" + JsonEscape(dll_path.string()) + "\"");
        return 1;
    }

    const fs::path script_path = fs::weakly_canonical(fs::path(argv[2]));
    if (!fs::exists(script_path)) {
        PrintJsonResult(false, pid, "Script file not found.", "\"script_path\":\"" + JsonEscape(script_path.string()) + "\"");
        return 1;
    }

    const std::string json_args = (argc >= 4) ? argv[3] : "{}";
    (void)json_args;

    std::string error;
    if (!InjectDllByPath(pid, dll_path.string(), error)) {
        PrintJsonResult(false, pid, error, "\"inject_dll\":\"" + JsonEscape(dll_path.string()) + "\"");
        return 1;
    }

    PrintJsonResult(
        true,
        pid,
        "DLL injected successfully.",
        "\"inject_dll\":\"" + JsonEscape(dll_path.string()) + "\",\"script_path\":\"" + JsonEscape(script_path.string()) + "\""
    );
    return 0;
}