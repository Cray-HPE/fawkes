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

export SKOPEO_IMAGE='artifactory.algol60.net/csm-docker/stable/quay.io/skopeo/stable:v1'

declare -a podman_run_flags=(--network host)

# Prefer to use podman, but for environments with docker
if [[ "${USE_DOCKER_NOT_PODMAN:-"no"}" == "yes" ]]; then
    echo >&2 "warning: using docker, not podman"
    shopt -s expand_aliases
    alias podman=docker
fi

# usage: requires COMMAND [...COMMAND]
#
# Verifies that the given space delimited list of commands
# are in the current PATH.
function requires() {
    while [[ $# -gt 0 ]]; do
        command -v "$1" >/dev/null 2>&1 || {
            echo >&2 "command not found: ${1}"
            return 1
        }
        shift
    done
}

# usage: version
#
# Prints the current version
function version() {
    local s
    local v
    v="$(git describe --tags --match 'v*' | sed -e 's/^v//')"
    s="$(git status -s)"
    if [ -n "$s" ]; then
        v=${v}-dirty
    fi
    echo "$v"
}
