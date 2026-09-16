#!/bin/sh

# Uninstall only the Docker installation managed by docker-offline/install.sh.
# Docker configuration, data directories, and the docker group are preserved.

set -eu
umask 022

PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}
export PATH

PROGRAM=${0##*/}
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd -P)
INSTALL_ROOT=/usr/local/lib/docker-offline
CURRENT_LINK=$INSTALL_ROOT/current
MANAGED_MARKER=$INSTALL_ROOT/MANAGED-BY
BIN_LINK_DIR=/usr/local/bin
PLUGIN_LINK_DIR=/usr/local/lib/docker/cli-plugins
UNIT_DIR=/etc/systemd/system

CHECK_ONLY=0
ASSUME_YES=0

usage() {
    cat <<EOF
用法：
  $PROGRAM [--check-only] [--yes]

选项：
  --check-only   只显示卸载范围，不修改系统
  --yes          跳过交互确认，适用于自动化执行
  -h, --help     显示帮助

默认保留：
  /etc/docker/daemon.json
  /var/lib/docker
  /var/lib/containerd
  docker 用户组
EOF
}

log() {
    printf '%s\n' "[INFO] $*"
}

warn() {
    printf '%s\n' "[WARN] $*" >&2
}

die() {
    printf '%s\n' "[ERROR] $*" >&2
    exit 1
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --check-only)
            CHECK_ONLY=1
            ;;
        --yes)
            ASSUME_YES=1
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

if [ "$CHECK_ONLY" -eq 1 ] && [ "$ASSUME_YES" -eq 1 ]; then
    die "--check-only 与 --yes 不能同时使用"
fi

missing_commands=
for command_name in uname systemctl id readlink rm rmdir grep awk sed cat cmp timeout; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        missing_commands="$missing_commands $command_name"
    fi
done
[ -z "$missing_commands" ] || die "缺少卸载所需命令：$missing_commands"

[ "$(uname -s)" = Linux ] || die "仅支持 Linux"
[ -d /run/systemd/system ] || die "systemd 未作为系统管理器运行"
[ -d "$INSTALL_ROOT" ] && [ ! -L "$INSTALL_ROOT" ] ||
    die "安装目录不存在或已被替换为符号链接，拒绝卸载"
[ "$(readlink -f "$INSTALL_ROOT")" = /usr/local/lib/docker-offline ] ||
    die "安装根目录解析结果不匹配，拒绝卸载"
[ -f "$MANAGED_MARKER" ] && [ ! -L "$MANAGED_MARKER" ] ||
    die "未发现本脚本管理标记，拒绝卸载"
grep -Fxq 'This installation is managed by docker-offline/install.sh.' "$MANAGED_MARKER" ||
    die "管理标记内容不匹配，拒绝卸载"

is_managed_link() {
    [ -L "$1" ] || return 1
    [ "$(readlink "$1")" = "$2" ]
}

[ -L "$CURRENT_LINK" ] || die "current 不是受管版本链接"
current_target=$(readlink -f "$CURRENT_LINK")
case "$current_target" in
    "$INSTALL_ROOT"/versions/docker-*) ;;
    *) die "current 指向受管版本目录之外，拒绝卸载" ;;
esac
[ -d "$current_target" ] || die "current 对应的版本目录不存在"

check_mounts() {
    [ -r /proc/self/mountinfo ] || die "无法检查安装目录的挂载状态"
    if awk -v root="$INSTALL_ROOT" '
        $5 == root || index($5, root "/") == 1 { found = 1 }
        END { exit !found }
    ' /proc/self/mountinfo; then
        die "安装目录内存在挂载点，请先处理挂载再卸载"
    fi
}
check_mounts

unit_property() {
    # --value is unavailable on CentOS 7's systemd 219.
    property_output=$(systemctl show "$1" --property="$2") || return 1
    printf '%s\n' "$property_output" | sed 's/^[^=]*=//'
}

# Refuse changed units/drop-ins before stopping any service. Keep the templates
# next to this script; they are also shipped in the offline bundle.
managed_units=
for unit_name in docker.service docker.socket containerd.service; do
    unit_path=$UNIT_DIR/$unit_name
    fragment_path=$(unit_property "$unit_name" FragmentPath) ||
        die "无法读取 $unit_name 的服务来源"
    dropin_paths=$(unit_property "$unit_name" DropInPaths) ||
        die "无法读取 $unit_name 的覆盖配置"
    case " $dropin_paths " in
        *"/$unit_name.d/"*)
            die "$unit_name 存在专用 drop-in 配置，需人工核对后卸载" ;;
    esac
    if [ -e "$unit_path" ] || [ -L "$unit_path" ]; then
        [ -f "$unit_path" ] && [ ! -L "$unit_path" ] ||
            die "$unit_path 不是本方案的普通单元文件"
        [ "$fragment_path" = "$unit_path" ] ||
            die "$unit_name 的生效单元不来自 $unit_path"
        cmp -s "$unit_path" "$SCRIPT_DIR/systemd/$unit_name" ||
            die "$unit_path 与随包模板不一致或模板缺失，拒绝卸载"
        managed_units="$managed_units $unit_name"
    elif [ -n "$fragment_path" ]; then
        die "$unit_name 由其他路径提供：$fragment_path"
    fi
