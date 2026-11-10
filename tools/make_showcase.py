"""Trepang2 Co-op beta showcase (1920x1080) from a take recorded by showcase_record.ps1.

Usage: python make_showcase.py <take dir> <out.mp4>
The take has raw.mp4 (desktop 2590x770: host window at x 0..1280, partner at 1290..2570, y 0..720)
and events.txt ("<seconds> <name>"). Captions use Segoe UI Bold; the last cards show the roadmap.
"""
import shutil
import subprocess
import sys
from pathlib import Path

TAKE = Path(sys.argv[1])
OUT_FILE = Path(sys.argv[2])
OUT = TAKE / "out"
OUT.mkdir(exist_ok=True)
FF = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/ffmpeg-*/bin/ffmpeg.exe"))
shutil.copy(r"C:\Windows\Fonts\segoeuib.ttf", OUT / "font.ttf")
shutil.copy(r"C:\Windows\Fonts\segoeui.ttf", OUT / "font2.ttf")
ACCENT, BG = "0xE8452C", "0x0b0b0d"
WA, WB = "crop=1280:720:0:0", "crop=1280:720:1290:0"
EV = {}
for line in (TAKE / "events.txt").read_text().splitlines():
    t, name = line.split(maxsplit=1)
    EV[name] = float(t)
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
          + ",".join([dt(title, 84, ACCENT, 60), dt(sub, 44, "white", 170, "font2.ttf"),
                      dt("HOST", 30, "0xbbbbbb", 845, "font.ttf", "12+(944-tw)/2"),
                      dt("PARTNER", 30, "0xbbbbbb", 845, "font.ttf", "964+(944-tw)/2")])
          + f",{fades(d)}[v]")
    enc(name, ["-ss", f"{t:.2f}", "-t", str(d), "-i", str(TAKE / "raw.mp4")], fc, d)


def card(name, d, lines):
    parts, y = [], 140
    for text, size, color, font in lines:
        parts.append(dt(text, size, color, y, font))
        y += int(size * 1.45)
    fc = f"color=c={BG}:s=1920x1080:d={d}:r=30," + ",".join(parts) + f",{fades(d)}[v]"
    enc(name, ["-f", "lavfi", "-i", "anullsrc"], fc, d)


segs = []
card("s00.mp4", 4.5, [("", 60, "white", "font.ttf"), ("TREPANG2 CO-OP", 130, ACCENT, "font.ttf"),
                      ("Beta showcase  -  v0.4.0", 56, "white", "font2.ttf"), ("", 30, "white", "font2.ttf"),
                      ("Unofficial mod  -  Horde mode co-op  -  work in progress", 40, "0xaaaaaa", "font2.ttf")])
segs.append("s00.mp4")
plan = [
    ("s01.mp4", EV["joined"] + 0.5, 3.5, "TWO PLAYERS, ONE ARENA", "Host a Horde arena (F5), a friend joins by IP (F6)"),
    ("s02.mp4", EV["facing"] + 0.3, 5.5, "EVERYONE IS A FULL PLAYER", "Own character, own guns and HUD  -  partner markers show where your team is"),
    ("s03.mp4", EV["fight"] + 0.5, 13.0, "FIGHT THE WAVES TOGETHER", "Enemies hunt both players  -  every shot and headshot of the partner counts"),
    ("s04.mp4", EV["money"] - 1.0, 4.5, "SHARED HORDE MONEY", "Kills by any player pay into the team's money"),
    ("s05.mp4", EV["down"] + 0.2, 7.5, "DOWN, NOT DEAD", "Below 30% HP you go down  -  a partner next to you revives you"),
    ("s06.mp4", EV["marker"] + 0.3, 5.0, "NEVER LOSE YOUR PARTNER", "Markers with distance, visible through walls"),
]
for name, t, d, title, sub in plan:
    dual(name, t, d, title, sub)
    segs.append(name)

G, W, A = "0xaaaaaa", "white", ACCENT
card("s90.mp4", 14, [("ROADMAP", 96, A, "font.ttf"),
                     ("v0.5   Steam connection without port forwarding, Steam invites, in-game co-op menu", 38, W, "font2.ttf"),
                     ("v0.6   Story campaign basics: missions together, level transitions, safehouse lobby, checkpoints", 38, W, "font2.ttf"),
                     ("v0.7   Campaign scripts: doors, elevators, objectives, cutscenes and dialogue for everyone", 38, W, "font2.ttf"),
                     ("v0.8   Bosses, special levels, side missions, difficulty for more players", 38, W, "font2.ttf"),
                     ("v0.9   Progression for every player, spectating, rejoining, full-campaign testing", 38, W, "font2.ttf"),
                     ("v1.0   The whole Trepang2 story campaign playable in co-op", 44, A, "font.ttf")])
segs.append("s90.mp4")
card("s99.mp4", 5, [("", 80, W, "font.ttf"), ("TREPANG2 CO-OP", 110, A, "font.ttf"),
                    ("Download & updates: github.com/ImmortalSouull/trepang2-coop", 44, W, "font2.ttf"),
                    ("", 30, W, "font2.ttf"),
                    ("Unofficial fan mod. Not affiliated with Trepang Studios or Team17.", 32, G, "font2.ttf")])
segs.append("s99.mp4")

(OUT / "list.txt").write_text("".join(f"file '{s}'\n" for s in segs))
run(["-f", "concat", "-safe", "0", "-i", "list.txt", "-c", "copy", str(OUT_FILE)])
print("written", OUT_FILE)
