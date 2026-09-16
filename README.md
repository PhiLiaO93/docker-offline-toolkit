# Docker 二进制离线部署

适用于使用 systemd 的 64 位 GNU/Linux，支持 `x86_64` 和 `aarch64`。安装脚本自动识别架构，全程不访问网络。

默认兼容版本：

- Docker Engine `26.1.4`
- Docker Compose `2.27.1`
- Docker Buildx `0.14.1`

> 静态二进制不会自动获得安全更新；CentOS 7 仅作为兼容目标，不代表仍受上游正式支持。

## 1. 制作离线包

在可访问互联网的 Linux 制包机上执行：

```bash
sh prepare-bundle.sh
```

默认输出：

```text
dist/docker-offline-26.1.4/
```

如需指定版本：

```bash
sh prepare-bundle.sh \
  --engine-version 26.1.4 \
  --compose-version 2.27.1 \
  --buildx-version 0.14.1 \
  --output /path/to/docker-offline-26.1.4
```

生成目录同时包含 x86_64、aarch64 二进制及 `SHA256SUMS`。

## 2. 部署前检查

将完整离线包复制到目标机，进入目录后执行：

```bash
sudo sh install.sh --check-only
```

检查通过后再安装。主要要求：

- systemd 正常运行，cgroup v1 或 v2 已挂载；
- `iptables` 不低于 1.4；
- 通用内核不低于 4.0；
- Engine 28及以下允许 RHEL/CentOS 7 的 `3.10.0-514+` 回移内核；
- 不存在由其他方式安装的 Docker、containerd、runc 或同名 systemd 单元。

## 3. 安装

安装并启动：

```bash
sudo sh install.sh
```

只安装、不立即启动：

```bash
sudo sh install.sh --no-start
```

如确需允许指定用户直接使用 Docker：

```bash
sudo sh install.sh --add-user appuser
```

`docker` 组具有等同 root 的主机控制能力，默认不添加任何用户。

## 4. 升级

仅支持升级由本脚本管理的安装：

```bash
sudo sh install.sh --upgrade
```

升级会停止 Docker 和现有容器。新版本启动或验证失败时，脚本会尝试切回原版本；升级前仍应完成数据备份和停机确认。

## 5. 验证

```bash
systemctl is-active containerd.service docker.socket docker.service
sudo docker version
sudo docker compose version
sudo docker buildx version
sudo docker info
```

安装脚本还会自动执行 Compose 配置解析和一次基于 `FROM scratch` 的本机 Buildx 构建，过程不会拉取测试镜像。

## 6. 卸载

在完整离线包目录内先查看卸载范围：

```bash
sudo sh uninstall.sh --check-only
```

确认后执行：

```bash
sudo sh uninstall.sh
```

卸载会停止服务并删除本脚本安装的程序和 systemd 单元，保留 Docker 配置、数据目录和 `docker` 组。非交互执行可添加 `--yes`。单元或链接被修改、存在单元专用 drop-in、目录内存在挂载点或服务停止后仍有受管进程时，脚本会中止。

## 7. 默认保护边界

- 不创建或覆盖 `/etc/docker/daemon.json`；
- 不删除或迁移 `/var/lib/docker`；
- 不接管既有的非本脚本安装；
- 不自动把用户加入 `docker` 组；
- 不包含业务镜像、跨架构 BuildKit 镜像或 QEMU/binfmt。

详细兼容规则和待确认事项见 [DESIGN.md](DESIGN.md)，实测结果及未覆盖范围见 [VALIDATION.md](VALIDATION.md)。
