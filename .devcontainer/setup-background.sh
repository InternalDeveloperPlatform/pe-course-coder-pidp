#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# setup-background.sh - All the heavy lifting, backgrounded by postCreateCommand.sh
#
# Phases: binary installs -> cluster setup -> terraform -> gitea config
# Status written to /tmp/pidp-setup/status (sourceable file)
# ============================================================================

SETUP_DIR="/tmp/pidp-setup"
STATUS_FILE="$SETUP_DIR/status"

# All relative paths (setup/terraform, setup/kind, setup/gitea) assume repo root
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# --- Status helpers ---
update_status() {
  local phase="$1"
  local step="$2"
  cat > "$STATUS_FILE" << EOF
PHASE=$phase
STARTED_AT=${STARTED_AT:-$(date +%s)}
CURRENT_STEP=$step
ERROR=
EOF
}

fail_status() {
  local phase="$1"
  local error="$2"
  cat > "$STATUS_FILE" << EOF
PHASE=failed
STARTED_AT=${STARTED_AT:-$(date +%s)}
CURRENT_STEP=
ERROR=$error
EOF
  echo "FATAL: $error" >&2
  exit 1
}

# Trap unexpected exits
trap 'fail_status "${CURRENT_PHASE:-unknown}" "Unexpected exit at line $LINENO"' ERR

STARTED_AT=$(date +%s)
export STARTED_AT

# --- Idempotency: skip if already complete ---
if [ -f "$STATUS_FILE" ] && grep -q "PHASE=complete" "$STATUS_FILE" 2>/dev/null; then
  echo "Setup already complete, nothing to do."
  exit 0
fi

run_as_root() {
  if [ "$(id -u)" -ne 0 ]; then
    sudo "$@"
  else
    "$@"
  fi
}

ARCH=$(uname -m)
ARCH_GO=""
if [[ "$ARCH" == "x86_64" ]]; then
  ARCH_GO="amd64"
elif [[ "$ARCH" == "aarch64" ]]; then
  ARCH_GO="arm64"
else
  fail_status "installing-binaries" "Unsupported architecture: $ARCH"
fi

export BASE_DIR=/home/vscode
mkdir -p "$BASE_DIR/state/kube"

# ============================================================================
# Phase 1: Binary installs (parallel where possible)
# ============================================================================
CURRENT_PHASE="installing-binaries"
update_status "installing-binaries" "Starting binary installs..."

install_mkcert() {
  if command -v mkcert &>/dev/null; then
    echo "mkcert already installed."
    return
  fi
  echo "Installing mkcert..."
  curl -JLO "https://dl.filippo.io/mkcert/latest?for=linux/amd64"
  chmod +x mkcert-v*-linux-amd64
  run_as_root mv mkcert-v*-linux-amd64 /usr/local/bin/mkcert
}

install_terraform() {
  if command -v terraform &>/dev/null; then
    echo "Terraform already installed."
    return
  fi
  echo "Installing terraform..."
  local version="1.5.7"
  wget -q "https://releases.hashicorp.com/terraform/${version}/terraform_${version}_linux_${ARCH_GO}.zip"
  unzip -o "terraform_${version}_linux_${ARCH_GO}.zip"
  run_as_root mv terraform /usr/local/bin/
  rm -f "terraform_${version}_linux_${ARCH_GO}.zip"
}

install_yq() {
  if command -v yq &>/dev/null; then
    echo "yq already installed."
    return
  fi
  echo "Installing yq..."
  local version="v4.35.1"
  wget -q "https://github.com/mikefarah/yq/releases/download/${version}/yq_linux_${ARCH_GO}"
  run_as_root mv "yq_linux_${ARCH_GO}" /usr/local/bin/yq
  run_as_root chmod +x /usr/local/bin/yq
}

install_score_k8s() {
  if command -v score-k8s &>/dev/null; then
    echo "score-k8s already installed."
    return
  fi
  echo "Installing score-k8s..."
  curl -sLO "https://github.com/score-spec/score-k8s/releases/download/0.1.18/score-k8s_0.1.18_linux_${ARCH_GO}.tar.gz"
  tar xzf score-k8s*.tar.gz
  rm -f score-k8s*.tar.gz README.md LICENSE
  run_as_root mv ./score-k8s /usr/local/bin/score-k8s
  run_as_root chown root: /usr/local/bin/score-k8s
}

