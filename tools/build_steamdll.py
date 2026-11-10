"""Builds mod/T2Coop/t2coop_steam.dll - a tiny native helper that lets the Lua mod use the Steam API.

No compiler is needed: this script assembles the x64 code itself and writes the PE file.

The DLL exports one function, t2s_run (called from Lua through package.loadlib). It reads a
command from %TMP%\\t2coop_cmd.txt, does it through the game's own steam_api64.dll and writes
the answer to %TMP%\\t2coop_out.txt (the file is not written if Steam is not running):

  P<text>  set the Steam rich presence "connect" key (empty = clear)   -> "1" / "0"
  I<text>  open the Steam overlay "invite friends" dialog for <text>    -> "1"
  F        friends that have a "connect" key set (= hosting T2 co-op)    -> "name\\tconnect\\n" ...
  J        connect string of the last accepted invite / "Join game", then forget it -> text or ""

Accepted invites arrive as the Steam callback GameRichPresenceJoinRequested_t (337), which this
DLL registers on its first run.
"""
import os
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "mod", "T2Coop", "t2coop_steam.dll")

RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI = range(8)
R8, R9, R10, R11, R12, R13, R14, R15 = range(8, 16)


class Asm:
    def __init__(self):
        self.b = bytearray()
        self.labels = {}
        self.fix = []   # (pos of rel32, end of instruction, kind 'code'|'data', name, addend)

    def label(self, name):
        self.labels[name] = len(self.b)

    def raw(self, *bs):
        for x in bs:
            if isinstance(x, int):
                self.b.append(x)
            else:
                self.b += x

    def _rel(self, kind, name, add=0, tail=0):
        pos = len(self.b)
        self.b += b"\0\0\0\0"
        self.fix.append((pos, pos + 4 + tail, kind, name, add))

    # --- instructions ---
    def push(self, r):
        if r >= 8:
            self.raw(0x41)
        self.raw(0x50 + (r & 7))

    def pop(self, r):
        if r >= 8:
            self.raw(0x41)
        self.raw(0x58 + (r & 7))

    def mov_rr(self, dst, src):  # 64-bit
        self.raw(0x48 | (4 if src >= 8 else 0) | (1 if dst >= 8 else 0), 0x89, 0xC0 | (src & 7) << 3 | (dst & 7))

    def mov_rr32(self, dst, src):
        rex = (4 if src >= 8 else 0) | (1 if dst >= 8 else 0)
        if rex:
            self.raw(0x40 | rex)
        self.raw(0x89, 0xC0 | (src & 7) << 3 | (dst & 7))

    def xor32(self, r):
        rex = (5 if r >= 8 else 0)
        if rex:
            self.raw(0x40 | rex)
        self.raw(0x31, 0xC0 | (r & 7) << 3 | (r & 7))

    def mov_imm32(self, r, imm):
        if r >= 8:
            self.raw(0x41)
        self.raw(0xB8 + (r & 7), struct.pack("<I", imm & 0xFFFFFFFF))

    def lea(self, r, name, add=0):  # lea r64, [rip+data]
        self.raw(0x48 | (4 if r >= 8 else 0), 0x8D, 0x05 | (r & 7) << 3)
        self._rel("data", name, add)

    def lea_code(self, r, name):
        self.raw(0x48 | (4 if r >= 8 else 0), 0x8D, 0x05 | (r & 7) << 3)
        self._rel("code", name)

    def call(self, name):  # call [rip+data]
        self.raw(0xFF, 0x15)
        self._rel("data", name)

    def store(self, name, r, add=0):  # mov [rip+data], r64
        self.raw(0x48 | (4 if r >= 8 else 0), 0x89, 0x05 | (r & 7) << 3)
        self._rel("data", name, add)

    def store_al(self, name, add=0):
        self.raw(0x88, 0x05)
        self._rel("data", name, add)

    def store_byte(self, name, imm, add=0):  # mov byte [rip+data], imm8
        self.raw(0xC6, 0x05)
        self._rel("data", name, add, tail=1)
        self.raw(imm)

    def store_dword(self, name, imm, add=0):  # mov dword [rip+data], imm32
        self.raw(0xC7, 0x05)
        self._rel("data", name, add, tail=4)
        self.raw(struct.pack("<I", imm))

    def cmp_byte(self, name, imm):  # cmp byte [rip+data], imm8
        self.raw(0x80, 0x3D)
        self._rel("data", name, 0, tail=1)
        self.raw(imm)

    def movzx_al(self, name):  # movzx eax, byte [rip+data]
        self.raw(0x0F, 0xB6, 0x05)
        self._rel("data", name)

    def load_eax(self, name):  # mov eax, [rip+data]
        self.raw(0x8B, 0x05)
        self._rel("data", name)

    def stack_imm(self, off, imm):  # mov qword [rsp+off], imm32
        self.raw(0x48, 0xC7, 0x44, 0x24, off, struct.pack("<i", imm))

    def jcc(self, cc, name):
        self.raw(0x0F, 0x80 + cc)
        self._rel("code", name)

    def jmp(self, name):
        self.raw(0xE9)
        self._rel("code", name)


