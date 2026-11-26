"""端到端冒烟测试。用 probe3 的条纹靶窗口当“被遮窗口”，用系统 screencapture 截图算亮度方差。

  python3 spike/smoke.py            # 默认材质
  python3 spike/smoke.py --all      # 再逐个材质跑一遍

覆盖的行为：
  focus     焦点不在靶上 → 毛玻璃；移到靶上 → 清晰；退出 → 清晰
  toggle    --disable / --enable / --toggle 即时生效（量延迟）
  settings  设置窗口能打开且尺寸正确、没有 Auto Layout 冲突、菜单栏图标存在
  drift     靶窗口每 1.2s 跳一个位置，覆盖层要跟着走（量延迟）
  low power 低性能模式：靶上盖的是暗色遮罩（还能看出条纹，但明显变暗），鼠标移上去仍变清晰
  screen off 设置里关掉的显示器完全不覆盖
  stage     台前调度开启（用 --set stageManager=1 模拟）时暂停覆盖
  switches  设置窗口里的快捷键 / 开机自启 / 显示器勾选框状态
  idle      鼠标和键盘静止满设定秒数后清晰的窗口重新模糊，动一下就恢复

黑名单 / 白名单只由 --selftest 覆盖：靶窗口 probe3 是裸二进制，没有 bundle id。
真实按键没法在测试里注入（需要辅助功能权限），所以快捷键只验证“注册成功”。

焦点位置用程序的 --mouse 调试参数指定（CG 坐标），不会挪动真实鼠标。
注意：测试期间程序会真的给你当前所有窗口盖毛玻璃，大约持续 20 秒。
"""
import os
import statistics
import subprocess
import sys
import time
import warnings

from PIL import Image, ImageStat

warnings.simplefilter("ignore")

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
BIN = os.path.join(ROOT, "build/PrivacyWindow.app/Contents/MacOS/PrivacyWindow")
PROBE = os.path.join(ROOT, "build/probe3")   # 由 build_tool("probe3") 从 spike/probe3.swift 编出来
WINLIST = os.path.join(ROOT, "build/winlist")
COVER = os.path.join(ROOT, "build/cover")
ON_TARGET = "500,760"      # 靶窗口（NS 原点 300,300）内部
baseline = 0                 # 由 main() 量出来
TARGET_PID = [0]             # main() 里靶窗口进程的 pid，用来判断“是谁盖住了靶区域”
AWAY = "60,1100"           # 远离靶窗口
CLEAR_MIN = 8000           # 条纹无遮挡时方差 ≈ 16000
BLURRED_MAX = 2000
DIM_MIN, DIM_MAX = 2500, 6000   # 50% 黑色遮罩：亮度减半，方差 ≈ 16000 × 0.25
results = []


def variance(rect="320,629,360,200"):
    out = "/tmp/_pw_inner.png"
    subprocess.run(["screencapture", "-x", "-R", rect, out], check=False)
    return ImageStat.Stat(Image.open(out).convert("L")).var[0]


def stop(proc):
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()


def wait_until(predicate, timeout):
    """反复量方差直到满足条件，返回耗时（秒）或 None。"""
    start = time.monotonic()
    while time.monotonic() - start < timeout:
        if predicate(variance()):
            return time.monotonic() - start
        time.sleep(0.02)
    return None


def record(name, ok, detail=""):
    results.append((name, ok))
    print(f"{name:<28} {'PASS' if ok else 'FAIL'}  {detail}")


def occluder(rect="320,629,360,200"):
    """盖在 rect 上面的最上层普通窗口（layer 0）的归属。靶窗口自己露在最上面时返回 None。

    跑测试时别的窗口随时可能被拖到靶窗口上面；那时截到的方差既不是
    “清晰”也不是“被盖住”，必须区分“程序不对”和“靶窗口被挡住”。"""
    out = subprocess.run([COVER, *rect.split(",")], capture_output=True, text=True).stdout
    for line in out.splitlines():
        cols = line.split("\t")
        if len(cols) >= 3 and cols[0] == "0":
            return None if int(cols[2]) == TARGET_PID[0] else cols[1]
    return None


