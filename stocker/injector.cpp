// injector.cpp
// Компилировать из корня репозитория:
//   cl /std:c++17 /EHsc /O2 stocker\injector.cpp /Fe:stocker\build\injector.exe /link user32.lib kernel32.lib

#include <windows.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>

namespace fs = std::filesystem;

namespace {
constexpr DWORD kDefaultResponseTimeoutMs = 3000;
constexpr DWORD kDefaultLuaResponseTimeoutMs = 45000;
constexpr DWORD kDefaultAttachTimeoutMs = 20000;

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

std::string ReadTextFileUtf8(const fs::path& path) {
    std::ifstream in(path, std::ios::binary);
    if (!in) {
        return {};
    }
    std::ostringstream ss;
    ss << in.rdbuf();
    return ss.str();
}

std::string UpsertTopLevelJsonStringField(std::string json, const std::string& key, const std::string& value) {
    const auto trimmed = Trim(json);
    if (trimmed.empty() || trimmed.front() != '{' || trimmed.back() != '}') {
        return "{\"" + JsonEscape(key) + "\":\"" + JsonEscape(value) + "\"}";
    }
    const std::string key_token = "\"" + key + "\"";
    const auto key_pos = trimmed.find(key_token);
    if (key_pos != std::string::npos) {
        const auto colon_pos = trimmed.find(':', key_pos + key_token.size());
        if (colon_pos != std::string::npos) {
            size_t value_start = colon_pos + 1;
            while (value_start < trimmed.size() && std::isspace(static_cast<unsigned char>(trimmed[value_start]))) {
                ++value_start;
            }
            size_t value_end = value_start;
            bool in_string = false;
            bool escape = false;
            int depth = 0;
            while (value_end < trimmed.size()) {
                const char c = trimmed[value_end];
                if (in_string) {
                    if (escape) {
                        escape = false;
                    } else if (c == '\\') {
                        escape = true;
                    } else if (c == '"') {
                        in_string = false;
                    }
                } else {
                    if (c == '"') {
                        in_string = true;
                    } else if (c == '{' || c == '[') {
                        ++depth;
                    } else if (c == '}' || c == ']') {
                        if (depth == 0) {
                            break;
                        }
                        --depth;
                    } else if (c == ',' && depth == 0) {
                        break;
                    }
                }
                ++value_end;
            }
            std::string updated = trimmed.substr(0, value_start);
            updated += "\"" + JsonEscape(value) + "\"";
            updated += trimmed.substr(value_end);
            return updated;
        }
    }
    std::string updated = trimmed;
    if (updated.size() >= 2) {
        if (updated == "{}") {
            updated = "{\"" + JsonEscape(key) + "\":\"" + JsonEscape(value) + "\"}";
        } else {
            updated.pop_back();  // remove trailing }
            updated += ",\"" + JsonEscape(key) + "\":\"" + JsonEscape(value) + "\"}";
        }
    }
    return updated;
}

std::string ToLuaLongBracket(const std::string& s) {
    for (int level = 0; level <= 8; ++level) {
        const std::string marker(level, '=');
        const std::string open = "[" + marker + "[";
        const std::string close = "]" + marker + "]";
        if (s.find(close) == std::string::npos) {
            return open + s + close;
        }
    }
    std::ostringstream out;
    out << "\"";
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
    out << "\"";
    return out.str();
}

std::string BuildLuaPayload(const std::string& script_text, const std::string& params_json) {
    const std::string script_lit = ToLuaLongBracket(script_text);
    const std::string params_lit = ToLuaLongBracket(params_json);
    std::ostringstream out;
    out << "local __sonaria_script = " << script_lit << "\n";
    out << "local __sonaria_args_json = " << params_lit << "\n";
    out << "local __fn, __err = loadstring(__sonaria_script)\n";
    out << "if not __fn then error('loadstring failed: ' .. tostring(__err)) end\n";
    out << "return __fn(__sonaria_args_json)\n";
    return out.str();
}

DWORD ParseDwordSetting(const std::string& raw, DWORD fallback) {
    if (raw.empty()) {
        return fallback;
    }
    char* end_ptr = nullptr;
    const unsigned long parsed = std::strtoul(raw.c_str(), &end_ptr, 10);
    if (end_ptr == raw.c_str()) {
        return fallback;
    }
    if (parsed == 0) {
        return fallback;
    }
    return static_cast<DWORD>(parsed);
}

bool WaitForFile(const fs::path& path, DWORD timeout_ms) {
    const auto start = std::chrono::steady_clock::now();
    while (true) {
        if (fs::exists(path) && fs::is_regular_file(path)) {
            return true;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - start
        );
        if (elapsed.count() >= static_cast<long long>(timeout_ms)) {
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(120));
    }
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

using LaunchExploitFn = void(__cdecl*)();
using IsInjectedFn = bool(__cdecl*)();
using SendLuaScriptFn = void(__cdecl*)(const char*);

bool ExecuteLuaViaExecutorApi(
    DWORD pid,
    const fs::path& api_dll_path,
    const fs::path& script_path,
    std::string json_args,
    DWORD response_timeout_ms,
    DWORD attach_timeout_ms,
    std::string& response_json,
    std::string& error
) {
    if (!fs::exists(api_dll_path)) {
        error = "Executor API DLL not found: " + api_dll_path.string();
        return false;
    }

    const std::string script_text = ReadTextFileUtf8(script_path);
    if (script_text.empty()) {
        error = "Lua script is empty or unreadable: " + script_path.string();
        return false;
    }

    const fs::path response_path = fs::temp_directory_path() / ("sonaria_response_" + std::to_string(pid) + ".json");
    std::error_code fs_ec;
    fs::remove(response_path, fs_ec);
    json_args = UpsertTopLevelJsonStringField(json_args, "response_file", response_path.string());

    const std::string lua_payload = BuildLuaPayload(script_text, json_args);

    HMODULE h_api = LoadLibraryA(api_dll_path.string().c_str());
    if (!h_api) {
        error = "LoadLibrary failed for executor API DLL: " + std::to_string(GetLastError());
        return false;
    }

    auto launch = reinterpret_cast<LaunchExploitFn>(GetProcAddress(h_api, "LaunchExploit"));
    auto is_injected = reinterpret_cast<IsInjectedFn>(GetProcAddress(h_api, "IsInjected"));
    auto send_script = reinterpret_cast<SendLuaScriptFn>(GetProcAddress(h_api, "SendLuaScript"));
    if (!launch || !is_injected || !send_script) {
        error = "Executor API exports not found (LaunchExploit/IsInjected/SendLuaScript).";
        FreeLibrary(h_api);
        return false;
    }

    launch();
    const auto attach_start = std::chrono::steady_clock::now();
    bool attached = false;
    while (true) {
        if (is_injected()) {
            attached = true;
            break;
        }
        const auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            std::chrono::steady_clock::now() - attach_start
        );
        if (elapsed.count() >= static_cast<long long>(attach_timeout_ms)) {
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }
    if (!attached) {
        error = "Executor did not attach to Roblox in time.";
        FreeLibrary(h_api);
        return false;
    }

    send_script(lua_payload.c_str());
    if (!WaitForFile(response_path, response_timeout_ms)) {
        error = "Lua response timeout (" + std::to_string(response_timeout_ms) + " ms).";
        FreeLibrary(h_api);
        return false;
    }

    response_json = ReadTextFileUtf8(response_path);
    fs::remove(response_path, fs_ec);
    if (response_json.empty()) {
        error = "Lua response file is empty: " + response_path.string();
        FreeLibrary(h_api);
        return false;
    }
    FreeLibrary(h_api);
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

    const fs::path script_path = fs::weakly_canonical(fs::path(argv[2]));
    if (!fs::exists(script_path)) {
        PrintJsonResult(false, pid, "Script file not found.", "\"script_path\":\"" + JsonEscape(script_path.string()) + "\"");
        return 1;
    }

    const std::string json_args = (argc >= 4) ? argv[3] : "{}";

    std::string api_raw = GetSetting("INJECTOR_EXECUTOR_API_PATH", dot_env, "stocker/wearedevs_exploit_api.dll");
    fs::path api_path = fs::path(api_raw);
    if (!api_path.is_absolute()) {
        api_path = repo_root / api_path;
    }
    api_path = fs::weakly_canonical(api_path);

    const DWORD response_timeout_ms = ParseDwordSetting(
        GetSetting("INJECTOR_RESPONSE_TIMEOUT_MS", dot_env, ""),
        kDefaultLuaResponseTimeoutMs
    );
    const DWORD attach_timeout_ms = ParseDwordSetting(
        GetSetting("INJECTOR_ATTACH_TIMEOUT_MS", dot_env, ""),
        kDefaultAttachTimeoutMs
    );

    std::string mode = GetSetting("INJECTOR_MODE", dot_env, "executor_api");
    std::transform(mode.begin(), mode.end(), mode.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });

    if (mode == "executor_api") {
        std::string response_json;
        std::string error;
        if (!ExecuteLuaViaExecutorApi(
                pid,
                api_path,
                script_path,
                json_args,
                response_timeout_ms,
                attach_timeout_ms,
                response_json,
                error
            )) {
            PrintJsonResult(
                false,
                pid,
                error,
                "\"script_path\":\"" + JsonEscape(script_path.string()) + "\",\"executor_api\":\"" + JsonEscape(api_path.string()) + "\""
            );
            return 1;
        }
        std::cout << "SONARIA_RESPONSE:" << response_json << std::endl;
        return 0;
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