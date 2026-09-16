#!/bin/sh

# Offline Docker Engine installer for systemd-based GNU/Linux hosts.
# The installation phase performs no network access.

set -eu
umask 022

# Non-root login shells on Debian and some other distributions omit sbin paths.
# Use the conventional administrative paths for deterministic preflight checks.
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export PATH

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)

INSTALL_ROOT=/usr/local/lib/docker-offline
VERSIONS_DIR=$INSTALL_ROOT/versions
CURRENT_LINK=$INSTALL_ROOT/current
MANAGED_MARKER=$INSTALL_ROOT/MANAGED-BY
BIN_LINK_DIR=/usr/local/bin
PLUGIN_LINK_DIR=/usr/local/lib/docker/cli-plugins
UNIT_DIR=/etc/systemd/system

MODE=install
START_SERVICE=1
ADD_USER=
STAGING_DIR=
NEW_LINK=
PREVIOUS_TARGET=
SMOKE_DIR=
SMOKE_TAG=
WARNINGS=0
ALREADY_INSTALLED=0

usage() {
    cat <<EOF
用法：
  $PROGRAM [--check-only] [--upgrade] [--no-start] [--add-user USER]

选项：
  --check-only      只检查主机、依赖、离线包和安装冲突，不修改系统
  --upgrade         升级由本脚本管理的现有安装；升级会停止正在运行的容器
  --no-start        安装并启用 systemd 单元，但不立即启动 Docker
  --add-user USER   将已有用户加入 docker 组（该组等同于 root 权限）
  -h, --help        显示帮助
EOF
}

log() {
    printf '%s\n' "[INFO] $*"
}

warn() {
    WARNINGS=$((WARNINGS + 1))
    printf '%s\n' "[WARN] $*" >&2
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

cleanup() {
    if [ -n "$SMOKE_TAG" ] && [ -x "$BIN_LINK_DIR/docker" ]; then
        "$BIN_LINK_DIR/docker" image rm --force "$SMOKE_TAG" >/dev/null 2>&1 || true
    fi
    if [ -n "$SMOKE_DIR" ] && [ -d "$SMOKE_DIR" ]; then
        rm -rf -- "$SMOKE_DIR"
    fi
    if [ -n "$NEW_LINK" ] && [ -L "$NEW_LINK" ]; then
        rm -f -- "$NEW_LINK"
    fi
    if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
        rm -rf -- "$STAGING_DIR"
    fi
}

trap cleanup EXIT HUP INT TERM

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only)
            MODE=check
            ;;
        --upgrade)
            MODE=upgrade
            ;;
        --no-start)
            START_SERVICE=0
            ;;
        --add-user)
            [ "$#" -ge 2 ] || die "--add-user 缺少用户名"
            ADD_USER=$2
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

if [ "$MODE" = check ] && [ -n "$ADD_USER" ]; then
    die "--check-only 与 --add-user 不能同时使用"
fi

missing_commands=
for command_name in uname systemctl tar gzip sha256sum install awk sed grep ps id \
    dirname mkdir mv ln rm readlink mktemp cat; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands="$missing_commands $command_name"
    fi
done
[ -z "$missing_commands" ] || die "缺少安装所需命令：$missing_commands"

version_at_least() {
    awk -v actual="$1" -v required="$2" 'BEGIN {
        split(actual, a, "."); split(required, r, ".");
        for (i = 1; i <= 3; i++) {
            av = (a[i] == "" ? 0 : a[i]) + 0;
            rv = (r[i] == "" ? 0 : r[i]) + 0;
            if (av > rv) exit 0;
            if (av < rv) exit 1;
        }
        exit 0;
    }'
}

manifest_value() {
    key=$1
    awk -F= -v wanted="$key" '$1 == wanted { print substr($0, index($0, "=") + 1) }' \
        "$SCRIPT_DIR/BUNDLE-VERSIONS"
}

validate_version_value() {
    case "$1" in
        ''|*[!0-9A-Za-z._+-]*) return 1 ;;
        *) return 0 ;;
    esac
}

