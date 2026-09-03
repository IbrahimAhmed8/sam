#!/usr/bin/env bats

load "lib/container_mesh.bash"

setup() {
  mesh_setup_env
}

teardown() {
  mesh_cleanup_env
}

@test "Authentication Flow 1: Client Credentials Flow" {
  run mesh_start_mock_oidc
  [[ "$status" -eq 0 ]]

  run mesh_start_router
  [[ "$status" -eq 0 ]]

  # mesh_start_node uses --token-url by default, which implements Client Credentials flow
  mesh_start_node 1

  run mesh_assert_container_running "${MESH_PREFIX}-node-1"
  [[ "$status" -eq 0 ]]
}

@test "Authentication Flow 2: Device Authorization Flow (Interactive)" {
  run mesh_start_mock_oidc
  [[ "$status" -eq 0 ]]

  run mesh_start_router
  [[ "$status" -eq 0 ]]

  # 1. Get a token from mock provider using Python helper
  local token
  token=$(docker run --rm --network "${MESH_NETWORK}" $(mesh_get_add_hosts) python:3.12 python3 -c "import urllib.request; import json; req = urllib.request.Request('http://mock-oidc:18080/token', data=b''); resp = urllib.request.urlopen(req); print(json.loads(resp.read().decode())['access_token'])")
  
  [[ -n "${token}" ]]

  # 2. Run sam-node join to enroll and store identity. The sam-node image has
  # no browser to open, so the loopback flow can't complete; join falls back
  # to the OAuth 2.0 Device Authorization Grant (RFC 8628), which the mock
  # OIDC provider advertises and auto-approves on the first poll.
  local node_name="${MESH_PREFIX}-node-login"
  local router_peer_id
  router_peer_id=$(cat "/tmp/${MESH_PREFIX}-router-peer-id")

  local data_vol="${MESH_PREFIX}-data"
  docker volume create "${data_vol}"
  CLEANUP_VOLUMES+=("${data_vol}")

  docker run -d --name "${node_name}-join" \
    --network "${MESH_NETWORK}" \
    $(mesh_get_add_hosts) \
    -v "${data_vol}:/data" \
    "sam-node:local" \
    join --data-dir /data "http://sam-control-plane:8080"
  MESH_CONTAINERS+=("${node_name}-join")

  run mesh_wait_for_log "${node_name}-join" "OAuth Device Authorization Flow" 20
  [[ "$status" -eq 0 ]]
  run mesh_wait_for_log "${node_name}-join" "Enter code: ABCD-1234" 20
  [[ "$status" -eq 0 ]]

  # Wait for the join process to finish and check it succeeded.
  run mesh_wait_for_log "${node_name}-join" "Successfully joined the Sovereign Agent Mesh!" 20
  [[ "$status" -eq 0 ]]
  [[ "$(docker inspect -f '{{.State.ExitCode}}' "${node_name}-join")" -eq 0 ]]
  docker rm -f "${node_name}-join" >/dev/null 2>&1 || true

  # Now run the node with the stored identity
  docker run -d \
    --name "${node_name}" \
    --network "${MESH_NETWORK}" \
    $(mesh_get_add_hosts) \
    -v "${data_vol}:/data" \
    -e SAM_UNSAFE_ALLOW_LOCAL_TARGETS="1" \
    "sam-node:local" \
    run \
    --data-dir /data \
    --control-plane "http://sam-control-plane:9090"
  MESH_CONTAINERS+=("${node_name}")

  mesh_wait_for_log "${node_name}" "Using stored identity." 20
}

