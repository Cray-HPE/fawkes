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
trap '{ rm -rf "$WORKDIR"; }' EXIT

# Create blobstores
while [[ $# -gt 0 ]]; do
    echo "DEBUG $0: Processing $1"
    nblobs="$(yq eval-all --no-doc '[document_index] | length' "$1")"

    for (( i=0; i<nblobs; i++ )); do
        tmpfile="${WORKDIR}/blobstore-${#}-${i}.yaml"
        yq '. | select(document_index == '"$i"')' "${1}" >"$tmpfile"
        blobstore_name="$(yq '.name' "$tmpfile")"

        # Determine type of blobstore
        if [[ -n "$(yq '.path' "$tmpfile")" ]]; then
            blobstore_type="file"
        elif [[ -n "$(yq '.bucketConfiguration' "$tmpfile")" ]]; then
            blobstore_type="s3"
            [[ -z $S3_ACCESS_KEY ]] || yq -i '.bucketConfiguration.bucketSecurity.accessKeyId = "'"$S3_ACCESS_KEY"'"' "$tmpfile"
            [[ -z $S3_SECRET_KEY ]] || yq -i '.bucketConfiguration.bucketSecurity.secretAccessKey = "'"$S3_SECRET_KEY"'"' "$tmpfile"
            [[ -z $S3_ENDPOINT ]]   || yq -i '.bucketConfiguration.advancedBucketConnection.endpoint = "'"$S3_ENDPOINT"'"' "$tmpfile"
        else
            echo >&2 "ERROR Unknown blobstore type: ${blobstore_name}. Exiting"
            exit 1
        fi

        # First try to create
        echo >&2 "DEBUG Creating ${blobstore_type} blobstore: ${blobstore_name}... "
        if yq -o j '.' "$tmpfile" | curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -sfL \
            --connect-timeout "${CURL_CONNECT_TIMEOUT:-10}" \
            --retry-connrefused \
            -X POST "${URL}/v1/blobstores/${blobstore_type}" \
            -H 'Accept: application/json' \
            -H 'Content-Type:application/json' \
            -d @-; then
            echo >&2 "INFO Successfully created ${blobstore_type} blobstore: ${blobstore_name}"
        else
            echo >&2 "ERROR Failed to create ${blobstore_type} blobstore: ${blobstore_name}"

            # Failed to create, try to update
            echo >&2 "DEBUG Updating ${blobstore_type} blobstore: ${blobstore_name} as creating failed... "
            if yq -o j "$tmpfile" | curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -sfL \
                --connect-timeout "${CURL_CONNECT_TIMEOUT:-10}" \
                --retry-connrefused \
                -X PUT "${URL}/v1/blobstores/${blobstore_type}/${blobstore_name}" \
                -H 'Accept: application/json' \
                -H 'Content-Type:application/json' \
                -d @-; then
                echo >&2 "INFO Successfully updated ${blobstore_type} blobstore: ${blobstore_name}"
            else
                echo >&2 "ERROR Failed to update ${blobstore_type} blobstore: ${blobstore_name}"
            fi
        fi
    done

    shift
done