os_release_value() {
    wanted_key=$1
    [ -r /etc/os-release ] || return 0
    awk -F= -v wanted="$wanted_key" '
        $1 == wanted {
            value = substr($0, index($0, "=") + 1)
            sub(/^"/, "", value)
            sub(/"$/, "", value)
            print value
            exit
        }
    ' /etc/os-release
}

group_exists() {
    if command -v getent >/dev/null 2>&1; then
        getent group "$1" >/dev/null 2>&1
    else
        grep -q "^$1:" /etc/group 2>/dev/null
    fi
}

verify_runtime() {
    systemctl is-active --quiet containerd.service || {
        warn "containerd 未处于 active 状态"
        return 1
    }
    systemctl is-active --quiet docker.service || {
        warn "docker 未处于 active 状态"
        return 1
    }
    "$BIN_LINK_DIR/docker" info >/dev/null || {
        warn "docker info 验证失败"
        return 1
    }
    "$BIN_LINK_DIR/docker" compose version >/dev/null || {
        warn "docker compose 验证失败"
        return 1
    }
    "$BIN_LINK_DIR/docker" buildx version >/dev/null || {
        warn "docker buildx 验证失败"
        return 1
    }

    runtime_client_version=$(
        "$BIN_LINK_DIR/docker" version --format '{{.Client.Version}}' 2>/dev/null
    )
    runtime_server_version=$(
        "$BIN_LINK_DIR/docker" version --format '{{.Server.Version}}' 2>/dev/null
    )
    runtime_compose_version=$(
        "$BIN_LINK_DIR/docker" compose version --short 2>/dev/null | sed 's/^v//'
    )
    runtime_buildx_version=$(
        "$BIN_LINK_DIR/docker" buildx version 2>/dev/null |
            awk 'NR == 1 { value = $2; sub(/^v/, "", value); print value }'
    )
    if [ "$runtime_client_version" != "$engine_version" ] ||
       [ "$runtime_server_version" != "$engine_version" ]; then
        warn "Engine 运行版本不匹配：清单 $engine_version，客户端 $runtime_client_version，服务端 $runtime_server_version"
        return 1
    fi
    if [ "$runtime_compose_version" != "$compose_version" ]; then
        warn "Compose 运行版本不匹配：清单 $compose_version，实际 $runtime_compose_version"
        return 1
    fi
    if [ "$runtime_buildx_version" != "$buildx_version" ]; then
        warn "Buildx 运行版本不匹配：清单 $buildx_version，实际 $runtime_buildx_version"
        return 1
    fi

    SMOKE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/docker-offline-smoke.XXXXXX") || {
        warn "无法创建离线构建验证临时目录"
        return 1
    }
    SMOKE_TAG=docker-offline-smoke:install-${SMOKE_DIR##*.}
    cat >"$SMOKE_DIR/Dockerfile" <<EOF
FROM scratch
LABEL io.example.docker-offline-smoke="true"
EOF
    cat >"$SMOKE_DIR/compose.yaml" <<EOF
services:
  smoke:
    image: scratch
EOF
    printf '%s\n' buildx.log >"$SMOKE_DIR/.dockerignore"
    "$BIN_LINK_DIR/docker" compose -f "$SMOKE_DIR/compose.yaml" config >/dev/null ||
        { warn "docker compose config 离线验证失败"; return 1; }
    if ! "$BIN_LINK_DIR/docker" buildx build --progress=plain --load \
        --tag "$SMOKE_TAG" "$SMOKE_DIR" >"$SMOKE_DIR/buildx.log" 2>&1; then
        warn "docker buildx 本机离线构建验证失败，构建日志如下"
        sed -n '1,160p' "$SMOKE_DIR/buildx.log" >&2
        return 1
    fi
    "$BIN_LINK_DIR/docker" image inspect "$SMOKE_TAG" >/dev/null ||
        { warn "离线构建结果检查失败"; return 1; }
    "$BIN_LINK_DIR/docker" image rm "$SMOKE_TAG" >/dev/null || {
        warn "验证镜像清理失败：$SMOKE_TAG"
        return 1
    }
    SMOKE_TAG=
    rm -rf -- "$SMOKE_DIR"
    SMOKE_DIR=
}

verify_artifact() {
    relative_path=$1
    expected=$(awk -v wanted="$relative_path" '
        $2 == wanted || $2 == "*" wanted { print $1 }
    ' "$SCRIPT_DIR/SHA256SUMS")
    count=$(printf '%s\n' "$expected" | awk 'NF { n++ } END { print n + 0 }')
    [ "$count" -eq 1 ] || die "SHA256SUMS 中 $relative_path 的记录数量不是 1"
    printf '%s  %s\n' "$expected" "$relative_path" |
        (cd "$SCRIPT_DIR" && sha256sum -c - >/dev/null) ||
        die "校验失败：$relative_path"
    log "SHA-256 校验通过：$relative_path"
}

system_name=$(uname -s)
[ "$system_name" = Linux ] || die "仅支持 Linux，当前为：$system_name"

machine_arch=$(uname -m)
case "$machine_arch" in
    x86_64|amd64)
        bundle_arch=x86_64
        ;;
    aarch64|arm64)
        bundle_arch=aarch64
        ;;
    *)
        die "不支持的 CPU 架构：$machine_arch；仅支持 x86_64 和 aarch64"
        ;;
