#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法：
  ./scripts/deploy-self-hosted.sh [選項]

此腳本沿用 Linux 主機上的 Ollama（可由 Docker Compose 執行），myJisho API
預設只監聽 loopback。Ollama 必須將 API 發布到主機的 loopback。

選項：
  --model MODEL        必填的 Ollama 模型；也可由環境或 deploy/.env 提供
  --ollama-url URL     主機可存取的 Ollama URL，預設 http://127.0.0.1:11434
  --skip-model-pull    模型不存在時不透過 Ollama API 自動下載
  --tailscale          讓 API 只監聽主機的 Tailscale IPv4
  -h, --help           顯示說明
EOF
}

model="${MYJISHO_LLM_MODEL:-}"
ollama_url="http://127.0.0.1:11434"
skip_model_pull=false
enable_tailscale=false

while (($# > 0)); do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || {
        echo "--model 缺少值。" >&2
        exit 2
      }
      model=$2
      shift 2
      ;;
    --ollama-url)
      [[ $# -ge 2 ]] || {
        echo "--ollama-url 缺少值。" >&2
        exit 2
      }
      ollama_url=$2
      shift 2
      ;;
    --skip-model-pull)
      skip_model_pull=true
      shift
      ;;
    --tailscale)
      enable_tailscale=true
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "未知參數：$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
deploy_dir="${repo_root}/deploy"
env_file="${deploy_dir}/.env"
backup_dir="${deploy_dir}/backups"
internal_compose="${deploy_dir}/compose.internal.yaml"

if [[ -z ${model} && -f ${env_file} ]]; then
  while IFS='=' read -r key value; do
    if [[ ${key} == "MYJISHO_LLM_MODEL" ]]; then
      model=${value}
      break
    fi
  done <"${env_file}"
fi
if [[ -z ${model} || ${model} =~ [[:space:]] ]]; then
  echo "缺少有效的 MYJISHO_LLM_MODEL；請使用 --model、程序環境或 deploy/.env 明確設定模型。" >&2
  exit 2
fi

for command_name in docker curl openssl awk python3; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必要命令：${command_name}" >&2
    exit 1
  fi
done

if ! ollama_url=$(
  python3 - "${ollama_url}" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

raw = sys.argv[1].rstrip("/")
parsed = urlsplit(raw)
if (
    parsed.scheme not in {"http", "https"}
    or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
    or parsed.username is not None
    or parsed.password is not None
    or parsed.path not in {"", "/"}
    or parsed.query
    or parsed.fragment
):
    raise SystemExit(1)
print(urlunsplit((parsed.scheme, parsed.netloc, "", "", "")))
PY
); then
  echo "--ollama-url 必須是主機 loopback HTTP(S) URL，例如 http://127.0.0.1:11434。" >&2
  exit 2
fi

docker compose version >/dev/null
docker info >/dev/null

if ! curl --fail --silent --show-error --max-time 5 \
  "${ollama_url}/api/version" >/dev/null; then
  echo "無法連線到 Ollama：${ollama_url}" >&2
  echo "若 Ollama 由 Docker Compose 執行，請確認它已啟動，且 ports 包含：" >&2
  echo '  - "127.0.0.1:11434:11434"' >&2
  exit 1
fi

model_exists=$(
  curl --fail --silent --show-error --max-time 10 \
    "${ollama_url}/api/tags" |
    python3 -c '
import json
import sys

target = sys.argv[1]
names = {
    item.get("name") or item.get("model")
    for item in json.load(sys.stdin).get("models", [])
}
print("yes" if target in names else "no")
' "${model}"
)
if [[ ${model_exists} != "yes" ]]; then
  if [[ ${skip_model_pull} == true ]]; then
    echo "Ollama 尚未安裝模型 ${model}，且指定了 --skip-model-pull。" >&2
    exit 1
  fi
  echo "透過 Ollama API 下載模型：${model}"
  pull_payload=$(
    python3 -c 'import json,sys; print(json.dumps({"model": sys.argv[1], "stream": False}))' \
      "${model}"
  )
  curl --fail --silent --show-error \
    --request POST \
    --header "Content-Type: application/json" \
    --data "${pull_payload}" \
    "${ollama_url}/api/pull" >/dev/null
fi

tailscale_ip=""
tailscale_hostname=""
if [[ ${enable_tailscale} == true ]]; then
  if ! command -v tailscale >/dev/null 2>&1; then
    echo "指定了 --tailscale，但主機尚未安裝 Tailscale。" >&2
    exit 1
  fi
  if ! tailscale status >/dev/null 2>&1; then
    echo "Tailscale 尚未登入或未連線；請先執行 sudo tailscale up。" >&2
    exit 1
  fi
  tailscale_ip=$(tailscale ip -4 | awk 'NF { print; exit }')
  if ! python3 -c '
import ipaddress
import sys

address = ipaddress.ip_address(sys.argv[1])
if address.version != 4 or address not in ipaddress.ip_network("100.64.0.0/10"):
    raise SystemExit(1)
