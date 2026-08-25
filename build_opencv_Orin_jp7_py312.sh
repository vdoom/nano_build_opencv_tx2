#!/usr/bin/env bash
# 2019 Michael de Gans
#
# JetPack 7 (L4T R39.x) variant, derived from build_opencv_Orin_jp6_py310.sh
#
# Target: Jetson Orin (Nano / NX / AGX) running JetPack 7
#   Ubuntu 24.04 (noble), Python 3.12, CUDA 13.x, cuDNN 9.x, GCC 13, CMake 4.x
#
# What changed vs. the JetPack 6 script:
#   * default OpenCV bumped to 4.14.0 - this is the first release whose cudev
#     headers compile against the CCCL shipped with CUDA 13.2. Up to and
#     including 4.13.0, opencv_contrib/modules/cudev/.../ptr2d/zip.hpp opens
#     _LIBCUDACXX_BEGIN_NAMESPACE_STD, which CCCL renamed, and every .cu in
#     cudaarithm & friends dies with "tuple is not a template". Do not pin an
#     older version here unless you also drop the CUDA modules.
#   * CUDA_ARCH_BIN is 8.7 only - CUDA 13 dropped every arch below 7.5, so the
#     old "5.3,6.2,7.2,8.7" list makes nvcc fail outright
#   * CUDNN_VERSION='8.0' dropped; cuDNN 9 is detected from the headers, which
#     on 24.04 live in the multiarch dir (/usr/include/aarch64-linux-gnu)
#   * libtbb2 -> libtbb12 (libtbb2 no longer exists in noble)
#   * libatlas-base-dev dropped - on noble it conflicts with liblapacke
#     (Breaks: libatlas3-base < 3.10.3-14); OpenBLAS covers it anyway
#   * gstreamer -bad dev headers deliberately not installed: on noble they
#     drag in the distro libopencv-dev, which then shadows this build
#   * cudacodec / NVCUVID forced OFF - the Video Codec SDK is not part of Tegra
#   * -D CMAKE_POLICY_VERSION_MINIMUM=3.5 so CMake 4 accepts the bundled
#     third-party projects that still declare an ancient minimum
#   * python module goes to /usr/local/lib/python3.12/dist-packages, which is on
#     sys.path by default and does not fight with apt-managed dist-packages
#
# Env overrides: OPENCV_VER, JOBS, CUDA_ARCH
#
# Usage:  ./build_opencv_Orin_jp7_py312.sh [version] [test]

set -e

# change default constants here:
readonly PREFIX=/usr/local  # install prefix, (can be ~/.local for a user install)
readonly DEFAULT_VERSION=${OPENCV_VER:-4.14.0}  # gets reset by the first argument
readonly CPUS=3 #$(nproc)  # controls the number of jobs

# Orin is sm_87. AGX Thor (also JP7) is sm_110 - override with CUDA_ARCH=11.0
readonly CUDA_ARCH=${CUDA_ARCH:-8.7}

# nvcc on the CUDA modules peaks at ~2.5 GB per job, so size the build by memory
# rather than by core count, or an 8 GB Orin NX gets OOM-killed near the end.
if [[ -n "${JOBS}" ]] ; then
    : # respect the environment
else
    MEM_KB=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    SWAP_KB=$(awk '/SwapTotal/ {print $2}' /proc/meminfo)
    JOBS=$(( (MEM_KB + SWAP_KB) / 2621440 ))  # one job per 2.5 GiB
    [[ ${JOBS} -lt 1 ]] && JOBS=1
    [[ ${JOBS} -gt ${CPUS} ]] && JOBS=${CPUS}
    if [[ ${SWAP_KB} -eq 0 ]] && [[ ${MEM_KB} -lt 12582912 ]] ; then
        echo "WARNING: no swap and less than 12 GB of RAM."
        echo "         Building with -j${JOBS}. If the build gets OOM-killed, add swap:"
        echo "           sudo fallocate -l 8G /swapfile && sudo chmod 600 /swapfile"
        echo "           sudo mkswap /swapfile && sudo swapon /swapfile"
    fi
fi

