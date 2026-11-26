#!/bin/zsh
# Runs the unit tests. Works with just the Command Line Tools (Swift Testing, no Xcode needed).
set -e
cd "$(dirname "$0")/.."
CLT=/Library/Developer/CommandLineTools/Library/Developer
args=()
if [[ ! -d /Applications/Xcode.app && -d $CLT/Frameworks ]]; then
  args=(-Xswiftc -F$CLT/Frameworks -Xlinker -F$CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/Frameworks -Xlinker -rpath -Xlinker $CLT/usr/lib)
fi
swift test "${args[@]}" "$@"