install_humctl() {
  if command -v humctl &>/dev/null; then
    echo "humctl already installed."
    return
  fi
  echo "Installing humctl..."
  curl -sLO "https://github.com/humanitec/cli/releases/download/v0.36.2/cli_0.36.2_linux_${ARCH_GO}.tar.gz"
  tar xzf "cli_0.36.2_linux_${ARCH_GO}.tar.gz"
  rm -f "cli_0.36.2_linux_${ARCH_GO}.tar.gz" README.md LICENSE
  run_as_root mv ./humctl /usr/local/bin/humctl
  run_as_root chown root: /usr/local/bin/humctl
}

install_kubectl() {
  if command -v kubectl &>/dev/null; then
    echo "kubectl already installed."
    return
  fi
  echo "Installing kubectl..."
  local stable
  stable=$(curl -sL https://dl.k8s.io/release/stable.txt)
  curl -sLO "https://dl.k8s.io/release/${stable}/bin/linux/${ARCH_GO}/kubectl"
  chmod +x ./kubectl
  run_as_root mv ./kubectl /usr/local/bin/kubectl
}

install_kind() {
  if command -v kind &>/dev/null; then
    echo "kind already installed."
    return
  fi
  echo "Installing kind..."
  curl -sLo ./kind "https://kind.sigs.k8s.io/dl/v0.26.0/kind-linux-${ARCH_GO}"
  chmod +x ./kind
  run_as_root mv ./kind /usr/local/bin/kind
}

# Fire off binary installs in parallel (no apt conflicts here, all direct downloads)
update_status "installing-binaries" "Downloading binaries in parallel..."
install_mkcert &
install_terraform &
install_yq &
install_score_k8s &
install_humctl &
install_kubectl &
install_kind &
wait

# mkcert cert generation (needs mkcert binary from above)
update_status "installing-binaries" "Generating certificates with mkcert..."
export CAROOT="/workspaces"
mkcert -install

# glow uses apt, so run it serial to avoid dpkg lock contention with foreground
update_status "installing-binaries" "Installing glow (apt)..."
if ! command -v glow &>/dev/null; then
  run_as_root mkdir -p /etc/apt/keyrings
  curl -fsSL https://repo.charm.sh/apt/gpg.key | run_as_root gpg --dearmor -o /etc/apt/keyrings/charm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" | run_as_root tee /etc/apt/sources.list.d/charm.list
  run_as_root apt-get update -y
  run_as_root apt-get install -y glow
fi

echo "Phase 1 complete: all binaries installed."

# ============================================================================
# Phase 2: Cluster setup (depends on docker + kind binary)
# ============================================================================
CURRENT_PHASE="cluster-setup"
update_status "cluster-setup" "Checking Docker daemon..."

# Ensure dockerd is running
if ! pgrep -x "dockerd" >/dev/null; then
  echo "Starting dockerd..."
  run_as_root dockerd > /dev/null 2>&1 &
  # Wait for docker to become responsive
  for i in $(seq 1 30); do
    if docker info &>/dev/null; then
      break
    fi
    sleep 1
  done
  if ! docker info &>/dev/null; then
    fail_status "cluster-setup" "Docker daemon failed to start within 30s"
  fi
fi

update_status "cluster-setup" "Creating Docker network..."
if ! docker network ls | grep -q 'kind'; then
  docker network create -d=bridge \
    -o com.docker.network.bridge.enable_ip_masquerade=true \
    -o com.docker.network.driver.mtu=1500 \
    --subnet fc00:f853:ccd:e793::/64 kind
else
  echo "Network 'kind' already exists."
fi

update_status "cluster-setup" "Starting registry container..."
reg_name='kind-registry'
reg_port='5001'
if [ "$(docker inspect -f '{{.State.Running}}' "${reg_name}" 2>/dev/null || true)" != 'true' ]; then
  docker run -d --restart=always -p "127.0.0.1:${reg_port}:5000" --network bridge --name "${reg_name}" registry:2
fi

update_status "cluster-setup" "Creating Kind cluster..."
# Check both the kubeconfig AND whether the cluster already exists in docker.
# The persistent disk can keep the cluster alive across workspace restarts even
# if the kubeconfig file gets cleaned up.
if kind get clusters 2>/dev/null | grep -q '^5min-idp$'; then
  echo "Kind cluster '5min-idp' already exists, regenerating kubeconfig..."
  kind export kubeconfig -n 5min-idp --kubeconfig "$BASE_DIR/state/kube/config.yaml"
elif [ ! -f "$BASE_DIR/state/kube/config.yaml" ]; then
  kind create cluster -n 5min-idp --kubeconfig "$BASE_DIR/state/kube/config.yaml" --config ./setup/kind/cluster.yaml
fi

update_status "cluster-setup" "Updating /etc/hosts..."
if ! grep -q "5min-idp-control-plane" /etc/hosts; then
  echo "127.0.0.1 5min-idp-control-plane" | run_as_root tee -a /etc/hosts
fi

# Connect current container to the kind network if it exists.
# In envbuilder/Coder setups the container runs with --net=host, so this is
# best-effort: host networking already reaches kind ports via localhost.
update_status "cluster-setup" "Connecting container to kind network (best-effort)..."
container_name="5min-idp"
if docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${container_name}" &>/dev/null; then
  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${container_name}")" = 'null' ]; then
    docker network connect "kind" "${container_name}"
  fi
