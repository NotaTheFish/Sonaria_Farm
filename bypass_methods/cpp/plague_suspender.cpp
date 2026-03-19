// bypass/plague_suspender.cpp
#include <windows.h>
#include <tlhelp32.h>
#include <vector>

// Код из репозитория Baifron
class PlagueSuspender {
private:
    std::vector<DWORD> GetRobloxThreads() {
        std::vector<DWORD> threads;
        HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        
        if (hSnapshot != INVALID_HANDLE_VALUE) {
            THREADENTRY32 te;
            te.dwSize = sizeof(te);
            
            DWORD robloxPID = FindRobloxProcess();
            
            if (Thread32First(hSnapshot, &te)) {
                do {
                    if (te.th32OwnerProcessID == robloxPID) {
                        threads.push_back(te.th32ThreadID);
                    }
                } while (Thread32Next(hSnapshot, &te));
            }
            CloseHandle(hSnapshot);
        }
        return threads;
    }
    
public:
    void SuspendByfronThreads() {
        auto threads = GetRobloxThreads();
        
        for (DWORD tid : threads) {
            HANDLE hThread = OpenThread(THREAD_SUSPEND_RESUME, FALSE, tid);
            if (hThread) {
                // Приостанавливаем потоки, которые могут быть связаны с Byfron
                SuspendThread(hThread);
                CloseHandle(hThread);
            }
        }
    }
};