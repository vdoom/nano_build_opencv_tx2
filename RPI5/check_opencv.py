#!/usr/bin/env python3
"""
Verify the locally-built OpenCV 4.13.0 is the one Python is actually loading,
and that all the Pi 5 optimizations made it through.
"""

import os
import sys
import re

EXPECTED_VERSION = "4.13.0"
EXPECTED_PREFIX = "/usr/local"

OK = "\033[32mOK\033[0m"
FAIL = "\033[31mFAIL\033[0m"
WARN = "\033[33mWARN\033[0m"

failures = 0


def check(label, condition, detail=""):
    global failures
    tag = OK if condition else FAIL
    if not condition:
        failures += 1
    print(f"  [{tag}] {label}" + (f"  — {detail}" if detail else ""))


def warn(label, condition, detail=""):
    tag = OK if condition else WARN
    print(f"  [{tag}] {label}" + (f"  — {detail}" if detail else ""))


# ---------------------------------------------------------------------------
print("== 1. Import & version ==")
try:
    import cv2
except ImportError as e:
    print(f"  [{FAIL}] cannot import cv2: {e}")
    sys.exit(1)

cv2_path = os.path.dirname(cv2.__file__)
check(f"cv2.__version__ == {EXPECTED_VERSION}",
      cv2.__version__ == EXPECTED_VERSION,
      f"got {cv2.__version__}")
check(f"cv2 loaded from {EXPECTED_PREFIX}",
      cv2_path.startswith(EXPECTED_PREFIX),
      f"got {cv2_path}")

# ---------------------------------------------------------------------------
print("\n== 2. Shared libraries actually mapped ==")
try:
    with open(f"/proc/{os.getpid()}/maps") as f:
        maps = f.read()
    so_lines = sorted(set(re.findall(r"\S+/libopencv_[^\s]+\.so[^\s]*", maps)))
    if not so_lines:
        check("libopencv_*.so mapped", False, "no opencv libs in /proc/self/maps")
    else:
        for so in so_lines[:8]:
            check(f"{os.path.basename(so)} from {EXPECTED_PREFIX}",
                  so.startswith(EXPECTED_PREFIX), so)
        if len(so_lines) > 8:
            print(f"  ... {len(so_lines) - 8} more")
except OSError as e:
    print(f"  [{WARN}] could not read /proc/self/maps: {e}")

# ---------------------------------------------------------------------------
print("\n== 3. Build configuration ==")
info = cv2.getBuildInformation()


def grep(pattern, multi=False):
    rx = re.compile(pattern)
    hits = [l.strip() for l in info.splitlines() if rx.search(l)]
    return hits if multi else (hits[0] if hits else "")


def has(pattern):
    return bool(re.search(pattern, info))


# CPU baseline must include NEON + FP16 + DOTPROD (Cortex-A76 minimum we asked for)
baseline_line = grep(r"^\s*Baseline:")
check("Baseline includes NEON",     "NEON"     in baseline_line, baseline_line)
check("Baseline includes FP16",     "FP16"     in baseline_line, baseline_line)
check("Baseline includes DOTPROD",  "DOTPROD"  in baseline_line, baseline_line)

# Custom HALs (the big ARM win)
hal_line = grep(r"Custom HAL:")
check("KleidiCV HAL active", "KleidiCV" in hal_line, hal_line)
check("Carotene HAL active", "carotene" in hal_line.lower(), hal_line)

# Parallel framework
par_line = grep(r"Parallel framework:")
check("TBB parallel framework", "TBB" in par_line, par_line)

# LAPACK / Eigen
check("LAPACK available", has(r"Lapack:\s+YES"),
      grep(r"Lapack:"))
check("Eigen available",  has(r"Eigen:\s+YES"),
      grep(r"Eigen:"))

# Video I/O
check("FFMPEG enabled",     has(r"FFMPEG:\s+YES"),     grep(r"FFMPEG:"))
check("GStreamer enabled",  has(r"GStreamer:\s+YES"),  grep(r"GStreamer:"))
check("V4L2 enabled",       has(r"v4l/v4l2:\s+YES"),   grep(r"v4l/v4l2:"))

# Compiler flags actually applied
warn("compiled with -mcpu=cortex-a76", "cortex-a76" in info)
warn("compiled with -O3",               "-O3" in info)
warn("compiled with -ffast-math",       "ffast-math" in info)
warn("compiled with -flto",             "flto" in info)
warn("compiled with -fopenmp",          "fopenmp" in info)

# What we deliberately did NOT enable
warn("CUDA disabled (expected on Pi)",   has(r"CUDA:\s+NO") or not has(r"CUDA:\s+YES"))
warn("OpenCL disabled (expected on Pi)", has(r"OpenCL:[^\n]*NO") or not has(r"OpenCL:.*YES.*\(.*\)"))

# ---------------------------------------------------------------------------
print("\n== 4. Functional smoke test ==")
try:
    import numpy as np
    rng = np.random.default_rng(0)
    img = (rng.random((480, 640, 3)) * 255).astype(np.uint8)
    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    orb = cv2.ORB_create(500)
    kp = orb.detect(gray, None)
    check("ORB keypoint detection", len(kp) > 0, f"{len(kp)} keypoints")

    # DNN module loads (uses bundled protobuf)
    net = cv2.dnn.readNet  # just touch the symbol
    check("dnn module importable", callable(net))

    # contrib modules
    check("aruco (contrib) present",     hasattr(cv2, "aruco"))
    check("ximgproc (contrib) present",  hasattr(cv2, "ximgproc"))
    check("xfeatures2d (contrib) present", hasattr(cv2, "xfeatures2d"))
    check("freetype (contrib) present",  hasattr(cv2, "freetype"))

    # Threads
    threads, cpus = cv2.getNumThreads(), cv2.getNumberOfCPUs()
    check(f"threads ({threads}) > 1",    threads > 1, f"cpus={cpus}")

    # GStreamer pipeline parses (does NOT open a real device — just probes the backend)
    cap = cv2.VideoCapture("videotestsrc num-buffers=1 ! videoconvert ! appsink",
                           cv2.CAP_GSTREAMER)
    ok = cap.isOpened()
    cap.release()
    check("GStreamer backend usable", ok)

except Exception as e:
    print(f"  [{FAIL}] smoke test crashed: {e}")
    failures += 1

# ---------------------------------------------------------------------------
print("\n== 5. No competing OpenCV in sys.path ==")
try:
    import importlib.util
    spec = importlib.util.find_spec("cv2")
    origin = spec.origin if spec else None
    check("cv2 resolves to /usr/local",
          origin is not None and origin.startswith(EXPECTED_PREFIX),
          str(origin))

    # Look for a pip-installed shadow
    try:
        import importlib.metadata as md
        for dist in md.distributions():
            name = dist.metadata["Name"] or ""
            if name.lower() in ("opencv-python", "opencv-contrib-python",
                                "opencv-python-headless",
                                "opencv-contrib-python-headless"):
                warn(f"pip package '{name}' installed (may shadow the build)",
                     False, f"version {dist.version}")
                break
        else:
            warn("no shadowing pip 'opencv-*' package", True)
    except Exception:
        pass
except Exception as e:
    print(f"  [{WARN}] could not introspect cv2 spec: {e}")

# ---------------------------------------------------------------------------
print()
if failures:
    print(f"\033[31m{failures} check(s) failed.\033[0m")
    sys.exit(1)
print("\033[32mAll critical checks passed.\033[0m")