else
  echo "Container '${container_name}' not found, skipping network connect (likely --net=host)."
fi

update_status "cluster-setup" "Exporting kubeconfigs..."
kubeconfig_docker="$BASE_DIR/state/kube/config-internal.yaml"
kind export kubeconfig --internal -n 5min-idp --kubeconfig "$kubeconfig_docker"
kind export kubeconfig --internal -n 5min-idp

update_status "cluster-setup" "Configuring containerd registry..."
REGISTRY_DIR="/etc/containerd/certs.d/localhost:${reg_port}"
for node in $(kind get nodes -n 5min-idp); do
  docker exec "${node}" mkdir -p "${REGISTRY_DIR}"
  cat <<EOF | docker exec -i "${node}" cp /dev/stdin "${REGISTRY_DIR}/hosts.toml"
[host."http://${reg_name}:5000"]
EOF
done

if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${reg_name}")" = 'null' ]; then
  docker network connect "kind" "${reg_name}"
fi

update_status "cluster-setup" "Applying registry ConfigMap..."
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
  host: "localhost:${reg_port}"
  help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF

echo "Phase 2 complete: cluster is up."

# ============================================================================
# Phase 3: Terraform (depends on cluster + terraform binary)
# ============================================================================
CURRENT_PHASE="terraform"
update_status "terraform" "Running terraform init..."

export TF_VAR_humanitec_org="${HUMANITEC_ORG:-}"
export TF_VAR_humanitec_token="${HUMANITEC_SERVICE_USER:-}"
export TF_VAR_tls_cert_string="${PIDP_CERT:-}"
export TF_VAR_tls_key_string="${PIDP_KEY:-}"
export TF_VAR_kubeconfig="$kubeconfig_docker"

terraform -chdir=setup/terraform init

update_status "terraform" "Running terraform apply..."
# Helm releases can timeout on first attempt while pulling images. Retry once
# since cached images make the second attempt much faster.
if ! terraform -chdir=setup/terraform apply -auto-approve; then
  echo "Terraform apply failed, retrying (images should be cached now)..."
  update_status "terraform" "Retrying terraform apply..."
  terraform -chdir=setup/terraform apply -auto-approve
fi

echo "Phase 3 complete: terraform applied."

# ============================================================================
# Phase 4: Gitea configuration (depends on terraform output)
# ============================================================================
CURRENT_PHASE="gitea-config"
update_status "gitea-config" "Setting up Gitea runner..."

GITEA_API="https://5min-idp-control-plane"
GITEA_AUTH="Basic NW1pbmFkbWluOjVtaW5hZG1pbg=="

