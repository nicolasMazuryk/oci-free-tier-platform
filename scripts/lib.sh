# Shared helpers for scripts/*.sh (source me).
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export OCI_CLI_PROFILE="${OCI_CLI_PROFILE:-DEFAULT}"
OCI_CONFIG="${OCI_CONFIG:-$HOME/.oci/config}"

oci_cfg() { # oci_cfg <key>
  awk -F= -v p="[$OCI_CLI_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&$1~"^"k"$"{gsub(/ /,"",$2);print $2}' k="$1" "$OCI_CONFIG"
}
export TF_VAR_tenancy_ocid="${TF_VAR_tenancy_ocid:-$(oci_cfg tenancy)}"
export TF_VAR_user_ocid="${TF_VAR_user_ocid:-$(oci_cfg user)}"
export TF_VAR_oci_profile="${TF_VAR_oci_profile:-$OCI_CLI_PROFILE}"

tf() { terraform -chdir="$REPO_ROOT/terraform/$1" "${@:2}"; }
tfout() { tf "$1" output -raw "$2"; }   # tfout <layer> <name>
log() { printf '\033[1;34m==>\033[0m %s\n' "$*" >&2; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
