"""Disassemble the function containing an RVA and show string references inside it.
Usage: python disasm.py <exe> <rva_hex> [max_insns]
"""
import struct
import sys

import capstone
import pefile

exe, rva = sys.argv[1], int(sys.argv[2], 16)
maxn = int(sys.argv[3]) if len(sys.argv) > 3 else 400
pe = pefile.PE(exe, fast_load=True)
base = pe.OPTIONAL_HEADER.ImageBase
img = pe.get_memory_mapped_image()

# Function bounds from the x64 exception table (.pdata RUNTIME_FUNCTION entries).
pdata = next(s for s in pe.sections if s.Name.startswith(b".pdata"))
start, end = rva, rva + 0x400
raw = img[pdata.VirtualAddress:pdata.VirtualAddress + pdata.Misc_VirtualSize]
for i in range(0, len(raw) - 12, 12):
    b, e, _u = struct.unpack_from("<III", raw, i)
    if b <= rva < e:
        start, end = b, e
        break
print(f"function {start:#x}..{end:#x} (target {rva:#x}, +{rva - start:#x})")
sys.stdout.reconfigure(encoding="utf-8")

md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_64)
md.detail = True


def string_at(r):
    try:
        s = img[r:r + 200]
        if all(32 <= b < 127 for b in s[:4]):
            return s.split(b"\0")[0].decode(errors="replace")
        if s[1] == 0 and s[3] == 0 and 32 <= s[0] < 127:
            return s.decode("utf-16-le", errors="replace").split("\0")[0]
    except Exception:
        pass
    return None


n = 0
for ins in md.disasm(img[start:start + 0x4000], base + start):
    r = ins.address - base
    mark = "  <== " if r == rva or (r < rva < r + ins.size) else ""
    extra = ""
    if "rip" in ins.op_str:
        for op in ins.operands:
            if op.type == capstone.x86.X86_OP_MEM and op.mem.base == capstone.x86.X86_REG_RIP:
                tgt = ins.address + ins.size + op.mem.disp - base
                s = string_at(tgt)
                if s:
                    extra = f'   ; "{s[:80]}"'
    print(f"{r:#09x}: {ins.mnemonic:6} {ins.op_str}{extra}{mark}")
    n += 1
    if n >= maxn or r >= end:
        break
