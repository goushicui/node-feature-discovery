#!/bin/bash -e
set -o pipefail

this=`basename $0`

usage () {
cat << EOF
Usage: $this [-h] [-a] [SITE_SUBDIR]

Options:
  -h         show this help and exit
  -a         amend (with --reset-author) instead of creating a new commit
  -p REMOTE  do git push to remote repo
EOF
}

# Helper function for detecting available versions from the current directory
create_versions_js() {
    local _baseurl="/node-feature-discovery"

    echo -e "function getVersionListItems() {\n  return ["
    # 'stable' is a symlink pointing to the latest version
    [ -f stable ] && echo "    { name: 'stable', url: '$_baseurl/stable' },"
    for f in `ls -d */  | tr -d /` ; do
        echo "    { name: '$f', url: '$_baseurl/$f' },"
    done
    echo -e "  ];\n}"
}

#
# Argument parsing
#
while getopts "hap:" opt; do
    case $opt in
        h)  usage
            exit 0
            ;;
        a)  amend="--amend --reset-author"
            ;;
        p)  push_remote="$OPTARG"
            ;;
        *)  usage
            exit 1
            ;;
    esac
done
shift "$((OPTIND - 1))"

site_subdir="$1"

# Check that no extra args were provided
if [ $# -gt 1 ]; then
    echo "ERROR: extra positional arguments: $@"
    usage
    exit 1
fi

#
# Build the documentation
#
build_dir="docs/_site"
echo "Creating new Git worktree at $build_dir"
git worktree add "$build_dir" gh-pages

# Drop worktree on exit
trap "echo 'Removing Git worktree $build_dir'; git worktree remove '$build_dir'" EXIT

# Parse subdir name from GITHUB_REF
if [ -z "$site_subdir" ]; then
    case "$GITHUB_REF" in
        refs/tags/*)
            _base_ref=${GITHUB_REF#refs/tags/}
            ;;
        refs/heads/*)
            _base_ref=${GITHUB_REF#refs/heads/}
            ;;
        *) _base_ref=
    esac
    echo "Parsed baseref: '$_base_ref'"

    case "$GITHUB_REF" in
        refs/tags/v*)
            _version=${GITHUB_REF#refs/tags/v}
            ;;
        refs/heads/release-*)
            _version=${GITHUB_REF#refs/heads/release-}
            ;;
        *) _version=
    esac
    echo "Detected version: '$_version'"

    _version=`echo -n $_version | sed -nE s'!^([0-9]+\.[0-9]+).*$!\1!p'`

    # User version as the subdir
    site_subdir=${_version:+v$_version}
    # Fallback to base-ref i.e. name of the branch or tag
    site_subdir=${site_subdir:-$_base_ref}
fi

# Default to 'master' if no subdir was given and we couldn't parse
# it
export SITE_SUBDIR=${site_subdir:-master}
echo "Updating site subdir: '$SITE_SUBDIR'"

export JEKYLL_ENV=production
make site-build

#
# Update gh-pages branch
#
if [ -n "$_GIT_TAG" ]; then
    commit_hash=${GIT_TAG:10}
else
    commit_hash=`git describe --dirty --always`
fi

# Switch to work in the gh-pages worktree
cd "$build_dir"

_stable=`(ls -d1 v*/ || :) | sort -n | tail -n1`
[ -n "$_stable" ] && ln -sfT "$_stable" stable

# Detect existing versions from the gh-pages branch
create_versions_js > versions.js

if [ -z "`git status --short`" ]; then
    echo "No new content, gh-pages branch already up-to-date"
    exit 0
fi

# Create a new commit
commit_msg=`echo -e "Update documentation for $SITE_SUBDIR\n\nAuto-generated from $commit_hash by '$this'"`

echo "Committing changes..."
git add .
git commit $amend -m "$commit_msg"

cd -

echo "gh-pages branch successfully updated"

if [ -n "$push_remote" ]; then
    echo "Pushing gh-pages to $push_remote"
    git push ${amend+-f} "$push_remote" gh-pages
fi