check_platform () {
    if ! [[ -f /usr/local/cuda/bin/nvcc ]] ; then
        echo "nvcc not found under /usr/local/cuda - is CUDA installed?"
        exit 1
    fi
    echo "CUDA:   $(/usr/local/cuda/bin/nvcc --version | sed -n 's/.*release \([0-9.]*\).*/\1/p')"
    echo "L4T:    $(head -1 /etc/nv_tegra_release 2>/dev/null || echo unknown)"
    echo "Python: $(python3 -V)"
    echo "Board:  $(tr -d '\0' < /proc/device-tree/model 2>/dev/null || echo unknown)"
}

cleanup () {
# https://stackoverflow.com/questions/226703/how-do-i-prompt-for-yes-no-cancel-input-in-a-linux-shell-script
    while true ; do
        echo "Do you wish to remove temporary build files in /tmp/build_opencv ? "
        if ! [[ "$1" -eq "--test-warning" ]] ; then
            echo "(Doing so may make running tests on the build later impossible)"
        fi
        read -p "Y/N " yn
        case ${yn} in
            [Yy]* ) rm -rf /tmp/build_opencv ; break;;
            [Nn]* ) exit ;;
            * ) echo "Please answer yes or no." ;;
        esac
    done
}

setup () {
    cd /tmp
    if [[ -d "build_opencv" ]] ; then
        echo "It appears an existing build exists in /tmp/build_opencv"
        cleanup
    fi
    mkdir build_opencv
    cd build_opencv
}

git_source () {
    echo "Getting version '$1' of OpenCV"
    git clone --depth 1 --branch "$1" https://github.com/opencv/opencv.git
    git clone --depth 1 --branch "$1" https://github.com/opencv/opencv_contrib.git
}

install_dependencies () {
    # open-cv has a lot of dependencies, but most can be found in the default
    # package repository or should already be installed (eg. CUDA).
    echo "Installing build dependencies."
    sudo apt-get update
    #sudo apt-get dist-upgrade -y --autoremove
    sudo apt-get install -y \
        build-essential \
        cmake \
        git \
        gfortran \
        libavcodec-dev \
        libavformat-dev \
        libavutil-dev \
        libswresample-dev \
        libcanberra-gtk3-module \
        libdc1394-dev \
        libeigen3-dev \
        libglew-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer-plugins-good1.0-dev \
        libgstreamer1.0-dev \
        libgtk-3-dev \
        libhdf5-dev \
        libjpeg-dev \
        libjpeg8-dev \
        libjpeg-turbo8-dev \
        liblapack-dev \
        liblapacke-dev \
        libopenblas-dev \
        libopenjp2-7-dev \
        libpng-dev \
        libpostproc-dev \
        libprotobuf-dev \
        protobuf-compiler \
        libswscale-dev \
        libtbb-dev \
        libtbb12 \
        libtesseract-dev \
        libtiff-dev \
        libv4l-dev \
        libwebp-dev \
        libxine2-dev \
        libxvidcore-dev \
        libx264-dev \
        pkg-config \
        python3-dev \
        python3-numpy \
        python3-matplotlib \
        v4l-utils \
        zlib1g-dev
}

