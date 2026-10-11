#!/usr/bin/env sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p vendor .tools
if [ ! -f vendor/knots/build.zig ]; then
  git clone https://github.com/knots-ui/knots.git vendor/knots
  git -C vendor/knots checkout 88bd83b4dc79f3178c9ca5345d5cb3c1c536f58f
fi
for patch in knots-native-dialogs.patch knots-owned-completions.patch knots-pointer-targets.patch; do
  if ! git -C vendor/knots apply --reverse --check "$PWD/patches/$patch" 2>/dev/null; then
    git -C vendor/knots apply --check "$PWD/patches/$patch"
    git -C vendor/knots apply "$PWD/patches/$patch"
  fi
done
if [ ! -f vendor/libgit2/CMakeLists.txt ]; then
  git clone --depth 1 --branch v1.9.7 https://github.com/libgit2/libgit2.git vendor/libgit2
fi
if [ ! -f vendor/nfd/src/include/nfd.h ]; then
  git clone --depth 1 --branch v1.4.1 https://github.com/btzy/nativefiledialog-extended.git vendor/nfd
fi
test "$(git -C vendor/nfd rev-parse HEAD)" = 65b2f070a0fcfee0d453a64e770a217ab0b6ff4f
cmake -S vendor/libgit2 -B .tools/git2-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/.tools/git2" -DCMAKE_INSTALL_LIBDIR=lib-DBUILD_TESTS=OFF -DBUILD_CLI=OFF -DBUILD_EXAMPLES=OFF -DUSE_SSH=exec -DUSE_BUNDLED_ZLIB=ON -DREGEX_BACKEND=builtin
cmake --build .tools/git2-build --parallel 4
cmake --install .tools/git2-build
if [ "$(uname -s)" = Linux ]; then
  git -C vendor/nfd submodule update --init --depth 1
  cmake -S vendor/nfd -B .tools/nfd-build -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PWD/.tools/nfd" -DLIB_INSTALL_DIR=lib -DBUILD_SHARED_LIBS=OFF -DNFD_BUILD_TESTS=OFF -DNFD_PORTAL=ON -DNFD_X11=OFF -DNFD_WAYLAND=ON
  cmake --build .tools/nfd-build --parallel 4
  cmake --install .tools/nfd-build
fi
