#!/usr/bin/env bash
set -euo pipefail

# 需要传入的 tgz 文件
TGZ="${1:?用法: docker_import_all.sh <docker_migrate_all_xxx.tgz>}"
WORK="/root/docker_migrate_unpack_$(date +%s)"
mkdir -p "$WORK"
tar -xzf "$TGZ" -C "$WORK"

DIR="$(find "$WORK" -maxdepth 2 -type d -name 'docker_migrate_all_*' -print -quit)"
if [[ -z "${DIR:-}" ]]; then
  # 兼容自定义 OUT 名
  DIR="$(find "$WORK" -maxdepth 2 -type f -name 'meta/containers.list' -print -quit | xargs -I{} dirname {} | xargs -I{} dirname {})"
fi
echo "使用目录：$DIR"

echo "[1] 导入镜像..."
if [[ -f "$DIR/meta/images_tars.list" ]]; then
  while read -r tarf; do
    [[ -z "$tarf" ]] && continue
    echo "  - load: $tarf"
    docker load -i "$tarf"
  done < "$DIR/meta/images_tars.list"
else
  echo "  (未找到 images_tars.list，跳过)"
fi

echo "[2] 还原命名 volumes..."
if [[ -f "$DIR/meta/volumes.list" ]]; then
  while read -r v; do
    [[ -z "$v" ]] && continue
    echo "  - restore volume: $v"
    docker volume create "$v" >/dev/null || true
    if [[ -f "$DIR/volumes/volume_${v}.tar" ]]; then
      docker run --rm -v "$v":/to -v "$DIR/volumes":/from alpine \
        sh -c "cd /to && tar -xpf /from/volume_${v}.tar"
    fi
  done < "$DIR/meta/volumes.list"
else
  echo "  (没有 volumes.list，跳过)"
fi

echo "[3] 还原 bind 挂载目录..."
# 将 tar 里的绝对路径解到系统相同位置（必要时先创建父目录）
if compgen -G "$DIR/binds/bind_*.tar" > /dev/null; then
  for f in "$DIR"/binds/bind_*.tar; do
    echo "  - restore bind tar: $f"
    # tar 里包含绝对路径，解压前不容易预创建所有父目录，这里直接解，失败再提示
    tar -xpf "$f" -C /
  done
else
  echo "  (没有 bind_*.tar，跳过)"
fi

echo "[4] 启动所有容器（自动生成的 docker run）..."
bash "$DIR/meta/restore_run_all.sh"

echo "完成 ✅"
echo "建议检查：docker ps -a && docker logs <容器名> | tail"
