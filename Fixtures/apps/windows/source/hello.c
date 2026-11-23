// Fixture: a tiny Windows GUI program with no C runtime.
// Imports kernel32 directly and user32 through a delay-load (the helper is a stub).
__declspec(dllimport) void __stdcall ExitProcess(unsigned int code);
__declspec(dllimport) unsigned long __stdcall GetTickCount(void);
__declspec(dllimport) int __stdcall MessageBoxW(void *window, const unsigned short *text, const unsigned short *caption, unsigned int type);

void *__stdcall __delayLoadHelper2(const void *descriptor, void **slot) { return 0; }

void entry(void) {
    if (GetTickCount() == 1) MessageBoxW(0, u"Hello", u"Greece", 0);
    ExitProcess(0);
}
