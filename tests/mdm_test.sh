#!/bin/bash
# Validate the App Management profile and its example DDM activation.
set -eu

HERE="$(cd "$(dirname "$0")" && pwd -P)"
PROFILE="${HERE}/../mdm/brewau-app-management.mobileconfig"
DDM="${HERE}/../mdm/brewau-app-management.ddm.json"
ENTRY="PayloadContent.0.Services.SystemPolicyAppBundles.0"

expect() {
  local actual
  actual="$(plutil -extract "$2" raw -o - "$1")"
  if [[ "${actual}" != "$3" ]]; then
    printf 'FAIL: %s in %s: expected %s, got %s\n' "$2" "$1" "$3" "${actual}" >&2
    exit 1
  fi
}

plutil -lint "${PROFILE}"
expect "${PROFILE}" PayloadType Configuration
expect "${PROFILE}" PayloadScope System
expect "${PROFILE}" PayloadIdentifier com.kastruppro.brewau.pppc
expect "${PROFILE}" PayloadContent.0.PayloadType com.apple.TCC.configuration-profile-policy
expect "${PROFILE}" "${ENTRY}.IdentifierType" path
expect "${PROFILE}" "${ENTRY}.Identifier" /opt/brewau/libexec/brewau-agent
expect "${PROFILE}" "${ENTRY}.CodeRequirement" \
  'identifier "com.kastruppro.brewau.agent" and anchor apple generic and certificate leaf[subject.OU] = "5W98EXLE44"'
expect "${PROFILE}" "${ENTRY}.Authorization" Allow
expect "${DDM}" 0.Type com.apple.configuration.legacy
expect "${DDM}" 1.Type com.apple.activation.simple
expect "${DDM}" 1.Payload.StandardConfigurations.0 "$(plutil -extract 0.Identifier raw -o - "${DDM}")"
echo "App Management profile and DDM example passed"
