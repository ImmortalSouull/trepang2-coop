"""Showcase of the v0.9.21 features (1920x1080) from the takes recorded by showcase_v0921.ps1.

Usage: python make_showcase_v0921.py <coop take dir> <safe take dir> <out.mp4>
Each take has raw.mp4 (remuxed from raw.mkv) and events.txt ("<seconds> <name>").
coop: host window at x 0..1280, partner at 1290..2570; safe: host only at x 0..1280.
"""
import shutil
import subprocess
import sys
from pathlib import Path

COOP, SAFE, OUT_FILE = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
OUT = COOP.parent / "v0921-out"
OUT.mkdir(exist_ok=True)
FF = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/ffmpeg-*/bin/ffmpeg.exe"))
shutil.copy(r"C:\Windows\Fonts\segoeuib.ttf", OUT / "font.ttf")
shutil.copy(r"C:\Windows\Fonts\segoeui.ttf", OUT / "font2.ttf")
ACCENT, BG = "0xE8452C", "0x0b0b0d"
WA, WB = "crop=1280:720:0:0", "crop=1280:720:1290:0"


def events(take):
    ev = {}
    for line in (take / "events.txt").read_text().splitlines():
        t, name = line.split(maxsplit=1)
        ev[name] = float(t)
    return ev


EC, ES = events(COOP), events(SAFE)
_n = 0


def dt(text, size, color, y, font="font.ttf", x="(w-tw)/2"):
    global _n
    _n += 1
    (OUT / f"t{_n}.txt").write_text(text, encoding="utf-8")
    return f"drawtext=fontfile={font}:expansion=none:textfile=t{_n}.txt:fontsize={size}:fontcolor={color}:x={x}:y={y}"


def fades(d):
    return f"fade=t=in:st=0:d=0.3,fade=t=out:st={d - 0.3:.2f}:d=0.3"


def run(args):
    subprocess.run([str(FF), "-v", "error", "-y"] + args, cwd=OUT, check=True)


def enc(name, inputs, fc, d):
    run(inputs + ["-filter_complex", fc, "-map", "[v]", "-t", str(d), "-an", "-r", "30",
                  "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p", name])


def dual(name, t, d, title, sub):
    fc = (f"[0:v]split[a][b];[a]{WA},scale=944:531:flags=lanczos,setsar=1[l];[b]{WB},scale=944:531:flags=lanczos,setsar=1[r];"
          f"color=c={BG}:s=1920x1080:d={d}:r=30[bg];[bg][l]overlay=12:300:shortest=1[t1];[t1][r]overlay=964:300:shortest=1,"
          + ",".join([dt(title, 80, ACCENT, 60), dt(sub, 40, "white", 168, "font2.ttf"),
                      dt("HOST", 30, "0xbbbbbb", 845, "font.ttf", "12+(944-tw)/2"),
                      dt("PARTNER", 30, "0xbbbbbb", 845, "font.ttf", "964+(944-tw)/2")])
          + f",{fades(d)}[v]")
    enc(name, ["-ss", f"{t:.2f}", "-t", str(d), "-i", str(COOP / "raw.mp4")], fc, d)


def single(name, t, d, title, sub):
    fc = (f"[0:v]{WA},scale=1280:720:flags=lanczos,setsar=1[l];"
          f"color=c={BG}:s=1920x1080:d={d}:r=30[bg];[bg][l]overlay=320:270:shortest=1,"
          + ",".join([dt(title, 80, ACCENT, 50), dt(sub, 40, "white", 158, "font2.ttf")])
          + f",{fades(d)}[v]")
    enc(name, ["-ss", f"{t:.2f}", "-t", str(d), "-i", str(SAFE / "raw.mp4")], fc, d)


def card(name, d, lines):
    parts, y = [], 140
    for text, size, color, font in lines:
        parts.append(dt(text, size, color, y, font))
        y += int(size * 1.45)
    fc = f"color=c={BG}:s=1920x1080:d={d}:r=30," + ",".join(parts) + f",{fades(d)}[v]"
    enc(name, ["-f", "lavfi", "-i", "anullsrc"], fc, d)


G, W, A = "0xaaaaaa", "white", ACCENT
segs = []
card("s00.mp4", 4.5, [("", 60, W, "font.ttf"), ("TREPANG2 CO-OP", 130, A, "font.ttf"),
                      ("What's new in v0.9.21", 60, W, "font2.ttf"), ("", 30, W, "font2.ttf"),
                      ("EXTRAS  -  F6 quick access  -  Steam & network fixes", 42, G, "font2.ttf")])
