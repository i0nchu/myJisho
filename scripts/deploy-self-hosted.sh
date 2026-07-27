#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法：
  ./scripts/deploy-self-hosted.sh --domain stage-kotoba.example.com [選項]

選項：
  --domain HOSTNAME       staging 專用網域（必填，不含 https:// 或路徑）
  --model MODEL           Ollama 模型，預設 qwen3:8b
  --skip-model-pull       不執行 ollama pull
  --skip-public-health    只檢查主機 loopback，不等待公開 HTTPS
  -h, --help              顯示說明
EOF
}

domain=""
model="qwen3:8b"
skip_model_pull=false
skip_public_health=false

while (($# > 0)); do
  case "$1" in
    --domain)
      [[ $# -ge 2 ]] || {
        echo "--domain 缺少值。" >&2
        exit 2
      }
      domain=$2
      shift 2
      ;;
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
    --skip-public-health)
      skip_public_health=true
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

if [[ -z ${domain} ]]; then
  echo "--domain 為必填。" >&2
  usage >&2
  exit 2
fi
if [[ ${domain} == *"://"* || ${domain} == *"/"* ]] ||
  [[ ! ${domain} =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]; then
  echo "網域格式不正確：${domain}" >&2
  exit 2
fi
if [[ -z ${model} || ${model} =~ [[:space:]] ]]; then
  echo "模型名稱不可為空或包含空白。" >&2
  exit 2
fi

for command_name in docker curl openssl awk; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必要命令：${command_name}" >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
deploy_dir="${repo_root}/deploy"
env_file="${deploy_dir}/.env"
backup_dir="${deploy_dir}/backups"
base_compose="${deploy_dir}/compose.yaml"
stage_compose="${deploy_dir}/compose.stage.yaml"
compose=(
  docker compose
  --env-file "${env_file}"
  -f "${base_compose}"
  -f "${stage_compose}"
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

if [[ ! -f ${env_file} ]]; then
  api_token=$(openssl rand -hex 32)
  cat >"${env_file}" <<EOF
COMPOSE_PROJECT_NAME=kotoba-stage
KOTOBA_API_TOKEN=${api_token}
KOTOBA_LLM_MODEL=${model}
KOTOBA_STAGE_DOMAIN=${domain}
KOTOBA_ALLOWED_HOSTS=127.0.0.1,localhost,${domain}
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
  upsert_env "KOTOBA_LLM_MODEL" "${model}"
  upsert_env "KOTOBA_STAGE_DOMAIN" "${domain}"
  upsert_env "KOTOBA_ALLOWED_HOSTS" "127.0.0.1,localhost,${domain}"
  upsert_env "KOTOBA_BACKUP_DIR" "./backups"
fi

api_token=$(awk -F= '$1 == "KOTOBA_API_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
if [[ ${#api_token} -lt 32 || ${#api_token} -gt 512 || ${api_token} =~ [[:space:]] ]]; then
  echo "deploy/.env 的 KOTOBA_API_TOKEN 必須為 32–512 個無空白字元。" >&2
  exit 1
fi

"${compose[@]}" config --quiet
"${compose[@]}" up -d ollama

if [[ ${skip_model_pull} == false ]]; then
  "${compose[@]}" exec -T ollama ollama pull "${model}"
fi

"${compose[@]}" up -d --build kotoba-api caddy

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
  "${compose[@]}" logs --tail=100 kotoba-api ollama
  echo "Kotoba API 未能在 120 秒內通過主機 health check。" >&2
  exit 1
fi
echo "主機 health check 通過：${health_json}"

if [[ ${skip_public_health} == false ]]; then
  public_health=""
  for _ in $(seq 1 90); do
    if public_health=$(curl --fail --silent --show-error \
      --max-time 5 \
      -H "Authorization: Bearer ${api_token}" \
      "https://${domain}/api/health" 2>/dev/null); then
      break
    fi
    sleep 2
  done
  if [[ -z ${public_health} ]]; then
    "${compose[@]}" logs --tail=100 caddy
    echo "公開 HTTPS 未能在 180 秒內通過檢查。" >&2
    echo "請確認 DNS A/AAAA、NAT／雲端防火牆及 TCP 80/443 均指向此主機。" >&2
    exit 1
  fi
  echo "公開 HTTPS health check 通過：${public_health}"
fi

echo
echo "Kotoba staging 部署完成。"
echo "API：https://${domain}"
echo "機密 token：${env_file}（權限 600；不會在此輸出）"
echo "狀態：cd ${deploy_dir} && docker compose --env-file .env -f compose.yaml -f compose.stage.yaml ps"
echo "實機 App 需使用："
echo "  --dart-define=KOTOBA_LOCAL_API=https://${domain}"
echo "  --dart-define=KOTOBA_LOCAL_API_TOKEN=<deploy/.env 內的 KOTOBA_API_TOKEN>"
