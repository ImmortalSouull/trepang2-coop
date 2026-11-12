"""Stacks of a hung game, unwound with dbghelp's StackWalk64 (uses each module's .pdata; no symbols).
Prints module+RVA per frame, so RVAs can go to natives.py / disasm.py.
Usage: python hangstack.py <pid> [max_threads] [max_frames]
"""
import ctypes
import ctypes.wintypes as wt
import sys

pid = int(sys.argv[1])
maxthreads = int(sys.argv[2]) if len(sys.argv) > 2 else 8
maxframes = int(sys.argv[3]) if len(sys.argv) > 3 else 30
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
psapi = ctypes.WinDLL("psapi", use_last_error=True)
dbg = ctypes.WinDLL("dbghelp", use_last_error=True)


class M128A(ctypes.Structure):
    _fields_ = [("Low", ctypes.c_ulonglong), ("High", ctypes.c_longlong)]


class CONTEXT(ctypes.Structure):
    _fields_ = [("P1Home", ctypes.c_ulonglong), ("P2Home", ctypes.c_ulonglong), ("P3Home", ctypes.c_ulonglong),
                ("P4Home", ctypes.c_ulonglong), ("P5Home", ctypes.c_ulonglong), ("P6Home", ctypes.c_ulonglong),
                ("ContextFlags", wt.DWORD), ("MxCsr", wt.DWORD),
                ("SegCs", wt.WORD), ("SegDs", wt.WORD), ("SegEs", wt.WORD), ("SegFs", wt.WORD), ("SegGs", wt.WORD), ("SegSs", wt.WORD),
                ("EFlags", wt.DWORD),
                ("Dr0", ctypes.c_ulonglong), ("Dr1", ctypes.c_ulonglong), ("Dr2", ctypes.c_ulonglong), ("Dr3", ctypes.c_ulonglong),
                ("Dr6", ctypes.c_ulonglong), ("Dr7", ctypes.c_ulonglong),
                ("Rax", ctypes.c_ulonglong), ("Rcx", ctypes.c_ulonglong), ("Rdx", ctypes.c_ulonglong), ("Rbx", ctypes.c_ulonglong),
                ("Rsp", ctypes.c_ulonglong), ("Rbp", ctypes.c_ulonglong), ("Rsi", ctypes.c_ulonglong), ("Rdi", ctypes.c_ulonglong),
                ("R8", ctypes.c_ulonglong), ("R9", ctypes.c_ulonglong), ("R10", ctypes.c_ulonglong), ("R11", ctypes.c_ulonglong),
                ("R12", ctypes.c_ulonglong), ("R13", ctypes.c_ulonglong), ("R14", ctypes.c_ulonglong), ("R15", ctypes.c_ulonglong),
                ("Rip", ctypes.c_ulonglong),
                ("Flt", ctypes.c_byte * 512),
                ("VectorRegister", M128A * 26), ("VectorControl", ctypes.c_ulonglong),
                ("DebugControl", ctypes.c_ulonglong), ("LastBranchToRip", ctypes.c_ulonglong), ("LastBranchFromRip", ctypes.c_ulonglong),
                ("LastExceptionToRip", ctypes.c_ulonglong), ("LastExceptionFromRip", ctypes.c_ulonglong)]


class ADDRESS64(ctypes.Structure):
    _fields_ = [("Offset", ctypes.c_ulonglong), ("Segment", wt.WORD), ("Mode", ctypes.c_int)]


class KDHELP64(ctypes.Structure):
    _fields_ = [("Thread", ctypes.c_ulonglong), ("ThCallbackStack", wt.DWORD), ("ThCallbackBStore", wt.DWORD),
                ("NextCallback", wt.DWORD), ("FramePointer", wt.DWORD), ("KiCallUserMode", ctypes.c_ulonglong),
                ("KeUserCallbackDispatcher", ctypes.c_ulonglong), ("SystemRangeStart", ctypes.c_ulonglong),
                ("KiUserExceptionDispatcher", ctypes.c_ulonglong), ("StackBase", ctypes.c_ulonglong),
                ("StackLimit", ctypes.c_ulonglong), ("BuildVersion", wt.DWORD), ("RetpolineStubFunctionTableSize", wt.DWORD),
                ("RetpolineStubFunctionTable", ctypes.c_ulonglong), ("RetpolineStubOffset", wt.DWORD),
                ("RetpolineStubSize", wt.DWORD), ("Reserved0", ctypes.c_ulonglong * 2)]


