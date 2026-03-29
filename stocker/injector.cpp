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
#include <iterator>
#include <sstream>
#include <string>
#include <thread>
#include <unordered_map>
#include <vector>

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

// -1 = inherit global stdcall_mode; 0 = cdecl; 1 = stdcall; 2 = infer from export name (_prefix)
int ParseCallconvOverride(const std::string& raw) {
    if (raw.empty()) {
        return -1;
    }
    std::string s = Trim(raw);
    std::transform(s.begin(), s.end(), s.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    if (s == "cdecl") {
        return 0;
    }
    if (s == "stdcall") {
        return 1;
    }
    if (s == "auto" || s == "from_export" || s == "from_name") {
        return 2;
    }
    return -1;
}

bool EffectiveStdcall(int override_mode, bool global_stdcall, const std::string& export_name) {
    if (override_mode == 0) {
        return false;
    }
    if (override_mode == 1) {
        return true;
    }
    if (override_mode == 2) {
        return !export_name.empty() && export_name.front() == '_';
    }
    return global_stdcall;
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

std::vector<std::string> ListDllExportNames(const fs::path& dll_path, size_t max_names, std::string& error) {
    error.clear();
    std::ifstream in(dll_path, std::ios::binary);
    if (!in) {
        error = "Cannot open DLL for export scan: " + dll_path.string();
        return {};
    }
    std::vector<unsigned char> buf((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    if (buf.size() < sizeof(IMAGE_DOS_HEADER)) {
        error = "DLL too small for DOS header.";
        return {};
    }
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(buf.data());
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) {
        error = "Invalid DOS signature.";
        return {};
    }
    const size_t nt_off = static_cast<size_t>(dos->e_lfanew);
    if (nt_off + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER) > buf.size()) {
        error = "Invalid NT header offset.";
        return {};
    }
    const DWORD sig = *reinterpret_cast<const DWORD*>(buf.data() + nt_off);
    if (sig != IMAGE_NT_SIGNATURE) {
        error = "Invalid NT signature.";
        return {};
    }
    const auto* file_hdr = reinterpret_cast<const IMAGE_FILE_HEADER*>(buf.data() + nt_off + sizeof(DWORD));
    const auto opt_off = nt_off + sizeof(DWORD) + sizeof(IMAGE_FILE_HEADER);
    if (opt_off + file_hdr->SizeOfOptionalHeader > buf.size()) {
        error = "Optional header out of bounds.";
        return {};
    }

    bool is64 = false;
    IMAGE_DATA_DIRECTORY export_dir{};
    std::vector<IMAGE_SECTION_HEADER> sections;

    const WORD magic = *reinterpret_cast<const WORD*>(buf.data() + opt_off);
    if (magic == IMAGE_NT_OPTIONAL_HDR64_MAGIC) {
        is64 = true;
        const auto* opt = reinterpret_cast<const IMAGE_OPTIONAL_HEADER64*>(buf.data() + opt_off);
        export_dir = opt->DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        const auto sec_off = opt_off + file_hdr->SizeOfOptionalHeader;
        const size_t sec_bytes = static_cast<size_t>(file_hdr->NumberOfSections) * sizeof(IMAGE_SECTION_HEADER);
        if (sec_off + sec_bytes > buf.size()) {
            error = "Section headers out of bounds.";
            return {};
        }
        sections.assign(
            reinterpret_cast<const IMAGE_SECTION_HEADER*>(buf.data() + sec_off),
            reinterpret_cast<const IMAGE_SECTION_HEADER*>(buf.data() + sec_off + sec_bytes)
        );
    } else if (magic == IMAGE_NT_OPTIONAL_HDR32_MAGIC) {
        is64 = false;
        const auto* opt = reinterpret_cast<const IMAGE_OPTIONAL_HEADER32*>(buf.data() + opt_off);
        export_dir = opt->DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
        const auto sec_off = opt_off + file_hdr->SizeOfOptionalHeader;
        const size_t sec_bytes = static_cast<size_t>(file_hdr->NumberOfSections) * sizeof(IMAGE_SECTION_HEADER);
        if (sec_off + sec_bytes > buf.size()) {
            error = "Section headers out of bounds.";
            return {};
        }
        sections.assign(
            reinterpret_cast<const IMAGE_SECTION_HEADER*>(buf.data() + sec_off),
            reinterpret_cast<const IMAGE_SECTION_HEADER*>(buf.data() + sec_off + sec_bytes)
        );
    } else {
        error = "Unknown optional header magic.";
        return {};
    }
    (void)is64;

    auto rva_to_ptr = [&](DWORD rva, size_t size) -> const unsigned char* {
        for (const auto& s : sections) {
            const DWORD va = s.VirtualAddress;
            const DWORD raw = s.PointerToRawData;
            const DWORD raw_size = s.SizeOfRawData;
            if (rva >= va && rva < va + raw_size) {
                const size_t off = static_cast<size_t>(raw + (rva - va));
                if (off + size <= buf.size()) {
                    return buf.data() + off;
                }
                return nullptr;
            }
        }
        return nullptr;
    };

    if (export_dir.VirtualAddress == 0 || export_dir.Size < sizeof(IMAGE_EXPORT_DIRECTORY)) {
        error = "No export directory.";
        return {};
    }
    const auto* exp = reinterpret_cast<const IMAGE_EXPORT_DIRECTORY*>(
        rva_to_ptr(export_dir.VirtualAddress, sizeof(IMAGE_EXPORT_DIRECTORY))
    );
    if (!exp) {
        error = "Export directory out of bounds.";
        return {};
    }
    const auto* names = reinterpret_cast<const DWORD*>(
        rva_to_ptr(exp->AddressOfNames, static_cast<size_t>(exp->NumberOfNames) * sizeof(DWORD))
    );
    if (!names) {
        error = "Export names table out of bounds.";
        return {};
    }

    std::vector<std::string> out;
    const size_t count = std::min<size_t>(exp->NumberOfNames, max_names);
    out.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const DWORD name_rva = names[i];
        const unsigned char* p = rva_to_ptr(name_rva, 1);
        if (!p) {
            continue;
        }
        const unsigned char* end = buf.data() + buf.size();
        std::string s;
        while (p < end && *p != 0) {
            s.push_back(static_cast<char>(*p));
            ++p;
            if (s.size() > 2000) {
                break;
            }
        }
        if (!s.empty()) {
            out.push_back(std::move(s));
        }
    }
    return out;
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
using SendLuaScriptFn = void(__cdecl*)(const char*);
using AddScriptFn = void(__cdecl*)(const char*);
using ExecuteNoArgFn = void(__cdecl*)();
using LaunchExploitStdFn = void(__stdcall*)();
using IsInjectedStdFn = int(__stdcall*)();
using SendLuaScriptStdFn = void(__stdcall*)(const char*);
using AddScriptStdFn = void(__stdcall*)(const char*);
using ExecuteNoArgStdFn = void(__stdcall*)();

FARPROC GetProcAddressAny(HMODULE mod, const std::vector<const char*>& names, std::string& found) {
    found.clear();
    for (const char* n : names) {
        if (!n || !*n) {
            continue;
        }
        FARPROC p = GetProcAddress(mod, n);
        if (p) {
            found = n;
            return p;
        }
    }
    return nullptr;
}

// SEH must live in functions without C++ unwinding (MSVC C2712).
DWORD UnsafeCallInitializeRaw(FARPROC p, int stdcall_flag) {
    DWORD code = 0;
    __try {
        if (stdcall_flag) {
            reinterpret_cast<LaunchExploitStdFn>(p)();
        } else {
            reinterpret_cast<LaunchExploitFn>(p)();
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        code = GetExceptionCode();
    }
    return code;
}

DWORD UnsafeCallIsAttachedRaw(FARPROC p, int stdcall_flag, int* out_nonzero) {
    DWORD code = 0;
    int v = 0;
    __try {
        if (stdcall_flag) {
            v = reinterpret_cast<IsInjectedStdFn>(p)();
        } else {
            v = reinterpret_cast<int(__cdecl*)()>(p)();
        }
    } __except (EXCEPTION_EXECUTE_HANDLER) {
        code = GetExceptionCode();
    }
    if (code == 0 && out_nonzero) {
        *out_nonzero = v;
    }
    return code;
}

bool SafeCallInitialize(FARPROC p, bool stdcall, std::string& error) {
    const DWORD seh = UnsafeCallInitializeRaw(p, stdcall ? 1 : 0);
    if (seh != 0) {
        std::ostringstream msg;
        msg << "initialize() raised SEH 0x" << std::hex << seh;
        error = msg.str();
        return false;
    }
    return true;
}

bool SafeCallIsAttached(FARPROC p, bool stdcall, bool& out_bool, std::string& error) {
    int v = 0;
    const DWORD seh = UnsafeCallIsAttachedRaw(p, stdcall ? 1 : 0, &v);
    if (seh != 0) {
        std::ostringstream msg;
        msg << "isAttached() raised SEH 0x" << std::hex << seh;
        error = msg.str();
        return false;
    }
    out_bool = (v != 0);
    return true;
}

bool ExecuteLuaViaExecutorApi(
    DWORD pid,
    const fs::path& api_dll_path,
    const fs::path& script_path,
    std::string json_args,
    DWORD response_timeout_ms,
    DWORD attach_timeout_ms,
    bool skip_initialize,
    bool skip_is_attached,
    bool allow_unattached_execute,
    bool safe_mode,
    bool execute_only_mode,
    bool force_stdcall,
    bool force_cdecl,
    bool trace_steps,
    const std::string& initialize_export_override,
    const std::string& isattached_export_override,
    int initialize_callconv_override,
    int isattached_callconv_override,
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
    if (trace_steps) {
        std::cout << "[injector] executor_api: dll loaded: " << api_dll_path.string() << std::endl;
    }

    std::string launch_name;
    std::string injected_name;
    std::string send_name;
    FARPROC launch_p = nullptr;
    if (!initialize_export_override.empty()) {
        launch_p = GetProcAddress(h_api, initialize_export_override.c_str());
        launch_name = initialize_export_override;
        if (!launch_p) {
            error = "INJECTOR_EXECUTOR_INITIALIZE_EXPORT not found in DLL: \"" + JsonEscape(initialize_export_override) + "\"";
            FreeLibrary(h_api);
            return false;
        }
    } else {
        launch_p = GetProcAddressAny(
            h_api,
            {
                "initialize",
                "Initialize",
                "_initialize@0",
                "LaunchExploit",
                "_LaunchExploit@0",
                "launchExploit",
                "LAUNCH_EXPLOIT",
                "Init",
                "init",
                "StartExploit",
            },
            launch_name
        );
    }
    FARPROC injected_p = nullptr;
    if (!isattached_export_override.empty()) {
        injected_p = GetProcAddress(h_api, isattached_export_override.c_str());
        injected_name = isattached_export_override;
        if (!injected_p) {
            error = "INJECTOR_EXECUTOR_ISATTACHED_EXPORT not found in DLL: \"" + JsonEscape(isattached_export_override) + "\"";
            FreeLibrary(h_api);
            return false;
        }
    } else {
        injected_p = GetProcAddressAny(
            h_api,
            {
                "isAttached",
                "IsAttached",
                "_isAttached@0",
                "IsInjected",
                "_IsInjected@0",
                "isInjected",
                "IS_INJECTED",
                "IsReady",
                "attached",
            },
            injected_name
        );
    }
    FARPROC send_p = GetProcAddressAny(
        h_api,
        {
            "execute",
            "Execute",
            "_execute@4",
            "SendLuaScript",
            "_SendLuaScript@4",
            "SendScript",
            "_SendScript@4",
            "ExecuteScript",
            "_ExecuteScript@4",
        },
        send_name
    );
    std::string add_name;
    FARPROC add_p = GetProcAddressAny(
        h_api,
        {
            "add",
            "Add",
            "_add@4",
            "AddScript",
            "_AddScript@4",
        },
        add_name
    );
    std::string execute_noarg_name;
    FARPROC execute_noarg_p = GetProcAddressAny(
        h_api,
        {
            "execute",
            "Execute",
            "_execute@0",
            "_Execute@0",
        },
        execute_noarg_name
    );

    if (!launch_p || !injected_p || !send_p) {
        std::string scan_err;
        const auto exports = ListDllExportNames(api_dll_path, 60, scan_err);
        std::ostringstream msg;
        msg << "Executor API exports not found. "
            << "launch=" << (launch_p ? launch_name : "null")
            << " injected=" << (injected_p ? injected_name : "null")
            << " send=" << (send_p ? send_name : "null");
        if (!exports.empty()) {
            msg << " available_exports=[";
            for (size_t i = 0; i < exports.size(); ++i) {
                if (i) {
                    msg << ",";
                }
                msg << "\"" << JsonEscape(exports[i]) << "\"";
            }
            msg << "]";
        } else if (!scan_err.empty()) {
            msg << " export_scan_error=" << scan_err;
        }
        error = msg.str();
        FreeLibrary(h_api);
        return false;
    }

    bool stdcall_mode = (!launch_name.empty() && launch_name.front() == '_')
                        || (!injected_name.empty() && injected_name.front() == '_')
                        || (!send_name.empty() && send_name.front() == '_');
    if (force_stdcall) {
        stdcall_mode = true;
    }
    if (force_cdecl) {
        stdcall_mode = false;
    }
    const bool init_stdcall = EffectiveStdcall(initialize_callconv_override, stdcall_mode, launch_name);
    const bool attach_stdcall = EffectiveStdcall(isattached_callconv_override, stdcall_mode, injected_name);
    if (trace_steps) {
        std::cout << "[injector] executor_api: resolved launch=" << launch_name
                  << " isAttached=" << injected_name
                  << " execute=" << send_name
                  << " add=" << (add_name.empty() ? "-" : add_name)
                  << " execute0=" << (execute_noarg_name.empty() ? "-" : execute_noarg_name)
                  << " stdcall_mode=" << (stdcall_mode ? "1" : "0")
                  << " init_stdcall=" << (init_stdcall ? "1" : "0")
                  << " attach_stdcall=" << (attach_stdcall ? "1" : "0")
                  << std::endl;
    }
    const bool wrd_ambiguous_signature =
        (send_name == "execute" && add_name == "add" && execute_noarg_name == "execute");

    auto send_cdecl = reinterpret_cast<SendLuaScriptFn>(send_p);
    auto send_std = reinterpret_cast<SendLuaScriptStdFn>(send_p);
    auto add_cdecl = reinterpret_cast<AddScriptFn>(add_p);
    auto add_std = reinterpret_cast<AddScriptStdFn>(add_p);
    auto exec0_cdecl = reinterpret_cast<ExecuteNoArgFn>(execute_noarg_p);
    auto exec0_std = reinterpret_cast<ExecuteNoArgStdFn>(execute_noarg_p);

    bool skip_initialize_effective = skip_initialize || execute_only_mode;
    if (!skip_initialize_effective && safe_mode && wrd_ambiguous_signature) {
        skip_initialize_effective = true;
        if (trace_steps) {
            std::cout << "[injector] executor_api: safe_mode enabled, skipping initialize() for ambiguous WRD signature" << std::endl;
        }
    }

    if (!skip_initialize_effective) {
        if (trace_steps) {
            std::cout << "[injector] executor_api: calling initialize" << std::endl;
        }
        if (!SafeCallInitialize(launch_p, init_stdcall, error)) {
            FreeLibrary(h_api);
            return false;
        }
    } else if (trace_steps) {
        if (skip_initialize) {
            std::cout << "[injector] executor_api: skip initialize by config" << std::endl;
        }
    }
    bool attached = false;
    bool skip_is_attached_effective = skip_is_attached || execute_only_mode;
    if (execute_only_mode && trace_steps) {
        std::cout << "[injector] executor_api: execute_only mode, skipping initialize()/isAttached()" << std::endl;
    }
    if (!skip_is_attached_effective && safe_mode && wrd_ambiguous_signature) {
        skip_is_attached_effective = true;
        if (trace_steps) {
            std::cout << "[injector] executor_api: safe_mode enabled, skipping isAttached() for ambiguous WRD signature" << std::endl;
        }
    }
    const auto attach_start = std::chrono::steady_clock::now();
    if (!skip_is_attached_effective) {
        while (true) {
            bool injected = false;
            if (!SafeCallIsAttached(injected_p, attach_stdcall, injected, error)) {
                FreeLibrary(h_api);
                return false;
            }
            if (injected) {
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
    } else if (trace_steps) {
        if (skip_is_attached) {
            std::cout << "[injector] executor_api: skip isAttached polling by config" << std::endl;
        }
    }
    if (skip_is_attached_effective && safe_mode && !skip_is_attached && wrd_ambiguous_signature && !skip_initialize_effective) {
        // WRD wrappers with ambiguous execute exports may crash on isAttached().
        // In safe mode treat initialize() as attach trigger and proceed.
        std::this_thread::sleep_for(std::chrono::milliseconds(650));
        attached = true;
        if (trace_steps) {
            std::cout << "[injector] executor_api: assuming attached after initialize (safe_mode fallback)" << std::endl;
        }
    }
    if (trace_steps) {
        std::cout << "[injector] executor_api: isAttached=" << (attached ? "true" : "false") << std::endl;
    }

    const bool allow_unattached_execute_effective = allow_unattached_execute || execute_only_mode;
    if (!attached) {
        if (safe_mode && wrd_ambiguous_signature && skip_initialize_effective && !allow_unattached_execute) {
            error = "Safe mode blocked initialize/isAttached for ambiguous WRD wrapper; attach state is unknown. "
                    "Set INJECTOR_EXECUTOR_ALLOW_UNATTACHED_EXECUTE=1 to try execute anyway (unsafe).";
            FreeLibrary(h_api);
            return false;
        }
        if (!allow_unattached_execute_effective) {
            error = "Executor not attached (isAttached=false). "
                    "Set INJECTOR_EXECUTOR_ALLOW_UNATTACHED_EXECUTE=1 to override (unsafe).";
            FreeLibrary(h_api);
            return false;
        }
        if (trace_steps) {
            std::cout << "[injector] executor_api: proceeding with execute despite not attached (unsafe override)" << std::endl;
        }
    }

    if (trace_steps) {
        std::cout << "[injector] executor_api: calling execute" << std::endl;
    }
    const bool execute0_is_distinct = (execute_noarg_p != nullptr && execute_noarg_p != send_p);
    const bool execute0_explicit_noarg = (execute_noarg_name == "_execute@0" || execute_noarg_name == "_Execute@0");
    const bool use_add_execute_flow = (add_p != nullptr && execute_noarg_p != nullptr && (execute0_is_distinct || execute0_explicit_noarg));
    if (use_add_execute_flow) {
        if (trace_steps) {
            std::cout << "[injector] executor_api: using add(script)+execute() flow" << std::endl;
        }
        if (stdcall_mode) {
            add_std(lua_payload.c_str());
            exec0_std();
        } else {
            add_cdecl(lua_payload.c_str());
            exec0_cdecl();
        }
    } else {
        if (trace_steps) {
            if (add_p != nullptr && execute_noarg_p != nullptr && !execute0_is_distinct && !execute0_explicit_noarg) {
                std::cout << "[injector] executor_api: execute0 export ambiguous, fallback to execute(script) flow" << std::endl;
            } else {
                std::cout << "[injector] executor_api: using execute(script) flow" << std::endl;
            }
        }
        if (stdcall_mode) {
            send_std(lua_payload.c_str());
        } else {
            send_cdecl(lua_payload.c_str());
        }
    }
    if (!WaitForFile(response_path, response_timeout_ms)) {
        if (!attached) {
            error = "Executor not attached and no Lua response in timeout (" + std::to_string(response_timeout_ms) + " ms).";
        } else {
            error = "Lua response timeout (" + std::to_string(response_timeout_ms) + " ms).";
        }
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
    const bool skip_initialize = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_SKIP_INITIALIZE", dot_env, "0"),
        0
    ) != 0;
    const bool skip_is_attached = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_SKIP_ISATTACHED", dot_env, "0"),
        0
    ) != 0;
    const bool allow_unattached_execute = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_ALLOW_UNATTACHED_EXECUTE", dot_env, "0"),
        0
    ) != 0;
    const bool safe_mode = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_SAFE_MODE", dot_env, "1"),
        1
    ) != 0;
    const bool execute_only_mode = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_EXECUTE_ONLY", dot_env, "0"),
        0
    ) != 0;
    std::string callconv = GetSetting("INJECTOR_EXECUTOR_CALLCONV", dot_env, "auto");
    std::transform(callconv.begin(), callconv.end(), callconv.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    const bool force_stdcall = (callconv == "stdcall");
    const bool force_cdecl = (callconv == "cdecl");
    const bool trace_steps = ParseDwordSetting(
        GetSetting("INJECTOR_EXECUTOR_TRACE_STEPS", dot_env, "1"),
        1
    ) != 0;
    const std::string initialize_export = GetSetting("INJECTOR_EXECUTOR_INITIALIZE_EXPORT", dot_env, "");
    const std::string isattached_export = GetSetting("INJECTOR_EXECUTOR_ISATTACHED_EXPORT", dot_env, "");
    const int initialize_callconv = ParseCallconvOverride(GetSetting("INJECTOR_EXECUTOR_INITIALIZE_CALLCONV", dot_env, ""));
    const int isattached_callconv = ParseCallconvOverride(GetSetting("INJECTOR_EXECUTOR_ISATTACHED_CALLCONV", dot_env, ""));

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
                skip_initialize,
                skip_is_attached,
                allow_unattached_execute,
                safe_mode,
                execute_only_mode,
                force_stdcall,
                force_cdecl,
                trace_steps,
                initialize_export,
                isattached_export,
                initialize_callconv,
                isattached_callconv,
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