"""Write a small minidump (thread stacks + modules) of a running process: python minidump.py <pid> <out.dmp>
For hangs: then python dumpstack.py <out.dmp> 30 --threads 3"""
import ctypes
import sys
from ctypes import wintypes

pid, out = int(sys.argv[1]), sys.argv[2]
k32 = ctypes.WinDLL("kernel32", use_last_error=True)
dbg = ctypes.WinDLL("dbghelp", use_last_error=True)
k32.OpenProcess.restype = wintypes.HANDLE
h = k32.OpenProcess(0x0400 | 0x0010, False, pid)   # QUERY_INFORMATION | VM_READ
if not h:
    sys.exit("OpenProcess failed %d" % ctypes.get_last_error())
k32.CreateFileW.restype = wintypes.HANDLE
f = k32.CreateFileW(out, 0x40000000, 0, None, 2, 0x80, None)   # GENERIC_WRITE, CREATE_ALWAYS
ok = dbg.MiniDumpWriteDump(wintypes.HANDLE(h), pid, wintypes.HANDLE(f), 0x0, None, None, None)   # MiniDumpNormal
print("ok" if ok else "MiniDumpWriteDump failed %d" % ctypes.get_last_error())
k32.CloseHandle(wintypes.HANDLE(f))
k32.CloseHandle(wintypes.HANDLE(h))
