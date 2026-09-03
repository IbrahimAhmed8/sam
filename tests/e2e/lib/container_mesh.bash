#!/usr/bin/env bash

# Shared BATS helpers for containerized SAM mesh tests.
# Refactored to use Kind-hosted unified OIDC and control plane services.

if [[ -z "${MESH_HELPERS_LOADED:-}" ]]; then
  MESH_HELPERS_LOADED=1

  MESH_RUNTIME_IMAGE="${MESH_RUNTIME_IMAGE:-sam-e2e-runtime:local}"
  MESH_NETWORK="kind"
  MESH_CONTAINERS=()
  MESH_PREFIX=""
  MESH_SOCKET_DIR=""

  mesh_cleanup_stale_resources() {
    local stale_containers
    stale_containers=$(docker ps -aq --filter "name=mesh-")
    if [[ -n "${stale_containers}" ]]; then
      docker rm -f ${stale_containers} >/dev/null 2>&1 || true
    fi
  }

  mesh_require_docker() {
    command -v docker >/dev/null 2>&1 || return 1
    docker info >/dev/null 2>&1 || return 1
    return 0
  }

  mesh_build_runtime_image() {
    if ! docker image inspect "${MESH_RUNTIME_IMAGE}" >/dev/null 2>&1; then
      docker build \
        -f tests/e2e/docker/Dockerfile.sam-runtime \
        -t "${MESH_RUNTIME_IMAGE}" \
        . >/dev/null
    fi
  }

  mesh_setup_env() {
    if [[ -n "${MESH_PREFIX:-}" ]]; then
      return 0
    fi
    mesh_build_runtime_image

    export SAM_UNSAFE_ALLOW_LOCAL_TARGETS=1
    MESH_PREFIX="mesh-${BATS_TEST_NUMBER}-$$-$(date +%s)"
    MESH_SOCKET_DIR="/tmp/${MESH_PREFIX}-sockets"
    mkdir -p "${MESH_SOCKET_DIR}"
    CLEANUP_VOLUMES=()
  }

  mesh_cleanup_test_resources() {
    if [[ "${BATS_TEST_COMPLETED:-0}" -ne 1 ]]; then
      mkdir -p tests/e2e/logs
      local c
      for c in "${MESH_CONTAINERS[@]}"; do
        docker logs "${c}" > "tests/e2e/logs/${c}.log" 2>&1 || true
      done
    fi

    local c
    for c in "${MESH_CONTAINERS[@]}"; do
      docker rm -f "${c}" >/dev/null 2>&1 || true
    done
    MESH_CONTAINERS=()

    local v
    for v in "${CLEANUP_VOLUMES[@]}"; do
      docker volume rm "${v}" >/dev/null 2>&1 || true
    done
    CLEANUP_VOLUMES=()
  }

  mesh_cleanup_env() {
    mesh_cleanup_test_resources
  }

  mesh_gen_hex32() {
    hexdump -vn 32 -e '1/1 "%02x"' /dev/urandom
  }

  mesh_wait_for_log() {
    local container="$1"
    local needle="$2"
    local timeout_s="${3:-20}"
    local i
    for ((i=0; i<timeout_s*10; i++)); do
      if docker logs "${container}" 2>&1 | grep -Fq "${needle}"; then
        return 0
      fi
      sleep 0.1
    done
    return 1
  }

  # Pods matching a selector that will never become ready on their own.
  # Deliberately excludes CrashLoopBackOff: the control plane restarts a few
  # times while the database comes up, so treating that as terminal would swap
  # one flake for another. Images are preloaded with `kind load`, so a pull
  # failure is always a real one.
  mesh_unrecoverable_pods() {
    local selector="$1"
    [[ -n "${selector}" ]] || return 0
    kubectl --context="${KUBECONTEXT}" get pods -l "${selector}" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"="}{range .status.containerStatuses[*]}{.state.waiting.reason}{end}{"\n"}{end}' 2>/dev/null |
      grep -E '=(ImagePullBackOff|InvalidImageName|CreateContainerConfigError)$' || true
  }

  # Scoped so an unrelated broken pod elsewhere in the namespace cannot abort a
  # wait for a healthy workload.
  mesh_selector_for() {
    local target="$1" selector
    selector=$(kubectl --context="${KUBECONTEXT}" get "${target}" \
      -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null) || return 0
    echo "${selector%,}"
  }

  mesh_dump_cluster() {
    local what="$1"
    {
      echo "--- ${what} never became ready ---"
      kubectl --context="${KUBECONTEXT}" get pods -o wide
      kubectl --context="${KUBECONTEXT}" get events --sort-by=.lastTimestamp | tail -30
      local pod
      for pod in $(kubectl --context="${KUBECONTEXT}" get pods -o name); do
        echo "--- ${pod} ---"
        kubectl --context="${KUBECONTEXT}" logs "${pod}" --all-containers --tail=50 2>&1 || true
      done
    } >&2 2>&1 || true
  }

  # Waits for a workload without putting a stopwatch on a busy machine.
  #
  # The ceiling is generous, which costs nothing when things are healthy because
  # this returns the moment the rollout completes; the old fixed 60s failed runs
  # for being slow rather than broken, on a cold cluster that had just loaded
  # four images onto three nodes. A pod that cannot recover still aborts at once,
  # so a genuine breakage is no slower to report than before, and now says why.
  mesh_wait_for_rollout() {
    local target="$1"
    local timeout_s="${2:-${MESH_ROLLOUT_TIMEOUT:-300}}"
    local deadline=$((SECONDS + timeout_s))
    local selector
    selector="$(mesh_selector_for "${target}")"

    while true; do
      # Doubles as the poll interval: it blocks until ready or the slice expires.
      if kubectl --context="${KUBECONTEXT}" rollout status "${target}" --timeout=5s >/dev/null 2>&1; then
        return 0
      fi
      local stuck
      stuck="$(mesh_unrecoverable_pods "${selector}")"
      if [[ -n "${stuck}" ]]; then
        echo "${target}: pod cannot recover: ${stuck}" >&2
        mesh_dump_cluster "${target}"
        return 1
      fi
      if ((SECONDS >= deadline)); then
        echo "${target}: not ready after ${timeout_s}s" >&2
        mesh_dump_cluster "${target}"
        return 1
      fi
    done
  }

  mesh_wait_for_job() {
    local target="$1"
    local timeout_s="${2:-${MESH_ROLLOUT_TIMEOUT:-300}}"
    local deadline=$((SECONDS + timeout_s))

    while true; do
      if kubectl --context="${KUBECONTEXT}" wait --for=condition=complete --timeout=5s "${target}" >/dev/null 2>&1; then
        return 0
      fi
      if kubectl --context="${KUBECONTEXT}" wait --for=condition=failed --timeout=1s "${target}" >/dev/null 2>&1; then
        echo "${target}: failed" >&2
        mesh_dump_cluster "${target}"
        return 1
      fi
      if ((SECONDS >= deadline)); then
        echo "${target}: did not complete within ${timeout_s}s" >&2
        mesh_dump_cluster "${target}"
        return 1
      fi
    done
  }

  mesh_wait_for_mcp_ready() {
    local idx="$1"
    local timeout_s="${2:-20}"
    local i
    for ((i=0; i<timeout_s; i++)); do
      if docker run --rm --network "${MESH_NETWORK}" python:3.12 curl -s -X POST -H "Content-Type: application/json" -H "X-Sam-Authentication: Bearer secret-token" -d '{"jsonrpc":"2.0","method":"ping","id":1}' --max-time 5 -D - http://${MESH_PREFIX}-node-${idx}:8080/mcp | grep -q "200 OK"; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  # POST /debug/connect-peer on node <idx>; the REST endpoint that replaced
  # the connect_peer MCP tool (#318). Nonzero exit on any non-2xx response.
  mesh_connect_peer() {
    local idx="$1"
    local peer_addr="$2"
    docker run --rm --network "${MESH_NETWORK}" python:3.12 \
      curl -sf -X POST --max-time 30 \
      -H "Content-Type: application/json" \
      -H "X-Sam-Authentication: Bearer secret-token" \
      -d "{\"peer_addr\":\"${peer_addr}\"}" \
      "http://${MESH_PREFIX}-node-${idx}:8080/debug/connect-peer"
  }

  mesh_get_node_count_via_mcp() {
    local idx="$1"
    local output
    output="$(timeout 15s docker run --rm --network "${MESH_NETWORK}" "${MESH_RUNTIME_IMAGE}" mcp-client -url "http://${MESH_PREFIX}-node-${idx}:8080/mcp" -tool "get_mesh_info" 2>/dev/null)"
    echo "${output}" | jq 'if .connected_peers then (.connected_peers | length) - 1 else 0 end'
  }

  mesh_wait_for_node_count() {
    local idx="$1"
    local expected="$2"
    local timeout_s="${3:-20}"
    local i
    for ((i=0; i<timeout_s; i++)); do
      local output
      output="$(timeout 15s docker run --rm --network "${MESH_NETWORK}" "${MESH_RUNTIME_IMAGE}" mcp-client -url "http://${MESH_PREFIX}-node-${idx}:8080/mcp" -tool "get_mesh_info" 2>/dev/null)"
      echo "Node ${idx} get_mesh_info raw output: ${output}"
      local count
      count="$(echo "${output}" | jq 'if .connected_peers then (.connected_peers | length) - 1 else 0 end')"
      echo "Node ${idx} reported known peers count: ${count}"
      if [[ "${count}" -eq "${expected}" ]]; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  mesh_wait_for_peer_connection() {
    local idx="$1"
    local target_peer="$2"
    local timeout_s="${3:-20}"
    local i
    for ((i=0; i<timeout_s; i++)); do
      local output
      output="$(timeout 15s docker run --rm --network "${MESH_NETWORK}" "${MESH_RUNTIME_IMAGE}" mcp-client -url "http://${MESH_PREFIX}-node-${idx}:8080/mcp" -tool "get_mesh_info" 2>/dev/null)"
      echo "[$(date +%T)] Node ${idx} get_mesh_info raw output: ${output}"
      local connected
      connected="$(echo "${output}" | jq -r --arg peer "$target_peer" '.connected_peers | index($peer) != null')"
      echo "[$(date +%T)] Node ${idx} connection to ${target_peer}: ${connected}"
      if [[ "${connected}" == "true" ]]; then
        return 0
      fi
      sleep 1
    done
    return 1
  }

  mesh_wait_for_peer_disconnection() {
    local idx="$1"
    local target_peer="$2"
    local timeout_s="${3:-20}"
    local i
    for ((i=0; i<timeout_s; i++)); do
      local output
      output="$(timeout 15s docker run --rm --network "${MESH_NETWORK}" "${MESH_RUNTIME_IMAGE}" mcp-client -url "http://${MESH_PREFIX}-node-${idx}:8080/mcp" -tool "get_mesh_info" 2>/dev/null)"
      echo "[$(date +%T)] Node ${idx} get_mesh_info raw output: ${output}"
      local connected
      connected="$(echo "${output}" | jq -r --arg peer "$target_peer" '.connected_peers | index($peer) != null')"
      echo "[$(date +%T)] Node ${idx} connection to ${target_peer}: ${connected}"
      if [[ "${connected}" == "false" ]]; then
        return 0
      fi
      sleep 1
    done
    return 1
  }


  mesh_get_add_hosts() {
    local net="${MESH_NETWORK:-kind}"
    # Resolve mock-oidc node IP
    local oidc_node
    oidc_node=$(kubectl --context="${KUBECONTEXT:-kind-sam-wi-test}" get pod -l app=mock-oidc -o jsonpath='{.items[0].spec.nodeName}')
    local oidc_node_ip
    oidc_node_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${oidc_node}")

    # Check if a custom local router container exists in this test scope
    local router_ip=""
    local custom_router="${MESH_PREFIX}-router"
    if docker inspect "${custom_router}" >/dev/null 2>&1; then
      router_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${custom_router}")
      local cp_ip=""
      local custom_cp="${MESH_PREFIX}-control-plane"
      if docker inspect "${custom_cp}" >/dev/null 2>&1; then
        cp_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${custom_cp}")
      fi
      echo "--add-host mock-oidc:${oidc_node_ip} --add-host sam-router:${router_ip} --add-host sam-control-plane:${cp_ip}"
    else
      # Resolve sam-router-0 node IP
      local router_node
      router_node=$(kubectl --context="${KUBECONTEXT:-kind-sam-wi-test}" get pod sam-router-0 -o jsonpath='{.spec.nodeName}')
      local router_node_ip
      router_node_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${net}\").IPAddress}}" "${router_node}")
      echo "--add-host mock-oidc:${oidc_node_ip} --add-host sam-router:${router_node_ip} --add-host sam-control-plane:${router_node_ip} --add-host ${router_node}:${router_node_ip}"
    fi
  }

  mesh_setup_suite() {
    export PATH="${HOME}/go/bin:$PATH"
    export SAM_UNSAFE_ALLOW_LOCAL_TARGETS=1
    mesh_cleanup_stale_resources
    if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
      echo "docker not available or daemon not running" >&2
      return 1
    fi
    if ! command -v kind >/dev/null 2>&1; then
      echo "kind not available" >&2
      return 1
    fi
    if ! command -v kubectl >/dev/null 2>&1; then
      echo "kubectl not available" >&2
      return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
      echo "jq not available" >&2
      return 1
    fi

    cd "${BATS_TEST_DIRNAME}/../.."
    make
    make docker-build

    if [[ ! -x "./bin/sam-node" || ! -x "./bin/sam-control-plane" || ! -x "./bin/sam-router" || ! -x "./bin/mcp-client" ]]; then
      echo "missing binaries; run: make build" >&2
      return 1
    fi

    export KUBERNETES_CLUSTER_NAME="sam-wi-test"
    export KUBECONTEXT="kind-${KUBERNETES_CLUSTER_NAME}"

    # Recreating is the default so a local run matches CI, which builds a cluster
    # per run. Reuse carries over database PVCs, control plane signing keys and
    # bootstrap tokens; E2E_REUSE_CLUSTER=1 trades that fidelity for a faster loop.
    local reused_cluster=0
    if [[ "${E2E_REUSE_CLUSTER:-0}" == "1" ]] && kind get clusters | grep -q "^${KUBERNETES_CLUSTER_NAME}$"; then
      kind export kubeconfig --name "${KUBERNETES_CLUSTER_NAME}"
      reused_cluster=1
    else
      kind delete cluster --name "${KUBERNETES_CLUSTER_NAME}" >/dev/null 2>&1 || true
      kind create cluster --name "${KUBERNETES_CLUSTER_NAME}" --config=tests/e2e/fixtures/kind-cluster.yaml
    fi

    kind load docker-image sam-control-plane:local --name "${KUBERNETES_CLUSTER_NAME}"
    kind load docker-image sam-router:local --name "${KUBERNETES_CLUSTER_NAME}"
    kind load docker-image sam-node:local --name "${KUBERNETES_CLUSTER_NAME}"
    kind load docker-image sam-mock-oidc:local --name "${KUBERNETES_CLUSTER_NAME}"

    kubectl --context="${KUBECONTEXT}" apply -f tests/e2e/fixtures/mock-oidc.yaml
    mesh_wait_for_rollout deployment/mock-oidc

    local kube_issuer
    kube_issuer=$(kubectl --context="${KUBECONTEXT}" get --raw /.well-known/openid-configuration | jq -r .issuer)
    [[ -n "${kube_issuer}" ]]

    kubectl --context="${KUBECONTEXT}" apply -f tests/e2e/fixtures/allow-anonymous-oidc.yaml

    export ISSUERS="http://mock-oidc:18080,${kube_issuer}"

    local oidc_node
    oidc_node=$(kubectl --context="${KUBECONTEXT}" get pod -l app=mock-oidc -o jsonpath='{.items[0].spec.nodeName}')
    local oidc_node_ip
    oidc_node_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${MESH_NETWORK:-kind}\").IPAddress}}" "${oidc_node}")

    local helm_bin="helm"
    if ! command -v helm >/dev/null 2>&1; then
      if [[ -x "./bin/helm" ]]; then
        helm_bin="./bin/helm"
      else
        echo "helm CLI not found; please install helm or place it in ./bin/helm" >&2
        return 1
      fi
    fi

    # router.externalAddrs: nodes resolve sam-router per-network via --add-host, so the router must
    # announce that name. Announcing a node IP instead is unroutable from an isolated test network.
    # bootstrap.nodeServices: policy.bats asserts the control plane denies an ungranted service, so
    # this lane pins the grants it tests rather than inheriting the chart default.
    local helm_args=(--kube-context="${KUBECONTEXT}" upgrade --install sam ./charts/sam-mesh
      --namespace default
      --set fullnameOverride="sam"
      --set global.imageTag="local"
      --set controlPlane.oidcIssuer="${ISSUERS//,/\\,}"
      --set controlPlane.allowedAudiences="sam-mesh-audience\,sam-control-plane-audience"
      --set controlPlane.insecureSkipTlsVerify=true
      --set controlPlane.adminToken="super-secret-admin-token"
      --set controlPlane.replicaCount=2
      --set controlPlane.hostPort=8080
      --set router.useOidcToken=false
      --set router.hostPort=4501
      --set console.enabled=false
      --set 'router.externalAddrs={/dns4/sam-router/tcp/4501}'
      --set 'bootstrap.nodeServices={mcp://calculator,mcp://db-agent,mcp://http-tool,mcp://stdio-tool,system://sam.catalog}')
    if ! "${helm_bin}" "${helm_args[@]}"; then
      # The reused cluster may hold StatefulSets whose immutable spec (e.g.
      # volumeClaimTemplates) changed; drop them (PVCs survive) and retry.
      kubectl --context="${KUBECONTEXT}" delete statefulset sam-router sam-db --ignore-not-found
      "${helm_bin}" "${helm_args[@]}"
    fi

    mesh_wait_for_rollout statefulset/sam-db
    mesh_wait_for_rollout deployment/sam-control-plane
    mesh_wait_for_job job/sam-bootstrap
    # A router surviving a reinstall holds a biscuit no current control plane key
    # verifies and a bootstrap token past its 24h default, so it can never lease
    # again. Restarting re-enrolls it against the state this run just installed.
    if [[ "${reused_cluster}" == "1" ]]; then
      kubectl --context="${KUBECONTEXT}" rollout restart statefulset/sam-router
    fi
    mesh_wait_for_rollout statefulset/sam-router

    local i
    for ((i=0; i<200; i++)); do
      if kubectl --context="${KUBECONTEXT}" logs "sam-router-0" 2>&1 | grep -q "PeerID:"; then
        break
      fi
      sleep 0.1
    done
    local router_peer_id
    router_peer_id=$(kubectl --context="${KUBECONTEXT}" logs "sam-router-0" | grep -oE '12D3Koo[a-zA-Z0-9]+' | head -n 1 || true)
    [[ -n "${router_peer_id}" ]]

    # The router pod reports Ready before its lease reaches the control plane, and
    # a node's /register serves router addresses from that lease, so a node
    # started in between enrolls against an empty list and exits.
    local router_node_ip
    router_node_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"${MESH_NETWORK:-kind}\").IPAddress}}" \
      "$(kubectl --context="${KUBECONTEXT}" get pod sam-router-0 -o jsonpath='{.spec.nodeName}')")
    local lease_deadline=$((SECONDS + 60))
    until docker run --rm --network "${MESH_NETWORK:-kind}" python:3.12 \
        curl -sf --max-time 5 "http://${router_node_ip}:8080/info" 2>/dev/null | grep -qaF "${router_peer_id}"; do
      if ((SECONDS >= lease_deadline)); then
        echo "router lease did not reach the control plane within 60s" >&2
        return 1
      fi
      sleep 1
    done

    echo "${router_peer_id}" > "/tmp/sam-wi-test-router-peer-id"
    return 0
  }

  mesh_teardown_suite() {
    cd "${BATS_TEST_DIRNAME}/../.."
    mesh_cleanup_stale_resources
    # kind delete cluster --name "${KUBERNETES_CLUSTER_NAME:-sam-wi-test}" >/dev/null 2>&1 || true
    echo "teardown suite"
  }

  mesh_start_node() {
    local idx="$1"
    local flags="${2:-}"
    local config_path="${3:-}"
    # Extra docker arguments, for tests that need to share something with the
    # node container, such as the directory its API socket lives in.
    local docker_args="${4:-}"
    local name="${MESH_PREFIX}-node-${idx}"

    local add_hosts
    add_hosts=$(mesh_get_add_hosts)

    local router_peer_id
    router_peer_id=$(cat "/tmp/${MESH_PREFIX}-router-peer-id")

    local mount_args=()
    local config_args=()
    if [[ -n "${config_path}" ]]; then
      local abs_config
      abs_config=$(realpath "${config_path}")
      mount_args+=(-v "${abs_config}:/etc/sam/node-config.yaml:ro")
      config_args+=(--config /etc/sam/node-config.yaml)
    fi

    docker run -d \
      --name "${name}" \
      --network "${MESH_NETWORK}" \
      --network-alias "${name}" \
      ${add_hosts} \
      "${mount_args[@]}" \
      ${docker_args} \
      -e SAM_CLIENT_SECRET="sam-e2e-secret" \
      -e SAM_API_TOKEN="secret-token" \
      -e SAM_UNSAFE_ALLOW_LOCAL_TARGETS="1" \
      "${MESH_RUNTIME_IMAGE}" \
      /usr/local/bin/sam-node run \
      ${flags} \
      --log-level debug \
      --discovery-interval 2s \
      --control-plane "http://sam-control-plane:8080" \
      --client-id "sam-mesh-audience" \
      --oidc-issuer "http://mock-oidc:18080" \
      --listen "/ip4/0.0.0.0/udp/5001/quic-v1" \
      --listen "/ip4/0.0.0.0/tcp/5002" \
      --bind-addr "0.0.0.0:8080" \
      --mesh "${MESH_PREFIX}" \
      --dht-provider-addr-ttl 5s \
      --dht-max-record-age 5s \
      "${config_args[@]}" >/dev/null

    MESH_CONTAINERS+=("${name}")
  }

  mesh_start_mock_oidc() {
    # No-op: Mock OIDC is running in k8s
    return 0
  }

  mesh_start_router() {
    # No-op: router is running in k8s
    local peer_id
    peer_id=$(cat "/tmp/sam-wi-test-router-peer-id")
    echo "${peer_id}" > "/tmp/${MESH_PREFIX}-router-peer-id"
    return 0
  }

  mesh_assert_container_running() {
    local name="$1"
    if [[ "${name}" == *"-router" ]]; then
      kubectl --context="${KUBECONTEXT:-kind-sam-wi-test}" get pod sam-router-0 -o jsonpath='{.status.phase}' | grep -q "Running"
      return $?
    fi
    local state
    state="$(docker inspect -f '{{.State.Running}}' "${name}" 2>/dev/null || true)"
    [[ "${state}" == "true" ]]
  }
fi
