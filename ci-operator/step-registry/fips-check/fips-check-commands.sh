#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


get_nodes=$(oc --request-timeout=60s get nodes -o jsonpath --template '{range .items[*]}{.metadata.name}{","}{end}')

IFS="," read -r -a nodes <<< "$get_nodes"

# bash doesn't handle '.' in array elements easily
num_nodes="${#nodes[@]}"
# TODO: This must be replaced by code that waits for all the expected number
# of nodes to be ready.

# oc debug in the default namespace returns podsecurity admission
# errors, the namespace we run debug in needs to have the right security
# labels
# https://docs.openshift.com/container-platform/4.11/authentication/understanding-and-managing-pod-security-admission.html
oc create ns fips-check -o yaml | \
  oc label -f - \
  security.openshift.io/scc.podSecurityLabelSync=false \
  pod-security.kubernetes.io/enforce=privileged \
  pod-security.kubernetes.io/audit=privileged \
  pod-security.kubernetes.io/warn=privileged

function cleanup() {
  oc delete ns fips-check
}
trap cleanup EXIT

for (( i=0; i<$num_nodes; i++ )); do
  attempt=0
  while true; do
      out=$(oc --request-timeout=60s -n fips-check debug node/"${nodes[i]}" -- cat /proc/sys/crypto/fips_enabled || true)
      if [[ ! -z "${out}" ]]; then
          break
      fi
      attempt=$(( attempt + 1 ))
      if [[ $attempt -gt 3 ]]; then
          break
      fi
      echo "command failed, $(( 4 - $attempt )) retries left"
      sleep 5
  done
  if [[ -z "${out}" ]]; then
    echo "oc debug node/${nodes[i]} failed"
    exit 1
  fi
  if [[ "${FIPS_ENABLED:-}" == "true" ]]; then
    if [[ "${out}" -ne 1 ]]; then
      echo "fips not enabled in node ${nodes[i]} but should be, exiting"
      exit 1
    fi
    echo "fips-check passed for node ${nodes[i]}: fips is enabled."
  else
    if [[ "${out}" -ne 0 ]]; then
      echo "fips is enabled in node ${nodes[i]} but should not be, exiting"
      exit 1
    fi
  fi
done
