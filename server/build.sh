#!/bin/zsh
set -e
HERE="${0:A:h}"
WORK="$HOME/Library/Caches/BifrostLink/server-build"
TAG=v4.1
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export JAVA_HOME="${JAVA_HOME:-$(/usr/libexec/java_home -v 17 2>/dev/null || /usr/libexec/java_home)}"
export PATH="$JAVA_HOME/bin:$PATH"
export SCRCPY_VERSION_NAME="4.1-bifrost"
if [[ ! -d "$WORK/scrcpy" ]]; then
  mkdir -p "$WORK"
  git clone --quiet --depth 1 --branch "$TAG" https://github.com/Genymobile/scrcpy.git "$WORK/scrcpy"
fi
cd "$WORK/scrcpy"
git reset --quiet --hard && git clean -fdq server
git apply "$HERE/bifrost.patch"
mkdir -p "$WORK/out"
BUILD_DIR="$WORK/out" ./server/build_without_gradle.sh >/dev/null
cp "$WORK/out/scrcpy-server" "$HERE/../Resources/bifrost-server.jar"
echo "built Resources/bifrost-server.jar ($SCRCPY_VERSION_NAME)"
