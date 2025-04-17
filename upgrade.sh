#!/usr/bin/env sh

sed -i "s/$OLD_BRANCH/$NEW_BRANCH/g" Dockerfile
sed -i "s/$OLD_COMMIT/$NEW_COMMIT/g" Dockerfile
sed -i "s/moodle-$OLD_VERSION/moodle-$NEW_VERSION/g" README.md
