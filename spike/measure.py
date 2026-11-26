"""驱动 probe3 <mode>，用系统 screencapture 截图并计算靶窗口内部的亮度方差。
screencapture -R 用左上角原点：靶窗口 NS y=300..560 => CG y=609..869，内容区内部取 y=647..847。"""
import subprocess, sys, time, statistics, warnings
from PIL import Image
warnings.simplefilter("ignore")

MODES = sys.argv[1:] or ["baseline", "hud", "under", "full", "menu", "popover", "sheet", "titlebar", "dim"]
INNER = "320,629,360,200"      # 条纹内部（靶窗口 CG X=300 Y=577 W=400 H=292，标题栏 32）
WHOLE = "290,567,420,312"     # 含窗口四角

def stats(path):
    im = Image.open(path).convert("L")
    px = list(im.getdata())
    return statistics.pvariance(px), statistics.mean(px)

print(f"{'mode':<10} {'variance':>9} {'meanLum':>8}")
for mode in MODES:
    p = subprocess.Popen(["../build/probe3", mode], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.6)
    inner, whole = f"/tmp/_sc_{mode}_in.png", f"/tmp/_sc_{mode}_win.png"
    subprocess.run(["screencapture", "-x", "-R", INNER, inner], check=False)
    subprocess.run(["screencapture", "-x", "-R", WHOLE, whole], check=False)
    time.sleep(1.2)
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        p.kill()
    v, m = stats(inner)
    print(f"{mode:<10} {v:>9.0f} {m:>8.1f}")