JE, JNE, JGE, JG = 0x4, 0x5, 0xD, 0xF

KERNEL32 = ["GetTempPathA", "lstrcatA", "lstrcpyA", "lstrcpynA", "lstrlenA", "CreateFileA", "ReadFile",
            "WriteFile", "CloseHandle", "GetModuleHandleA", "GetProcAddress"]
STEAM = [  # (slot, export name)
    ("f_friends", "SteamAPI_SteamFriends_v017"),
    ("f_register", "SteamAPI_RegisterCallback"),
    ("f_setrp", "SteamAPI_ISteamFriends_SetRichPresence"),
    ("f_invite", "SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialogConnectString"),
    ("f_count", "SteamAPI_ISteamFriends_GetFriendCount"),
    ("f_byidx", "SteamAPI_ISteamFriends_GetFriendByIndex"),
    ("f_getrp", "SteamAPI_ISteamFriends_GetFriendRichPresence"),
    ("f_name", "SteamAPI_ISteamFriends_GetFriendPersonaName"),
]
FRIEND_FLAG_IMMEDIATE = 4
CB_JOIN_REQUESTED = 337          # GameRichPresenceJoinRequested_t
CB_SIZE = 8 + 256


def code():
    a = Asm()
    imp = lambda n: "imp_" + n
    a.label("t2s_run")
    for r in (RBX, RSI, RDI, R12, R13, R14, R15):
        a.push(r)
    a.raw(0x48, 0x83, 0xEC, 0x40)                      # sub rsp, 0x40
    # paths: %TMP%\t2coop_cmd.txt, %TMP%\t2coop_out.txt
    for path, name in (("path_cmd", "s_cmd"), ("path_out", "s_out")):
        a.mov_imm32(RCX, 260); a.lea(RDX, path); a.call(imp("GetTempPathA"))
        a.lea(RCX, path); a.lea(RDX, name); a.call(imp("lstrcatA"))
    a.store_byte("buf_cmd", 0)
    a.store_byte("buf_out", 0)
    # read the command
    a.lea(RCX, "path_cmd"); a.mov_imm32(RDX, 0x80000000); a.mov_imm32(R8, 3); a.xor32(R9)
    a.stack_imm(0x20, 3); a.stack_imm(0x28, 0x80); a.stack_imm(0x30, 0)
    a.call(imp("CreateFileA"))
    a.raw(0x48, 0x83, 0xF8, 0xFF); a.jcc(JE, "done")  # cmp rax, -1
    a.mov_rr(RBX, RAX)
    a.mov_rr(RCX, RBX); a.lea(RDX, "buf_cmd"); a.mov_imm32(R8, 1024); a.lea(R9, "nio"); a.stack_imm(0x20, 0)
    a.call(imp("ReadFile"))
    a.mov_rr(RCX, RBX); a.call(imp("CloseHandle"))
    a.load_eax("nio"); a.lea(RCX, "buf_cmd"); a.raw(0xC6, 0x04, 0x01, 0x00)   # mov byte [rcx+rax], 0
    # steam_api64.dll must already be loaded by the game
    a.lea(RCX, "s_steamdll"); a.call(imp("GetModuleHandleA"))
    a.raw(0x48, 0x85, 0xC0); a.jcc(JE, "done")         # test rax, rax
    a.mov_rr(R12, RAX)
    for slot, name in STEAM:
        a.mov_rr(RCX, R12); a.lea(RDX, "n_" + slot); a.call(imp("GetProcAddress"))
        a.raw(0x48, 0x85, 0xC0); a.jcc(JE, "done")
        a.store(slot, RAX)
    a.call("f_friends")
    a.raw(0x48, 0x85, 0xC0); a.jcc(JE, "done")
    a.mov_rr(R13, RAX)
    # register the "join requested" callback once
    a.cmp_byte("cb_done", 0); a.jcc(JNE, "skipreg")
    a.lea_code(RAX, "cb_run"); a.store("vtbl", RAX, 0); a.store("vtbl", RAX, 8)
    a.lea_code(RAX, "cb_size"); a.store("vtbl", RAX, 16)
    a.lea(RAX, "vtbl"); a.store("cbobj", RAX, 0)
    a.store_dword("cbobj", CB_JOIN_REQUESTED, 12)
    a.lea(RCX, "cbobj"); a.mov_imm32(RDX, CB_JOIN_REQUESTED); a.call("f_register")
    a.store_byte("cb_done", 1)
    a.label("skipreg")
    a.movzx_al("buf_cmd")
    for ch, lab in (("P", "doP"), ("I", "doI"), ("F", "doF"), ("J", "doJ")):
        a.raw(0x3C, ord(ch)); a.jcc(JE, lab)           # cmp al, imm8
    a.jmp("writeout")

    a.label("doP")
    a.mov_rr(RCX, R13); a.lea(RDX, "s_connect"); a.lea(R8, "buf_cmd", 1); a.call("f_setrp")
    a.raw(0x04, ord("0"))                              # add al, '0'
    a.store_al("buf_out"); a.store_byte("buf_out", 0, 1)
    a.jmp("writeout")

    a.label("doI")
    a.mov_rr(RCX, R13); a.lea(RDX, "buf_cmd", 1); a.call("f_invite")
    a.store_byte("buf_out", ord("1")); a.store_byte("buf_out", 0, 1)
    a.jmp("writeout")

    a.label("doJ")
    a.lea(RCX, "buf_out"); a.lea(RDX, "joinreq"); a.call(imp("lstrcpyA"))
    a.store_byte("joinreq", 0)
    a.jmp("writeout")

    a.label("doF")
    a.mov_rr(RCX, R13); a.mov_imm32(RDX, FRIEND_FLAG_IMMEDIATE); a.call("f_count")
    a.mov_rr32(RSI, RAX)
    a.xor32(RBX)
    a.label("floop")
    a.raw(0x39, 0xF3); a.jcc(JGE, "writeout")          # cmp ebx, esi
    a.mov_rr(RCX, R13); a.mov_rr32(RDX, RBX); a.mov_imm32(R8, FRIEND_FLAG_IMMEDIATE); a.call("f_byidx")
    a.mov_rr(R12, RAX)
    a.mov_rr(RCX, R13); a.mov_rr(RDX, R12); a.lea(R8, "s_connect"); a.call("f_getrp")
    a.raw(0x48, 0x85, 0xC0); a.jcc(JE, "fnext")
    a.raw(0x80, 0x38, 0x00); a.jcc(JE, "fnext")        # cmp byte [rax], 0
    a.mov_rr(R14, RAX)
    a.lea(RCX, "buf_out"); a.call(imp("lstrlenA"))
    a.raw(0x3D, struct.pack("<I", 60000)); a.jcc(JG, "writeout")
    a.mov_rr(RCX, R13); a.mov_rr(RDX, R12); a.call("f_name")
    a.mov_rr(RDX, RAX); a.lea(RCX, "buf_out"); a.call(imp("lstrcatA"))
    a.lea(RCX, "buf_out"); a.lea(RDX, "s_tab"); a.call(imp("lstrcatA"))
    a.lea(RCX, "buf_out"); a.mov_rr(RDX, R14); a.call(imp("lstrcatA"))
    a.lea(RCX, "buf_out"); a.lea(RDX, "s_nl"); a.call(imp("lstrcatA"))
    a.label("fnext")
    a.raw(0xFF, 0xC3)                                  # inc ebx
    a.jmp("floop")

    a.label("writeout")
    a.lea(RCX, "path_out"); a.mov_imm32(RDX, 0x40000000); a.mov_imm32(R8, 3); a.xor32(R9)
    a.stack_imm(0x20, 2); a.stack_imm(0x28, 0x80); a.stack_imm(0x30, 0)
    a.call(imp("CreateFileA"))
    a.raw(0x48, 0x83, 0xF8, 0xFF); a.jcc(JE, "done")
    a.mov_rr(RBX, RAX)
    a.lea(RCX, "buf_out"); a.call(imp("lstrlenA"))
    a.mov_rr32(R8, RAX)
    a.mov_rr(RCX, RBX); a.lea(RDX, "buf_out"); a.lea(R9, "nio"); a.stack_imm(0x20, 0)
    a.call(imp("WriteFile"))
    a.mov_rr(RCX, RBX); a.call(imp("CloseHandle"))

    a.label("done")
    a.xor32(RAX)
    a.raw(0x48, 0x83, 0xC4, 0x40)                      # add rsp, 0x40
    for r in (R15, R14, R13, R12, RDI, RSI, RBX):
        a.pop(r)
    a.raw(0xC3)

    # CCallbackBase::Run(void* param) - this = rcx, param = rdx: copy the connect string
    a.label("cb_run")
    a.raw(0x48, 0x83, 0xEC, 0x28)                      # sub rsp, 0x28
    a.lea(RCX, "joinreq"); a.raw(0x48, 0x83, 0xC2, 0x08); a.mov_imm32(R8, 256)   # add rdx, 8
    a.call(imp("lstrcpynA"))
    a.raw(0x48, 0x83, 0xC4, 0x28, 0xC3)                # add rsp, 0x28; ret
    a.label("cb_size")
    a.mov_imm32(RAX, CB_SIZE); a.raw(0xC3)
    return a


