# Docker 离线安装基线验收记录

## 一、验收环境

- 日期：2026-09-14 至 2026-09-16
- 虚拟化平台：Microsoft Hyper-V
- 操作系统：Debian GNU/Linux 13.7（trixie）
- CPU 架构：x86_64
- Linux 内核：6.12.107+deb13-amd64
- systemd：257
- cgroup：v2
- 根文件系统：ext4
- 安装前状态：未安装 Docker、dockerd、containerd 或 runc

为满足安装基线，测试前通过 Debian 软件源安装了 `iptables` 和 `git`；`kmod`、`curl`、`xz` 已存在。该步骤属于测试环境准备，不属于目标机离线安装流程。

## 二、验收版本

现代组合：

- Docker Engine：29.8.0
- Docker Compose：5.5.1
- Docker Buildx：0.37.0
- 双架构交付目录大小：约 338 MB

兼容组合：

- Docker Engine：26.1.4
- Docker Compose：2.27.1
- Docker Buildx：0.14.1
- 双架构交付目录大小：约 360 MB

## 三、已通过项目

1. `install.sh` 和 `prepare-bundle.sh` 通过 Debian `/bin/sh` 语法检查。
2. 两套组合的制包脚本均成功下载并生成 x86_64、aarch64 双架构交付目录。
3. `SHA256SUMS` 清单中的文件全部校验通过，包括两个架构的 Engine、Compose 和 Buildx。
4. x86_64 与 aarch64 的 Engine、Compose、Buildx 文件经 `file` 检查，ELF 架构与目录一致，相关二进制均为静态链接。
5. 非 root 用户执行 `sh install.sh --check-only` 成功，硬性条件满足，0 项警告，未修改系统。
6. 首次安装成功，Docker Engine、containerd、Docker Socket 均启动并设为开机启用。
7. 现代组合的 Docker 客户端和服务端版本均为 29.8.0；兼容组合均为 26.1.4。两套 Compose 与 Buildx 插件均可被 Docker CLI 正确发现。
8. Compose 配置解析成功；Buildx 使用 `FROM scratch` 完成本机离线构建、镜像检查及测试镜像清理。
9. 重复执行安装脚本能够识别同版本安装，未重复部署，并再次完成运行验证。
10. 虚拟机重启后，`containerd.service`、`docker.socket`、`docker.service` 均保持 `enabled` 和 `active`。
11. 两套组合均在重启后再次执行幂等验证和 Buildx 构建成功。
12. `systemd-analyze verify` 检查三个单元未报告错误；验收期间 Docker/containerd 日志未出现 warning 级别记录。
13. 默认未把测试用户加入 `docker` 组。普通用户能够执行 Docker CLI 和发现插件，但访问 Docker Socket 时被拒绝，符合预期权限边界。
14. 安装未创建 `/etc/docker/daemon.json`，没有覆盖客户侧守护进程配置。
15. ARM64 的安装、容器运行、重启、卸载保留和重新安装结果见第七节。

## 四、实测发现并修复的问题

1. Debian 普通登录用户的 `PATH` 可能不包含 `/usr/sbin`，导致已安装的 `iptables` 被误判为缺失。脚本现已显式加入标准系统管理路径。
2. `mktemp -d` 创建的版本暂存目录默认权限为 `0700`。如果直接切换为正式版本目录，root 验证能够通过，但普通用户无法执行 Docker CLI。脚本现已在切换前将版本目录、`bin` 和 `cli-plugins` 明确设为 `0755`。
3. Buildx 冒烟测试的进度输出较多。脚本现已在成功时静默构建日志，仅在失败时输出最多 160 行日志。
4. 制包暂存目录由 `mktemp -d` 创建时默认权限为 `0700`，不利于换账号交付。制包脚本现已在输出前将交付目录根权限明确设为 `0755`。
5. 跨版本切换时，`mv` 默认跟随指向目录的 `current` 符号链接，导致新链接被移入旧版本目录而非替换目标。脚本现改用 GNU `mv -T` 原子替换，并在运行验证中强制断言 Engine 客户端、Engine 服务端、Compose、Buildx 的实际版本与清单完全一致。
6. 卸载后保留 `daemon.json` 重新安装时，Docker 26 配置校验因找不到 `docker-proxy` 失败。校验阶段现将本次解压的 `bin` 目录加入该命令的 PATH，已有配置可正常校验。
7. ARM64 制包时，GitHub 连接建立后持续无数据且制包脚本无限等待。下载现增加连接、低速和总时限，并保留有限次数重试。
8. Incus 会通过 `/run/systemd/system/service.d/` 注入全局服务 drop-in。卸载脚本现只拒绝 `docker.service.d`、`docker.socket.d`、`containerd.service.d` 等单元专用 drop-in，避免把全局容器策略误判为 Docker 单元被接管。