esac
log "主机架构：$machine_arch（离线包目录：$bundle_arch）"

for required_file in \
    BUNDLE-VERSIONS SHA256SUMS \
    "artifacts/$bundle_arch/docker.tgz" \
    "artifacts/$bundle_arch/docker-compose" \
    "artifacts/$bundle_arch/docker-buildx" \
    systemd/containerd.service systemd/docker.service systemd/docker.socket; do
    [ -f "$SCRIPT_DIR/$required_file" ] || die "离线包缺少文件：$required_file"
done

engine_version=$(manifest_value DOCKER_ENGINE_VERSION)
compose_version=$(manifest_value DOCKER_COMPOSE_VERSION)
buildx_version=$(manifest_value DOCKER_BUILDX_VERSION)
for version_value in "$engine_version" "$compose_version" "$buildx_version"; do
    validate_version_value "$version_value" || die "BUNDLE-VERSIONS 含非法版本值"
done
engine_major=${engine_version%%.*}
case "$engine_major" in
    ''|*[!0-9]*) die "无法识别 Docker Engine 主版本：$engine_version" ;;
esac
log "离线包版本：Engine $engine_version，Compose $compose_version，Buildx $buildx_version"

[ -d /run/systemd/system ] || die "systemd 未作为系统管理器运行（缺少 /run/systemd/system）"
systemd_version=$(systemctl --version | awk 'NR == 1 { print $2 }')
case "$systemd_version" in
    ''|*[!0-9]*) die "无法识别 systemd 版本" ;;
esac
log "systemd 版本：$systemd_version"

kernel_release=$(uname -r)
kernel_numeric=$(printf '%s\n' "$kernel_release" | sed 's/[^0-9.].*$//')
os_id=$(os_release_value ID)
os_version_id=$(os_release_value VERSION_ID)
[ -n "$os_id" ] || os_id=unknown
[ -n "$os_version_id" ] || os_version_id=unknown
log "操作系统标识：$os_id $os_version_id"

if version_at_least "$kernel_numeric" 4.0; then
    log "Linux 内核：$kernel_release（通用 4.x+ 规则通过）"
else
    if [ "$engine_major" -ge 29 ]; then
        die "Engine $engine_version 使用现代内核基线，当前内核 $kernel_release 低于 4.0"
    fi
    case "$os_id:$os_version_id:$kernel_release" in
        centos:7*:3.10.0-*.el7.*|rhel:7*:3.10.0-*.el7.*)
            el7_kernel_base=$(printf '%s\n' "$kernel_release" |
                sed -n 's/^3\.10\.0-\([0-9][0-9]*\).*/\1/p')
            [ -n "$el7_kernel_base" ] || die "无法识别 EL7 内核发行号：$kernel_release"
            [ "$el7_kernel_base" -ge 514 ] ||
                die "EL7 OverlayFS 要求 3.10.0-514 或更高，当前为：$kernel_release"
            log "Linux 内核：$kernel_release（RHEL/CentOS 7 回移内核规则通过）"
            if [ "$el7_kernel_base" -lt 1160 ]; then
                warn "当前 EL7 内核基线早于 7.9 的 3.10.0-1160；兼容门槛已通过，但建议先评估内核安全及缺陷修复更新"
            fi
            ;;
        *)
            die "内核 $kernel_release 低于 4.0；仅 Engine 28 及以下的 RHEL/CentOS 7 3.10.0-514+ 回移内核可例外放行"
            ;;
    esac
fi

