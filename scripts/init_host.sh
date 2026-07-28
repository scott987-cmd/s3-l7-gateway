#!/usr/bin/env bash
# ============================================================================
# init_host.sh -- 初始化目标主机:安装 Docker Engine + compose 插件 + aws-cli。
# 幂等,可重复执行。需 root。
#
# 兼容策略(不假设发行版):
#   * RHEL 系(dnf/yum): CentOS / RHEL / Rocky / AlmaLinux / Anolis /
#     Alibaba Cloud Linux / Amazon Linux / openEuler / Fedora
#     docker-ce 只发布到 centos/{7,8,9,10},而这些发行版的 $releasever 可能是
#     4、23、2023 等,直接用仓库文件里的 $releasever 会 404。
#     因此这里"先探测 repomd.xml 再落盘 baseurl",不依赖 $releasever。
#   * Debian 系(apt): Debian / Ubuntu,按 codename 探测。
#
# 用法(远端): sudo bash scripts/init_host.sh
# ============================================================================
set -euo pipefail
log(){ echo "[init] $*"; }
die(){ echo "[init][ERR] $*" >&2; exit 1; }

[[ "$(id -u)" == "0" ]] || die "需要 root 权限运行(sudo bash scripts/init_host.sh)"

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  RPM_ARCH=x86_64 ; DEB_ARCH=amd64 ;;
  aarch64|arm64) RPM_ARCH=aarch64; DEB_ARCH=arm64 ;;
  *) die "不支持的架构: $ARCH" ;;
esac

# shellcheck disable=SC1091
[[ -r /etc/os-release ]] && . /etc/os-release
OS_ID="${ID:-unknown}"; OS_VER="${VERSION_ID:-}"; OS_LIKE="${ID_LIKE:-}"
log "主机: ${PRETTY_NAME:-$OS_ID $OS_VER}  arch=$ARCH"

have(){ command -v "$1" >/dev/null 2>&1; }
url_ok(){ curl -fsS -o /dev/null -m 15 "$1" 2>/dev/null; }

# ---------------------------------------------------------------------------
# docker-ce 在 RHEL 系镜像上的候选 releasever。
# 返回一个优先级列表:先按发行版猜,再兜底 9/8/10。
# ---------------------------------------------------------------------------
rpm_releasever_candidates(){
  local major="${OS_VER%%.*}" guess=""
  case "$OS_ID" in
    centos|rhel|rocky|almalinux|ol|circle) guess="$major" ;;
    anolis)  [[ "$major" -ge 23 ]] 2>/dev/null && guess=9 || guess="$major" ;;
    alinux)  case "$major" in 2) guess=7 ;; 3) guess=8 ;; *) guess=9 ;; esac ;;
    amzn)    case "$major" in 2) guess=7 ;; *) guess=9 ;; esac ;;
    openEuler|openeuler) guess=9 ;;
    fedora)  guess=9 ;;
    *)
      # 未知发行版:用 ID_LIKE 判断家族。多数 RHEL 衍生版会声明
      # ID_LIKE="rhel centos fedora" 之类,此时按 el9 起步比直接放弃更可能命中。
      case " $OS_LIKE " in
        *" rhel "*|*" centos "*|*" fedora "*|*" anolis "*) guess=9 ;;
        *) guess="" ;;
      esac
      ;;
  esac
  local out=()
  [[ -n "$guess" ]] && out+=("$guess")
  local v
  for v in 9 8 10 7; do
    [[ " ${out[*]} " == *" $v "* ]] || out+=("$v")
  done
  printf '%s\n' "${out[@]}"
}

RPM_MIRRORS=(
  "https://mirrors.aliyun.com/docker-ce"
  "https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
  "https://mirrors.ustc.edu.cn/docker-ce"
  "https://mirrors.ivolces.com/docker"
  "https://download.docker.com"
)

install_docker_rpm(){
  local PKG=dnf; have dnf || PKG=yum
  log "安装基础依赖 ..."
  $PKG -y install ca-certificates jq openssl curl tar gzip >/dev/null 2>&1 || true
  $PKG -y install dnf-plugins-core >/dev/null 2>&1 || true

  # 先探测出一个真实存在的 (mirror, releasever) 组合,再写 repo 文件。
  local base rel found_base="" found_rel="" found_mirror=""
  for base in "${RPM_MIRRORS[@]}"; do
    while read -r rel; do
      [[ -n "$rel" ]] || continue
      local probe="$base/linux/centos/$rel/$RPM_ARCH/stable/repodata/repomd.xml"
      if url_ok "$probe"; then
        found_base="$base/linux/centos/$rel/$RPM_ARCH/stable"
        found_rel="$rel"; found_mirror="$base"
        break 2
      fi
    done < <(rpm_releasever_candidates)
    log "  镜像无可用版本: $base"
  done

  [[ -n "$found_base" ]] || return 1
  log "  选定 docker-ce 源: $found_mirror  (centos/$found_rel/$RPM_ARCH)"

  cat > /etc/yum.repos.d/docker-ce.repo <<EOF
[docker-ce-stable]
name=Docker CE Stable - $RPM_ARCH
baseurl=$found_base
enabled=1
gpgcheck=0
EOF

  $PKG clean all >/dev/null 2>&1 || true
  log "  安装 docker-ce / cli / containerd / compose 插件 ..."
  $PKG -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin \
    || $PKG -y install docker-ce docker-ce-cli containerd.io docker-compose-plugin \
    || return 1
  return 0
}

