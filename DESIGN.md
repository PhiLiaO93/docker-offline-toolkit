# Docker 离线部署设计说明

## 1. 范围

本方案使用 Docker 官方 Linux 静态二进制，在 systemd 主机上部署 rootful Docker Engine、containerd、Compose CLI 插件和 Buildx CLI 插件。安装阶段不访问网络，目前支持 x86_64 和 aarch64。

Rootless、Kubernetes、Swarm、业务镜像、跨架构构建运行时及客户侧 Docker 守护进程配置不在当前基线内。

## 2. 版本基线

默认兼容组合：

- Docker Engine 26.1.4
- Docker Compose 2.27.1
- Docker Buildx 0.14.1

该组合与 Engine 26.1.4 官方发布时的打包版本一致，主要用于兼容仍在使用 RHEL/CentOS 7 回移内核的环境。

已验证的现代组合为 Engine 29.8.0、Compose 5.5.1、Buildx 0.37.0，可通过制包参数生成，但不作为默认值。

静态二进制不会随发行版自动更新。版本应在发布流程中固定，并根据安全公告和兼容性测试统一升级，不在客户现场自动选择最新版。

## 3. 内核与系统兼容规则

- 通用 GNU/Linux：内核 4.0及以上。
- Engine 28及以下：RHEL/CentOS 7 可使用 3.10.0-514及以上回移内核。
- Engine 29及以上：要求内核 4.0及以上。
- CentOS 7 的 XFS 用于 Docker 数据目录时，需要确认 `ftype=1`。
- SELinux Enforcing 环境需要单独验证容器策略，不能通过关闭 SELinux 规避问题。

ARM64 已在 Debian 13 Incus 嵌套容器中验证。该环境未暴露 `bridge-nf-call-iptables` 和 `bridge-nf-call-ip6tables`，Docker 会提示警告；本地 ARM64 镜像运行、容器名解析和自定义 bridge 网络通信均已实测通过，但不能据此确认所有宿主机桥接防火墙策略。

`3.10.0-693.*.el7` 能通过 OverlayFS 兼容门槛，但属于 RHEL/CentOS 7.4 内核线；7.9 的初始内核线为 `3.10.0-1160`。脚本会放行并告警，是否更新内核应单独评估。

CentOS Linux 7 已结束维护，当前 Docker 官方 CentOS 安装文档也不再将其列为受支持版本。此处仅表示兼容目标，不表示上游仍提供正式支持。

## 4. 预检与安装验证

安装脚本检查以下内容：

- Linux、systemd、CPU 架构、内核和 cgroup；
- iptables 版本及 git、xz、ip6tables、modprobe 等能力；
- OverlayFS 和 SELinux 状态；
- 离线包组成、SHA-256、Engine 关键二进制及版本一致性；
- 既有 Docker/containerd/runc 和 systemd 单元冲突；
- 安装后的服务状态、Engine 客户端与服务端版本、Compose、Buildx；
- Compose 配置解析和不依赖基础镜像的 Buildx 冒烟构建。

## 5. 安装路径与配置边界

- 版本目录：`/usr/local/lib/docker-offline/versions/`
- 当前版本链接：`/usr/local/lib/docker-offline/current`
- 命令链接：`/usr/local/bin/`
- CLI 插件：`/usr/local/lib/docker/cli-plugins/`
- systemd 单元：`/etc/systemd/system/`
- Docker 配置：`/etc/docker/daemon.json`
- Docker 默认数据目录：`/var/lib/docker`

安装脚本不会创建、覆盖或迁移 Docker 配置与数据。已有 `daemon.json` 时只使用目标 Engine 执行语法校验。

`config/daemon.json.example` 仅提供日志轮转和数据目录样例，未经目标环境确认不得直接覆盖现有配置。

## 6. 离线包与供应链边界

制包脚本从 Docker 下载站点及 Compose、Buildx 官方 Releases 获取文件，检查 Engine 压缩包结构并生成 `SHA256SUMS`。

单文件下载设置 15 秒连接超时、60 秒低速超时和 600 秒总时限，并最多重试 3 次，避免网络异常时无限等待。

现场摘要能够发现传输损坏或摘要生成后的文件变化，但不能替代独立可信来源提供的预核准摘要、发布签名、Sigstore 验证或 SBOM。正式交付前需决定是否将这些能力纳入发布流程。

Dockerfile 基础镜像、系统软件源、语言依赖和 Compose 引用镜像必须另行离线准备。仅安装 Buildx 不能使依赖互联网的构建自动离线。

跨架构构建还需要准备 BuildKit 容器镜像和 QEMU/binfmt，并明确输出到本地镜像、OCI 归档或私有仓库。

## 7. 升级、回滚与卸载边界

升级仅适用于本脚本管理的安装，并会停止 Docker、Docker Socket、containerd 和现有容器。

脚本使用版本目录和 `current` 链接切换二进制。新版本启动或运行验证失败时会尝试恢复旧链接和服务，但不能保证跨大版本存储元数据能够反向兼容。生产升级仍需备份、停机窗口和应用级回退方案。

卸载脚本核对管理标记、安装路径、版本链接、命令链接，以及生效的 systemd 单元与随包模板是否一致。存在修改过的单元、单元专用 drop-in 配置或非受管链接时中止。systemd 的全局服务策略仍会生效，但不表示 Docker 单元已被其他安装接管。需从完整离线包执行，保留旁边的 `systemd/` 模板目录。

`--check-only` 只检查并显示范围；实际卸载需要 root 权限和交互确认，自动化可使用 `--yes`。停止服务最多等待 120 秒，停止失败或仍有受管进程（如 live-restore 留下的 shim）时中止；安装目录内存在挂载点时也中止。

默认删除 systemd 单元、受管命令链接、CLI 插件链接和全部版本目录，保留 `/etc/docker/daemon.json`、`/var/lib/docker`、`/var/lib/containerd` 及 `docker` 组。脚本不提供数据清除参数。删除的程序可从原离线包重新安装。

当前尚未提供人工选择历史版本和清理旧版本功能。

## 8. 待确认事项

1. 正式支持的发行版、版本、内核、cgroup、文件系统和安全模块矩阵。
2. `data-root`、日志轮转、地址池、IPv6、代理、私有仓库、企业 CA 和 `live-restore` 的配置归属。
3. `DOCKER-USER` 防火墙策略和允许发布的端口范围。
4. 本机原生构建或跨架构构建的范围。
5. 离线业务镜像、软件源和语言依赖的归档格式及摘要清单。
6. 离线包签名、SBOM、漏洞扫描和版本更新周期。
7. 升级、人工回滚、卸载及数据保留策略。
8. CPU、内存、磁盘、镜像存储、构建缓存和日志容量门槛。

## 9. 参考资料

- [Docker Engine 二进制安装](https://docs.docker.com/engine/install/binaries/)
- [Docker Engine 26.1 发布说明](https://docs.docker.com/engine/release-notes/26.1/)
- [OverlayFS 存储驱动](https://docs.docker.com/engine/storage/drivers/overlayfs-driver/)
- [Docker Compose 插件安装](https://docs.docker.com/compose/install/linux/)