done
engine_version=unknown
compose_version=unknown
buildx_version=unknown
if [ -f "$CURRENT_LINK/INSTALL-METADATA" ]; then
    engine_version=$(awk -F= '$1 == "DOCKER_ENGINE_VERSION" { print $2 }' \
        "$CURRENT_LINK/INSTALL-METADATA")
    compose_version=$(awk -F= '$1 == "DOCKER_COMPOSE_VERSION" { print $2 }' \
        "$CURRENT_LINK/INSTALL-METADATA")
    buildx_version=$(awk -F= '$1 == "DOCKER_BUILDX_VERSION" { print $2 }' \
        "$CURRENT_LINK/INSTALL-METADATA")
fi

log "当前版本：Engine $engine_version，Compose $compose_version，Buildx $buildx_version"
[ -n "$current_target" ] && log "当前版本目录：$current_target"

for unit_name in containerd.service docker.socket docker.service; do
    unit_state=$(systemctl is-active "$unit_name" 2>/dev/null || true)
    [ -n "$unit_state" ] || unit_state=unknown
    log "服务状态：$unit_name=$unit_state"
done

log "将删除：$INSTALL_ROOT"
for unit_name in containerd.service docker.socket docker.service; do
    [ -e "$UNIT_DIR/$unit_name" ] && log "将删除：$UNIT_DIR/$unit_name"
done

for binary_name in docker dockerd containerd containerd-shim-runc-v2 ctr runc \
    docker-init docker-proxy; do
    link_path=$BIN_LINK_DIR/$binary_name
    if is_managed_link "$link_path" "$CURRENT_LINK/bin/$binary_name"; then
        log "将删除链接：$link_path"
    elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
        die "发现非本脚本链接或文件，保留现场并中止：$link_path"
    fi
done

for plugin_name in docker-compose docker-buildx; do
    link_path=$PLUGIN_LINK_DIR/$plugin_name
    if is_managed_link "$link_path" "$CURRENT_LINK/cli-plugins/$plugin_name"; then
        log "将删除链接：$link_path"
    elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
        die "发现非本脚本插件，保留现场并中止：$link_path"
    fi
done

log "将保留：/etc/docker/daemon.json、/var/lib/docker、/var/lib/containerd、docker 用户组"

if [ "$CHECK_ONLY" -eq 1 ]; then
    log "检查完成；未修改系统"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || die "卸载必须以 root 身份运行"

if [ "$ASSUME_YES" -ne 1 ]; then
    [ -t 0 ] || die "非交互执行必须添加 --yes"
    printf '%s' "卸载会停止 Docker 及现有容器，是否继续？[y/N] "
    read -r answer || answer=n
    case "$answer" in
        y|Y|yes|YES) ;;
        *)
            log "已取消卸载"
            exit 0
            ;;
    esac
fi

log "停止 Docker、Docker Socket 和 containerd"
if [ -n "$managed_units" ]; then
    # The list contains only the three fixed unit names checked above.
    timeout 120 systemctl stop $managed_units ||
        die "停止服务失败或超过 120 秒；程序文件保留，请检查服务状态"
fi
for unit_name in $managed_units; do
    stopped_state=$(unit_property "$unit_name" ActiveState) ||
        die "无法核对 $unit_name 的停止状态"
    case "$stopped_state" in
        inactive|failed) ;;
        *) die "$unit_name 尚未完全停止：$stopped_state，拒绝删除文件" ;;
    esac
done

# A live-restore container or separately started daemon can outlive systemd.
for proc_entry in /proc/[0-9]*/exe; do
    executable_path=$(readlink "$proc_entry" 2>/dev/null || true)
    case "$executable_path" in
        "$INSTALL_ROOT"/*)
            die "仍有受管程序运行：$proc_entry -> $executable_path；请停止后重试" ;;
    esac
done
check_mounts

for unit_name in $managed_units; do
    systemctl disable "$unit_name" >/dev/null || die "禁用 $unit_name 失败"
done

for binary_name in docker dockerd containerd containerd-shim-runc-v2 ctr runc \
    docker-init docker-proxy; do
    link_path=$BIN_LINK_DIR/$binary_name
    if is_managed_link "$link_path" "$CURRENT_LINK/bin/$binary_name"; then
        rm -f -- "$link_path"
    elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
        warn "保留非本脚本链接或文件：$link_path"
    fi
done

for plugin_name in docker-compose docker-buildx; do
    link_path=$PLUGIN_LINK_DIR/$plugin_name
    if is_managed_link "$link_path" "$CURRENT_LINK/cli-plugins/$plugin_name"; then
        rm -f -- "$link_path"
    elif [ -e "$link_path" ] || [ -L "$link_path" ]; then
        warn "保留非本脚本插件：$link_path"
    fi
done

for unit_name in $managed_units; do
    rm -f -- "$UNIT_DIR/$unit_name"
done
rm -rf -- "$INSTALL_ROOT"
rmdir "$PLUGIN_LINK_DIR" >/dev/null 2>&1 || true

systemctl daemon-reload
systemctl reset-failed docker.service docker.socket containerd.service \
    >/dev/null 2>&1 || true

log "Docker 程序卸载完成"
log "已保留：/etc/docker/daemon.json、/var/lib/docker、/var/lib/containerd、docker 用户组"
