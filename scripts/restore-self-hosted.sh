#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'EOF'
用法：
  ./scripts/restore-self-hosted.sh BACKUP_FILE [--yes]

BACKUP_FILE 必須位於 deploy/.env 的 KOTOBA_BACKUP_DIR 內。
還原前會先自動備份目前資料；未加 --yes 時需輸入 RESTORE 確認。
EOF
}

if (($# < 1 || $# > 2)); then
  usage >&2
  exit 2
fi
archive_input=$1
assume_yes=false
if (($# == 2)); then
  if [[ $2 != "--yes" ]]; then
    usage >&2
    exit 2
  fi
  assume_yes=true
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
deploy_dir="${repo_root}/deploy"
env_file="${deploy_dir}/.env"
internal_compose="${deploy_dir}/compose.internal.yaml"

if [[ ! -f ${env_file} ]]; then
  echo "找不到 deploy/.env；請先完成 staging 部署。" >&2
  exit 1
fi
for command_name in docker realpath sha256sum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必要命令：${command_name}" >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

deployment_mode=$(awk -F= '$1 == "KOTOBA_DEPLOYMENT_MODE" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
if [[ ${deployment_mode:-internal} != "internal" ]]; then
  echo "此還原工具只支援目前的 internal deployment mode。" >&2
  exit 1
fi

backup_setting=$(awk -F= '$1 == "KOTOBA_BACKUP_DIR" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
backup_setting=${backup_setting:-./backups}
if [[ ${backup_setting} == /* ]]; then
  backup_dir=${backup_setting}
else
  backup_dir="${deploy_dir}/${backup_setting#./}"
fi
backup_dir=$(realpath -- "${backup_dir}")

if [[ ${archive_input} == /* ]]; then
  archive_candidate=${archive_input}
else
  archive_candidate="${backup_dir}/${archive_input}"
fi
if [[ ! -f ${archive_candidate} ]]; then
  echo "找不到備份檔：${archive_candidate}" >&2
  exit 1
fi
archive_path=$(realpath -- "${archive_candidate}")
case "${archive_path}" in
  "${backup_dir}"/*) ;;
  *)
    echo "拒絕還原：備份檔不在 ${backup_dir} 內。" >&2
    exit 1
    ;;
esac
archive_name=$(basename -- "${archive_path}")
if [[ ! ${archive_name} =~ ^kotoba-stage-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]; then
  echo "備份檔名格式不正確：${archive_name}" >&2
  exit 1
fi
if [[ -f ${archive_path}.sha256 ]]; then
  (
    cd -- "${backup_dir}"
    sha256sum --check "$(basename -- "${archive_path}.sha256")"
  )
else
  echo "警告：找不到 checksum 檔，無法驗證備份完整性。" >&2
fi

if [[ ${assume_yes} == false ]]; then
  echo "即將以 ${archive_name} 取代目前 staging 詞庫。"
  read -r -p "輸入 RESTORE 繼續：" confirmation
  if [[ ${confirmation} != "RESTORE" ]]; then
    echo "已取消。"
    exit 0
  fi
fi

echo "先備份目前資料。"
"${script_dir}/backup-self-hosted.sh"

compose=(
  docker compose
  --env-file "${env_file}"
  -f "${internal_compose}"
)
"${compose[@]}" stop -t 30 kotoba-api
restart_api() {
  "${compose[@]}" up -d kotoba-api >/dev/null
}
trap restart_api EXIT

# The quoted $1 is intentionally evaluated by the helper container's shell.
# shellcheck disable=SC2016
"${compose[@]}" run --rm --no-deps backup-helper sh -ceu '
  find /data -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  tar -xzf "/backup/$1" -C /data
' sh "${archive_name}"

trap - EXIT
restart_api

api_token=$(awk -F= '$1 == "KOTOBA_API_TOKEN" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
for _ in $(seq 1 60); do
  if curl --fail --silent --show-error \
    --max-time 3 \
    -H "Authorization: Bearer ${api_token}" \
    "http://127.0.0.1:8766/api/health" >/dev/null 2>&1; then
    echo "還原完成且 API health check 通過：${archive_name}"
    exit 0
  fi
  sleep 2
done

"${compose[@]}" logs --tail=100 kotoba-api
echo "資料已解壓縮，但 API 未能在 120 秒內恢復健康。" >&2
exit 1
