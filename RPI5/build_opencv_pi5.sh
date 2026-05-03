#!/usr/bin/env bash
#
# Build & install OpenCV 4.13.0 + opencv_contrib for Raspberry Pi 5 (BCM2712 / Cortex-A76).
# Targets Debian 13 (trixie), aarch64, kernel 6.12+, GCC 14, CMake 3.31+, Python 3.13.
#
# Optimizations enabled:
#   - Cortex-A76 tuning (-mcpu=cortex-a76), implies ARMv8.2-A + FP16 + dotprod + crypto + i8mm
#   - NEON / FP16 / DOTPROD baseline; NEON_BF16 dispatch
#   - KleidiCV (Arm-tuned CV kernels) + Carotene NEON HAL
#   - TBB + OpenMP + pthreads parallel backends
#   - OpenBLAS / LAPACK / Eigen
#   - FFmpeg, GStreamer (incl. libcamera plugin), V4L2 for HW H.264/HEVC decode
#   - libjpeg-turbo / png / tiff / webp / openjpeg / openexr / freetype
#   - LTO, fast-math, contrib non-free modules
#
# Skipped on purpose: CUDA, OpenCL, Vulkan, Qt — not useful on Pi 5.

set -euo pipefail

OPENCV_VER="${OPENCV_VER:-4.13.0}"
SRC="${SRC:-$(cd "$(dirname "$0")" && pwd)}"
JOBS="${JOBS:-2}"
PREFIX="${PREFIX:-/usr/local}"

PY_EXE="$(command -v python3)"
PY_SITE="$($PY_EXE -c 'import sys,sysconfig;print(sysconfig.get_paths()["platlib"].replace("/usr/lib","/usr/local/lib"))')"

echo "==> OpenCV ${OPENCV_VER}"
echo "==> source dir : ${SRC}"
echo "==> install to : ${PREFIX}"
echo "==> jobs       : ${JOBS}"
echo "==> python     : ${PY_EXE}  (cv2 -> ${PY_SITE})"

# ---------------------------------------------------------------------------
# 1. System dependencies
# ---------------------------------------------------------------------------
echo "==> Installing apt dependencies"
sudo apt update
sudo apt install -y \
  build-essential cmake ninja-build pkg-config git ccache \
  libgtk-3-dev libcanberra-gtk3-dev \
  libavcodec-dev libavformat-dev libavutil-dev libswscale-dev libswresample-dev \
  libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
  gstreamer1.0-plugins-base gstreamer1.0-plugins-good gstreamer1.0-plugins-bad \
  gstreamer1.0-plugins-ugly gstreamer1.0-libav gstreamer1.0-tools \
  libv4l-dev v4l-utils libdc1394-dev \
  libjpeg-dev libpng-dev libtiff-dev libwebp-dev libopenjp2-7-dev libopenexr-dev \
  libtbb-dev libeigen3-dev libblas-dev liblapack-dev liblapacke-dev libopenblas-dev \
  libhdf5-dev libprotobuf-dev protobuf-compiler \
  libgflags-dev libgoogle-glog-dev libceres-dev \
  libfreetype-dev libharfbuzz-dev \
  python3-dev python3-numpy

# libcamera + gstreamer1.0-libcamera come from Raspberry Pi's repo (libcamera0.6 +rpt build).
# Don't reinstall via stock Debian — that downgrade would remove the +rpt one. Just confirm
# they're already present (they are on a stock Raspberry Pi OS image).
dpkg -s libcamera-dev          >/dev/null 2>&1 || echo "WARN: libcamera-dev missing"
dpkg -s gstreamer1.0-libcamera >/dev/null 2>&1 || echo "WARN: gstreamer1.0-libcamera missing"

# ---------------------------------------------------------------------------
# 2. Sources
# ---------------------------------------------------------------------------
cd "${SRC}"
if [ ! -d opencv ]; then
  echo "==> Cloning opencv ${OPENCV_VER}"
  git clone --depth 1 --branch "${OPENCV_VER}" https://github.com/opencv/opencv.git
fi
if [ ! -d opencv_contrib ]; then
  echo "==> Cloning opencv_contrib ${OPENCV_VER}"
  git clone --depth 1 --branch "${OPENCV_VER}" https://github.com/opencv/opencv_contrib.git
fi

mkdir -p opencv/build
cd opencv/build

# ---------------------------------------------------------------------------
# 3. Configure
# ---------------------------------------------------------------------------
CFLAGS_PI5="-mcpu=cortex-a76 -mtune=cortex-a76 -O3 -fomit-frame-pointer -ffast-math -pipe"

