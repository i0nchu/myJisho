#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${EUID} -ne 0 ]]; then
  echo "請使用 sudo 執行：sudo ./scripts/install-docker-ubuntu.sh" >&2
  exit 1
fi

if [[ ! -r /etc/os-release ]]; then
  echo "找不到 /etc/os-release，無法確認作業系統。" >&2
  exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ ${ID:-} != "ubuntu" || ${VERSION_ID:-} != "24.04" ]]; then
  echo "此安裝器只支援 Ubuntu Server 24.04；目前為 ${PRETTY_NAME:-unknown}。" >&2
  exit 1
fi

target_user=${SUDO_USER:-}
if [[ -z ${target_user} || ${target_user} == "root" ]]; then
  echo "請由日常管理帳號透過 sudo 執行，不要直接以 root 登入執行。" >&2
  exit 1
fi

if command -v docker >/dev/null 2>&1 &&
  docker compose version >/dev/null 2>&1; then
  echo "Docker Engine 與 Compose v2 已安裝，略過套件安裝。"
else
  conflicting=()
  for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null |
      grep -q '^ii '; then
      conflicting+=("${package}")
    fi
  done
  if ((${#conflicting[@]} > 0)); then
    echo "偵測到會和 Docker 官方套件衝突的套件：" >&2
    printf '  %s\n' "${conflicting[@]}" >&2
    echo "請先確認既有容器與資料，再依 Docker 官方文件移除衝突套件。" >&2
    exit 1
  fi

  apt-get update
  apt-get install -y ca-certificates curl
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  architecture=$(dpkg --print-architecture)
  ubuntu_codename=${UBUNTU_CODENAME:-${VERSION_CODENAME}}
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${ubuntu_codename}
Components: stable
Architectures: ${architecture}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update
  apt-get install -y \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin
fi

systemctl enable --now docker.service containerd.service
docker run --rm hello-world >/dev/null

if ! id -nG "${target_user}" | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker "${target_user}"
  group_changed=true
else
  group_changed=false
fi

echo
echo "Docker 安裝與服務檢查完成。"
if [[ ${group_changed} == true ]]; then
  echo "已將 ${target_user} 加入 docker 群組。請登出 SSH 後重新登入，再執行部署。"
  echo "注意：docker 群組具有 root 等級權限，只應授予可信任的管理帳號。"
else
  echo "${target_user} 已在 docker 群組，可直接進行部署。"
fi
