# Sourced by the build and test scripts (zsh).
mkdir -p .build/clang-cache
typeset -a compiler_flags
compiler_flags=(-swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" -module-cache-path "$PWD/.build/clang-cache")
toolchain_include="$(xcode-select -p)/usr/include/swift"
if [[ -f "$toolchain_include/module.modulemap" && -f "$toolchain_include/bridging.modulemap" ]] \
    && /usr/bin/grep -q 'module SwiftBridging' "$toolchain_include/module.modulemap" \
    && /usr/bin/grep -q 'module SwiftBridging' "$toolchain_include/bridging.modulemap"; then
    # Some upgraded CLT installations retain a duplicate 2023 map. Hide only the
    # obsolete map in this compiler invocation; never change system files.
    print '// Obsolete duplicate SwiftBridging map hidden for this build.' > .build/empty.modulemap
    cat > .build/toolchain-overlay.yaml <<EOF
{
  'version': 0,
  'roots': [{
    'type': 'file',
    'name': '$toolchain_include/module.modulemap',
    'external-contents': '$PWD/.build/empty.modulemap'
  }]
}
EOF
    compiler_flags+=(-vfsoverlay "$PWD/.build/toolchain-overlay.yaml")
fi
