"""Unwind the crashing thread of a UE4 minidump with the modules' own x64 unwind data (.pdata), no symbols.
Prints module+RVA per frame (feed exe RVAs to disasm.py / natives.py).
Usage: python dumpstack.py <UE4Minidump.dmp> [max_frames] [--threads N]
  --threads N: a hang dump (no exception): unwind the first N threads of the thread list instead.
Module files are read from the paths recorded in the dump.
"""
import mmap
import struct
import sys

import pefile

DMP = sys.argv[1]
MAXF = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 40
NTHREADS = int(sys.argv[sys.argv.index("--threads") + 1]) if "--threads" in sys.argv else 0
_fh = open(DMP, "rb")
d = mmap.mmap(_fh.fileno(), 0, access=mmap.ACCESS_READ)
nstreams, sdir = struct.unpack_from("<II", d, 8)
streams = {}
for i in range(nstreams):
    t, size, rva = struct.unpack_from("<III", d, sdir + i * 12)
    streams[t] = (size, rva)

# memory: MemoryListStream (5) and Memory64ListStream (9)
mem = []
if 5 in streams:
    _, r = streams[5]
    n = struct.unpack_from("<I", d, r)[0]
    for i in range(n):
        start, size, rva = struct.unpack_from("<QII", d, r + 4 + i * 16)
        mem.append((start, size, rva))
if 9 in streams:
    _, r = streams[9]
    n, base = struct.unpack_from("<QQ", d, r)
    off = base
    for i in range(n):
        start, size = struct.unpack_from("<QQ", d, r + 16 + i * 16)
        mem.append((start, size, off))
        off += size


def rd(addr, n):
    for start, size, rva in mem:
        if start <= addr and addr + n <= start + size:
            return d[rva + addr - start: rva + addr - start + n]
    return None


def q(addr):
    b = rd(addr, 8)
    return struct.unpack("<Q", b)[0] if b else None


# modules (4)
mods = []
_, r = streams[4]
n = struct.unpack_from("<I", d, r)[0]
for i in range(n):
    e = r + 4 + i * 108
    base, size = struct.unpack_from("<QI", d, e)
    name_rva = struct.unpack_from("<I", d, e + 20)[0]
    ln = struct.unpack_from("<I", d, name_rva)[0]
    path = d[name_rva + 4: name_rva + 4 + ln].decode("utf-16le")
    mods.append([base, size, path, None])


def modof(a):
    for m in mods:
        if m[0] <= a < m[0] + m[1]:
            return m
    return None


def pe_of(m):
    if m[3] is None:
        try:
            pe = pefile.PE(m[2], fast_load=True)
            pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_EXCEPTION"]])
            img = pe.get_memory_mapped_image()
            funcs = []
            for e in getattr(pe, "DIRECTORY_ENTRY_EXCEPTION", []):
                funcs.append((e.struct.BeginAddress, e.struct.EndAddress, e.struct.UnwindData))
            funcs.sort()
            m[3] = (img, funcs)
        except Exception as ex:
            m[3] = (None, [])
    return m[3]


def lookup(funcs, rva):
    lo, hi = 0, len(funcs) - 1
    while lo <= hi:
        mid = (lo + hi) // 2
        b, e, u = funcs[mid]
        if rva < b:
            hi = mid - 1
        elif rva >= e:
            lo = mid + 1
        else:
            return funcs[mid]
    return None


REG = ["rax", "rcx", "rdx", "rbx", "rsp", "rbp", "rsi", "rdi", "r8", "r9", "r10", "r11", "r12", "r13", "r14", "r15"]