[ -r /proc/self/cgroup ] || die "无法读取 /proc/self/cgroup"
if ! grep -q ' - cgroup2 ' /proc/self/mountinfo 2>/dev/null &&
   ! grep -q ' - cgroup ' /proc/self/mountinfo 2>/dev/null; then
    die "未检测到已挂载的 cgroup/cgroup2 文件系统"
fi
log "cgroup 文件系统已挂载"

if ! command -v iptables >/dev/null 2>&1; then
    die "缺少 iptables；本基线使用 Docker 默认 iptables 防火墙后端"
fi
iptables_version=$(iptables --version 2>/dev/null | sed -n 's/.*v\([0-9][0-9.]*\).*/\1/p' | awk 'NR == 1')
[ -n "$iptables_version" ] || die "无法识别 iptables 版本"
version_at_least "$iptables_version" 1.4 ||
    die "iptables 版本过低：$iptables_version；要求至少 1.4"
log "iptables 版本：$iptables_version"

for optional_command in git xz ip6tables modprobe; do
    if ! command -v "$optional_command" >/dev/null 2>&1; then
        case "$optional_command" in
            git) warn "未安装 git：本地目录构建可用，但 Git 构建上下文不可用" ;;
            xz) warn "未安装 xz：不满足 Docker 官方静态安装先决条件清单" ;;
            ip6tables) warn "未安装 ip6tables：启用 IPv6 容器网络前必须补齐" ;;
            modprobe) warn "未安装 modprobe：脚本无法预检或加载内核模块" ;;
        esac
    fi
done

if grep -qw overlay /proc/filesystems 2>/dev/null; then
    log "OverlayFS：内核已提供"
elif command -v modprobe >/dev/null 2>&1 && modprobe -n overlay >/dev/null 2>&1; then
    log "OverlayFS：模块可加载"
else
    warn "未确认 OverlayFS 可用；容器镜像存储和构建可能失败"
fi

if command -v getenforce >/dev/null 2>&1; then
    selinux_mode=$(getenforce 2>/dev/null || true)
    if [ "$selinux_mode" = Enforcing ]; then
        warn "SELinux 为 Enforcing；静态包不包含发行版的容器 SELinux 策略，需在目标系统实测"
    fi
fi

verify_artifact install.sh
verify_artifact BUNDLE-VERSIONS
verify_artifact systemd/containerd.service
verify_artifact systemd/docker.service
verify_artifact systemd/docker.socket
verify_artifact "artifacts/$bundle_arch/docker.tgz"
verify_artifact "artifacts/$bundle_arch/docker-compose"
verify_artifact "artifacts/$bundle_arch/docker-buildx"

archive_listing=$(tar -tzf "$SCRIPT_DIR/artifacts/$bundle_arch/docker.tgz") ||
    die "Docker Engine 压缩包无法读取"
unsafe_archive_entries=$(
    printf '%s\n' "$archive_listing" |
        grep -Ev '^(\./)?docker(/|/[0-9A-Za-z._+-]+)$' || true
)
[ -z "$unsafe_archive_entries" ] ||
    die "Docker Engine 压缩包包含越界或异常路径，拒绝解压"
for binary_name in docker dockerd containerd containerd-shim-runc-v2 ctr runc; do
    if ! printf '%s\n' "$archive_listing" | grep -Eq "^(\./)?docker/$binary_name$"; then
        die "Docker Engine 压缩包缺少：docker/$binary_name"
    fi
done

if [ ! -f "$MANAGED_MARKER" ]; then
    conflicts=
    for binary_name in docker dockerd containerd runc; do
        binary_path=$(command -v "$binary_name" 2>/dev/null || true)
        if [ -n "$binary_path" ]; then
            conflicts="$conflicts $binary_name=$binary_path"
        fi
    done
    if systemctl cat docker.service >/dev/null 2>&1 ||
       systemctl cat containerd.service >/dev/null 2>&1 ||
       systemctl cat docker.socket >/dev/null 2>&1; then
        conflicts="$conflicts systemd-unit=present"
    fi
    [ -z "$conflicts" ] ||
        die "发现非本脚本管理的 Docker/containerd，拒绝覆盖：$conflicts"
