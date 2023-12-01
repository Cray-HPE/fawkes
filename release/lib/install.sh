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

: "${NEXUS_URL:="http://packages/nexus"}"
: "${NEXUS_REGISTRY:="registry:5000"}"

# If NEXUS_URL is localhost, then assume our registry is as well. Localhost should only
# be used in a bootstrapping context.
if [[ "$NEXUS_URL" =~ "localhost" ]]; then
    NEXUS_REGISTRY=localhost:${NEXUS_REGISTRY##*:}
fi

export NEXUS_URL
export NEXUS_REGISTRY

LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${LIB_DIR}/util.sh"

requires curl find podman realpath

# usage: nexus-get-credential [[-n NAMESPACE] SECRET]
#
# Gets Nexus username and password from SECRET in NAMESPACE and sets
# NEXUS_USERNAME and NEXUS_PASSWORD as appropriate. By default NAMESPACE is
# "nexus" and SECRET is "nexus-admin-credential".
function nexus-get-credential() {
    requires base64 kubectl

    [[ $# -gt 0 ]] || set -- -n nexus nexus-admin-credential

    kubectl get secret "${@}" >/dev/null || return $?

    NEXUS_USERNAME="$(kubectl get secret "${@}" -o jsonpath='{.data.username}' | base64 -d)"
    NEXUS_PASSWORD="$(kubectl get secret "${@}" -o jsonpath='{.data.password}' | base64 -d)"
    export NEXUS_USERNAME NEXUS_PASSWORD
}

# usage: nexus-setdefault-credential
#
# Ensures NEXUS_USERNAME and NEXUS_PASSWORD are set, at least to default
# credential.
function nexus-setdefault-credential() {
    set -x
    if [[ -n "${NEXUS_PASSWORD:-}" ]] && [[ -n "${NEXUS_PASSWORD:-}" ]]; then
        return 0
    fi
    if ! nexus-get-credential; then
        echo >&2 "warning: Nexus admin credential not detected, falling back to defaults"
        export NEXUS_USERNAME="admin"
        export NEXUS_PASSWORD="admin123"
    fi
    return 0
}

# usage: skopeo-sync DIRECTORY
#
# Uploads a DIRECTORY of container images to the Nexus registry.
#
# Requires the following environment variables to be set:
#
#   NEXUS_REGISTRY - Hostname of Nexus registry; defaults to registry.local
#   SKOPEO_IMAGE - Image containing Skopeo tool; recommended to vendor with tag
#       specific to a product version
#
# If the NEXUS_PASSWORD environment variable is not set, attempts to set
# NEXUS_USERNAME and NEXUS_PASSWORD based on the nexus-admin-credential
# Kubernetes secret. Otherwise, the default Nexus admin credentials are used.
function skopeo-sync() {
    local src
    src="${1:-}"

    [[ -d "$src" ]] || return 0

    nexus-setdefault-credential
    # Note: Have to default NEXUS_USERNAME below since
    # nexus-setdefault-credential returns immediately if NEXUS_PASSWORD is set.
    podman run --rm "${podman_run_flags[@]}" \
        -v "$(realpath "$src"):/image:ro" \
        "$SKOPEO_IMAGE" \
        sync --scoped --src dir --dest docker \
        --dest-creds "${NEXUS_USERNAME:-}:${NEXUS_PASSWORD}" \
        --dest-tls-verify=false \
        /image "$NEXUS_REGISTRY"
}

# usage: nexus-setup (blobstores|repositories) CONFIG
#
# Sets up Nexus blob stores or repositories given CONFIG, a valid configuration
# YAML file where each document is valid HTTP POST data to the respective Nexus
# REST API:
#
# - Blob stores: /service/rest/v1/blobstores/<type>[/<name>]
# - Repositories: /service/rest/v1/repositories/<format>/<type>[/<name>]
#
# Requires the following environment variables to be set:
#
#   NEXUS_URL - Base Nexus URL; defaults to https://packages.local
#   CRAY_NEXUS_SETUP_IMAGE - Image containing Cray's Nexus setup tools;
#       recommended to vendor with tag specific to a product version
#
# If the NEXUS_PASSWORD environment variable is not set, attempts to set
# NEXUS_USERNAME and NEXUS_PASSWORD based on the nexus-admin-credential
# Kubernetes secret. Otherwise, the default Nexus admin credentials are used.
function nexus-setup() {
    local type
    local config
    type="${1:-}"
    config="${2:-}"
    if [ -z "$config" ]; then
        echo >&2 'No config file given!'
        return 1
    fi
    nexus-setdefault-credential
    "${LIB_DIR}/../nexus-setup/nexus-${type}-create.sh" "${config}"
    return $?
}

# usage: nexus-upload (helm|raw|yum) DIRECTORY REPOSITORY
#
# Uploads a DIRECTORY of assets to the specified Nexus REPOSITORY.
#
# The REPOSITORY must be of the specified format (i.e., helm, raw, yum) else
# the upload may not succeed or select the proper files under the given
# DIRECTORY.
#
# Requires the following environment variables to be set:
#
#   NEXUS_URL - Base Nexus URL; defaults to http://packages.local
#   CRAY_NEXUS_SETUP_IMAGE - Image containing Cray's Nexus setup tools;
#       recommended to vendor with tag specific to a product version
#
# If the NEXUS_PASSWORD environment variable is not set, attempts to set
# NEXUS_USERNAME and NEXUS_PASSWORD based on the nexus-admin-credential
# Kubernetes secret. Otherwise, the default Nexus admin credentials are used.
function nexus-upload() {
    local repotype
    local src
    local reponame

    repotype="${1:-}"
    src="${2:-}"
    reponame="${3:-}"

    if [ ! -d "$src" ]; then
        return 1
    fi

    nexus-setdefault-credential
    "${LIB_DIR}/../nexus-setup/nexus-upload-repo-${repotype}.sh" "${src}" "${reponame}"
    return $?
}

# usage: load-vendor-image TARFILE
#
# Loads a vendored container image TARFILE saved using "docker save" into
# podman's runtime to facilitate installation.
function load-vendor-image() {
    (
        set -o pipefail
        podman load -q -i "$1" 2>/dev/null | sed -e 's/^.*: //'
    )
}

declare -a vendor_images=()

# usage: load-install-deps
#
# Loads vendored images into podman's image storage to facilitate installation.
# Product install scripts should call this function before using any functions
# which use CRAY_NEXUS_SETUP_IMAGE or SKOPEO_IMAGE to interact with Nexus.
function load-install-deps() {

    if [[ -f "${LIB_DIR}/../vendor/skopeo.tar" ]]; then
        [[ -v SKOPEO_IMAGE ]] || SKOPEO_IMAGE="$(load-vendor-image "${LIB_DIR}/../vendor/skopeo.tar")" || return
        vendor_images+=( "$SKOPEO_IMAGE" )
    fi
}