' "${tailscale_ip}"; then
    echo "無法取得有效的 Tailscale IPv4 位址。" >&2
    exit 1
  fi
  tailscale_hostname=$(
    tailscale status --json |
      python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self", {}).get("DNSName") or "").rstrip("."))'
  )
fi

compose=(
  docker compose
  --env-file "${env_file}"
  -f "${internal_compose}"
)

umask 077
mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"

upsert_env() {
  local key=$1
  local value=$2
  local temporary_file
  temporary_file=$(mktemp "${deploy_dir}/.env.XXXXXX")
  awk -v key="${key}" -v value="${value}" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 {
      if (!found) {
        print key "=" value
        found = 1
      }
      next
    }
    { print }
    END {
      if (!found) print key "=" value
    }
  ' "${env_file}" >"${temporary_file}"
  chmod 600 "${temporary_file}"
  mv -f -- "${temporary_file}" "${env_file}"
}

api_bind_host="127.0.0.1"
allowed_hosts="127.0.0.1,localhost"
if [[ -n ${tailscale_ip} ]]; then
  api_bind_host="${tailscale_ip}"
  allowed_hosts="${allowed_hosts},${tailscale_ip}"
fi
if [[ -n ${tailscale_hostname} ]]; then
  allowed_hosts="${allowed_hosts},${tailscale_hostname}"
fi

if [[ ! -f ${env_file} ]]; then
  api_token=$(openssl rand -hex 32)
  cat >"${env_file}" <<EOF
COMPOSE_PROJECT_NAME=myjisho-stage
MYJISHO_DEPLOYMENT_MODE=internal
MYJISHO_API_TOKEN=${api_token}
MYJISHO_API_HOST=${api_bind_host}
MYJISHO_TAILSCALE_IP=${tailscale_ip}
MYJISHO_LLM_MODEL=${model}
MYJISHO_LLM_BASE_URL=${ollama_url}/v1
MYJISHO_STAGE_DOMAIN=
MYJISHO_ALLOWED_HOSTS=${allowed_hosts}
MYJISHO_BACKUP_DIR=./backups
EOF
  chmod 600 "${env_file}"
  echo "已建立 deploy/.env 與隨機 API token。"
else
  chmod 600 "${env_file}"
  if ! grep -q '^MYJISHO_API_TOKEN=' "${env_file}"; then
    upsert_env "MYJISHO_API_TOKEN" "$(openssl rand -hex 32)"
  fi
  upsert_env "COMPOSE_PROJECT_NAME" "myjisho-stage"
  upsert_env "MYJISHO_DEPLOYMENT_MODE" "internal"
  upsert_env "MYJISHO_API_HOST" "${api_bind_host}"
  upsert_env "MYJISHO_TAILSCALE_IP" "${tailscale_ip}"
  upsert_env "MYJISHO_LLM_MODEL" "${model}"
  upsert_env "MYJISHO_LLM_BASE_URL" "${ollama_url}/v1"
  upsert_env "MYJISHO_STAGE_DOMAIN" ""
  upsert_env "MYJISHO_ALLOWED_HOSTS" "${allowed_hosts}"
  upsert_env "MYJISHO_BACKUP_DIR" "./backups"
fi

api_token=$(awk -F= '$1 == "MYJISHO_API_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
if [[ ${#api_token} -lt 32 || ${#api_token} -gt 512 || ${api_token} =~ [[:space:]] ]]; then
  echo "deploy/.env 的 MYJISHO_API_TOKEN 必須為 32–512 個無空白字元。" >&2
  exit 1
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d --build myjisho-api

health_url="http://${api_bind_host}:8766/api/health"
health_json=""
for _ in $(seq 1 60); do
  if health_json=$(curl --fail --silent --show-error \
    --max-time 3 \
    -H "Authorization: Bearer ${api_token}" \
    "${health_url}" 2>/dev/null); then
    break
  fi
  sleep 2
done
if [[ -z ${health_json} ]]; then
  "${compose[@]}" ps
  "${compose[@]}" logs --tail=100 myjisho-api
  echo "myJisho API 未能在 120 秒內通過 health check：${health_url}" >&2
  exit 1
fi
echo "API health check 通過：${health_json}"

echo
echo "myJisho 內網 staging 部署完成。"
echo "API listener：http://${api_bind_host}:8766"
echo "既有 Ollama：${ollama_url}（myJisho 未建立或重啟 Ollama container）"
echo "機密 token：${env_file}（權限 600；不會在此輸出）"
if [[ -n ${tailscale_ip} ]]; then
  echo "Tailnet API：http://${tailscale_ip}:8766"
  echo "實機 App 需使用："
  echo "  --dart-define=MYJISHO_LOCAL_API=http://${tailscale_ip}:8766"
  echo "  --dart-define=MYJISHO_LOCAL_API_TOKEN=<deploy/.env 內的 MYJISHO_API_TOKEN>"
else
  echo "目前沒有任何 LAN／公網 listener；只可在 server 本機測試。"
  echo "Cloudflare Tunnel 可將外部 hostname 代理到 http://127.0.0.1:8766。"
fi
