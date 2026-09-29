#!/usr/bin/env python3
"""The capability matrix behind docs/comparison.md: one scenario at a time, a hot program
edited while it runs, and what each reload did, in a log.

    python3 tests/matrix/run.py S7                    one scenario: logs/S7.log
    python3 tests/matrix/run.py S16 --tag -release -d:release
                                                      extra nim flags after the scenario;
                                                      --tag names the log (logs/S16-release.log)
    python3 tests/matrix/run.py times logs/S1.log     save to "building", and to "reloaded",
                                                      per edit

A scenario is scen/<S>/v1, v2, ...: v1 is built hot (with main_default.nim, unless it has
its own main.nim) and run; each later version's files are copied into src/ in turn, as an
editor saves (a temporary file, then a rename), and a file named DELETE lists files to
remove. It waits for each version's reload, or its failure, before the next. Each line the
program prints goes to the log with its time, beside the driver's own DRIVER lines. The
logs are read by hand: nothing here passes or fails on its own.
"""
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
RESULT = re.compile(r"hotreload: reloaded|build failed|signature changed|can.t load")
PLATFORM = {"win32": "windows", "darwin": "macos"}.get(sys.platform, "linux")


class Log:
    """lines with their times, from this driver and the program alike"""

    def __init__(self, path):
        self.path = path
        self.lock = threading.Lock()
        self.file = open(path, "w")
        self.results = 0

    def line(self, text):
        with self.lock:
            self.file.write(f"{time.time():.6f} {text}\n")
            self.file.flush()
            if RESULT.search(text):
                self.results += 1

    def contains(self, text):
        with self.lock, open(self.path) as f:
            return text in f.read()


def versions(scenario):
    """v1, v2, ... in order (v10 after v9)"""
    names = [d for d in os.listdir(os.path.join(HERE, "scen", scenario)) if re.fullmatch(r"v\d+", d)]
    return [os.path.join(HERE, "scen", scenario, d) for d in sorted(names, key=lambda d: int(d[1:]))]


def install(version, src):
    """a version's files into src/, as an editor saves them"""
    delete = os.path.join(version, "DELETE")
    if os.path.exists(delete):
        for name in open(delete).read().split():
            path = os.path.join(src, name)
            if os.path.exists(path):
                os.remove(path)
    for name in os.listdir(version):
        if name == "DELETE":
            continue
        tmp = os.path.join(src, "." + name + ".tmp")
        shutil.copyfile(os.path.join(version, name), tmp)
        os.replace(tmp, os.path.join(src, name))


def run(scenario, tag, flags):
    src = os.path.join(HERE, "src")
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
    log = Log(os.path.join(HERE, "logs", scenario + tag + ".log"))
    steps = versions(scenario)

    shutil.rmtree(src, ignore_errors=True)
    os.makedirs(src)
    install(steps[0], src)
    if not os.path.exists(os.path.join(src, "main.nim")):
        shutil.copyfile(os.path.join(HERE, "main_default.nim"), os.path.join(src, "main.nim"))

    program = os.path.join(HERE, "out", "hot", "matrix" + (".exe" if PLATFORM == "windows" else ""))
    log.line(f"DRIVER build exe ({' '.join(flags)})")
    build = subprocess.run(["nim", "c", "-d:hotReload", "-d:useMalloc", "--debugger:native", "--hints:off", *flags,
                            f"--nimcache:{os.path.join(HERE, 'build', PLATFORM, 'hot', 'exe-' + scenario + tag)}",
                            f"--out:{program}", os.path.join(src, "main.nim")],
                           cwd=HERE, capture_output=True, text=True)
    for text in (build.stdout + build.stderr).splitlines():
        log.line(text)
    if build.returncode != 0:
        log.line("DRIVER EXE BUILD FAILED")
        sys.exit(f"the build failed: {log.path}")
    log.line("DRIVER exe built")

    p = subprocess.Popen([program], cwd=HERE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)

    def read():
        for text in p.stdout:
            log.line(text.rstrip("\n"))
    reader = threading.Thread(target=read, daemon=True)
    reader.start()
    try:
        end = time.time() + 10
        while time.time() < end and not log.contains(" START"):
            time.sleep(0.1)
        time.sleep(float(os.environ.get("FIRSTWAIT", "1.5")))
        for version in steps[1:]:
            before = log.results
            install(version, src)
            log.line(f"DRIVER applied {os.path.basename(version)}")
            end = time.time() + 60
            while time.time() < end and log.results == before:
                time.sleep(0.05)
            time.sleep(float(os.environ.get("WAIT", "1.5")))
    finally:
        # Ctrl-C, as a person stops it (a terminate where there's no SIGINT to send)
        if PLATFORM == "windows":
            p.terminate()
        else:
            p.send_signal(signal.SIGINT)
        try:
            p.wait(5)
        except subprocess.TimeoutExpired:
            p.kill()
        reader.join(2)
        log.line("DRIVER done")
    print(log.path)


def times(path):
    """save to build start, and to the result, per edit"""
    if not os.path.exists(path):
        path = os.path.join(HERE, path)  # logs/S1.log, from wherever it's run
    applied = build = None
    version = ""
    for text in open(path):
        stamp, _, rest = text.rstrip("\n").partition(" ")
        t = float(stamp)
        if rest.startswith("DRIVER applied"):
            applied, version, build = t, rest.split()[-1], None
        elif applied is not None and rest.startswith("hotreload: building"):
            build = t
        elif applied is not None and re.search(r"hotreload: reloaded|build failed|signature changed", rest):
            what = "reloaded" if "reloaded" in rest else "result"
            start = f"{build - applied:.3f}s" if build is not None else "-"
            print(f"{version}: save->build start {start}, save->{what} {t - applied:.3f}s")
            applied = None


def main(args):
    if len(args) == 2 and args[0] == "times":
        return times(args[1])
    if not args or args[0].startswith("-"):
        sys.exit(__doc__)
    scenario, rest = args[0], args[1:]
    tag = ""
    if len(rest) >= 2 and rest[0] == "--tag":
        tag, rest = rest[1], rest[2:]
    run(scenario, tag, rest)


if __name__ == "__main__":
    main(sys.argv[1:])
