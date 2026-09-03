#!/bin/bash

set -eu

# Load container mesh helpers
source "${BATS_TEST_DIRNAME}/lib/container_mesh.bash"

function setup_suite {
  export SAM_UNSAFE_ALLOW_LOCAL_TARGETS=1
  mesh_setup_suite
}

function teardown_suite {
  mesh_teardown_suite
}