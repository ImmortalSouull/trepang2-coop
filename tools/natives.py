"""Map crash RVAs to UE native function names.

UE4 registers native UFunctions with tables of {const char* Name, FNativeFuncPtr Ptr}.
We scan the exe's data sections for such pairs and resolve each RVA to the nearest
registered function at or below it.
Usage: python natives.py <exe> <rva_hex> [<rva_hex> ...]
"""
import bisect
import re
import struct
import sys

import pefile

exe = sys.argv[1]
rvas = [int(a, 16) for a in sys.argv[2:] if all(ch in "0123456789abcdefABCDEFx" for ch in a) and not a.startswith("--")]
pe = pefile.PE(exe, fast_load=True)
base = pe.OPTIONAL_HEADER.ImageBase
data = pe.__data__
secs = {s.Name.rstrip(b"\0").decode(): s for s in pe.sections}
text = secs[".text"]
t_lo, t_hi = base + text.VirtualAddress, base + text.VirtualAddress + text.Misc_VirtualSize


def va_to_off(va):
    rva = va - base
    for s in pe.sections:
        if s.VirtualAddress <= rva < s.VirtualAddress + s.Misc_VirtualSize:
            return rva - s.VirtualAddress + s.PointerToRawData
    return None


ident = re.compile(rb"[A-Za-z_][A-Za-z0-9_ ]{2,80}\0")
funcs = {}
for name in (".rdata", ".data"):
    s = secs.get(name)
    if not s:
        continue
    blob = data[s.PointerToRawData:s.PointerToRawData + s.SizeOfRawData]
    for i in range(0, len(blob) - 16, 8):
        nptr, fptr = struct.unpack_from("<QQ", blob, i)
        if not (t_lo <= fptr < t_hi):
            continue
        off = va_to_off(nptr)
        if off is None:
            continue
        m = ident.match(data, off)
        if m:
            funcs.setdefault(fptr - base, m.group(0)[:-1].decode())

starts = sorted(funcs)
print(f"{len(starts)} registered natives")
for r in rvas:
    i = bisect.bisect_right(starts, r) - 1
    if i >= 0:
        s = starts[i]
        print(f"{r:#x}: {funcs[s]} (+{r - s:#x})")

# Optional: --find NAME prints the thunk address of a registered native.
if "--find" in sys.argv:
    name = sys.argv[sys.argv.index("--find") + 1]
    for a, n in funcs.items():
        if n == name:
            print(f"{name} thunk at {a:#x}")
