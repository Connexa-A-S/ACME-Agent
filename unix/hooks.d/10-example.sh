#!/usr/bin/env bash
#
# Example hook for the CNXA ACME Unix agent.
#
# Hooks run in filename order. They receive the deployment context as environment
# variables. Exit codes:
#   0 = OK
#   1 = warning, continue pipeline
#   2 = retry requested (agent exits non-zero so the next timer run retries)
#   3+ = fatal failure
#
set -eu

echo "Hook received certificate update for ${CNXA_SERVICE_NAME} / ${CNXA_DOMAIN}"
echo "Current: ${CNXA_CURRENT_PATH}"
echo "Version: ${CNXA_VERSION_PATH}"
echo "Format:  ${CNXA_FORMAT}"
echo "SHA256:  ${CNXA_FINGERPRINT}"

exit 0
