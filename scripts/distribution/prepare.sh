#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."

mode="${1:-development}"
case "$mode" in development|release) ;; *) exit 2 ;; esac

build="$PWD/.build/distribution"
downloads="$build/downloads"
mkdir -p "$downloads" "$build/tmp"
export TMPDIR="$build/tmp"

fetch() {
    local checksum="$1" url="$2" destination="$3"
    if [[ ! -f "$destination" ]]; then
        mkdir -p "$(dirname "$destination")"
        curl --fail --location --silent --show-error --retry 2 "$url" -o "$destination.part"
        if ! printf '%s  %s\n' "$checksum" "$destination.part" | shasum -a 256 -c --status; then
            rm -f "$destination.part"
            echo "下载文件校验失败：$url" >&2
            return 1
        fi
        mv "$destination.part" "$destination"
    fi
    if ! printf '%s  %s\n' "$checksum" "$destination" | shasum -a 256 -c --status; then
        echo "缓存文件校验失败，请删除后重试：$destination" >&2
        return 1
    fi
}

staging="$(mktemp -d "$build/prepare.XXXXXXXX")"
trap 'rm -rf "$staging"' EXIT

prepare_musicdl() {
    local host_arch go_sha go_archive go source_archive source key
    host_arch="$(uname -m)"
    case "$host_arch" in
        arm64)
            go_sha=875cf54a15311eee2c99b9dd67c68c4a49351d489ab622bf2cfd28c8f2078d3c
            ;;
        x86_64)
            host_arch=amd64
            go_sha=278d580b32e299fe4a9c990fcf2d02acfe538c7e551a6ee18f9c7164573d2c63
            ;;
        *)
            echo "此架构不支持构建 music-dl。" >&2
            return 1
            ;;
    esac
    key="$(shasum -a 256 scripts/distribution/prepare.sh scripts/distribution/musicdl{.patch,-main.go,-build.sh} | shasum -a 256 | cut -d ' ' -f 1)"
    if [[ -x "$build/musicdl/KTakeMusicDL" && -s "$build/musicdl/go-music-dl-v1.1.5-source.tar.gz" &&
          "$(cat "$build/musicdl/build-key")" == "$key" ]]; then return; fi

    go_archive="$downloads/go1.26.3.darwin-$host_arch.tar.gz"
    fetch "$go_sha" "https://go.dev/dl/${go_archive##*/}" "$go_archive"
    tar -xzf "$go_archive" -C "$staging"
    go="$staging/go/bin/go"
    source_archive="$downloads/go-music-dl-v1.1.5.tar.gz"
    fetch 8aea51460eeb645a78aa3a333bd30c24c01764c1ae53750fbf9e2eabbc70c42d \
        "https://codeload.github.com/guohuiyuan/go-music-dl/tar.gz/refs/tags/v1.1.5" "$source_archive"
    tar -xzf "$source_archive" -C "$staging"
    source="$staging/go-music-dl-1.1.5"
    mkdir -p "$source/cmd/ktake-music-dl" "$staging/musicdl" "$build/go-cache" "$build/go-path"
    cp scripts/distribution/musicdl-main.go "$source/cmd/ktake-music-dl/main.go"
    cp scripts/distribution/musicdl-build.sh "$source/build-ktake.sh"
    cp "$source/LICENSE" "$staging/musicdl/LICENSE"
    patch -d "$source" -p1 < scripts/distribution/musicdl.patch
    (
        cd "$source"
        export GOENV=off GOWORK=off GOTOOLCHAIN=local GOFLAGS=
        export GOPATH="$build/go-path" GOMODCACHE="$build/go-path/pkg/mod"
        export GOCACHE="$build/go-cache" GOTMPDIR="$build/tmp"
        export GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org
        "$go" mod vendor
        KTAKE_GO="$go" ./build-ktake.sh "$staging/musicdl/KTakeMusicDL"
    )
    COPYFILE_DISABLE=1 tar -czf "$staging/musicdl/go-music-dl-v1.1.5-source.tar.gz" \
        -C "$staging" go-music-dl-1.1.5
    printf '%s\n' "$key" > "$staging/musicdl/build-key"
    rm -rf "$build/musicdl"
    mv "$staging/musicdl" "$build/musicdl"
}

install_wheels() {
    local python="$1" target="$2" manifest="$3" checksum url
    local -a wheels
    wheels=()
    while read -r checksum url; do
        [[ -z "$checksum" || "$checksum" == \#* ]] && continue
        fetch "$checksum" "$url" "$downloads/wheels/${url##*/}"
        wheels+=("$downloads/wheels/${url##*/}")
    done < "$manifest"
    "$python" -I -B -m pip --isolated --disable-pip-version-check install \
        --no-cache-dir --no-deps --no-index --no-compile --target "$target" "${wheels[@]}"
}

prepare_separation() {
    local key runtime packages python
    key="$(shasum -a 256 scripts/distribution/prepare.sh scripts/distribution/{separation-runtime-wheels,small-karaoke-conversion-wheels}.txt | shasum -a 256 | cut -d ' ' -f 1)"
    if [[ -x "$build/separation/SeparationRuntime/bin/python3.12" &&
          ! -e "$build/separation/SeparationModels" &&
          "$(cat "$build/separation/build-key")" == "$key" ]]; then return; fi

    mkdir -p "$staging/separation"
    fetch 84cb7acbf75264982c8bdd818bfa1ff0f1eb76007b48a5f3e01d28633b46afdf \
        "https://github.com/astral-sh/python-build-standalone/releases/download/20251014/cpython-3.12.12%2B20251014-aarch64-apple-darwin-install_only_stripped.tar.gz" \
        "$downloads/python-arm64.tar.gz"
    tar -xzf "$downloads/python-arm64.tar.gz" -C "$staging/separation"
    runtime="$staging/separation/SeparationRuntime"
    mv "$staging/separation/python" "$runtime"
    python="$runtime/bin/python3.12"
    packages="$runtime/lib/python3.12/site-packages"
    install_wheels "$python" "$packages" scripts/distribution/separation-runtime-wheels.txt
    install_wheels "$python" "$packages" scripts/distribution/small-karaoke-conversion-wheels.txt
    "$python" -I -B -m pip --isolated --disable-pip-version-check check
    # The bundled checkpoint converter only runs Python and prebuilt PyTorch libraries.
    rm -rf "$packages/bin" "$packages/pip" "$packages/pip-25.2.dist-info" "$packages/torch/include" \
        "$runtime/include" "$runtime/share" "$runtime/lib/python3.12/ensurepip"
    find "$runtime/bin" -mindepth 1 -maxdepth 1 ! -name python3.12 -delete

    printf '%s\n' "$key" > "$staging/separation/build-key"
    rm -rf "$build/separation"
    mv "$staging/separation" "$build/separation"
}

if [[ "$mode" == release && "$(uname -m)" != arm64 ]]; then
    echo "请在 Apple 芯片 Mac 上构建完整安装包。" >&2
    exit 1
fi
prepare_musicdl
if [[ "$mode" == release ]]; then prepare_separation; fi
