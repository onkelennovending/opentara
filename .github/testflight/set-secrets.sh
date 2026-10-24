#!/usr/bin/env bash
# Fork-only helper: store the App Store Connect API key as the three repository secrets the
# TestFlight workflow expects. Needs gh (logged in with admin rights on the fork).
#
#   .github/testflight/set-secrets.sh <KEY_ID> <ISSUER_ID> <path/to/AuthKey_<KEY_ID>.p8> [owner/repo]
set -euo pipefail

KEY_ID=${1:?key id (10 characters, e.g. 5BMYQUA359)}
ISSUER_ID=${2:?issuer id (UUID from the App Store Connect API page)}
P8=${3:?path to the .p8 file}
REPO=${4:-onkelennovending/opentara}

grep -q "BEGIN PRIVATE KEY" "$P8" || { echo "$P8 does not look like an App Store Connect .p8 (no BEGIN PRIVATE KEY line)" >&2; exit 1; }
[[ ${#KEY_ID} -eq 10 ]] || { echo "key id should have 10 characters, got '$KEY_ID'" >&2; exit 1; }
[[ $ISSUER_ID =~ ^[0-9a-fA-F-]{36}$ ]] || { echo "issuer id should be a UUID, got '$ISSUER_ID'" >&2; exit 1; }

gh secret set ASC_KEY_ID --repo "$REPO" --body "$KEY_ID"
gh secret set ASC_ISSUER_ID --repo "$REPO" --body "$ISSUER_ID"
gh secret set ASC_PRIVATE_KEY --repo "$REPO" < "$P8"
echo
gh secret list --repo "$REPO"
echo
echo "Done. Start the upload with: gh workflow run testflight.yml --repo $REPO --ref main"