DEB_MIRRORS=(
  "https://mirrors.aliyun.com/docker-ce"
  "https://mirrors.tuna.tsinghua.edu.cn/docker-ce"
  "https://download.docker.com"
)

install_docker_deb(){
  export DEBIAN_FRONTEND=noninteractive
  log "安装基础依赖 ..."
  apt-get update -qq || true
  apt-get install -y -qq ca-certificates curl gnupg jq openssl >/dev/null 2>&1 || true

  local distro="$OS_ID" codename="${VERSION_CODENAME:-}"
  [[ "$distro" == "ubuntu" || "$distro" == "debian" ]] || distro=debian
  [[ -n "$codename" ]] || codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-stable}")"

  local base found=""
  for base in "${DEB_MIRRORS[@]}"; do
    if url_ok "$base/linux/$distro/dists/$codename/Release"; then found="$base"; break; fi
    log "  镜像无该版本: $base ($distro/$codename)"
  done
  [[ -n "$found" ]] || return 1
  log "  选定 docker-ce 源: $found  ($distro/$codename)"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL -m 30 "$found/linux/$distro/gpg" | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$DEB_ARCH signed-by=/etc/apt/keyrings/docker.gpg] $found/linux/$distro $codename stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -qq || return 1
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-buildx-plugin || return 1
  return 0
}

# ---------------------------------------------------------------------------
# aws-cli:包管理器 → pip3 → 官方 zip。任一成功即止。
# ---------------------------------------------------------------------------
install_awscli(){
  have aws && { log "aws-cli 已就绪: $(aws --version 2>&1 | head -1)"; return 0; }
  log "安装 aws-cli ..."

  if have dnf || have yum; then
    local PKG=dnf; have dnf || PKG=yum
    $PKG -y install awscli >/dev/null 2>&1 && have aws && { log "  经包管理器安装成功"; return 0; }
  elif have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq awscli >/dev/null 2>&1 && have aws && { log "  经包管理器安装成功"; return 0; }
  fi

  # 优先官方 v2:pip3 装到的是 aws-cli v1,它在 --no-verify-ssl 下会往 stderr
  # 打 InsecureRequestWarning,容易被脚本误判为失败。
  local tmpdir; tmpdir="$(mktemp -d)"
  if have dnf; then dnf -y install unzip >/dev/null 2>&1 || true
  elif have apt-get; then apt-get install -y -qq unzip >/dev/null 2>&1 || true; fi
  local zip_arch=x86_64; [[ "$RPM_ARCH" == aarch64 ]] && zip_arch=aarch64
  if curl -fsSL -m 120 -o "$tmpdir/awscliv2.zip" "https://awscli.amazonaws.com/awscli-exe-linux-${zip_arch}.zip" \
     && unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir" \
     && "$tmpdir/aws/install" --update >/dev/null 2>&1; then
    rm -rf "$tmpdir"; have aws && { log "  经官方安装器安装成功"; return 0; }
  fi
  rm -rf "$tmpdir"

  if have pip3; then
    pip3 install --quiet awscli >/dev/null 2>&1 \
      || pip3 install --quiet --break-system-packages awscli >/dev/null 2>&1 || true
    have aws && { log "  经 pip3 安装成功(aws-cli v1)"; return 0; }
  fi

  log "  [WARN] aws-cli 安装失败。部署不受影响,但 smoke/speed/stress 测试需要它。"
  return 1
}

# ---------------------------------------------------------------------------
main(){
  if have docker && docker compose version >/dev/null 2>&1; then
    log "docker + compose 已就绪: $(docker --version)"
  else
    local ok=1
    if have dnf || have yum; then
      install_docker_rpm && ok=0
    elif have apt-get; then
      install_docker_deb && ok=0
    else
      die "未识别的包管理器(需要 dnf/yum 或 apt-get)"
    fi
    [[ "$ok" == 0 ]] || die "所有镜像源均安装失败,请检查网络/DNS 后重试"
  fi

  log "启用并启动 docker ..."
  systemctl enable --now docker >/dev/null 2>&1 || systemctl start docker >/dev/null 2>&1 || true

  # 国内拉取 nginx / sigv4-proxy 基础镜像用的 registry 加速,仅在未配置时写入。
  if [[ ! -f /etc/docker/daemon.json ]]; then
    mkdir -p /etc/docker
    cat > /etc/docker/daemon.json <<'JSON'
{
  "registry-mirrors": ["https://docker.mirrors.ustc.edu.cn", "https://docker.m.daocloud.io", "https://mirror.ccs.tencentyun.com"]
}
JSON
    systemctl restart docker >/dev/null 2>&1 || true
  fi

  install_awscli || true

  log "校验:"
  docker --version
  docker compose version
  aws --version 2>&1 | head -1 || true
  docker info >/dev/null 2>&1 && log "docker daemon 可用" || die "docker daemon 不可用"
  log "完成。"
}

main "$@"