def align(x, a):
    return (x + a - 1) // a * a


def build():
    a = code()
    text = bytes(a.b)
    TEXT_RVA = 0x1000
    DATA_RVA = align(TEXT_RVA + len(text), 0x1000)

    # ---- .data layout ----
    d = bytearray()
    sym = {}

    def put(name, blob, al=8):
        while len(d) % al:
            d.append(0)
        sym[name] = len(d)
        d.extend(blob)

    # imports (kernel32 only; Steam is looked up at run time)
    n = len(KERNEL32)
    put("impdesc", b"\0" * 40)
    put("ilt", b"\0" * 8 * (n + 1))
    put("iat", b"\0" * 8 * (n + 1))
    hints = []
    for f in KERNEL32:
        put("hn_" + f, b"\0\0" + f.encode() + b"\0", 2)
        hints.append(sym["hn_" + f])
    put("s_k32", b"KERNEL32.dll\0")
    for i, f in enumerate(KERNEL32):
        rva = DATA_RVA + hints[i]
        struct.pack_into("<Q", d, sym["ilt"] + 8 * i, rva)
        struct.pack_into("<Q", d, sym["iat"] + 8 * i, rva)
        sym["imp_" + f] = sym["iat"] + 8 * i
    struct.pack_into("<IIIII", d, sym["impdesc"], DATA_RVA + sym["ilt"], 0, 0, DATA_RVA + sym["s_k32"], DATA_RVA + sym["iat"])
    # exports
    put("expdir", b"\0" * 40, 4)
    put("exp_funcs", b"\0" * 4, 4)
    put("exp_names", b"\0" * 4, 4)
    put("exp_ords", b"\0" * 2, 2)
    put("s_dllname", b"t2coop_steam.dll\0", 1)
    put("s_fn", b"t2s_run\0", 1)
    export_end = len(d)
    struct.pack_into("<IIHHIIIIIII", d, sym["expdir"], 0, 0, 0, 0, DATA_RVA + sym["s_dllname"], 1, 1, 1,
                     DATA_RVA + sym["exp_funcs"], DATA_RVA + sym["exp_names"], DATA_RVA + sym["exp_ords"])
    struct.pack_into("<I", d, sym["exp_funcs"], TEXT_RVA + a.labels["t2s_run"])
    struct.pack_into("<I", d, sym["exp_names"], DATA_RVA + sym["s_fn"])
    # strings
    for name, s in (("s_cmd", "t2coop_cmd.txt"), ("s_out", "t2coop_out.txt"), ("s_steamdll", "steam_api64.dll"),
                    ("s_connect", "connect"), ("s_tab", "\t"), ("s_nl", "\n")):
        put(name, s.encode() + b"\0", 1)
    for slot, name in STEAM:
        put("n_" + slot, name.encode() + b"\0", 1)
    # slots
    for slot, _ in STEAM:
        put(slot, b"\0" * 8)
    put("nio", b"\0" * 8)
    put("cb_done", b"\0" * 8)
    put("vtbl", b"\0" * 24)
    put("cbobj", b"\0" * 16)
    raw_data_len = len(d)
    # zero-filled buffers (not stored in the file)
    bss = {}
    off = align(raw_data_len, 16)
    for name, size in (("path_cmd", 288), ("path_out", 288), ("joinreq", 272), ("buf_cmd", 1040), ("buf_out", 65552)):
        bss[name] = off
        off += size
    data_vsize = off
    sym.update(bss)

    # ---- fixups ----
    t = bytearray(text)
    for pos, end, kind, name, add in a.fix:
        target = (TEXT_RVA + a.labels[name]) if kind == "code" else (DATA_RVA + sym[name] + add)
        struct.pack_into("<i", t, pos, target - (TEXT_RVA + end))
    text = bytes(t)

    RELOC_RVA = align(DATA_RVA + data_vsize, 0x1000)
    reloc = struct.pack("<IIHH", TEXT_RVA, 12, 0, 0)   # one empty block (code is position independent)
    SIZE_OF_IMAGE = align(RELOC_RVA + len(reloc), 0x1000)

    FA = 0x200
    text_raw = align(len(text), FA)
    data_raw = align(raw_data_len, FA)
    reloc_raw = align(len(reloc), FA)
    HDR = 0x400
    text_ptr, data_ptr = HDR, HDR + text_raw
    reloc_ptr = data_ptr + data_raw

    dos = bytearray(0x80)
    dos[0:2] = b"MZ"
    struct.pack_into("<I", dos, 0x3C, 0x80)
    coff = struct.pack("<4sHHIIIHH", b"PE\0\0", 0x8664, 3, 0, 0, 0, 0xF0, 0x2022)
    dirs = [(0, 0)] * 16
    dirs[0] = (DATA_RVA + sym["expdir"], export_end - sym["expdir"])
    dirs[1] = (DATA_RVA + sym["impdesc"], 40)
    dirs[5] = (RELOC_RVA, len(reloc))
    dirs[12] = (DATA_RVA + sym["iat"], 8 * (n + 1))
    opt = struct.pack("<HBBIIIIIQIIHHHHHHIIIIHHQQQQII", 0x20B, 14, 0, text_raw, data_raw + reloc_raw,
                      data_vsize - raw_data_len, 0, TEXT_RVA, 0x180000000, 0x1000, FA, 6, 0, 0, 0, 6, 0, 0,
                      SIZE_OF_IMAGE, HDR, 0, 2, 0x0160, 0x100000, 0x1000, 0x100000, 0x1000, 0, 16)
    opt += b"".join(struct.pack("<II", *x) for x in dirs)
    assert len(opt) == 0xF0

    def sec(name, vsize, rva, rawsize, ptr, ch):
        return struct.pack("<8sIIIIIIHHI", name, vsize, rva, rawsize, ptr, 0, 0, 0, 0, ch)

    secs = (sec(b".text", len(text), TEXT_RVA, text_raw, text_ptr, 0x60000020)
            + sec(b".data", data_vsize, DATA_RVA, data_raw, data_ptr, 0xC0000040)
            + sec(b".reloc", len(reloc), RELOC_RVA, reloc_raw, reloc_ptr, 0x42000040))
    hdr = bytes(dos) + coff + opt + secs
    hdr += b"\0" * (HDR - len(hdr))
    img = hdr + text.ljust(text_raw, b"\0") + bytes(d[:raw_data_len]).ljust(data_raw, b"\0") + reloc.ljust(reloc_raw, b"\0")
    return img


if __name__ == "__main__":
    img = build()
    out = sys.argv[1] if len(sys.argv) > 1 else OUT
    with open(out, "wb") as f:
        f.write(img)
    print("wrote", out, len(img), "bytes")
