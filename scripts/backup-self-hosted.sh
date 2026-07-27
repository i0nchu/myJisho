#!/usr/bin/env bash
set -Eeuo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd -- "${script_dir}/.." && pwd)
deploy_dir="${repo_root}/deploy"
env_file="${deploy_dir}/.env"
internal_compose="${deploy_dir}/compose.internal.yaml"

if [[ ! -f ${env_file} ]]; then
  echo "找不到 deploy/.env；請先完成 staging 部署。" >&2
  exit 1
fi
for command_name in docker sha256sum; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "缺少必要命令：${command_name}" >&2
    exit 1
  fi
done
docker compose version >/dev/null
docker info >/dev/null

deployment_mode=$(awk -F= '$1 == "KOTOBA_DEPLOYMENT_MODE" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
if [[ ${deployment_mode:-internal} != "internal" ]]; then
  echo "此備份工具只支援目前的 internal deployment mode。" >&2
  exit 1
fi

backup_setting=$(awk -F= '$1 == "KOTOBA_BACKUP_DIR" { sub(/^[^=]*=/, ""); print; exit }' "${env_file}")
backup_setting=${backup_setting:-./backups}
if [[ ${backup_setting} == /* ]]; then
  backup_dir=${backup_setting}
else
  backup_dir="${deploy_dir}/${backup_setting#./}"
fi

umask 077
mkdir -p "${backup_dir}"
chmod 700 "${backup_dir}"
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
archive_name="kotoba-stage-${timestamp}.tar.gz"
archive_path="${backup_dir}/${archive_name}"
if [[ -e ${archive_path} || -e ${archive_path}.sha256 ]]; then
  echo "同名備份已存在，請稍後一秒再執行：${archive_path}" >&2
  exit 1
fi
compose=(
  docker compose
  --env-file "${env_file}"
  -f "${internal_compose}"
)

api_was_running=$(
  "${compose[@]}" ps --status running --services |
    grep -cx 'kotoba-api' || true
)
restart_api() {
  if [[ ${api_was_running} -gt 0 ]]; then
    "${compose[@]}" up -d kotoba-api >/dev/null
  fi
}
trap restart_api EXIT

if [[ ${api_was_running} -gt 0 ]]; then
  echo "暫停 API，以建立一致的 SQLite 備份。"
  "${compose[@]}" stop -t 30 kotoba-api
fi

"${compose[@]}" run --rm --no-deps backup-helper \
  tar -C /data -czf "/backup/${archive_name}" .
(
  cd -- "${backup_dir}"
  sha256sum "${archive_name}" >"${archive_name}.sha256"
)

trap - EXIT
restart_api

echo "備份完成：${archive_path}"
echo "Checksum：${archive_path}.sha256"
