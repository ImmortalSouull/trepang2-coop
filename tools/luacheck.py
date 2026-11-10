"""Compile-check Lua files with Lua 5.4 (same major version as UE4SS). Usage: python luacheck.py file.lua ..."""
import sys

try:
    from lupa import lua54 as lupa_mod
except ImportError:
    import lupa as lupa_mod

rt = lupa_mod.LuaRuntime()
ok = True
for path in sys.argv[1:]:
    src = open(path, encoding="utf-8").read()
    res = rt.execute("return function(s, n) local f, e = load(s, n); return e end")(src, "@" + path)
    if res:
        ok = False
        print("FAIL", res)
    else:
        print("ok  ", path)
sys.exit(0 if ok else 1)
