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

ROOT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "${ROOT_DIR}/lib/install.sh"

RELEASE_VERSION="${RELEASE_VERSION:-"$(basename "$(pwd)")"}"
requires apachectl bsdtar curl

WEB_ROOT="$(apachectl -S 2>/dev/null | awk '/ServerRoot/{print $NF}' | tr -d '"')"
if [ -z "${WEB_ROOT}" ] || [ ! -d "${WEB_ROOT}" ]; then
    echo >&2 "WEB_ROOT was detected as [$WEB_ROOT] but it does not exist. Web server is not properly configured! Docs will not be copied."
else
    if [ -d "${ROOT_DIR}/docs" ]; then
        rsync -rltDv "${ROOT_DIR}/docs" "${WEB_ROOT}"
    else
        echo >&2 'Docs were not present in the local tar and will not be copied into place.'
    fi
fi

if [ "${1:-}" = 'docs-only' ]; then
    echo 'Done - docs-only.'
    exit 0
fi

# Create blobstores and repositories.
nexus-setup blobstores   "${ROOT_DIR}/nexus-blobstores.yml"
nexus-setup repositories "${ROOT_DIR}/nexus-repositories.yml"

# Upload binaries.
nexus-upload raw "${ROOT_DIR}/binaries" "fawkes-${RELEASE_VERSION/fawkes-/}-third-party"

# Upload RPMs.
nexus-upload yum "${ROOT_DIR}/rpm/noos" "fawkes-${RELEASE_VERSION/fawkes-/}-noos"
nexus-upload yum "${ROOT_DIR}/rpm/sle-15sp4" "fawkes-${RELEASE_VERSION/fawkes-/}-sle-15sp4"
nexus-upload yum "${ROOT_DIR}/rpm/sle-15sp5" "fawkes-${RELEASE_VERSION/fawkes-/}-sle-15sp5"

(
cd "${ROOT_DIR}/images/hypervisor"
find ./ -name "*.iso" -exec bsdtar -xf {} "*kernel" "*initrd.img.xz" \;
find ./ -name "*.iso" -exec ln -snf ./{} hypervisor-x86_64.iso \;
)

# Upload images.
nexus-upload raw "${ROOT_DIR}/images" "fawkes-${RELEASE_VERSION/fawkes-/}-images"

# Upload container images.
load-install-deps
skopeo-sync "${ROOT_DIR}/docker"

echo 'Done.'