elif [ "$MODE" = install ]; then
    installed_version=unknown
    if [ -L "$CURRENT_LINK" ] && [ -f "$CURRENT_LINK/INSTALL-METADATA" ]; then
        installed_version=$(awk -F= '$1 == "DOCKER_ENGINE_VERSION" { print $2 }' \
            "$CURRENT_LINK/INSTALL-METADATA")
    fi
    if [ "$installed_version" = "$engine_version" ]; then
        log "Docker Engine $engine_version 已由本脚本安装；无需重复安装"
        ALREADY_INSTALLED=1
    else
        die "已存在本脚本管理的版本 $installed_version；升级请显式使用 --upgrade"
    fi
fi

if [ "$MODE" = upgrade ] && [ ! -f "$MANAGED_MARKER" ]; then
    die "--upgrade 仅适用于本脚本管理的现有安装"
fi

if [ -n "$ADD_USER" ]; then
    case "$ADD_USER" in
        *[!0-9A-Za-z._-]*|'') die "用户名格式不受支持：$ADD_USER" ;;
    esac
    command -v usermod >/dev/null 2>&1 || die "--add-user 需要 usermod"
    id "$ADD_USER" >/dev/null 2>&1 || die "用户不存在：$ADD_USER"
fi

if [ "$MODE" = check ]; then
    log "检查完成：硬性条件满足，警告 $WARNINGS 项；未修改系统"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "安装或升级必须以 root 身份运行"

if ! group_exists docker; then
    command -v groupadd >/dev/null 2>&1 || die "创建 docker 组需要 groupadd"
    groupadd --system docker
    log "已创建 docker 系统组"
fi

if [ "$ALREADY_INSTALLED" -eq 1 ]; then
    if [ -n "$ADD_USER" ]; then
        usermod -aG docker "$ADD_USER"
        warn "已将 $ADD_USER 加入 docker 组；重新登录后生效，该组成员可获得等同 root 的主机权限"
    fi
    if [ "$START_SERVICE" -eq 1 ]; then
        systemctl start containerd.service docker.socket docker.service ||
            die "现有安装的 Docker 服务启动失败"
        verify_runtime || die "现有安装验证失败"
        log "现有安装验证通过"
    fi
    exit 0
fi

mkdir -p "$VERSIONS_DIR" "$BIN_LINK_DIR" "$PLUGIN_LINK_DIR" "$UNIT_DIR"
STAGING_DIR=$(mktemp -d "$VERSIONS_DIR/.install.XXXXXX")
mkdir -p "$STAGING_DIR/bin" "$STAGING_DIR/cli-plugins"

tar -xzf "$SCRIPT_DIR/artifacts/$bundle_arch/docker.tgz" -C "$STAGING_DIR"
for binary_name in docker dockerd containerd containerd-shim-runc-v2 ctr runc \
    docker-init docker-proxy; do
    binary_path=$STAGING_DIR/docker/$binary_name
    [ -e "$binary_path" ] || continue
    [ -f "$binary_path" ] && [ ! -L "$binary_path" ] ||
        die "Engine 压缩包中的 $binary_name 不是普通文件"
    install -m 0755 "$binary_path" "$STAGING_DIR/bin/$binary_name"
done
rm -rf -- "$STAGING_DIR/docker"
install -m 0755 "$SCRIPT_DIR/artifacts/$bundle_arch/docker-compose" \
    "$STAGING_DIR/cli-plugins/docker-compose"
install -m 0755 "$SCRIPT_DIR/artifacts/$bundle_arch/docker-buildx" \
    "$STAGING_DIR/cli-plugins/docker-buildx"
chmod 0755 "$STAGING_DIR" "$STAGING_DIR/bin" "$STAGING_DIR/cli-plugins"

actual_engine_version=$(
    "$STAGING_DIR/bin/dockerd" --version 2>/dev/null |
        sed -n 's/^Docker version \([^,]*\),.*/\1/p'
)
[ "$actual_engine_version" = "$engine_version" ] ||
    die "Engine 文件版本与清单不一致：期望 $engine_version，实际 $actual_engine_version"
"$STAGING_DIR/cli-plugins/docker-compose" version 2>/dev/null |
    grep -F "$compose_version" >/dev/null || die "Compose 文件版本与清单不一致"
"$STAGING_DIR/cli-plugins/docker-buildx" version 2>/dev/null |
    grep -F "$buildx_version" >/dev/null || die "Buildx 文件版本与清单不一致"

