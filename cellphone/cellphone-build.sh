#!/bin/zsh

BASE_DIR=$(pwd)/cellphone
cd $BASE_DIR

build_tslib() {
    echo "tslib was built"
    if [ -f build/lib/libts.so.0 ]; then
        return  
    fi
    TMP=$PATH
    export PATH=$BASE_DIR/../buildroot-2026.02/output/host/bin:$PATH
    git clone https://github.com/libts/tslib.git
    cd tslib

    ./autogen.sh
    ./configure \
      --host=arm-linux \
      --prefix=/usr \
      --sysconfdir=/etc \
      --enable-static \
      --disable-debug \
      CFLAGS="-Os -fPIC"
    make -j`nproc`
    cd ..
    mkdir -p build/lib/ts
    mkdir -p build/bin
    mkdir -p build/include
    cp -a tslib/plugins/.libs/*.so build/lib/ts
    cp -a tslib/plugins/.libs/*.a build/lib/ts
    cp -a tslib/src/.libs/libts.so.* build/lib
    cp -a tslib/src/.libs/libts.a build/lib
    cp -a tslib/tests/.libs/* build/bin
    cp tslib/src/tslib.h build/include
    cd $BASE_DIR
    export PATH=$TMP
}

build_cellphone() {
    if [ -f build/bin/lvglsim ]; then
        echo "Cellphone was built"
        return 0
    fi
    git clone https://github.com/rota1001/lv_port_linux.git
    cd lv_port_linux
    git checkout cellphone
    git submodule update --init --recursive
    cp ../cross_compile.cmake .
    cmake -B build -DCMAKE_TOOLCHAIN_FILE=./cross_compile.cmake
    cmake --build build -j$(nproc)
    cd $BASE_DIR
    cp lv_port_linux/build/bin/lvglsim build/bin
}

build_tslib
build_cellphone
