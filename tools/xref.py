"""Find code that references a string (ASCII or UTF-16) and print the containing functions.
Usage: python xref.py <exe> <string>
"""
import struct
import sys

import pefile

exe, text = sys.argv[1], sys.argv[2]
pe = pefile.PE(exe, fast_load=True)
img = pe.get_memory_mapped_image()
tsec = next(s for s in pe.sections if s.Name.startswith(b".text"))
t0, t1 = tsec.VirtualAddress, tsec.VirtualAddress + tsec.Misc_VirtualSize
pdata = next(s for s in pe.sections if s.Name.startswith(b".pdata"))
raw = img[pdata.VirtualAddress:pdata.VirtualAddress + pdata.Misc_VirtualSize]
funcs = [struct.unpack_from("<III", raw, i)[:2] for i in range(0, len(raw) - 12, 12)]
funcs.sort()


def func_of(rva):
    lo, hi = 0, len(funcs) - 1
    while lo <= hi:
        m = (lo + hi) // 2
        b, e = funcs[m]
        if rva < b:
            hi = m - 1
        elif rva >= e:
            lo = m + 1
        else:
            return b, e
    return None


targets = []
for enc in (text.encode() + b"\0", text.encode("utf-16-le") + b"\0\0"):
    start = 0
    while True:
        i = img.find(enc, start)
        if i < 0:
            break
        if not (t0 <= i < t1):
            targets.append(i)
        start = i + 1
print("string at:", [hex(t) for t in targets])
tset = set(targets)
code = img[t0:t1]
hits = set()
# lea/mov reg, [rip+disp32]: look for any disp32 whose target is the string.
for off in range(0, len(code) - 7):
    if code[off] in (0x48, 0x4C) and code[off + 1] in (0x8D, 0x8B) and (code[off + 2] & 0xC7) == 0x05:
        disp = struct.unpack_from("<i", code, off + 3)[0]
        tgt = t0 + off + 7 + disp
        if tgt in tset:
            f = func_of(t0 + off)
            hits.add((t0 + off, f))
for ins, f in sorted(hits):
    print(f"ref at {ins:#x} in function {f[0]:#x}..{f[1]:#x}" if f else f"ref at {ins:#x}")
