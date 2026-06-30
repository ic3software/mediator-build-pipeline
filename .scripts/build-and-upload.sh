#!/usr/bin/env bash
#
#
# Required env vars (export them, or put them in <repo>/.env):
#   R2_ACCESS_KEY_ID
#   R2_SECRET_ACCESS_KEY
#   R2_ACCOUNT_ID
#   R2_BUCKET
#
# Usage:
#   .scripts/build-and-upload.sh            # build + upload
#   .scripts/build-and-upload.sh --build-only
#   .scripts/build-and-upload.sh --dry-run  # build + print aws cmds, don't upload

set -euo pipefail

BUILD_ONLY=0
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --dry-run)    DRY_RUN=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      echo "unknown arg: $arg" >&2
      exit 2
      ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

for tool in cargo git jq; do
  command -v "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done
if [[ $BUILD_ONLY -eq 0 ]]; then
  command -v aws >/dev/null || { echo "missing tool: aws (install aws-cli)" >&2; exit 1; }
fi

metadata="$(cargo metadata --no-deps --format-version 1)"
mediator_version="$(printf '%s' "$metadata" | jq -r '.packages[] | select(.name=="affinidi-messaging-mediator") | .version')"
if [[ -z "$mediator_version" || "$mediator_version" == "null" ]]; then
  echo "Failed to resolve affinidi-messaging-mediator version" >&2
  exit 1
fi
git_hash="$(git rev-parse --short HEAD)"
version_tag="${mediator_version}-${git_hash}"

echo "==> building mediator ${version_tag} (release, didcomm + redis-backend + fjall-backend)"
cargo build --release -p affinidi-messaging-mediator --no-default-features --features "didcomm,redis-backend,fjall-backend"
cp target/release/mediator target/release/mediator-standard

echo "==> building mediator-k8s ${version_tag} (release, didcomm + redis-backend + fjall-backend + secrets-vault)"
cargo build --release -p affinidi-messaging-mediator --no-default-features --features "didcomm,redis-backend,fjall-backend,secrets-vault"
cp target/release/mediator target/release/mediator-k8s

echo "==> building mediator-setup ${version_tag} (release)"
cargo build --release -p affinidi-messaging-mediator-setup

mediator_bin="target/release/mediator-standard"
k8s_bin="target/release/mediator-k8s"
setup_bin="target/release/mediator-setup"
for b in "$mediator_bin" "$k8s_bin" "$setup_bin"; do
  [[ -f "$b" ]] || { echo "build succeeded but $b missing" >&2; exit 1; }
done

if [[ $BUILD_ONLY -eq 1 ]]; then
  echo "==> --build-only set; skipping upload. binaries: $mediator_bin, $k8s_bin, $setup_bin"
  exit 0
fi

for var in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; do
  if [[ -z "${!var:-}" ]]; then
    echo "missing env var: $var (set in shell or in <repo>/.env)" >&2
    exit 1
  fi
done

export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export AWS_DEFAULT_REGION="us-east-1"
ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

upload() {
  local src="$1"
  local dest="$2"
  echo "==> uploading $src -> $dest"
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "    [dry-run] aws s3 cp $src $dest --endpoint-url $ENDPOINT"
  else
    aws s3 cp "$src" "$dest" --endpoint-url "$ENDPOINT"
  fi
}

upload "$mediator_bin" "s3://${R2_BUCKET}/mediator/latest/mediator"
upload "$mediator_bin" "s3://${R2_BUCKET}/mediator/${version_tag}/mediator"
upload "$k8s_bin"      "s3://${R2_BUCKET}/mediator-k8s/latest/mediator"
upload "$k8s_bin"      "s3://${R2_BUCKET}/mediator-k8s/${version_tag}/mediator"
upload "$setup_bin"    "s3://${R2_BUCKET}/mediator/latest/mediator-setup"
upload "$setup_bin"    "s3://${R2_BUCKET}/mediator/${version_tag}/mediator-setup"

echo "==> done."
