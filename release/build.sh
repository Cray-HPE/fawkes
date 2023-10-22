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

RELEASE_DIR="$(dirname "${BASH_SOURCE[0]}")"

if ! command -v podman >/dev/null 2>&1 ; then
    export USE_DOCKER_NOT_PODMAN=yes
fi

source "${RELEASE_DIR}/lib/build.sh"

requires parallel tar xz

set -x
RELEASE_VERSION="${RELEASE_VERSION:-"$(version)"}"
KEEP_BUILD_DIR="${KEEP_BUILD_DIR:-0}"
BUILD_DIR="$(mktemp -d)"
trap '[ -d "$BUILD_DIR" ] && [ "$KEEP_BUILD_DIR" -eq 0 ] && rm -rf "${BUILD_DIR}"' EXIT ERR INT
set +x
# Download binaries.
"${RELEASE_DIR}/list-index.py" binaries | \
    parallel -j 75% --bar --halt-on-error now,fail=1 -v download-url-artifact {} "$BUILD_DIR/binaries"

# Download container images.
"${RELEASE_DIR}/list-index.py" docker | \
    parallel -j 75% --bar --halt-on-error now,fail=1 -v cache-internal-image {} "$BUILD_DIR/docker/{}"

# Download OS images.
"${RELEASE_DIR}/list-index.py" images | \
    parallel -j 75% --bar --halt-on-error now,fail=1 -v download-internal-with-sha {} "$BUILD_DIR/images"

# Download RPMs.
for rpm in rpm/*; do
"${RELEASE_DIR}/list-index.py" "$rpm" | \
    parallel -j 75% --bar --halt-on-error now,fail=1 -v download-url-artifact "https://${ARTIFACTORY_USER}:${ARTIFACTORY_TOKEN}@{}" "$BUILD_DIR/$rpm"
done
create-fake-conntrack "$BUILD_DIR/rpm/noos"

# Generate and add web docs.
# FIXME: These don't work correctly in apache2.
# FIXME: Build environment needs ruby2.7 or higher for asciidoctor-pdf, this is commented out until that can be achieved.
#ROOT_DIR="$RELEASE_DIR/../"
#(
#    cd "$ROOT_DIR"
#    make docs
#    cp -pr build "${BUILD_DIR}/docs"
#)

# Add shell code.
cp -vpr "${RELEASE_DIR}/lib" "$BUILD_DIR"
cp -vpr "${RELEASE_DIR}/nexus-setup" "$BUILD_DIR"
cp -vp "${RELEASE_DIR}/upload.sh" "$BUILD_DIR"

# Add release docs.
cp -vp "${RELEASE_DIR}/README.md" "$BUILD_DIR/"

# Add nexus manifests.
cp -vp nexus-*.yml "$BUILD_DIR/"
sed -i'' 's/0\.0\.0/'"$RELEASE_VERSION"'/g' "${BUILD_DIR}/nexus-repositories.yml"

# Download HPE GPG signing key (for verifying signed RPMs)
mkdir -p "${BUILD_DIR}/security" && curl -sfSLRo "${BUILD_DIR}/security/hpe-signing-key.asc" "https://arti.hpc.amslabs.hpecorp.net/artifactory/dst-misc-stable-local/SigningKeys/HPE-SHASTA-RPM-PROD.asc"

# Save quay.io/skopeo/stable images for use in upload.sh
if [ -n "${DIND_USER_HOME:-}" ]; then
    mkdir -p "${DIND_USER_HOME}/vendor"
    vendor-install-deps "${DIND_USER_HOME}/vendor"
    rsync -rltDv "${DIND_USER_HOME}/vendor" "${BUILD_DIR}"
else
    vendor-install-deps "${BUILD_DIR}/vendor"
fi

# Generate the tar.
rm -rf "${RELEASE_DIR}/dist" && mkdir "${RELEASE_DIR}/dist"

# Single quote this, without escapes, so the vars are calculated when the `trap` runs.
trap '[ -d "$RELEASE_DIR/dist" ] && [ "$KEEP_BUILD_DIR" -eq 0 ] && rm -rf "$RELEASE_DIR/dist"' ERR INT

# Name the build directory.
mv "$BUILD_DIR" "${RELEASE_DIR}/dist/fawkes-${RELEASE_VERSION}"
chmod 755 "${RELEASE_DIR}/dist/fawkes-${RELEASE_VERSION}"

(
cd "${RELEASE_DIR}/dist"
kernel="$(uname -s)"
find "fawkes-$RELEASE_VERSION" -type d -exec chmod 755 {} \;
if [ "$kernel" == Linux ]; then
    tar --no-xattrs -czvf "fawkes-$RELEASE_VERSION.tar.gz" "fawkes-$RELEASE_VERSION/"
elif [ "$kernel" == Darwin ]; then
    tar --disable-copyfile --no-xattrs -czvf "fawkes-$RELEASE_VERSION.tar.gz" "fawkes-$RELEASE_VERSION/"
fi
)
rm -rf "${RELEASE_DIR}/dist/fawkes-${RELEASE_VERSION}"

echo 'Done.'