echo "==> Running cmake"
cmake -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="${PREFIX}" \
  -DOPENCV_EXTRA_MODULES_PATH="${SRC}/opencv_contrib/modules" \
  -DOPENCV_ENABLE_NONFREE=ON \
  -DOPENCV_GENERATE_PKGCONFIG=ON \
  -DBUILD_EXAMPLES=OFF -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF \
  -DBUILD_DOCS=OFF -DBUILD_opencv_apps=OFF \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_LTO=ON \
  -DENABLE_FAST_MATH=ON \
  \
  -DCMAKE_C_FLAGS="${CFLAGS_PI5}" \
  -DCMAKE_CXX_FLAGS="${CFLAGS_PI5}" \
  -DCPU_BASELINE=NATIVE \
  -DCPU_DISPATCH="NEON_FP16;NEON_DOTPROD;NEON_BF16" \
  -DENABLE_NEON=ON \
  \
  -DWITH_KLEIDICV=ON \
  -DWITH_CAROTENE=ON \
  -DWITH_TBB=ON -DBUILD_TBB=OFF \
  -DWITH_OPENMP=ON \
  -DWITH_PTHREADS_PF=ON \
  -DWITH_OPENBLAS=ON -DWITH_LAPACK=ON \
  -DOpenBLAS_INCLUDE_DIR=/usr/include/aarch64-linux-gnu \
  -DOpenBLAS_LIB=/usr/lib/aarch64-linux-gnu/libopenblas.so \
  -DLAPACK_INCLUDE_DIR="/usr/include/aarch64-linux-gnu;/usr/include" \
  -DLAPACK_LIBRARIES="/usr/lib/aarch64-linux-gnu/libopenblas.so;/usr/lib/aarch64-linux-gnu/liblapack.so" \
  -DLAPACK_CBLAS_H="cblas.h" \
  -DLAPACK_LAPACKE_H="lapacke.h" \
  -DWITH_EIGEN=ON \
  \
  -DWITH_V4L=ON -DWITH_LIBV4L=ON \
  -DWITH_FFMPEG=ON \
  -DWITH_GSTREAMER=ON \
  -DWITH_GTK=ON -DWITH_GTK_2_X=OFF \
  -DWITH_JPEG=ON -DWITH_PNG=ON -DWITH_TIFF=ON -DWITH_WEBP=ON \
  -DWITH_OPENJPEG=ON -DWITH_OPENEXR=ON \
  -DWITH_PROTOBUF=ON -DBUILD_PROTOBUF=ON \
  -DWITH_FREETYPE=ON \
  \
  -DWITH_CUDA=OFF -DWITH_OPENCL=OFF -DWITH_VULKAN=OFF \
  -DWITH_QT=OFF \
  \
  -DBUILD_opencv_python3=ON \
  -DPYTHON3_EXECUTABLE="${PY_EXE}" \
  -DOPENCV_PYTHON3_INSTALL_PATH="${PY_SITE}" \
  ..

# ---------------------------------------------------------------------------
# 4. Build & install
# ---------------------------------------------------------------------------
echo "==> Building (ninja -j${JOBS})"
ninja -j"${JOBS}"

echo "==> Installing to ${PREFIX}"
sudo ninja install
sudo ldconfig

# ---------------------------------------------------------------------------
# 5. Verify
# ---------------------------------------------------------------------------
echo
echo "==> Installed pkg-config version:"
PKG_CONFIG_PATH="${PREFIX}/lib/pkgconfig" pkg-config --modversion opencv4 || true

echo
echo "==> Python cv2 sanity check:"
"${PY_EXE}" - <<'PY'
import cv2
print("cv2 version:", cv2.__version__)
info = cv2.getBuildInformation()
keep = ("Version control", "Platform", "CPU/HW features", "Baseline",
        "Dispatched code", "Parallel framework", "Other third-party libraries",
        "OpenCL", "Video I/O", "Python 3", "Install path")
section = None
for line in info.splitlines():
    s = line.strip()
    if s.endswith(":") and not s.startswith("--"):
        section = s.rstrip(":")
    if any(k in line for k in ("NEON", "FP16", "DOTPROD", "KleidiCV", "Carotene",
                                "TBB", "OpenMP", "GStreamer", "FFMPEG",
                                "V4L/V4L2", "libcamera", "Eigen", "OpenBLAS",
                                "Version control", "install path", "Python 3")):
        print(line.rstrip())
PY

echo
echo "==> Done. OpenCV ${OPENCV_VER} installed under ${PREFIX}."
