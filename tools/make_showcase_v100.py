"""v1.0.0 showcase (1920x1080) from the takes recorded by showcase_v100.ps1.

Usage: python make_showcase_v100.py <caps dir> <out.mp4>
<caps dir> holds v100-campaign, v100-ghostsend, v100-credits; each has raw.mkv and events.txt.
Host window at x 0..1280, partner at 1290..2570.
"""
import shutil
import subprocess
import sys
from pathlib import Path

CAPS, OUT_FILE = Path(sys.argv[1]), Path(sys.argv[2])
OUT = CAPS / "v100-out"
OUT.mkdir(exist_ok=True)
FF = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/ffmpeg-*/bin/ffmpeg.exe"))
shutil.copy(r"C:\Windows\Fonts\segoeuib.ttf", OUT / "font.ttf")
shutil.copy(r"C:\Windows\Fonts\segoeui.ttf", OUT / "font2.ttf")
ACCENT, BG = "0xE8452C", "0x0b0b0d"
WA, WB = "crop=1280:720:0:0", "crop=1280:720:1290:0"


def run(args, cwd=OUT):
    subprocess.run([str(FF), "-v", "error", "-y"] + args, cwd=cwd, check=True)


TAKES = {}
for part in ("campaign", "ghostsend", "credits"):
    d = CAPS / f"v100-{part}"
    if not (d / "raw.mp4").exists():   # mkv seeks badly - remux once
        run(["-i", str(d / "raw.mkv"), "-c", "copy", str(d / "raw.mp4")])
    ev = {}
    for line in (d / "events.txt").read_text().splitlines():
        t, name = line.split(maxsplit=1)
        ev[name] = float(t)
    TAKES[part] = (d, ev)
_n = 0


def dt(text, size, color, y, font="font.ttf", x="(w-tw)/2"):
    global _n
    _n += 1
    (OUT / f"t{_n}.txt").write_text(text, encoding="utf-8")
    return f"drawtext=fontfile={font}:expansion=none:textfile=t{_n}.txt:fontsize={size}:fontcolor={color}:x={x}:y={y}"


def fades(d):
    return f"fade=t=in:st=0:d=0.3,fade=t=out:st={d - 0.3:.2f}:d=0.3"


def enc(name, inputs, fc, d):
    run(inputs + ["-filter_complex", fc, "-map", "[v]", "-t", str(d), "-an", "-r", "30",
                  "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p", name])


def dual(name, part, t, d, title, sub):
    src = TAKES[part][0] / "raw.mp4"
    fc = (f"[0:v]split[a][b];[a]{WA},scale=944:531:flags=lanczos,setsar=1[l];[b]{WB},scale=944:531:flags=lanczos,setsar=1[r];"
          f"color=c={BG}:s=1920x1080:d={d}:r=30[bg];[bg][l]overlay=12:300:shortest=1[t1];[t1][r]overlay=964:300:shortest=1,"
          + ",".join([dt(title, 80, ACCENT, 60), dt(sub, 40, "white", 168, "font2.ttf"),
                      dt("HOST", 30, "0xbbbbbb", 845, "font.ttf", "12+(944-tw)/2"),
                      dt("PARTNER", 30, "0xbbbbbb", 845, "font.ttf", "964+(944-tw)/2")])
          + f",{fades(d)}[v]")
    enc(name, ["-ss", f"{max(0.0, t):.2f}", "-t", str(d), "-i", str(src)], fc, d)


def card(name, d, lines):
    parts, y = [], 140
    for text, size, color, font in lines:
        parts.append(dt(text, size, color, y, font))
        y += int(size * 1.45)
    fc = f"color=c={BG}:s=1920x1080:d={d}:r=30," + ",".join(parts) + f",{fades(d)}[v]"
    enc(name, ["-f", "lavfi", "-i", "anullsrc"], fc, d)


G, W, A = "0xaaaaaa", "white", ACCENT
EC, EG, ER = TAKES["campaign"][1], TAKES["ghostsend"][1], TAKES["credits"][1]
segs = []
card("s00.mp4", 5, [("", 60, W, "font.ttf"), ("TREPANG2 CO-OP", 130, A, "font.ttf"),
                    ("v1.0  -  the whole campaign together", 60, W, "font2.ttf"), ("", 30, W, "font2.ttf"),
                    ("Story missions  -  Horde  -  side missions", 42, G, "font2.ttf")])
segs.append("s00.mp4")
plan = [
    ("s01.mp4", "campaign", EC["together"] - 3.0, 8.0, "JOIN YOUR FRIEND'S MISSION", "F4 - HOST in any mission, the partner joins next to the host"),
    ("s02.mp4", "campaign", EC["elevator"] + 0.3, 12.0, "ELEVATORS FOR EVERYONE", "The story moves the elevator  -  whoever rides it goes along"),
    ("s03.mp4", "campaign", EC["fall"] + 0.3, 8.0, "FELL OFF THE MAP?", "You're brought back to the host automatically"),
    ("s04.mp4", "campaign", EC["back"] - 4.0, 9.0, "CHECKPOINTS & RESTARTS", "The host's game reloads  -  partners come back on their own"),
    ("s05.mp4", "ghostsend", EG["safehouse"] - 2.0, 9.0, "MISSION COMPLETE", "Back to the safehouse together, then on to the next mission"),
    ("s06.mp4", "credits", ER["credits"] + 1.0, 11.0, "TO THE END", "The final scenes and credits for every player"),
]
for name, part, t, d, title, sub in plan:
    dual(name, part, t, d, title, sub)
    segs.append(name)
card("s90.mp4", 10, [("ALSO IN CO-OP", 90, A, "font.ttf"),
                     ("Cutscenes, dialogue, objectives, doors, terminals and story triggers - shared", 42, W, "font2.ttf"),
                     ("Down & revive, spectating, boss health bars, tougher enemies per player", 42, W, "font2.ttf"),
                     ("Horde on all 50 arenas, the shop for partners, side missions", 42, W, "font2.ttf"),
                     ("Your safehouse outfit or 300 enemy looks  -  EXTRAS  -  F6 quick access", 42, W, "font2.ttf"),
                     ("IP / VPN or Steam  -  up to 3 players", 42, W, "font2.ttf")])
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