# Runner setup (with timeout, not infinite)
if [ "$(docker inspect -f '{{.State.Running}}' gitea_runner 2>/dev/null || true)" != 'true' ]; then
  update_status "gitea-config" "Polling for Gitea runner registration token..."
  RUNNER_TOKEN=""
  TIMEOUT=120
  ELAPSED=0
  while [[ -z "$RUNNER_TOKEN" ]]; do
    if (( ELAPSED >= TIMEOUT )); then
      fail_status "gitea-config" "Timed out after ${TIMEOUT}s waiting for Gitea runner registration token"
    fi
    response=$(curl -k -s -X 'GET' \
      "${GITEA_API}/api/v1/admin/runners/registration-token" \
      -H 'accept: application/json' \
      -H "authorization: ${GITEA_AUTH}") || true
    if [[ "$response" == *"token"* ]]; then
      RUNNER_TOKEN=$(echo "$response" | jq -r '.token')
    fi
    sleep 1
    (( ELAPSED++ )) || true
  done

  update_status "gitea-config" "Starting Gitea runner container..."
  docker volume create gitea_runner_data
  docker create \
    --name gitea_runner \
    -v gitea_runner_data:/data \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v /etc/ssl/certs:/etc/ssl/certs:ro \
    -v /etc/ca-certificates:/etc/ca-certificates:ro \
    -e CONFIG_FILE=/config.yaml \
    -e GITEA_INSTANCE_URL="${GITEA_API}" \
    -e GITEA_RUNNER_REGISTRATION_TOKEN="$RUNNER_TOKEN" \
    -e GITEA_RUNNER_NAME=local \
    -e GITEA_RUNNER_LABELS=local \
    --network kind \
    gitea/act_runner:latest
  docker cp setup/gitea/config.yaml gitea_runner:/config.yaml
  docker start gitea_runner
else
  echo "gitea_runner already running."
fi

update_status "gitea-config" "Creating Gitea org and migrating Backstage repo..."

curl -k -s -X 'POST' \
  "${GITEA_API}/api/v1/orgs" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d '{
  "repo_admin_change_team_access": true,
  "username": "5minorg",
  "visibility": "public"
}'

curl -k -s -X 'POST' \
  "${GITEA_API}/api/v1/repos/migrate" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d '{
  "clone_addr": "https://github.com/humanitec-architecture/backstage.git",
  "mirror": false,
  "private": false,
  "repo_name": "backstage",
  "repo_owner": "5minorg"
}'

update_status "gitea-config" "Setting Gitea org variables and secrets..."

curl -k -s -X 'POST' \
  "${GITEA_API}/api/v1/orgs/5minorg/actions/variables/CLOUD_PROVIDER" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d '{"value": "5min"}'

curl -k -s -X 'POST' \
  "${GITEA_API}/api/v1/orgs/5minorg/actions/variables/HUMANITEC_ORG_ID" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d "{\"value\": \"${HUMANITEC_ORG:-}\"}"

humanitec_app_backstage=$(terraform -chdir=setup/terraform output -raw humanitec_app_backstage)

curl -k -s -X 'POST' \
  "${GITEA_API}/api/v1/orgs/5minorg/actions/variables/HUMANITEC_APP_ID" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d "{\"value\": \"${humanitec_app_backstage}\"}"

curl -k -s -X 'PUT' \
  "${GITEA_API}/api/v1/orgs/5minorg/actions/secrets/HUMANITEC_TOKEN" \
  -H 'accept: application/json' \
  -H "authorization: ${GITEA_AUTH}" \
  -H 'Content-Type: application/json' \
  -d "{\"data\": \"${TF_VAR_humanitec_token}\"}"

update_status "gitea-config" "Triggering Backstage install commit..."

curl -k -s -X POST \
  "${GITEA_API}/api/v1/repos/5minorg/backstage/contents/yolo.txt" \
  -H "Authorization: ${GITEA_AUTH}" \
  -H "Content-Type: application/json" \
  -d '{
    "branch": "main",
    "message": "Automated commit - make Backstage install",
    "committer": {
      "name": "5minadmin",
      "email": "clemens@humanitec.com"
    },
    "author": {
      "name": "5minadmin",
      "email": "clemens@humanitec.com"
    },
    "files": [
      {
        "content": "eW9sbwo=",
        "filename": "yolo.txt",
        "mode": "100644",
        "sha": "49ef4c1f9273718b2421b2c076f09786ede5982c"
      }
    ]
  }'

echo "Phase 4 complete: Gitea configured."

# ============================================================================
# Done
# ============================================================================
update_status "complete" "All done."
echo ""
echo ">>>> PocketIDP is prepared, ready to roll."