if [ -s /etc/docker/daemon.json ]; then
    PATH="$STAGING_DIR/bin:$PATH" "$STAGING_DIR/bin/dockerd" \
        --validate --config-file=/etc/docker/daemon.json >/dev/null ||
        die "/etc/docker/daemon.json 校验失败；未改动现有配置"
    log "现有 /etc/docker/daemon.json 校验通过，将原样保留"
fi

cat >"$STAGING_DIR/INSTALL-METADATA" <<EOF
DOCKER_ENGINE_VERSION=$engine_version
DOCKER_COMPOSE_VERSION=$compose_version
DOCKER_BUILDX_VERSION=$buildx_version
ARCHITECTURE=$bundle_arch
EOF

final_dir=$VERSIONS_DIR/docker-$engine_version-$bundle_arch
if [ -e "$final_dir" ]; then
    die "版本目录已存在但未处于当前安装状态：$final_dir"
fi
mv "$STAGING_DIR" "$final_dir"
STAGING_DIR=

if [ -L "$CURRENT_LINK" ]; then
    PREVIOUS_TARGET=$(readlink "$CURRENT_LINK")
elif [ -e "$CURRENT_LINK" ]; then
    die "$CURRENT_LINK 已存在且不是符号链接"
fi

if [ "$MODE" = upgrade ]; then
    log "停止 Docker 以执行升级；现有容器将停止"
    systemctl stop docker.service docker.socket containerd.service
fi

NEW_LINK=$INSTALL_ROOT/.current.new.$$
ln -s "$final_dir" "$NEW_LINK"
mv -Tf "$NEW_LINK" "$CURRENT_LINK"
NEW_LINK=

for binary_path in "$final_dir"/bin/*; do
    binary_name=${binary_path##*/}
    ln -sfn "$CURRENT_LINK/bin/$binary_name" "$BIN_LINK_DIR/$binary_name"
done
ln -sfn "$CURRENT_LINK/cli-plugins/docker-compose" "$PLUGIN_LINK_DIR/docker-compose"
ln -sfn "$CURRENT_LINK/cli-plugins/docker-buildx" "$PLUGIN_LINK_DIR/docker-buildx"

install -m 0644 "$SCRIPT_DIR/systemd/containerd.service" "$UNIT_DIR/containerd.service"
install -m 0644 "$SCRIPT_DIR/systemd/docker.service" "$UNIT_DIR/docker.service"
install -m 0644 "$SCRIPT_DIR/systemd/docker.socket" "$UNIT_DIR/docker.socket"

if command -v restorecon >/dev/null 2>&1; then
    restorecon -RF "$INSTALL_ROOT" "$BIN_LINK_DIR" "$PLUGIN_LINK_DIR" "$UNIT_DIR" >/dev/null 2>&1 ||
        warn "restorecon 未能完全恢复 SELinux 上下文，请人工检查"
fi

cat >"$MANAGED_MARKER" <<EOF
This installation is managed by docker-offline/install.sh.
Do not replace its symlinks or systemd units with distribution packages.
EOF

systemctl daemon-reload
systemctl enable containerd.service docker.socket docker.service >/dev/null

if [ -n "$ADD_USER" ]; then
    usermod -aG docker "$ADD_USER"
    warn "已将 $ADD_USER 加入 docker 组；重新登录后生效，该组成员可获得等同 root 的主机权限"
fi

rollback_upgrade() {
    if [ -n "$PREVIOUS_TARGET" ] && [ -d "$PREVIOUS_TARGET" ]; then
        warn "新版本启动失败，正在恢复此前版本：$PREVIOUS_TARGET"
        ln -sfn "$PREVIOUS_TARGET" "$CURRENT_LINK"
        systemctl daemon-reload
        systemctl start containerd.service docker.socket docker.service || true
    fi
}

if [ "$START_SERVICE" -eq 1 ]; then
    if ! systemctl start containerd.service docker.socket docker.service; then
        rollback_upgrade
        die "Docker 启动失败；请检查 systemctl status docker 和 journalctl -u docker"
    fi
    if ! verify_runtime; then
        rollback_upgrade
        die "Docker、Compose 或 Buildx 安装后验证失败；已尝试恢复此前版本"
    fi
    log "离线安装及本机验证完成"
else
    log "安装完成；服务已设为开机启用，但按 --no-start 要求未立即启动"
fi

log "当前版本：Engine $engine_version，Compose $compose_version，Buildx $buildx_version"
log "安装警告：$WARNINGS 项"
