#!/usr/bin/env python3
#
# MIT License
#
# (C) Copyright 2021-2023 Hewlett Packard Enterprise Development LP
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
import inspect
import argparse
import os.path
import pathlib
import sys
from pathlib import Path
import yaml

filename = inspect.getframeinfo(inspect.currentframe()).filename


def binaries(index: dict) -> list:
    """Prints binary artifact URLs."""
    for url, v in index.items():
        if 'projects' not in v:
            continue
        for project, r in v['projects'].items():
            for release, artifacts in r['releases'].items():
                for artifact in artifacts:
                    yield (f'{url}/{project}/releases/download/{release}/'
                           f'{artifact}')


def docker(index: dict) -> list:
    """Prints docker container artifact URLs."""
    for url, v in index.items():
        if 'images' not in v:
            continue
        for name, tags in v['images'].items():
            for t in tags:
                yield f'{url}/{name}:{t}'


def images(index: dict) -> list:
    """Prints image artifact URLs."""
    for url, v in index.items():
        if 'artifacts' not in v:
            continue
        for name, meta in v['artifacts'].items():
            if 'mediums' not in meta:
                continue
            if 'release' not in meta:
                release = 'latest'
            else:
                release = meta['release']
            if release == 'latest':
                release = "\\[RELEASE\\]"
            if 'arches' not in meta:
                meta['arches'] = ['x86_64']
            for arch in meta['arches']:
                for medium in meta['mediums']:
                    yield (f'{url}/{name}/{release}/{name}-{release}-{arch}.'
                           f'{medium}')


def rpms(index: dict) -> list:
    """Prints RPM artifact URLs."""
    for url, v in index.items():
        if 'rpms' not in v:
            continue
        for name in v['rpms']:
            repository = os.path.dirname(name)
            package = os.path.basename(name)
            _, arch = os.path.splitext(name)
            yield f'{url}/{repository}/{arch.replace(".", "")}/{package}.rpm'


def main():

    parser = argparse.ArgumentParser()
    parser.add_argument(
        'medium',
        help='Type of manifest to load.',
        nargs='?',
        type=str,
        default=None,
    )
    args = parser.parse_args()

    if args.medium is None:
        sys.exit(1)

    index_file = Path(filename).parent / f'{args.medium}/index.yml'

    try:
        with open(index_file) as i:
            index = yaml.safe_load(i)
    except OSError as error:
        print(f'Failed to open index file: {error.filename}')
        sys.exit(1)

    if args.medium == 'binaries':
        for binary in binaries(index):
            print(binary)
    elif args.medium == 'docker':
        for image in docker(index):
            print(image)
    elif args.medium == 'images':
        for image in images(index):
            print(image)
    elif args.medium.startswith('rpm/'):
        for rpm in rpms(index):
            print(rpm)
    else:
        print(f'No case for {args.medium}.')
        sys.exit(1)


if __name__ == '__main__':
    main()
