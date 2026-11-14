"""Final v1.0.0 showcase with four players (1920x1080) from the takes recorded by showcase4.ps1.

Usage: python make_showcase4.py <caps dir> <out.mp4> [take]
<caps dir> holds <take>-horde, <take>-campaign, <take>-ghostsend; each has raw.mkv, events.txt and rects.txt
(screen position + size of each game window's client area: "A x y w h").
"""
import shutil
import subprocess
import sys
from pathlib import Path

CAPS, OUT_FILE = Path(sys.argv[1]), Path(sys.argv[2])
TAKE = sys.argv[3] if len(sys.argv) > 3 else "v100q"
OUT = CAPS / f"{TAKE}-out"
OUT.mkdir(exist_ok=True)
FF = next((Path.home() / "AppData/Local/Microsoft/WinGet/Packages").glob("Gyan.FFmpeg*/ffmpeg-*/bin/ffmpeg.exe"))
shutil.copy(r"C:\Windows\Fonts\segoeuib.ttf", OUT / "font.ttf")
shutil.copy(r"C:\Windows\Fonts\segoeui.ttf", OUT / "font2.ttf")
ACCENT, BG = "0xE8452C", "0x0b0b0d"
TW, TH, GAP = 800, 450, 8
GX, GY = (1920 - 2 * TW - GAP) // 2, 172
POS = {"A": (GX, GY), "B": (GX + TW + GAP, GY), "C": (GX, GY + TH + GAP), "D": (GX + TW + GAP, GY + TH + GAP)}
LABEL = {"A": "HOST", "B": "PLAYER 2", "C": "PLAYER 3", "D": "PLAYER 4"}


def run(args, cwd=OUT):
    subprocess.run([str(FF), "-v", "error", "-y"] + args, cwd=cwd, check=True)


TAKES = {}
for part in ("horde", "campaign", "ghostsend"):
    d = CAPS / f"{TAKE}-{part}"
    if not (d / "raw.mkv").exists():
        continue
    if not (d / "raw.mp4").exists():   # mkv seeks badly - remux once
        run(["-i", str(d / "raw.mkv"), "-c", "copy", str(d / "raw.mp4")])
    ev = {}
    for line in (d / "events.txt").read_text().splitlines():
        t, name = line.split(maxsplit=1)
        ev[name] = float(t)
    rects = {}
    for line in (d / "rects.txt").read_text().splitlines():
        k, x, y, w, h = line.split()
        rects[k] = tuple(int(v) for v in (x, y, w, h))
    TAKES[part] = (d, ev, rects)
_n = 0


def dt(text, size, color, y, font="font.ttf", x="(w-tw)/2", extra=""):
    global _n
    _n += 1
    (OUT / f"t{_n}.txt").write_text(text, encoding="utf-8")
    return f"drawtext=fontfile={font}:expansion=none:textfile=t{_n}.txt:fontsize={size}:fontcolor={color}:x={x}:y={y}{extra}"


def fades(d):
    return f"fade=t=in:st=0:d=0.3,fade=t=out:st={d - 0.3:.2f}:d=0.3"


def enc(name, inputs, fc, d):
    run(inputs + ["-filter_complex", fc, "-map", "[v]", "-t", f"{d:.2f}", "-an", "-r", "30",
                  "-c:v", "libx264", "-crf", "18", "-preset", "medium", "-pix_fmt", "yuv420p", name])


def grid(name, part, t0, t1, maxd, title, sub):
    """t0..t1 of the take as a 2x2 grid; sped up to fit maxd seconds."""
    d0, ev, rects = TAKES[part]
    src_d = t1 - t0
    speed = max(1.0, src_d / maxd)
    d = src_d / speed
    fc = f"[0:v]setpts=(PTS-STARTPTS)/{speed:.4f},fps=30,split=4[i0][i1][i2][i3];color=c={BG}:s=1920x1080:d={d:.2f}:r=30[bg];"
    last = "bg"
    for n, k in enumerate("ABCD"):
        x, y, w, h = rects[k]
        fc += f"[i{n}]crop={w}:{h}:{x}:{y},scale={TW}:{TH}:flags=lanczos,setsar=1[c{n}];"
        px, py = POS[k]
        fc += f"[{last}][c{n}]overlay={px}:{py}:shortest=1[o{n}];"
        last = f"o{n}"
    texts = [dt(title, 72, ACCENT, 26), dt(sub, 36, "white", 112, "font2.ttf")]
    for k in "ABCD":
        px, py = POS[k]
        texts.append(dt(LABEL[k], 26, "white", py + 10, "font.ttf", f"{px + 12}",
                        ":box=1:boxcolor=0x000000@0.55:boxborderw=8"))
    if speed > 1.3:
        texts.append(dt(f"x{speed:.0f}" if speed >= 2 else "fast", 26, "0xbbbbbb", 1080 - 46, "font.ttf", "1920-tw-30"))
    fc += f"[{last}]" + ",".join(texts) + f",{fades(d)}[v]"
    enc(name, ["-ss", f"{max(0.0, t0):.2f}", "-t", f"{src_d + 0.5:.2f}", "-i", str(d0 / "raw.mp4")], fc, d)


