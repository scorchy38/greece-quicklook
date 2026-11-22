// Fixture: a tiny ARM64 DLL with named exports and one export by ordinal only (see greece.def).
int greece_add(int a, int b) { return a + b; }
int greece_answer(void) { return 42; }
int greece_secret(void) { return 7; }
int __stdcall DllMain(void *instance, unsigned long reason, void *reserved) { return 1; }
