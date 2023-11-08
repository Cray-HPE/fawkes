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
LIB_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${LIB_DIR}/util.sh"

requires rsync podman yq parallel rpm sha256sum

yq_version="$(yq --version | awk '{print $NF}')"
if [[ "$yq_version" =~ '/^v3/' ]]; then
    echo >&2 'Must use yq version 4 or higher.'
    exit 1
fi

export SKOPEO_IMAGE='artifactory.algol60.net/csm-docker/stable/quay.io/skopeo/stable:v1'

if [ -z "${ARTIFACTORY_USER:-}" ] || [ -z "${ARTIFACTORY_TOKEN:-}" ]; then
    echo >&2 "Missing authentication information for image download. Please set ARTIFACTORY_USER and ARTIFACTORY_TOKEN environment variables."
    exit 1
fi

# usage: cache-internal-image IMAGE DIRECTORY
#
# Downloads a container IMAGE and writes it as an image archive into
# DIRECTORY.
function cache-internal-image {
    local image
    local destdir
    local workdir
    local creds=''
    image="${1#docker://}"
    destdir="${2#dir:}"
    echo >&2 "+ skopeo copy docker://${image} dir:${destdir}"

    # Sync to temporary working directory in case of error
    workdir="$(mktemp -d .skopeo-copy-XXXXXXX)"

    # Single quote this, WITH escapes, so the vars are calculated when the `trap` is created.
    trap 'rm -fr '"$workdir"'' ERR INT EXIT RETURN

    if [[ "${image}" == artifactory.algol60.net/* ]]; then
        creds="${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}"
    fi

    podman run --rm \
        -u "$(id -u):$(id -g)" \
        -v /var/run/docker.sock:/var/run/docker.sock \
        --mount "type=bind,source=$(realpath "$workdir"),destination=/data" \
        "$SKOPEO_IMAGE" \
        --command-timeout 60s \
        --override-os linux \
        --override-arch amd64 \
        copy \
        --retry-times 5 \
        ${creds:+--src-creds "${creds}"} \
        "docker://${image}" \
        dir:/data \
        >&2 || return 255

    # Ensure intermediate directories exist
    mkdir -p "$(dirname "${destdir}")"

    # Ensure destination directory is fresh, which is particularly important
    # if there was a previous run
    [[ -e "${destdir}" ]] && rm -fr "${destdir}"

    # Move image to destination directory
    mv "${workdir}" "${destdir}/"
}
export -f cache-internal-image

# usage: download-url-artifact URL DIRECTORY
#
# Downloads an artifact at URL and writes it into DIRECTORY.
function download-url-artifact {

    local arch=''
    local artifact
    local url
    local destdir
    local workdir

    url="${1#https://}"
    destdir="${2#dir:}"
    artifact="$(basename "$url")"

    # Sync to temporary working directory in case of error
    workdir="$(mktemp -d .curl-download-XXXXXXX)"

    if [[ "$artifact" =~ \.rpm$ ]]; then
        arch="$(basename "$(dirname "$url")")/"
        mkdir "${workdir}/${arch}"
    fi
    echo >&2 "+ curl https://${url} dir:${destdir}"

    # Single quote this, WITH escapes, so the vars are calculated when the `trap` is created.
    trap 'rm -fr '"$workdir"'' ERR INT EXIT RETURN

    # Enforce HTTPS.
    curl -Lf -o "${workdir}/$arch$artifact" "https://$url" || return $?

    # Ensure intermediate directories exist
    mkdir -p "${destdir}"

    # Move artifact to destination directory.
    rsync -rltDv "${workdir}/" "${destdir}/"

    return $?
}
export -f download-url-artifact

# usage: download-with-sha URL DIRECTORY
#
# Downloads an artifact along with its sha256sum, if the sha256sum does not match the downloaded artifact
# an error is raised.
function download-internal-with-sha() {

    local artifact
    local artifact_name
    local url
    local destdir
    local workdir
    local version

    url="${1#https://}"
    destdir="${2#dir:}"

    artifact="$(basename "$url")"
    artifact_name="$(basename "$(dirname "$(dirname "$url")")")"
    workdir="$(mktemp -d .curl-download-XXXXXXX)"

    # Single quote this, WITH escapes, so the vars are calculated when the `trap` is created.
    trap 'rm -fr '"$workdir"'' ERR INT EXIT RETURN

    if [[ "$url" =~ /\\\[RELEASE\\\]/ ]] ;then
        version="$(curl -s -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" "https://artifactory.algol60.net/artifactory/api/search/latestVersion?g=stable&a=${artifact_name}")"
        url="${url//\\\[RELEASE\\\]/$version}"
        artifact="${artifact//\\\[RELEASE\\\]/$version}"
    fi
    echo >&2 "+ curl https://$url dir:$destdir/${artifact_name}"

    curl -sfSLR -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" -o "${workdir}/${artifact}" "https://$url" || return $?
    curl -sfSLR -u "${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}" "https://${url/\/artifactory\//\/artifactory\/api\/storage\/}" | jq -r '.checksums.sha256' > "${workdir}/${artifact}.sha256.txt" || return $?
    if [ "$(cat "${workdir}/${artifact}.sha256.txt")" != "$(sha256sum "${workdir}/${artifact}" | awk '{ print $1 }')" ]; then
        echo "SHA256 checksum for downloaded ${artifact} is incorrect, file may have been corrupted in transit."
        return 1
    fi

    # Ensure the file name exists in the sha256sum.txt file for `sha256sum -c` to work properly.
    sed -i '/'"$artifact"'$/ ! s/$/ '"$artifact"'/' "${workdir}/${artifact}.sha256.txt"
    (
        cd "$workdir"
        sha256sum -c "${artifact}.sha256.txt"
    ) || return 1

    # Ensure intermediate directories exist
    mkdir -p "$destdir"

    # Move artifact to destination directory.
    mv "${workdir}" "${destdir}/${artifact_name}"

    return $?
}
export -f download-internal-with-sha

# usage: vendor-install-deps [--no-skopeo] RELEASE DIRECTORY
#
# Vendors installation tools for a specified RELEASE to the given DIRECTORY.
#
# Even though compatible tools may be available on the target system, vendoring
# them ensures sufficient versions are shipped.
function vendor-install-deps() {
    local include_skopeo=1
    local creds=''
    local destdir

    while [[ $# -gt 2 ]]; do
        local opt="$1"
        shift
        case "$opt" in
            --no-skopeo)
                include_skopeo=0
                ;;
            --)
                break
                ;;
            --*)
                echo >&2 "error: unsupported option: $opt"
                return 2
                ;;
            *)
                break
                ;;
        esac
    done

    creds="${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}"

    destdir="$1"

    [[ -d "$destdir" ]] || mkdir -p "$destdir"

    if [[ "${include_skopeo:-1}" -eq 1 ]]; then
        docker run --rm -u "$(id -u):$(id -g)" "${podman_run_flags[@]}" \
            ${DOCKER_NETWORK:+"--network=${DOCKER_NETWORK}"} \
            -v "$(realpath "$destdir"):/data" \
            "$SKOPEO_IMAGE" \
            copy \
            ${creds:+--src-creds "${creds}"} \
            "docker://${SKOPEO_IMAGE}" "docker-archive:/data/skopeo.tar:$(basename "$SKOPEO_IMAGE")"
        if [ ! -f "${destdir}/skopeo.tar" ]; then
            return 1
        fi
    fi

}

# usage: create-fake-conntrack
#
# On some distributions, like SUSE, the provided conntrack-tools RPM fails to
# satisfy the kubectl/kubelet/kubeadm dependency on conntrack.
# Despite conntrack-tools providing the correct files, it does not indicate that
# it provides the "conntrack" package that Kubernetes is looking for.
# This builds a fake conntrack RPM that installs conntrack-tools while stating the package
# "conntrack" is provided.
function create-fake-conntrack {
    local workdir
    local destdir

    destdir="${1}"
    workdir="$(mktemp -d .conntrack-XXXXXXX)"
    trap 'rm -fr '"$workdir"'' ERR INT EXIT RETURN

    echo "Building a custom local repository for conntrack dependency, pulls in conntrack-tools while mocking conntrack."
    rpmbuild -ba "$LIB_DIR/../hack/conntrack/conntrack.spec" --define "_rpmdir $workdir"
    rsync -rltDv "${workdir}/" "$destdir/"
}
