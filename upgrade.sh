#!/usr/bin/env sh

OLD_BRANCH=$1
OLD_COMMIT=$2
OLD_VERSION=$3
NEW_BRANCH=$4
NEW_COMMIT=$5
NEW_VERSION=$6

sed -i "s/$OLD_BRANCH/$NEW_BRANCH/g" Dockerfile
sed -i "s/$OLD_COMMIT/$NEW_COMMIT/g" Dockerfile
sed -i "s/moodle-$OLD_VERSION/moodle-$NEW_VERSION/g" README.md