@test "Authentication Flow 3: Workload Identity Federation (JWT Path)" {
  run mesh_start_mock_oidc
  [[ "$status" -eq 0 ]]

  run mesh_start_router
  [[ "$status" -eq 0 ]]

  # 1. Get a token from mock provider
  local token
  token=$(docker run --rm --network "${MESH_NETWORK}" $(mesh_get_add_hosts) python:3.12 python3 -c "import urllib.request; import json; req = urllib.request.Request('http://mock-oidc:18080/token', data=b''); resp = urllib.request.urlopen(req); print(json.loads(resp.read().decode())['access_token'])")

  [[ -n "${token}" ]]

  # 2. Save it to a file in a volume
  local token_vol="${MESH_PREFIX}-token"
  docker volume create "${token_vol}"
  CLEANUP_VOLUMES+=("${token_vol}")
  
  docker run --rm \
    -v "${token_vol}:/tokens" \
    busybox \
    sh -c "echo \"${token}\" > /tokens/sa-token"

  # 3. Run sam-node with --jwt-path
  local node_name="${MESH_PREFIX}-node-wi"
  local router_peer_id
  router_peer_id=$(cat "/tmp/${MESH_PREFIX}-router-peer-id")

  docker run -d \
    --name "${node_name}" \
    --network "${MESH_NETWORK}" \
    $(mesh_get_add_hosts) \
    -v "${token_vol}:/var/run/secrets/tokens" \
    -e SAM_API_TOKEN="secret-token" \
    -e SAM_UNSAFE_ALLOW_LOCAL_TARGETS="1" \
    "sam-node:local" \
    run \
    --control-plane "http://sam-control-plane:8080" \
    --jwt-path "/var/run/secrets/tokens/sa-token"
  MESH_CONTAINERS+=("${node_name}")

  mesh_wait_for_log "${node_name}" "SAM Node Online" 20
}

@test "Authentication Flow 4: Bootstrap Token Flow (Headless)" {
  run mesh_start_mock_oidc
  [[ "$status" -eq 0 ]]

  run mesh_start_router
  [[ "$status" -eq 0 ]]

  # 1. Generate bootstrap token via control plane API running in Kubernetes
  # Create curl pod in background to request token
  kubectl --context="${KUBECONTEXT}" run curl-token-gen-node \
    --image=curlimages/curl:8.6.0 \
    --restart=Never \
    --overrides='{"spec": {"activeDeadlineSeconds": 30}}' \
    -- \
    curl -s -X POST \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer super-secret-admin-token" \
      -d '{"role": "sam:role:node", "max_usages": 1}' \
      http://sam-control-plane:8080/admin/bootstrap-tokens

  if ! kubectl --context="${KUBECONTEXT}" wait --for=jsonpath='{.status.phase}'=Succeeded pod/curl-token-gen-node --timeout=15s; then
    echo "ERROR: Token generation pod failed! Diagnostics:"
    kubectl --context="${KUBECONTEXT}" describe pod curl-token-gen-node || true
    kubectl --context="${KUBECONTEXT}" logs pod/curl-token-gen-node || true
    kubectl --context="${KUBECONTEXT}" delete pod curl-token-gen-node --ignore-not-found || true
    exit 1
  fi

  local token_json
  token_json=$(kubectl --context="${KUBECONTEXT}" logs pod/curl-token-gen-node)
  kubectl --context="${KUBECONTEXT}" delete pod curl-token-gen-node --ignore-not-found

  local node_token
  node_token=$(echo "${token_json}" | jq -r .token)
  [[ -n "${node_token}" && "${node_token}" != "null" ]]

  # 2. Run sam-node join with the bootstrap token
  local node_name="${MESH_PREFIX}-node-bootstrap"
  local data_vol="${MESH_PREFIX}-data-bootstrap"
  docker volume create "${data_vol}"
  CLEANUP_VOLUMES+=("${data_vol}")

  docker run --name "${node_name}-join" \
    --network "${MESH_NETWORK}" \
    $(mesh_get_add_hosts) \
    -v "${data_vol}:/data" \
    "sam-node:local" \
    join --data-dir /data --bootstrap-token "${node_token}" "http://sam-control-plane:8080"

  # 3. Start the node container with stored identity
  docker run -d \
    --name "${node_name}" \
    --network "${MESH_NETWORK}" \
    $(mesh_get_add_hosts) \
    -v "${data_vol}:/data" \
    -e SAM_UNSAFE_ALLOW_LOCAL_TARGETS="1" \
    "sam-node:local" \
    run \
    --data-dir /data \
    --control-plane "http://sam-control-plane:8080"
  MESH_CONTAINERS+=("${node_name}")

  mesh_wait_for_log "${node_name}" "Using stored identity." 20
}
