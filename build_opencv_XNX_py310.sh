#!/usr/bin/env bash
# 2019 Michael de Gans
# Modified for Python 3.10 (altinstall) with venv support

set -e

# change default constants here:
readonly PREFIX=/usr/local  # install prefix, (can be ~/.local for a user install)
readonly DEFAULT_VERSION=4.4.0  # controls the default version (gets reset by the first argument)
readonly CPUS=$(nproc)  # controls the number of jobs

# Python 3.10 venv path - modify this if your venv is in a different location
readonly VENV_PATH="${HOME}/venv310"

# better board detection. if it has 6 or more cpus, it probably has a ton of ram too
if [[ $CPUS -gt 5 ]]; then
    # something with a ton of ram
    #JOBS=$CPUS
    JOBS=3
else
    JOBS=3  # you can set this to 4 if you have a swap file
    # otherwise a Nano will choke towards the end of the build
fi

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
        libatlas-base-dev \
        libavcodec-dev \
        libavformat-dev \
        libavresample-dev \
        libcanberra-gtk3-module \
        libdc1394-22-dev \
        libeigen3-dev \
        libglew-dev \
        libgstreamer-plugins-base1.0-dev \
        libgstreamer-plugins-good1.0-dev \
        libgstreamer1.0-dev \
        libgtk-3-dev \
        libjpeg-dev \
        libjpeg8-dev \
        libjpeg-turbo8-dev \
        liblapack-dev \
        liblapacke-dev \
        libopenblas-dev \
        libpng-dev \
        libpostproc-dev \
        libswscale-dev \
        libtbb-dev \
        libtbb2 \
        libtesseract-dev \
        libtiff-dev \
        libv4l-dev \
        libxine2-dev \
        libxvidcore-dev \
        libx264-dev \
        pkg-config \
        python-dev \
        python-numpy \
        python3-dev \
        qv4l2 \
        v4l-utils \
        zlib1g-dev
}

configure () {
    # Detect Python 3.10 paths
    # First check if venv exists and is activated, otherwise use system python3.10
    if [[ -n "$VIRTUAL_ENV" ]] && [[ "$VIRTUAL_ENV" == "$VENV_PATH" ]]; then
        echo "Using activated venv at $VIRTUAL_ENV"
        PYTHON3_EXEC="${VIRTUAL_ENV}/bin/python3"
        PYTHON3_PACKAGES="${VIRTUAL_ENV}/lib/python3.10/site-packages"
    elif [[ -d "$VENV_PATH" ]]; then
        echo "Using venv at $VENV_PATH (not activated, but will use it)"
        PYTHON3_EXEC="${VENV_PATH}/bin/python3"
        PYTHON3_PACKAGES="${VENV_PATH}/lib/python3.10/site-packages"
    else
        echo "Warning: venv not found at $VENV_PATH, using system python3.10"
        PYTHON3_EXEC="/usr/local/bin/python3.10"
        PYTHON3_PACKAGES="/usr/local/lib/python3.10/site-packages"
    fi

    # Try to detect include directory
    if [[ -d "/usr/local/include/python3.10" ]]; then
        PYTHON3_INCLUDE="/usr/local/include/python3.10"
    elif [[ -d "/usr/include/python3.10" ]]; then
        PYTHON3_INCLUDE="/usr/include/python3.10"
    else
        echo "Error: Could not find Python 3.10 include directory"
        exit 1
    fi

    echo "Python 3.10 configuration:"
    echo "  Executable: $PYTHON3_EXEC"
    echo "  Include dir: $PYTHON3_INCLUDE"
    echo "  Packages path: $PYTHON3_PACKAGES"

    # Verify Python executable exists
    if [[ ! -f "$PYTHON3_EXEC" ]]; then
        echo "Error: Python executable not found at $PYTHON3_EXEC"
        exit 1
    fi

    local CMAKEFLAGS="
        -D BUILD_EXAMPLES=OFF
        -D BUILD_opencv_python2=OFF
        -D BUILD_opencv_python3=ON
        -D HAVE_opencv_python3=ON \
        -D CMAKE_BUILD_TYPE=RELEASE
        -D CMAKE_INSTALL_PREFIX=${PREFIX}
        -D CUDA_ARCH_BIN=5.3,6.2,7.2,8.7
        -D CUDA_ARCH_PTX=
        -D CUDA_FAST_MATH=ON
        -D CUDNN_VERSION='8.0'
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
        -D WITH_OPENGL=ON
        -D PYTHON3_EXECUTABLE=${PYTHON3_EXEC}
        -D PYTHON3_INCLUDE_DIR=${PYTHON3_INCLUDE}
        -D PYTHON3_PACKAGES_PATH=${PYTHON3_PACKAGES}
        -D PYTHON_DEFAULT_EXECUTABLE=${PYTHON3_EXEC}"

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

main () {

    local VER=${DEFAULT_VERSION}

    # parse arguments
    if [[ "$#" -gt 0 ]] ; then
        VER="$1"  # override the version
    fi

    if [[ "$#" -gt 1 ]] && [[ "$2" == "test" ]] ; then
        DO_TEST=1
    fi

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

    cleanup --test-warning

}

main "$@"
