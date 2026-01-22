#!/usr/bin/env bash
set -euo pipefail

# 设置输出目录，默认为 docker_migrate_all_<当前时间>
OUT="${1:-docker_migrate_all_$(date +%F_%H%M%S)}"
mkdir -p "$OUT"/{inspects,volumes,binds,meta}

echo "[0] 收集容器列表..."
mapfile -t CONTAINERS < <(docker ps -a --format '{{.ID}} {{.Names}}')
if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  echo "没有容器可导出。"
  exit 0
fi
printf "%s\n" "${CONTAINERS[@]}" > "$OUT/meta/containers.list"

echo "[1] 导出所有容器 inspect..."
while read -r cid cname; do
  docker inspect "$cid" > "$OUT/inspects/${cname}.json"
done < "$OUT/meta/containers.list"

echo "[2] 导出所有“正在使用”的镜像..."
# 只导出当前容器实际用到的 image
python3 - <<'PY' "$OUT"
import json, os, subprocess, sys
out=sys.argv[1]
imgs=set()
for fn in os.listdir(os.path.join(out,"inspects")):
    with open(os.path.join(out,"inspects",fn), "r", encoding="utf-8") as f:
        arr=json.load(f)
    if not arr: 
        continue
    imgs.add(arr[0].get("Config",{}).get("Image"))
imgs=[i for i in imgs if i]
with open(os.path.join(out,"meta","images.list"),"w",encoding="utf-8") as f:
    f.write("\n".join(sorted(imgs))+"\n")
print("镜像数量:", len(imgs))
if imgs:
    # 分批 save，避免命令行太长
    batch=20
    parts=[]
    for k in range(0,len(imgs),batch):
        part=os.path.join(out,"meta",f"images_{k//batch}.tar")
        cmd=["docker","save","-o",part]+imgs[k:k+batch]
        subprocess.check_call(cmd)
        parts.append(part)
    with open(os.path.join(out,"meta","images_tars.list"),"w",encoding="utf-8") as f:
        f.write("\n".join(parts)+"\n")
PY

echo "[3] 导出命名 volumes（只导出容器 Mounts 里 type=volume 的）..."
python3 - <<'PY' "$OUT"
import json, os, sys
out=sys.argv[1]
vols=set()
for fn in os.listdir(os.path.join(out,"inspects")):
    with open(os.path.join(out,"inspects",fn), "r", encoding="utf-8") as f:
        arr=json.load(f)
    if not arr: 
        continue
    for m in arr[0].get("Mounts",[]):
        if m.get("Type")=="volume" and m.get("Name"):
            vols.add(m["Name"])
vols=sorted(vols)
open(os.path.join(out,"meta","volumes.list"),"w",encoding="utf-8").write("\n".join(vols)+"\n")
print("命名 volume 数量:", len(vols))
PY

if [[ -s "$OUT/meta/volumes.list" ]]; then
  while read -r v; do
    [[ -z "$v" ]] && continue
    echo "  - export volume: $v"
    docker run --rm -v "$v":/from -v "$(pwd)/$OUT/volumes":/to alpine \
      sh -c "cd /from && tar -cpf /to/volume_${v}.tar ."
  done < "$OUT/meta/volumes.list"
else
  echo "  (没有命名 volume)"
fi

echo "[4] 导出 bind 挂载目录（只打包容器实际挂载到的宿主机路径）..."
# 安全过滤：跳过 /proc /sys /dev /run 等高风险路径；跳过根目录 /
python3 - <<'PY' "$OUT"
import json, os, sys, pathlib
out=sys.argv[1]
binds=set()
skip_prefixes=("/proc","/sys","/dev","/run")
for fn in os.listdir(os.path.join(out,"inspects")):
    with open(os.path.join(out,"inspects",fn), "r", encoding="utf-8") as f:
        arr=json.load(f)
    if not arr: 
        continue
    for m in arr[0].get("Mounts",[]):
        if m.get("Type")=="bind" and m.get("Source"):
            src=m["Source"]
            if src=="/": 
                continue
            if src.startswith(skip_prefixes):
                continue
            binds.add(src)
binds=sorted(binds)
open(os.path.join(out,"meta","binds.list"),"w",encoding="utf-8").write("\n".join(binds)+"\n")
print("bind 挂载路径数量:", len(binds))
PY