configure () {
    # python3.12 on 24.04: keep the module out of the apt-owned dist-packages
    local PY_EXE
    local PY_VER
    local PY_INC
    local PY_PKGS
    PY_EXE=$(command -v python3)
    PY_VER=$(${PY_EXE} -c 'import sys; print("%d.%d" % sys.version_info[:2])')
    PY_INC=$(${PY_EXE} -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
    PY_PKGS="${PREFIX}/lib/python${PY_VER}/dist-packages"

    if ! [[ -f "${PY_INC}/Python.h" ]] ; then
        echo "Python headers not found in ${PY_INC} - install python3-dev"
        exit 1
    fi

    # cuDNN 9 headers are multiarch-installed on Ubuntu 24.04
    local CUDNN_INC=/usr/include
    if [[ -f /usr/include/$(gcc -dumpmachine)/cudnn.h ]] ; then
        CUDNN_INC=/usr/include/$(gcc -dumpmachine)
    fi

    echo "Python: ${PY_EXE} (${PY_VER}), headers ${PY_INC}, cv2 -> ${PY_PKGS}"
    echo "cuDNN headers: ${CUDNN_INC}"

    local CMAKEFLAGS="
        -D BUILD_EXAMPLES=OFF
        -D BUILD_opencv_python2=OFF
        -D BUILD_opencv_python3=ON
        -D HAVE_opencv_python3=ON
        -D BUILD_opencv_cudacodec=OFF
        -D CMAKE_BUILD_TYPE=RELEASE
        -D CMAKE_INSTALL_PREFIX=${PREFIX}
        -D CMAKE_POLICY_VERSION_MINIMUM=3.5
        -D CUDA_ARCH_BIN=${CUDA_ARCH}
        -D CUDA_ARCH_PTX=
        -D CUDA_FAST_MATH=ON
        -D CUDA_TOOLKIT_ROOT_DIR=/usr/local/cuda
        -D CUDNN_INCLUDE_DIR=${CUDNN_INC}
        -D EIGEN_INCLUDE_PATH=/usr/include/eigen3
        -D ENABLE_NEON=ON
        -D OPENCV_DNN_CUDA=ON
        -D OPENCV_ENABLE_NONFREE=ON
        -D OPENCV_EXTRA_MODULES_PATH=/tmp/build_opencv/opencv_contrib/modules
        -D OPENCV_GENERATE_PKGCONFIG=ON
        -D WITH_CUBLAS=ON
        -D WITH_CUDA=ON
        -D WITH_CUDNN=ON
        -D WITH_GSTREAMER=ON
        -D WITH_LIBV4L=ON
        -D WITH_NVCUVID=OFF
        -D WITH_NVCUVENC=OFF
        -D WITH_OPENGL=ON
        -D WITH_TBB=ON
        -D PYTHON3_EXECUTABLE=${PY_EXE}
        -D PYTHON3_INCLUDE_DIR=${PY_INC}
        -D PYTHON3_PACKAGES_PATH=${PY_PKGS}
        -D PYTHON_DEFAULT_EXECUTABLE=${PY_EXE}"

    if [[ "$1" != "test" ]] ; then
        CMAKEFLAGS="
        ${CMAKEFLAGS}
        -D BUILD_PERF_TESTS=OFF
        -D BUILD_TESTS=OFF"
    fi

    echo "cmake flags: ${CMAKEFLAGS}"

    cd opencv
    mkdir build
    cd build
    cmake ${CMAKEFLAGS} .. 2>&1 | tee -a configure.log
}

verify () {
    # note: the repo's cv_ver.py uses distutils, which is gone in Python 3.12
    echo "Verifying the install:"
    python3 - <<'PYEOF' || echo "  WARNING: could not import the freshly built cv2"
import cv2
print("  version :", cv2.__version__)
print("  location:", cv2.__file__)
print("  CUDA devices:", cv2.cuda.getCudaEnabledDeviceCount())
info = cv2.getBuildInformation()
for line in info.splitlines():
    if any(k in line for k in ("NVIDIA CUDA:", "cuDNN:", "GStreamer:", "Python 3:")):
        print("  " + line.strip())
PYEOF
}

main () {

    local VER=${DEFAULT_VERSION}

    # parse arguments
    if [[ "$#" -gt 0 ]] ; then
        VER="$1"  # override the version
    fi

    if [[ "$#" -gt 1 ]] && [[ "$2" == "test" ]] ; then
        DO_TEST=1
    fi

    check_platform

    # prepare for the build:
    setup
    install_dependencies
    git_source ${VER}

    if [[ ${DO_TEST} ]] ; then
        configure test
    else
        configure
    fi

    # start the build
    echo "Building with -j${JOBS}"
    make -j${JOBS} 2>&1 | tee -a build.log

    if [[ ${DO_TEST} ]] ; then
        make test 2>&1 | tee -a test.log
    fi

    # avoid a sudo make install (and root owned files in ~) if $PREFIX is writable
    if [[ -w ${PREFIX} ]] ; then
        make install 2>&1 | tee -a install.log
    else
        sudo make install 2>&1 | tee -a install.log
    fi
    sudo ldconfig

    verify

    cleanup --test-warning

}

main "$@"