class STACKFRAME64(ctypes.Structure):
    _fields_ = [("AddrPC", ADDRESS64), ("AddrReturn", ADDRESS64), ("AddrFrame", ADDRESS64), ("AddrStack", ADDRESS64),
                ("AddrBStore", ADDRESS64), ("FuncTableEntry", ctypes.c_void_p), ("Params", ctypes.c_ulonglong * 4),
                ("Far", wt.BOOL), ("Virtual", wt.BOOL), ("Reserved", ctypes.c_ulonglong * 3), ("KdHelp", KDHELP64)]


class THREADENTRY32(ctypes.Structure):
    _fields_ = [("dwSize", wt.DWORD), ("cntUsage", wt.DWORD), ("th32ThreadID", wt.DWORD),
                ("th32OwnerProcessID", wt.DWORD), ("tpBasePri", wt.LONG), ("tpDeltaPri", wt.LONG), ("dwFlags", wt.DWORD)]


class MODINFO(ctypes.Structure):
    _fields_ = [("lpBaseOfDll", ctypes.c_void_p), ("SizeOfImage", wt.DWORD), ("EntryPoint", ctypes.c_void_p)]


hp = k32.OpenProcess(0x1F0FFF, False, pid)
dbg.SymInitializeW(hp, None, True)
dbg.SymFunctionTableAccess64.restype = ctypes.c_void_p
dbg.SymFunctionTableAccess64.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
dbg.SymGetModuleBase64.restype = ctypes.c_ulonglong
dbg.SymGetModuleBase64.argtypes = [ctypes.c_void_p, ctypes.c_ulonglong]
FTA = ctypes.WINFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_ulonglong)
GMB = ctypes.WINFUNCTYPE(ctypes.c_ulonglong, ctypes.c_void_p, ctypes.c_ulonglong)
fta = FTA(lambda h, a: dbg.SymFunctionTableAccess64(h, a))
gmb = GMB(lambda h, a: dbg.SymGetModuleBase64(h, a))

mods = (wt.HMODULE * 1024)()
need = wt.DWORD()
psapi.EnumProcessModulesEx(hp, mods, ctypes.sizeof(mods), ctypes.byref(need), 3)
ranges = []
for i in range(need.value // ctypes.sizeof(wt.HMODULE)):
    m = mods[i]
    if not m:
        continue
    name = ctypes.create_unicode_buffer(260)
    psapi.GetModuleBaseNameW(hp, ctypes.c_void_p(m), name, 260)
    mi = MODINFO()
    psapi.GetModuleInformation(hp, ctypes.c_void_p(m), ctypes.byref(mi), ctypes.sizeof(mi))
    ranges.append((mi.lpBaseOfDll, mi.lpBaseOfDll + mi.SizeOfImage, name.value))


def where(a):
    for lo, hi, n in ranges:
        if lo <= a < hi:
            return "%s+%x" % (n, a - lo)
    return hex(a)


snap = k32.CreateToolhelp32Snapshot(0x4, 0)
te = THREADENTRY32()
te.dwSize = ctypes.sizeof(te)
tids = []
ok = k32.Thread32First(snap, ctypes.byref(te))
while ok:
    if te.th32OwnerProcessID == pid:
        tids.append(te.th32ThreadID)
    ok = k32.Thread32Next(snap, ctypes.byref(te))

ctx_buf = ctypes.create_string_buffer(ctypes.sizeof(CONTEXT) + 16)
for tid in tids[:maxthreads]:
    ht = k32.OpenThread(0x1F03FF, False, tid)
    k32.SuspendThread(ht)
    addr = ctypes.addressof(ctx_buf)
    aligned = (addr + 15) & ~15
    ctx = CONTEXT.from_address(aligned)
    ctypes.memset(aligned, 0, ctypes.sizeof(CONTEXT))
    ctx.ContextFlags = 0x10000B
    k32.GetThreadContext(ht, ctypes.c_void_p(aligned))
    sf = STACKFRAME64()
    sf.AddrPC.Offset, sf.AddrPC.Mode = ctx.Rip, 3
    sf.AddrFrame.Offset, sf.AddrFrame.Mode = ctx.Rbp, 3
    sf.AddrStack.Offset, sf.AddrStack.Mode = ctx.Rsp, 3
    frames = []
    for _ in range(maxframes):
        if not dbg.StackWalk64(0x8664, hp, ht, ctypes.byref(sf), ctypes.c_void_p(aligned), None, fta, gmb, None):
            break
        if sf.AddrPC.Offset == 0:
            break
        frames.append(where(sf.AddrPC.Offset))
    k32.ResumeThread(ht)
    k32.CloseHandle(ht)
    print("thread %d:" % tid)
    for f in frames:
        print("   ", f)
