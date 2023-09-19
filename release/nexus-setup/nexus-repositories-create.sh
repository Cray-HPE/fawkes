#!/bin/bash
#
# MIT License
#
# (C) Copyright 2023 Hewlett Packard Enterprise Development LP
#
# Permission is hereby granted, free of charge, to any person obtaining a
# copy of this software and associated documentation files (the "Software"),
# to deal in the Software without restriction, including without limitation
# the rights to use, copy, modify, merge, publish, distribute, sublicense,
# and/or sell copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included
# in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
# THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR
# OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
# ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
#
set -euo pipefail
NEXUS_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "${NEXUS_DIR}/../lib/util.sh"
requires yq

. "${NEXUS_DIR}/nexus-ready.sh"

WORKDIR="$(mktemp -d)"

# Store results in this file.
RESULTS_FILE="/results/records.yaml"
RESULTS_HEADER_FILE=$(mktemp)
mkdir -p "$(dirname "$RESULTS_FILE")"
cat << EOF > "$RESULTS_HEADER_FILE"
component_versions:
  repositories:
EOF

trap '{ rm -rf "$WORKDIR"; }' EXIT

function find_repo(){
    # If changes are needed, ensure that testing is done on both Nexus 3.25.0 (csm-1.2) and
    # 3.38.0 (csm-1.3) since this is used in both versions.
    if [[ $# -ne 3 ]]; then
        echo >&2 "ERROR Missing arguments. Expecting repo_format repo_type repo_name. Arguments passed were: $*"
        return 1
    fi
    if [[ -z "$1" ]]; then echo >&2 "ERROR Empty repo_format argument"; return 1; fi
    if [[ -z "$2" ]]; then echo >&2 "ERROR Empty repo_type argument"; return 1; fi
    if [[ -z "$3" ]]; then echo >&2 "ERROR Empty repo_name argument"; return 1; fi
    repo_format=$1
    repo_type=$2
    repo_name=$3

    echo >&2 "DEBUG Looking for ${repo_format}/${repo_type} repository: ${repo_name}..."

    # Ask Nexus for all repositories and filter that result by format, type, and name.
    jqfilter=".[] | select(.format == \"$repo_format\") | select(.type == \"$repo_type\") | select(.name == \"$repo_name\")"
    result=$(curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -sfL "${URL}/v1/repositories" | jq "$jqfilter")

    # An empty string here means that the repo was not found in the json result by format, type, and name.
    if [[ -z "$result" ]]; then
      echo >&2 "ERROR Could not find the ${repo_format}/${repo_type} repository: ${repo_name}"
      return 1
    else
      echo >&2 "DEBUG Found ${repo_format}/${repo_type} repository: ${repo_name}"
      return 0
    fi
}


function record_result(){
    # append records for a single repository to the results file.
    repo_name="$1"
    repo_type="$2"
    shift 2
    repo_members=("$@")
    # Create results file when recording the first result.
    if [[ ! -f "$RESULTS_FILE" ]]; then
        mv "$RESULTS_HEADER_FILE" "$RESULTS_FILE"
    fi
    echo "  - name: '${repo_name}'" >> "$RESULTS_FILE"
    echo "    type: '${repo_type}'" >> "$RESULTS_FILE"
    if [[ ${#repo_members[@]} -gt 0 ]]; then
      echo "    members:" >> "$RESULTS_FILE"
      for member in "${repo_members[@]}"; do
          echo "    - '${member}':qa" >> "$RESULTS_FILE"
      done
    fi
}

while [[ $# -gt 0 ]]; do
    echo "DEBUG $0: Processing $1"
    nrepos="$(yq eval-all --no-doc '[document_index] | length' "$1")"

    for (( i=0; i<nrepos; i++ )); do
        tmpfile="${WORKDIR}/repository-${#}-${i}.yaml"
        yq '. | select(document_index == '"$i"')' "${1}" >"$tmpfile"

        repo_name="$(yq '.name' "$tmpfile")"
        repo_format="$(yq '.format' "$tmpfile")"
        repo_type="$(yq '.type' "$tmpfile")"
        if [[ $repo_type == "group" ]]; then
            repo_members=("$(yq '.group.memberNames[]' "$tmpfile")")
        else
            repo_members=()
        fi

        if find_repo "${repo_format}" "${repo_type}" "${repo_name}"; then
            found=0
        else
            found=1
        fi

        if [[ $found -eq 1 ]]; then
            # Repo was not found, try to create it.
            echo >&2 "DEBUG Creating ${repo_format}/${repo_type} repository: ${repo_name}..."
            if yq -o j "$tmpfile" | curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -sfL \
               --retry-connrefused \
               --retry "${CURL_RETRY:-36}" \
               --retry-delay "${CURL_RETRY_DELAY:-5}" \
               --max-time "${CURL_MAX_TIME:-180}" \
               -X POST "${URL}/v1/repositories/${repo_format}/${repo_type}" \
               -H "Content-Type: application/json" \
               -d @-; then
                echo >&2 "INFO Successfully created ${repo_format}/${repo_type} repository: ${repo_name}"
            else
                status="$?"
                echo >&2 "ERROR Failed to create ${repo_format}/${repo_type} repository: ${repo_name}"; exit $status;
            fi
        elif [[ $found -eq 0 ]]; then
            # Found the repo, try to update it.
            echo >&2 "DEBUG Updating ${repo_format}/${repo_type} repository: ${repo_name}..."
            if yq -o j "$tmpfile" | curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -sfL \
                --retry-connrefused \
                --retry "${CURL_RETRY:-36}" \
                --retry-delay "${CURL_RETRY_DELAY:-5}" \
                --max-time "${CURL_MAX_TIME:-180}" \
                -X PUT "${URL}/v1/repositories/${repo_format}/${repo_type}/${repo_name}" \
                -H "Content-Type: application/json" \
                -d @-; then
                echo >&2 "INFO Successfully updated ${repo_format}/${repo_type} repository: ${repo_name}"
            else
                status="$?"
                echo >&2 "ERROR Failed to update ${repo_format}/${repo_type} repository: ${repo_name}"; exit $status;
            fi
        else
            # We did not get a known response from the search API.
            echo >&2 "ERROR Search for ${repo_format}/${repo_type} repository: ${repo_name} failed with unexpected response"; exit 1
        fi
        record_result "$repo_name" "$repo_type" "${repo_members[@]}"
    done

    shift
done