# 打包 bind 路径：保留绝对路径结构（--absolute-names），方便新机还原到同路径
if [[ -s "$OUT/meta/binds.list" ]]; then
  i=0
  while read -r p; do
    [[ -z "$p" ]] && continue
    if [[ ! -e "$p" ]]; then
      echo "  - skip missing bind: $p"
      continue
    fi
    i=$((i+1))
    echo "  - export bind[$i]: $p"
    # 防止把奇怪的软链接拖进来：用 tar 的 -h 不跟随，保持原状
    tar -cpf "$OUT/binds/bind_${i}.tar" --absolute-names "$p"
  done < "$OUT/meta/binds.list"
else
  echo "  (没有 bind 挂载)"
fi

echo "[5] 生成还原启动脚本（从 inspect 自动拼 docker run）..."
python3 - <<'PY' "$OUT"
import json, os, sys, shlex
out=sys.argv[1]
ins_dir=os.path.join(out,"inspects")
os.makedirs(os.path.join(out,"meta"), exist_ok=True)

def q(s): 
    return shlex.quote(str(s))

lines=[]
lines.append("#!/usr/bin/env bash")
lines.append("set -euo pipefail")
lines.append("")
lines.append('echo "开始创建并启动容器..."')

for fn in sorted(os.listdir(ins_dir)):
    path=os.path.join(ins_dir,fn)
    arr=json.load(open(path,"r",encoding="utf-8"))
    if not arr: 
        continue
    j=arr[0]
    name=j.get("Name","").lstrip("/") or fn.replace(".json","")
    cfg=j.get("Config",{})
    host=j.get("HostConfig",{})
    net=j.get("NetworkSettings",{})

    image=cfg.get("Image","")
    if not image:
        continue

    cmd=["docker","run","-d","--name",name]

    # restart policy
    rp=host.get("RestartPolicy",{})
    if rp and rp.get("Name"):
        cmd+=["--restart", rp["Name"] + (":" + str(rp.get("MaximumRetryCount",0)) if rp["Name"]=="on-failure" else "")]

    # env
    for e in (cfg.get("Env") or []):
        cmd+=["-e", e]

    # ports
    pb=host.get("PortBindings") or {}
    for container_port, binds in pb.items():
        if not binds:
            continue
        for b in binds:
            hip=b.get("HostIp","")
            hp=b.get("HostPort","")
            if hp:
                if hip and hip!="0.0.0.0":
                    cmd+=["-p", f"{hip}:{hp}:{container_port}"]
                else:
                    cmd+=["-p", f"{hp}:{container_port}"]

    # mounts
    for m in (j.get("Mounts") or []):
        t=m.get("Type")
        if t=="volume":
            src=m.get("Name")
            dst=m.get("Destination")
            ro=m.get("RW") is False
            if src and dst:
                cmd+=["-v", f"{src}:{dst}" + (":ro" if ro else "")]
        elif t=="bind":
            src=m.get("Source")
            dst=m.get("Destination")
            ro=m.get("RW") is False
            if src and dst:
                cmd+=["-v", f"{src}:{dst}" + (":ro" if ro else "")]

    # network (尽量还原为原来的第一个网络名；没有就默认 bridge)
    nets=(net.get("Networks") or {})
    if nets:
        first=list(nets.keys())[0]
        if first and first!="bridge":
            cmd+=["--network", first]

    # workdir
    wd=cfg.get("WorkingDir")
    if wd:
        cmd+=["-w", wd]

    # entrypoint / cmd
    ep=cfg.get("Entrypoint")
    c=cfg.get("Cmd")
    # docker run 的格式：--entrypoint + image + cmd
    if ep:
        if isinstance(ep, list):
            cmd+=["--entrypoint", ep[0]]
        else:
            cmd+=["--entrypoint", ep]

    cmd.append(image)
    if c:
        if isinstance(c, list):
            cmd += c
        else:
            cmd += [c]

    lines.append("")
    lines.append(f'echo "启动: {name}"')
    lines.append(" ".join(q(x) for x in cmd))

script=os.path.join(out,"meta","restore_run_all.sh")
open(script,"w",encoding="utf-8").write("\n".join(lines)+"\n")
os.chmod(script,0o755)
print("已生成:", script)
PY

echo "[6] 打包迁移包..."
tar -czf "${OUT}.tgz" "$OUT"
echo "完成：${OUT}.tgz"
echo "传到新服务器：scp ${OUT}.tgz root@新服务器IP:/root/"
