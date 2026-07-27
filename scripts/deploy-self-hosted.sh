#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法：
  ./scripts/deploy-self-hosted.sh [選項]

此腳本沿用 Ubuntu 主機已安裝的 Ollama，Kotoba API 只監聽 loopback。

選項：
  --model MODEL       Ollama 模型，預設 qwen3:8b
  --skip-model-pull   模型不存在時不自動執行 ollama pull
  --tailscale         以 Tailscale Serve 提供 tailnet 內的私人 HTTPS
  -h, --help          顯示說明
EOF
}

model="qwen3:8b"
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

if [[ -z ${model} || ${model} =~ [[:space:]] ]]; then
  echo "模型名稱不可為空或包含空白。" >&2
  exit 2
fi

for command_name in docker curl openssl awk ollama python3; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必要命令：${command_name}" >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

if ! curl --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:11434/api/version >/dev/null; then
  echo "無法連線到主機 Ollama：http://127.0.0.1:11434" >&2
  echo "請先確認：systemctl status ollama" >&2
  exit 1
fi

if ! ollama show "${model}" >/dev/null 2>&1; then
  if [[ ${skip_model_pull} == true ]]; then
    echo "主機尚未安裝模型 ${model}，且指定了 --skip-model-pull。" >&2
    exit 1
  fi
  echo "下載主機 Ollama 模型：${model}"
  ollama pull "${model}"
fi

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
  tailscale_hostname=$(
    tailscale status --json |
      python3 -c 'import json,sys; print((json.load(sys.stdin).get("Self", {}).get("DNSName") or "").rstrip("."))'
  )
  if [[ -z ${tailscale_hostname} ]]; then
    echo "無法從 tailscale status 取得 MagicDNS hostname。" >&2
    exit 1
  fi
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
deploy_dir="${repo_root}/deploy"
env_file="${deploy_dir}/.env"
backup_dir="${deploy_dir}/backups"
internal_compose="${deploy_dir}/compose.internal.yaml"
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

allowed_hosts="127.0.0.1,localhost"
if [[ -n ${tailscale_hostname} ]]; then
  allowed_hosts="${allowed_hosts},${tailscale_hostname}"
fi

if [[ ! -f ${env_file} ]]; then
  api_token=$(openssl rand -hex 32)
  cat >"${env_file}" <<EOF
COMPOSE_PROJECT_NAME=kotoba-stage
KOTOBA_DEPLOYMENT_MODE=internal
KOTOBA_API_TOKEN=${api_token}
KOTOBA_LLM_MODEL=${model}
KOTOBA_LLM_BASE_URL=http://127.0.0.1:11434/v1
KOTOBA_STAGE_DOMAIN=${tailscale_hostname}
KOTOBA_ALLOWED_HOSTS=${allowed_hosts}
KOTOBA_BACKUP_DIR=./backups
EOF
  chmod 600 "${env_file}"
  echo "已建立 deploy/.env 與隨機 API token。"
else
  chmod 600 "${env_file}"
  if ! grep -q '^KOTOBA_API_TOKEN=' "${env_file}"; then
    upsert_env "KOTOBA_API_TOKEN" "$(openssl rand -hex 32)"
  fi
  upsert_env "COMPOSE_PROJECT_NAME" "kotoba-stage"
  upsert_env "KOTOBA_DEPLOYMENT_MODE" "internal"
  upsert_env "KOTOBA_LLM_MODEL" "${model}"
  upsert_env "KOTOBA_LLM_BASE_URL" "http://127.0.0.1:11434/v1"
  upsert_env "KOTOBA_STAGE_DOMAIN" "${tailscale_hostname}"
  upsert_env "KOTOBA_ALLOWED_HOSTS" "${allowed_hosts}"
  upsert_env "KOTOBA_BACKUP_DIR" "./backups"
fi

api_token=$(awk -F= '$1 == "KOTOBA_API_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
if [[ ${#api_token} -lt 32 || ${#api_token} -gt 512 || ${api_token} =~ [[:space:]] ]]; then
  echo "deploy/.env 的 KOTOBA_API_TOKEN 必須為 32–512 個無空白字元。" >&2
  exit 1
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d --build kotoba-api

health_json=""
for _ in $(seq 1 60); do
  if health_json=$(curl --fail --silent --show-error \
    --max-time 3 \
    -H "Authorization: Bearer ${api_token}" \
    "http://127.0.0.1:8766/api/health" 2>/dev/null); then
    break
  fi
  sleep 2
done
if [[ -z ${health_json} ]]; then
  "${compose[@]}" ps
  "${compose[@]}" logs --tail=100 kotoba-api
  echo "Kotoba API 未能在 120 秒內通過 loopback health check。" >&2
  exit 1
fi
echo "Loopback health check 通過：${health_json}"

if [[ ${enable_tailscale} == true ]]; then
  if ! sudo tailscale serve --bg --yes http://127.0.0.1:8766; then
    echo "無法啟用 Tailscale Serve。若輸出提供管理網址，請先在 tailnet 啟用 HTTPS／Serve 後重試。" >&2
    exit 1
  fi
  private_health=""
  for _ in $(seq 1 30); do
    if private_health=$(curl --fail --silent --show-error \
      --max-time 5 \
      -H "Authorization: Bearer ${api_token}" \
      "https://${tailscale_hostname}/api/health" 2>/dev/null); then
      break
    fi
    sleep 2
  done
  if [[ -z ${private_health} ]]; then
    sudo tailscale serve status
    echo "Tailscale HTTPS 未能在 60 秒內通過檢查。" >&2
    exit 1
  fi
  echo "Tailscale HTTPS health check 通過：${private_health}"
fi

echo
echo "Kotoba 內網 staging 部署完成。"
echo "本機 API：http://127.0.0.1:8766"
echo "主機 Ollama：http://127.0.0.1:11434（未建立 Ollama container）"
echo "機密 token：${env_file}（權限 600；不會在此輸出）"
if [[ -n ${tailscale_hostname} ]]; then
  echo "Tailnet API：https://${tailscale_hostname}"
  echo "實機 App 需使用："
  echo "  --dart-define=KOTOBA_LOCAL_API=https://${tailscale_hostname}"
  echo "  --dart-define=KOTOBA_LOCAL_API_TOKEN=<deploy/.env 內的 KOTOBA_API_TOKEN>"
else
  echo "目前沒有任何 LAN／公網 listener；只可在 server 本機測試。"
  echo "需要實機或外部連線時重新執行：./scripts/deploy-self-hosted.sh --tailscale"
fi
