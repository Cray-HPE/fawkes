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

if [[ $# -ne 2 ]]; then
    echo >&2 "usage: ${0##*/} , two arguments required: SRC-DIRECTORY DEST-REPOSITORY "
    exit 1
fi

path="$1"
repo="$2"
shift 2

if [[ ! -d "$path" ]]; then
    echo >&2 "ERROR No such directory: $path"
    exit 1
fi

NEXUS_DIR="$(dirname "${BASH_SOURCE[0]}")"
. "${NEXUS_DIR}/../lib/util.sh"
requires parallel

. "${NEXUS_DIR}/../nexus-setup/nexus-ready.sh"

function upload-asset-yum() {
    local asset
    local file
    local status
    file="${1:-}"
    asset="${file##"$path"}"

    if curl -u "${NEXUS_USERNAME}:${NEXUS_PASSWORD}" -fvL \
        --max-time "${CURL_MAX_TIME:-600}" \
        --upload-file \
        "$file" \
        "${NEXUS_URL}/repository/${repo///}${asset}"; then
        status=$?
        echo "INFO Uploaded: ${file} to ${repo}"
    else
        status=$?
        echo "ERROR Failed to upload ${file} to ${repo}" >&2
    fi
    return "$status"
}

export URL path repo
export -f upload-asset-yum
find "$path" -name '*.rpm' -type f \
    | parallel -j 1 --bar --halt-on-error now,fail=1 -v upload-asset-yum {}