def card(name, d, lines, y=140):
    parts = []
    for text, size, color, font in lines:
        parts.append(dt(text, size, color, y, font))
        y += int(size * 1.45)
    fc = f"color=c={BG}:s=1920x1080:d={d}:r=30," + ",".join(parts) + f",{fades(d)}[v]"
    enc(name, ["-f", "lavfi", "-i", "anullsrc"], fc, d)


G, W, A = "0xaaaaaa", "white", ACCENT
segs = []
card("s00.mp4", 5, [("", 60, W, "font.ttf"), ("TREPANG2 CO-OP", 130, A, "font.ttf"),
                    ("v1.0  -  now up to 4 players", 60, W, "font2.ttf"), ("", 30, W, "font2.ttf"),
                    ("The whole story campaign  -  Horde  -  side missions", 42, G, "font2.ttf")])
segs.append("s00.mp4")
plan = []
if "horde" in TAKES:
    H = TAKES["horde"][1]
    plan += [
        ("s01.mp4", "horde", H["join B"] - 0.5, H["in D"] + 2.5, 12, "UP TO FOUR PLAYERS", "One player hosts, friends join any time  -  IP / VPN or Steam"),
        ("s02.mp4", "horde", H["together"] - 0.5, H["menu"] + 5.0, 12, "ALL TOGETHER", "F4  -  the co-op menu lists every player"),
        ("s03.mp4", "horde", H["fight"] + 3.0, H["fight"] + 17.0, 14, "FIGHT AS A TEAM", "Shared enemies  -  everyone's damage counts  -  tougher enemies per player"),
        ("s04.mp4", "horde", H["down"] - 0.5, H["revived"] + 2.0, 12, "DOWN, NOT OUT", "Stand next to a downed partner to get them back up"),
        ("s05.mp4", "horde", H["spectate"] - 0.5, H["revived2"] + 2.5, 14, "WATCH YOUR TEAM", "While down you see through a partner's eyes  -  left click: next one"),
        ("s06.mp4", "horde", H["wipe"] - 0.5, H["back"] + 4.0, 14, "EVERYONE DOWN?", "The arena restarts for the whole team"),
    ]
if "campaign" in TAKES:
    C = TAKES["campaign"][1]
    plan += [
        ("s07.mp4", "campaign", C["together"] - 1.0, C["together"] + 6.0, 7, "THE WHOLE CAMPAIGN", "Host any story mission  -  partners spawn next to the host"),
        ("s08.mp4", "campaign", C["elevator"] - 0.3, C["elevatordown"] + 3.0, 14, "ELEVATORS FOR EVERYONE", "Doors, elevators, cutscenes and story triggers  -  shared"),
        ("s09.mp4", "campaign", C["restart"] - 0.5, C["back"] + 4.0, 12, "CHECKPOINTS & RESTARTS", "The host's game reloads  -  everyone comes back on their own"),
    ]
if "ghostsend" in TAKES:
    E = TAKES["ghostsend"][1]
    plan += [("s10.mp4", "ghostsend", E["end"] - 1.0, E["safehouse"] + 7.0, 12, "MISSION COMPLETE", "Back to the safehouse together, on to the next mission")]
for name, part, t0, t1, maxd, title, sub in plan:
    grid(name, part, t0, t1, maxd, title, sub)
    segs.append(name)
card("s90.mp4", 10, [("ALSO IN CO-OP", 90, A, "font.ttf"),
                     ("Cutscenes, dialogue, objectives, terminals and story triggers - shared", 42, W, "font2.ttf"),
                     ("Spectating while down, boss health bars, fall-off-the-map rescue", 42, W, "font2.ttf"),
                     ("Horde on all 50 arenas, the shop for partners, all 7 side missions", 42, W, "font2.ttf"),
                     ("Your safehouse outfit or 300 enemy looks  -  EXTRAS  -  F6 quick access", 42, W, "font2.ttf"),
                     ("Tested with 1, 2, 3 and 4 players through the whole game", 42, W, "font2.ttf")])
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