def unwind(regs, img, func, rva):
    """apply unwind codes of func; returns new regs (rip set to return address) or None (leaf)"""
    begin, end, uw = func
    while True:
        ver_flags, prolog, cnt, fr = struct.unpack_from("<BBBB", img, uw)
        flags = ver_flags >> 3
        frame_reg, frame_off = fr & 0xF, (fr >> 4) * 16
        codes = [struct.unpack_from("<BB", img, uw + 4 + i * 2) + (struct.unpack_from("<H", img, uw + 4 + i * 2)[0],)
                 for i in range(cnt)]
        if frame_reg:
            regs["rsp"] = regs[REG[frame_reg]] - frame_off
        i = 0
        offset_in_func = rva - begin
        while i < cnt:
            co, opinfo_op, raw = codes[i]
            op, info = opinfo_op & 0xF, opinfo_op >> 4
            if co > offset_in_func and False:
                pass
            if op == 0:   # PUSH_NONVOL
                regs[REG[info]] = q(regs["rsp"])
                regs["rsp"] += 8
                i += 1
            elif op == 1:   # ALLOC_LARGE
                if info == 0:
                    regs["rsp"] += codes[i + 1][2] * 8
                    i += 2
                else:
                    regs["rsp"] += codes[i + 1][2] | (codes[i + 2][2] << 16)
                    i += 3
            elif op == 2:   # ALLOC_SMALL
                regs["rsp"] += info * 8 + 8
                i += 1
            elif op == 3:   # SET_FPREG
                i += 1
            elif op == 4:   # SAVE_NONVOL
                regs[REG[info]] = q(regs["rsp"] + codes[i + 1][2] * 8)
                i += 2
            elif op == 5:   # SAVE_NONVOL_FAR
                regs[REG[info]] = q(regs["rsp"] + (codes[i + 1][2] | (codes[i + 2][2] << 16)))
                i += 3
            elif op == 8:   # SAVE_XMM128
                i += 2
            elif op == 9:   # SAVE_XMM128_FAR
                i += 3
            elif op == 10:   # PUSH_MACHFRAME
                regs["rip"] = q(regs["rsp"] + (8 if info else 0))
                regs["rsp"] = q(regs["rsp"] + (32 if info else 24))
                return regs
            else:
                i += 1
        if flags & 4:   # chained
            idx = (cnt + 1) & ~1
            begin, end, uw = struct.unpack_from("<III", img, uw + 4 + idx * 2)
            continue
        break
    regs["rip"] = q(regs["rsp"])
    regs["rsp"] += 8
    return regs


def walk(ctx, title):
    regs = {name: struct.unpack_from("<Q", ctx, 0x78 + i * 8)[0] for i, name in enumerate(REG)}
    regs["rip"] = struct.unpack_from("<Q", ctx, 0xF8)[0]
    print(title)
    for n in range(MAXF):
        rip = regs["rip"]
        m = modof(rip)
        name = (m[2].replace("\\", "/").split("/")[-1] + "+%x" % (rip - m[0])) if m else hex(rip)
        print("%2d %s" % (n, name))
        if not m:
            # a jump into data (a call through a freed object): take the return address on the stack
            if n == 0:
                regs["rip"] = q(regs["rsp"]); regs["rsp"] += 8
                continue
            break
        img, funcs = pe_of(m)
        if img is None:
            break
        f = lookup(funcs, rip - m[0])
        if not f:   # leaf
            regs["rip"] = q(regs["rsp"])
            regs["rsp"] += 8
        else:
            regs = unwind(dict(regs), img, f, rip - m[0])
        if not regs or not regs.get("rip"):
            break


if NTHREADS:
    _, r = streams[3]
    n = struct.unpack_from("<I", d, r)[0]
    for i in range(min(n, NTHREADS)):
        e = r + 4 + i * 48
        tid = struct.unpack_from("<I", d, e)[0]
        csize, crva = struct.unpack_from("<II", d, e + 40)
        walk(d[crva: crva + csize], "thread %d (#%d)" % (tid, i))
else:
    # exception context (6)
    _, r = streams[6]
    tid = struct.unpack_from("<I", d, r)[0]
    ctx_size, ctx_rva = struct.unpack_from("<II", d, r + 8 + 152)
    walk(d[ctx_rva: ctx_rva + ctx_size], "thread %d" % tid)
