#!/bin/sh

# Run this helper on a connected Linux host to create the transferable bundle.
# The generated install.sh never accesses the network.

set -eu
umask 022

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

ENGINE_VERSION=26.1.4
COMPOSE_VERSION=2.27.1
BUILDX_VERSION=0.14.1
OUTPUT=
STAGING_DIR=

usage() {
    cat <<EOF
用法：
  $PROGRAM [选项]

选项：
  --engine-version VERSION   Docker Engine 版本（默认：$ENGINE_VERSION）
  --compose-version VERSION  Docker Compose 版本（默认：$COMPOSE_VERSION）
  --buildx-version VERSION   Docker Buildx 版本（默认：$BUILDX_VERSION）
  --output DIRECTORY         输出目录
  -h, --help                 显示帮助
EOF
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

cleanup() {
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf -- "$STAGING_DIR"
    fi
}

trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --engine-version)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            ENGINE_VERSION=${2#v}
            shift
            ;;
        --compose-version)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            COMPOSE_VERSION=${2#v}
            shift
            ;;
        --buildx-version)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            BUILDX_VERSION=${2#v}
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || die "$1 缺少参数"
            OUTPUT=$2
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "未知参数：$1"
            ;;
    esac
    shift
done

for version_value in "$ENGINE_VERSION" "$COMPOSE_VERSION" "$BUILDX_VERSION"; do
    case "$version_value" in
        ''|*[!0-9A-Za-z._+-]*) die "非法版本值：$version_value" ;;
    esac
done

for command_name in curl sha256sum tar awk grep mktemp cp mv mkdir chmod dirname; do
    command -v "$command_name" >/dev/null 2>&1 || die "缺少命令：$command_name"
done

if [ -z "$OUTPUT" ]; then
    OUTPUT=$SCRIPT_DIR/dist/docker-offline-$ENGINE_VERSION
fi
case "$OUTPUT" in
    /|''|.) die "拒绝使用不安全的输出目录：$OUTPUT" ;;
esac
[ ! -e "$OUTPUT" ] || die "输出路径已存在：$OUTPUT"

output_parent=$(dirname -- "$OUTPUT")
mkdir -p "$output_parent"
STAGING_DIR=$(mktemp -d "$output_parent/.docker-offline-bundle.XXXXXX")
mkdir -p "$STAGING_DIR/artifacts/x86_64" "$STAGING_DIR/artifacts/aarch64" \
    "$STAGING_DIR/systemd" "$STAGING_DIR/config"

cp "$SCRIPT_DIR/install.sh" "$STAGING_DIR/install.sh"
cp "$SCRIPT_DIR/uninstall.sh" "$STAGING_DIR/uninstall.sh"
cp "$SCRIPT_DIR/systemd/containerd.service" "$STAGING_DIR/systemd/containerd.service"
cp "$SCRIPT_DIR/systemd/docker.service" "$STAGING_DIR/systemd/docker.service"
cp "$SCRIPT_DIR/systemd/docker.socket" "$STAGING_DIR/systemd/docker.socket"
cp "$SCRIPT_DIR/config/daemon.json.example" "$STAGING_DIR/config/daemon.json.example"
cp "$SCRIPT_DIR/README.md" "$STAGING_DIR/README.md"
cp "$SCRIPT_DIR/DESIGN.md" "$STAGING_DIR/DESIGN.md"
cp "$SCRIPT_DIR/VALIDATION.md" "$STAGING_DIR/VALIDATION.md"

cat >"$STAGING_DIR/BUNDLE-VERSIONS" <<EOF
DOCKER_ENGINE_VERSION=$ENGINE_VERSION
DOCKER_COMPOSE_VERSION=$COMPOSE_VERSION
DOCKER_BUILDX_VERSION=$BUILDX_VERSION
EOF

download() {
    url=$1
    destination=$2
    printf '%s\n' "[INFO] 下载：$url"
    curl --fail --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 600 \
        --speed-limit 1024 --speed-time 60 \
        --retry 3 --retry-delay 2 \
        --output "$destination" "$url"
}

for docker_arch in x86_64 aarch64; do
    case "$docker_arch" in
        x86_64) buildx_arch=amd64 ;;
        aarch64) buildx_arch=arm64 ;;
    esac
    artifact_dir=$STAGING_DIR/artifacts/$docker_arch
    download \
        "https://download.docker.com/linux/static/stable/$docker_arch/docker-$ENGINE_VERSION.tgz" \
        "$artifact_dir/docker.tgz"
    download \
        "https://github.com/docker/compose/releases/download/v$COMPOSE_VERSION/docker-compose-linux-$docker_arch" \
        "$artifact_dir/docker-compose"
    download \
        "https://github.com/docker/buildx/releases/download/v$BUILDX_VERSION/buildx-v$BUILDX_VERSION.linux-$buildx_arch" \
        "$artifact_dir/docker-buildx"

    archive_listing=$(tar -tzf "$artifact_dir/docker.tgz") ||
        die "无法读取 Engine 压缩包：$docker_arch"
    unsafe_archive_entries=$(
        printf '%s\n' "$archive_listing" |
            grep -Ev '^(\./)?docker(/|/[0-9A-Za-z._+-]+)$' || true
    )
    [ -z "$unsafe_archive_entries" ] ||
        die "Engine 压缩包包含越界或异常路径：$docker_arch"
    for binary_name in docker dockerd containerd containerd-shim-runc-v2 ctr runc; do
        printf '%s\n' "$archive_listing" | grep -Eq "^(\./)?docker/$binary_name$" ||
            die "Engine 压缩包缺少 docker/$binary_name：$docker_arch"
    done
    chmod 0755 "$artifact_dir/docker-compose" "$artifact_dir/docker-buildx"
done

(
    cd "$STAGING_DIR"
    sha256sum \
        install.sh \
        uninstall.sh \
        BUNDLE-VERSIONS \
        systemd/containerd.service \
        systemd/docker.service \
        systemd/docker.socket \
        config/daemon.json.example \
        README.md \
        DESIGN.md \
        VALIDATION.md \
        artifacts/x86_64/docker.tgz \
        artifacts/x86_64/docker-compose \
        artifacts/x86_64/docker-buildx \
        artifacts/aarch64/docker.tgz \
        artifacts/aarch64/docker-compose \
        artifacts/aarch64/docker-buildx >SHA256SUMS
)

chmod 0755 "$STAGING_DIR/install.sh"
chmod 0755 "$STAGING_DIR/uninstall.sh"
chmod 0755 "$STAGING_DIR"
mv "$STAGING_DIR" "$OUTPUT"
STAGING_DIR=

printf '%s\n' "[INFO] 双架构离线包已生成：$OUTPUT"
printf '%s\n' "[INFO] 转移到目标机并进入该目录后，先运行：sudo sh install.sh --check-only"
