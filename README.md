# Docker Migration Tools

## 版本 v1.0

这是一个用于 **Docker 容器迁移** 的工具集，提供导出和导入容器配置、镜像、卷和挂载路径的脚本。通过此工具，您可以轻松地将容器从一台服务器迁移到另一台，自动恢复原有环境。

## 功能

- **容器导出**：导出所有容器的配置、镜像、卷和挂载路径。
- **容器导入**：在目标服务器上还原容器配置并启动容器。
- **镜像和卷管理**：自动导出和导入 Docker 镜像与命名卷，确保容器环境完整恢复。
- **跨服务器迁移**：支持容器从源服务器迁移到目标服务器，确保容器服务的高可用性和无缝过渡。

## 安装

1. **克隆仓库**：

   ```bash
   git clone https://github.com/imantoua/docker-migration-tools.git
   cd docker-migration-tools
````

2. **确保 Docker 已安装**：
   请确保新旧服务器都已安装 Docker，并且可以正常运行 Docker 容器。

## 使用教程

### 1. 导出容器（源服务器）

首先，在源服务器上运行 `docker_export_all.sh` 脚本，导出所有容器的配置、镜像、卷和挂载路径。

```bash
chmod +x docker_export_all.sh
./docker_export_all.sh
```

此命令将生成一个压缩包，包含容器的配置、镜像和数据。

### 2. 上传压缩包至目标服务器

将生成的压缩包传输到目标服务器，例如：

```bash
scp docker_migrate_all_YYYY-MM-DD_HHMMSS.tgz user@target-server:/root/
```

### 3. 导入容器（目标服务器）

在目标服务器上，解压并运行 `restore_run_all.sh` 脚本，恢复容器配置并启动容器。

```bash
cd /root
tar -xzf docker_migrate_all_YYYY-MM-DD_HHMMSS.tgz
chmod +x restore_run_all.sh
./restore_run_all.sh
```

### 4. 完成

容器将根据原配置自动启动，您可以使用 `docker ps` 查看运行中的容器。

## 贡献

欢迎提交问题报告或功能请求！如果你有好的建议，欢迎提交 Pull Request。

## License

MIT License

---
ManTou
2026.01.22