def wait_target_visible(rect="320,629,360,200", timeout=6):
    """等靶窗口重新露到最上面（用户的窗口挪开）。返回挡住它的窗口名，没挡返回 None。"""
    who = occluder(rect)
    deadline = time.monotonic() + timeout
    while who is not None and time.monotonic() < deadline:
        time.sleep(0.25)
        who = occluder(rect)
    return who


def start_app(extra=(), log=None):
    mouse = [] if "--mouse" in extra else ["--mouse", AWAY]
    return subprocess.Popen([BIN, *mouse, *extra], stdout=log, stderr=subprocess.STDOUT)


def build_tool(name):
    """编译 spike/<name>.swift → build/<name>（源码没变就跳过）"""
    binary = os.path.join(ROOT, f"build/{name}")
    source = os.path.join(HERE, f"{name}.swift")
    if os.path.exists(binary) and os.path.getmtime(binary) > os.path.getmtime(source):
        return binary
    cache = ["-module-cache-path", os.path.join(ROOT, "build/mcache"),
             "-clang-scanner-module-cache-path", os.path.join(ROOT, "build/mcache/clang")]
    subprocess.run(["swiftc", "-swift-version", "5", source, *cache, "-o", binary],
                   check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return binary


def measure_covered_then_focused(extra):
    """鼠标先离开靶、1.5s 后移到靶上。返回 (离开时方差, 悬停时方差, 退出后方差)。"""
    app = start_app(["--mouse", f"{AWAY};{ON_TARGET}@1500", *extra])
    try:
        time.sleep(1.3)
        covered = variance()
        if not (covered < BLURRED_MAX or covered > CLEAR_MIN or DIM_MIN <= covered <= DIM_MAX):
            # 既不像盖住也不像清晰：多半是用户的窗口盖到了靶窗口上，查一下是谁
            who = wait_target_visible()
            if who is not None:
                print(f"  环境干扰：靶窗口被「{who}」挡住，这一项的结果不可信")
        time.sleep(1.6)                  # 切换点 + 防抖 40ms + 淡出 150ms
        focused = variance()
    finally:
        stop(app)
    time.sleep(0.5)
    return covered, focused, variance()


def phase_focus(target, material=None):
    extra = ["--trace", "--set", f"material={material}"] if material else []
    covered, focused, after_quit = measure_covered_then_focused(extra)
    record(f"focus {material or 'default'}", covered < BLURRED_MAX and focused > CLEAR_MIN and after_quit > CLEAR_MIN,
           f"blurred={covered:.0f} focused={focused:.0f} quit={after_quit:.0f}")


def phase_low_power():
    covered, focused, _ = measure_covered_then_focused(["--set", "lowPower=1"])
    record("low power uses dim mask", DIM_MIN <= covered <= DIM_MAX and focused > CLEAR_MIN,
           f"dimmed={covered:.0f} (期望 {DIM_MIN}–{DIM_MAX}) focused={focused:.0f}")


def phase_screen_off():
    covered, _, _ = measure_covered_then_focused(["--set", f"disableScreenAt={ON_TARGET.replace(',', ';')}"])
    record("disabled screen is left alone", covered > CLEAR_MIN, f"variance={covered:.0f}")


def phase_inverted_whitelist():
    """白名单反转：列表以外的一概不处理。靶窗口（probe3，没有 bundle id）不在列表里 → 必须保持清晰；
    关掉反转后同一个列表 = 普通白名单，靶窗口照常被盖。"""
    ghost = "com.example.not-running"
    covered, _, _ = measure_covered_then_focused(["--set", f"invertWhitelist=1,whitelist={ghost}"])
    record("inverted whitelist leaves unlisted apps alone", covered > CLEAR_MIN, f"variance={covered:.0f}")
    covered, _, _ = measure_covered_then_focused(["--set", f"invertWhitelist=0,whitelist={ghost}"])
    record("same list without inversion behaves as before", covered < BLURRED_MAX, f"blurred={covered:.0f}")


def phase_idle():
    """静止后重新模糊：鼠标停在靶窗口上 → 清晰；2 秒不动 → 重新盖住；再挪 1px → 立刻恢复清晰。
    keyActivity=0 关掉键盘检测，否则同时敲键盘的人会让它永远不静止。"""
    near = f"{int(ON_TARGET.split(',')[0]) + 1},{ON_TARGET.split(',')[1]}"
    app = start_app(["--mouse", f"{ON_TARGET};{near}@4500", "--set", "idleTimeout=2,keyActivity=0", "--trace"],
                    log=open(os.path.join(ROOT, "build/app-idle.out"), "w"))
    try:
        time.sleep(1.0)
        focused = variance()
        time.sleep(2.4)                 # 静止满 2 秒 + 淡入 150ms
        idle = variance()
        time.sleep(1.6)                 # 4.5s 处挪 1px + 防抖 40ms + 淡出 150ms
        back = variance()
    finally:
        stop(app)
    trace = open(os.path.join(ROOT, "build/app-idle.out"), encoding="utf-8", errors="replace").read()
    record("focused window blurs again after the idle timeout",
           focused > CLEAR_MIN and idle < BLURRED_MAX and "idle=1" in trace,
           f"focused={focused:.0f} idle={idle:.0f}")
    record("moving the mouse brings focus back", back > CLEAR_MIN, f"variance={back:.0f}")


def phase_stage_manager():
    covered, _, _ = measure_covered_then_focused(["--set", "stageManager=1"])
    record("stage manager pauses overlay", covered > CLEAR_MIN, f"variance={covered:.0f}")


def phase_toggle():
    with open(os.path.join(ROOT, "build/app.out"), "w") as log:
        app = start_app(["--trace"], log)
        time.sleep(1.5)
        blurred = variance()
        subprocess.run([BIN, "--disable"], check=False)
        off = wait_until(lambda v: v > CLEAR_MIN, 1.5)
        subprocess.run([BIN, "--enable"], check=False)
        on = wait_until(lambda v: v < BLURRED_MAX, 1.5)
        subprocess.run([BIN, "--toggle"], check=False)
        toggle_off = wait_until(lambda v: v > CLEAR_MIN, 1.5)
        subprocess.run([BIN, "--toggle"], check=False)
        toggle_on = wait_until(lambda v: v < BLURRED_MAX, 1.5)
        stop(app)
    def ms(t):                             # wait_until 超时返回 None，不能直接乘
        return "超时" if t is None else f"≤{t * 1000:.0f}ms"
    who = occluder() if off is None else None
    record("toggle off", blurred < BLURRED_MAX and off is not None,
           f"latency{ms(off)} (含截图耗时)" + ("" if off is not None else f"  靶区域最上层窗口: {who or '靶窗口自己'}"))
    record("toggle on", on is not None, f"latency{ms(on)} (含截图耗时)")
    record("toggle both ways", toggle_off is not None and toggle_on is not None)


def read_selfcheck(path):
    checks = {}
    for line in open(path, encoding="utf-8", errors="replace"):
        if line.startswith("selfcheck: "):
            parts = line.split(" ", 2)
            checks[parts[1]] = parts[2].strip() if len(parts) > 2 else ""
    return checks


def phase_settings():
    path = os.path.join(ROOT, "build/settings.out")
    with open(path, "w") as log:
        app = subprocess.Popen([BIN, "--open-settings", "--smoke", "5"], stdout=log, stderr=subprocess.STDOUT)
        try:
            checks = read_selfcheck(path)
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and "contentFits" not in checks:
                time.sleep(0.2)
                checks = read_selfcheck(path)
            build_tool("winlist")
            listing = ""
            for _ in range(10):          # 窗口刚 orderFront，等它上屏
                listing = subprocess.run([WINLIST, str(app.pid)], capture_output=True, text=True).stdout
                if "隐私窗口 设置" in listing:
                    break
                time.sleep(0.2)
        finally:
            stop(app)
    print(listing.rstrip())
    print(open(path, encoding="utf-8", errors="replace").read().strip())
    rows = [line.split("\t") for line in listing.splitlines() if line.count("\t") == 2]
    settings = [r[2] for r in rows if r[1] == "隐私窗口 设置"]
    record("settings window", any(abs(int(s.split()[2]) - 480) <= 2 and int(s.split()[3]) >= 590 for s in settings),
           settings[0] if settings else "not found")
    frame = checks.get("statusItem", "")
    record("menu bar icon", "x" in frame and "missing" not in frame, "frame=" + frame)
    record("settings layout", checks.get("contentFits") == "ok", "fits=" + checks.get("contentFits", "?"))
    # 窗口比主屏高就会被裁掉底部
    visible = checks.get("settingsWindowSize", "0x0").split("x")
    record("settings window fits on screen", len(visible) == 2 and int(visible[1]) <= 1100,
           "height=" + (visible[1] if len(visible) == 2 else "?"))
    screens = dict(item.split(":") for item in checks.get("screens", "").split(",") if ":" in item)
    record("per-screen switches", len(screens) >= 2 and set(screens.values()) == {"on"},
           "screens=" + checks.get("screens", "?"))
    record("launch at login off by default", checks.get("launchAtLogin") == "disabled",
           "state=" + checks.get("launchAtLogin", "?"))
    record("hotkey registered", checks.get("hotkey") == "registered", "state=" + checks.get("hotkey", "?"))


def phase_hotkey_off():
    path = os.path.join(ROOT, "build/settings-off.out")
    with open(path, "w") as log:
        app = subprocess.Popen([BIN, "--open-settings", "--smoke", "5", "--mouse", AWAY, "--set", "hotkeyEnabled=0"],
                               stdout=log, stderr=subprocess.STDOUT)
        try:
            checks = read_selfcheck(path)
            deadline = time.monotonic() + 4
            while time.monotonic() < deadline and "hotkey" not in checks:
                time.sleep(0.2)
                checks = read_selfcheck(path)
        finally:
            stop(app)
    record("hotkey can be turned off", checks.get("hotkey") == "off", "state=" + checks.get("hotkey", "?"))


def drain(pipe):
    """把管道里积压的行读完（probe3 每跳一格打一行，处理慢了会落后好几格）"""
    import fcntl
    fcntl.fcntl(pipe, fcntl.F_SETFL, fcntl.fcntl(pipe, fcntl.F_GETFL) | os.O_NONBLOCK)
    try:
        while pipe.readline():
            pass
    except (BlockingIOError, TypeError):
        pass
    finally:
        fcntl.fcntl(pipe, fcntl.F_SETFL, fcntl.fcntl(pipe, fcntl.F_GETFL) & ~os.O_NONBLOCK)


def phase_drift():
    """窗口移动时覆盖层要跟得上。

    - 靶窗口的真实位置用 winid 现查（CGWindowList），不信 probe3 打印的坐标：
      管道里积压的 pos 行可能落后好几格，按旧坐标截图截到的是桌面，会误判成“已盖住”。
    - 刚跳到新位置的那一两帧，合成画面里窗口和覆盖层可能只到了一个。只认两个特征值：
      ≈ baseline = 靶窗口在且没盖住；< BLURRED_MAX = 已盖住；中间值当作过渡忽略。
    每次移动后采样 1 秒：最后一次清晰帧的时刻 = 延迟上界；最后一帧仍清晰 = 没跟上。
    """
    winid = build_tool("winid")
    target = subprocess.Popen([PROBE, "baseline", "--stay", "--drift"], stdout=subprocess.PIPE, text=True)
    TARGET_PID[0] = target.pid
    time.sleep(1.2)
    app = start_app()
    time.sleep(2.0)
    firsts, latencies, stuck, moves = [], [], 0, 0
    covered_any = False
    try:
        drain(target.stdout)
        while moves < 8:
            line = target.stdout.readline()
            if line == "":
                break                                   # 靶窗口没了
            if not line.startswith("pos"):
                continue
            moves += 1
            listing = []
            for _ in range(10):              # 窗口刚跳走，CGWindowList 里可能还没更新
                listing = subprocess.run([winid, str(target.pid)], capture_output=True, text=True).stdout.split()
                if len(listing) >= 5:
                    break
                time.sleep(0.01)
            if len(listing) < 5:
                print(f"  drift: 查不到靶窗口（pid {target.pid}），中止")
                break
            x, y, w, h = map(int, listing[1:5])
            rect = f"{x + 20},{y + 52},{w - 40},{h - 92}"
            start = time.time()
            lastClear, covered, final, firstCovered = None, False, None, None
            while time.time() - start < 0.9:
                v = variance(rect)
                final = v
                if abs(v - baseline) < baseline * 0.02:
                    lastClear = time.time() - start
                elif v < BLURRED_MAX:
                    covered = True
                    if firstCovered is None:
                        firstCovered = time.time() - start
                        firsts.append(firstCovered)
            covered_any = covered_any or covered
            if lastClear is not None:
                latencies.append(lastClear)
            if lastClear is not None or not covered:
                stuck += 1
                print(f"  drift: window at {x},{y} last clear frame {lastClear}, final variance {final:.0f}")
            drain(target.stdout)                        # 下一格可能已经跳过了
    finally:
        stop(app)
        stop(target)
    worst = max(latencies) if latencies else 0
    # screencapture 本身要几十毫秒，所以这里得到的是延迟上界
    slowest = max(firsts) if firsts else 0
    record("overlay follows window", moves > 0 and stuck == 0 and covered_any and worst < 0.5,
           f"moves={moves} stuck={stuck} covered≤{slowest * 1000:.0f}ms, last clear frame≤{worst * 1000:.0f}ms (含截图耗时)")


def main():
    build_tool("probe3")
    build_tool("cover")
    target = subprocess.Popen([PROBE, "baseline", "--stay"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    global baseline
    TARGET_PID[0] = target.pid
    try:
        time.sleep(1.6)
        who = wait_target_visible()
        baseline = variance()
        print(f"baseline variance = {baseline:.0f}")
        if baseline < CLEAR_MIN:
            print(f"RESULT: FAIL（靶窗口没露出最上层，被「{who}」挡住了；把那个窗口挪开再跑）" if who
                  else "RESULT: FAIL（靶窗口没出现在预期位置，先查 probe3）")
            return 1
        if "--drift-only" in sys.argv:
            stop(target)
            phase_drift()
            return 0
        phase_focus(target)
        if "--all" in sys.argv:
            for material in ["fullScreenUI", "popover", "titlebar", "underWindowBackground"]:
                phase_focus(target, material)
        phase_toggle()
        phase_low_power()
        phase_screen_off()
        phase_inverted_whitelist()
        phase_idle()
        phase_stage_manager()
        phase_settings()
        phase_hotkey_off()
    finally:
        stop(target)
    phase_drift()

    trace = open(os.path.join(ROOT, "build/app.out"), encoding="utf-8", errors="replace").read()
    record("overlay ignores mouse", "overlayIgnoresMouse=true" in trace)

    passed = sum(1 for _, ok in results if ok)
    print(f"RESULT: {'PASS' if passed == len(results) else 'FAIL'} ({passed}/{len(results)})")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