以上修复均已在后续干净安装或跨版本切换中复测；最终版本在重启后再次验证。

## 五、尚未覆盖的验收边界

- 安装时虚拟机仍具备网络连接。安装脚本不包含下载操作，Buildx 测试使用 `FROM scratch` 且未拉取镜像，但尚未通过断开网卡或拦截网络系统调用验证零外连。
- 已在无容器、镜像、卷的测试状态下验证 29.8.0 到 26.1.4 的版本链接切换；这不是受支持的生产降级证明。尚未验证正常向上升级、升级失败自动回切、非本脚本安装冲突、摘要篡改拒绝和人工回滚流程。
- 尚未在 CentOS 7 的 3.10 回移内核上运行；`3.10.0-514+` 规则目前依据官方 OverlayFS 门槛实现，仍需 CentOS 7 实机验证。
- 尚未覆盖 SELinux Enforcing、AppArmor 定制策略、cgroup v1、XFS、企业代理/CA、私有仓库、IPv6、nftables 后端及跨架构构建。
- 本次未部署真实业务镜像，未验证业务 Compose 文件、端口发布、日志增长和资源容量；数据卷仅验证下述专用测试卷的文件保留。

## 六、卸载与重新安装验证

在上述 Debian 13 x86_64、Docker 26.1.4 环境完成：

- `--check-only` 显示卸载范围，服务继续运行；交互输入 `n` 取消后服务仍运行。
- 安装目录不存在时拒绝卸载。
- 将 `docker.service` 临时替换为符号链接后，卸载在停止服务前拒绝执行；测试脚本自动恢复原单元。回归脚本：`tests/uninstall-conflict.sh`，仅供一次性测试主机使用。
- `--yes` 卸载后，受管版本目录和程序链接移除，三个 systemd 单元的 LoadState 均为 `not-found`。
- 已有 `daemon.json` 和专用测试卷文件的 SHA-256 在卸载前后完全一致；两个数据目录的 inode、权限和 `docker` 组 GID 均未变化。
- 保留配置重新安装成功；Engine、Compose、Buildx 版本断言及本机构建通过。

以上为静态保留文件和同版本重装验证，不包含运行中业务容器、live-restore 容器、嵌套挂载或并发安装场景。CentOS 7 的卸载实测尚未完成。

## 七、ARM64 Incus 验收

环境：

- Oracle Ampere A1（aarch64）宿主机，Debian 13，内核 6.12.73，Incus 6.0.4；
- 独立的 Debian 13 aarch64 非特权系统容器；
- 启用 `security.nesting`、mknod/setxattr syscall intercept，限制 2 CPU、2 GiB 内存；
- Docker Engine 26.1.4、Compose 2.27.1、Buildx 0.14.1。

已通过：

- 完整离线包 SHA-256 校验，Engine、Compose、Buildx 均确认是 ARM aarch64 静态 ELF；
- `install.sh --check-only` 识别 aarch64，硬性条件满足，0 项脚本预检警告；
- 首次安装和安装内置的 `FROM scratch` Buildx 构建；
- Engine 客户端与服务端版本一致，存储驱动为 overlay2，cgroup v2/systemd 正常；
- 使用静态 BusyBox 导入本地 `linux/arm64` 镜像，不访问镜像仓库完成容器运行；
- 自定义 bridge 网络、容器名解析及容器间 HTTP 通信；
- Incus 容器重启后，containerd、Docker Socket、Docker 服务保持 enabled/active，运行和网络测试再次通过；
- Incus 全局 systemd service drop-in 可通过卸载预检，Docker 单元专用 drop-in 会在停止服务前被拒绝；
- `daemon.json`、专用测试卷文件的 SHA-256、数据目录 inode/权限和 `docker` 组 GID 在卸载前后保持一致；
- 保留配置和数据重新安装成功，专用测试卷可读，最终已删除测试卷、测试镜像、测试网络和测试配置。

环境边界：

- Incus 容器未暴露 `bridge-nf-call-iptables` 和 `bridge-nf-call-ip6tables`，`docker info` 会产生两条警告；实际 bridge 网络功能已通过，但未覆盖宿主机防火墙合规策略。
- ARM64 容器可从 Docker 下载站点获取 Engine，但连接 GitHub Releases 时出现建立连接后无数据；本次安装使用已在其他制包机生成并校验的双架构包。制包脚本已增加连接、低速和总时限。
- 尚未在不经过 Incus 嵌套的 ARM64 裸机或虚拟机上执行同一组测试。