segs.append("s00.mp4")
plan = [
    ("s01.mp4", EC["tabs"] + 0.4, 8.0, "F4 MENU IN THREE SHORT TABS", "CO-OP  -  LOOK  -  EXTRAS:  half the height it was"),
    ("s02.mp4", EC["extras"] + 0.3, 9.0, "EXTRAS", "Optional tweaks, each player sets their own  -  all off = the game as it is"),
    ("s03.mp4", EC["regen"] + 0.3, 8.5, "HEALTH REGENERATES TO FULL", "The game stops at 40 of 200  -  EXTRAS: up to 50 / 75 / 100 %   (max armor up to 300)"),
    ("s04.mp4", EC["resupply"] + 0.3, 6.5, "AUTO RESUPPLY", "A magazine for every gun, a grenade and some focus  -  every 60 or 30 s"),
    ("s05.mp4", EC["kills"] + 0.3, 6.5, "RESUPPLY ON KILL", "Every kill tops you up  -  plus heal on execution"),
    ("s06.mp4", EC["random"] + 0.3, 8.5, "RANDOMIZER", "Random mods and colours on your guns, enemies' guns in random colours"),
    ("s07.mp4", EC["f6shop"] + 0.3, 7.5, "F6  QUICK ACCESS", "The Horde shop from anywhere  -  for partners too"),
    ("s08.mp4", EC["f6mods"] + 0.3, 7.0, "WEAPON MODS ANYWHERE", "F6 - WEAPON MODS   (KEEP MY WEAPON MODS puts them on every gun you pick up)"),
]
for name, t, d, title, sub in plan:
    dual(name, t, d, title, sub)
    segs.append(name)
splan = [
    ("s10.mp4", ES["f6safe"] + 0.5, 3.0, "F6 IN THE SAFEHOUSE", "No more running from screen to screen"),
    ("s11.mp4", ES["s_MISSIONS"] + 0.8, 4.0, "F6 IN THE SAFEHOUSE", "Missions"),
    ("s12.mp4", ES["s_OUTFIT"] + 0.8, 4.0, "F6 IN THE SAFEHOUSE", "Outfit"),
    ("s13.mp4", ES["s_COMBAT SIMULATOR"] + 0.8, 4.0, "F6 IN THE SAFEHOUSE", "Combat simulator"),
    ("s14.mp4", ES["s_CHEATS"] + 0.8, 4.5, "F6 IN THE SAFEHOUSE", "Cheats   (REMEMBER CHEATS keeps them on between launches)"),
]
for name, t, d, title, sub in splan:
    single(name, t, d, title, sub)
    segs.append(name)
dual("s20.mp4", EC["travel"] + 0.3, 4.0, "NEXT ARENA", "The host changes the arena...")
dual("s21.mp4", EC["back"] - 2.5, 6.5, "PARTNERS GET BACK IN ON THEIR OWN", "All 47 Horde arenas and all 9 side missions checked together")
segs += ["s20.mp4", "s21.mp4"]
card("s90.mp4", 9, [("UNDER THE HOOD", 90, A, "font.ttf"),
                    ("Steam mode fixed  -  no more endless \"restart the game\"", 42, W, "font2.ttf"),
                    ("Smoother over a VPN / the internet  -  up to 20x more network speed per player", 42, W, "font2.ttf"),
                    ("Side missions Complex and Wet Basement: partners spawn next to the host", 42, W, "font2.ttf"),
                    ("Host crash on Bad Oil fixed  -  partners follow the host through level jumps", 42, W, "font2.ttf"),
                    ("Weapon mods and dual wield carry over to partners  -  health and ping in F4", 42, W, "font2.ttf")])
segs.append("s90.mp4")
card("s99.mp4", 5, [("", 80, W, "font.ttf"), ("TREPANG2 CO-OP", 110, A, "font.ttf"),
                    ("Download & updates:", 44, W, "font2.ttf"),
                    ("nexusmods.com/trepang2/mods/327", 48, W, "font.ttf"),
                    ("github.com/ImmortalSouull/trepang2-coop", 48, W, "font.ttf"),
                    ("", 20, W, "font2.ttf"),
                    ("Unofficial fan mod. Not affiliated with Trepang Studios or Team17.", 32, G, "font2.ttf")])
segs.append("s99.mp4")

(OUT / "list.txt").write_text("".join(f"file '{s}'\n" for s in segs))
run(["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", str(OUT_FILE)])
print("written", OUT_FILE)
