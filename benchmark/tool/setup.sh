#!/usr/bin/env bash
# Fetches the baselines next to this repo's package (`..`):
#
#   third_party/get_storage           jonataslaw/get_storage
#   third_party/get_secure_storage_gslender
#                                     gslender/get_secure_storage
#   third_party/get_secure_storage_fork_v1
#                                     the BOOFI copy with the first write-path
#                                     changes (FORK_PATH)
#
# The secure packages are renamed so they can share one pubspec.
set -euo pipefail

cd "$(dirname "$0")/.."
FORK_PATH="${FORK_PATH:-../../../BOOFI/Application/boofi/packages/get_secure_storage}"

mkdir -p third_party
cd third_party

if [ ! -d get_storage ]; then
  git clone --depth 1 https://github.com/jonataslaw/get_storage get_storage
  # master targets get 5, where Value.value is non-nullable. The secure
  # packages resolve get 4.7.x, where it is nullable, so add `!` to the six
  # uses. subject.value is always initialised, so behaviour is unchanged.
  sed -i '' -E \
    -e 's/\.\.value\.(clear|remove)\(/..value!.\1(/' \
    -e 's/\.\.value\[key\]/..value![key]/' \
    -e 's/subject\.value\[key\]/subject.value![key]/' \
    -e 's/subject\.value\.(keys|values)/subject.value!.\1/' \
    get_storage/lib/src/storage/io.dart
fi

if [ ! -d get_secure_storage_gslender ]; then
  git clone --depth 1 https://github.com/gslender/get_secure_storage get_secure_storage_gslender
  cd get_secure_storage_gslender
  sed -i '' 's/^name: get_secure_storage$/name: get_secure_storage_gslender/' pubspec.yaml
  grep -rl 'package:get_secure_storage/' lib | xargs sed -i '' 's#package:get_secure_storage/#package:get_secure_storage_gslender/#g'
  # Its example/ and test/ still import the old name; they are not used here.
  rm -rf example test
  cd ..
fi

cd ..
if [ ! -d third_party/get_secure_storage_fork_v1 ]; then
  if [ ! -f "$FORK_PATH/pubspec.yaml" ]; then
    echo "Fork v1 not found at $FORK_PATH (set FORK_PATH)" >&2
    exit 1
  fi
  mkdir -p third_party/get_secure_storage_fork_v1
  cp -R "$FORK_PATH/lib" "$FORK_PATH/pubspec.yaml" third_party/get_secure_storage_fork_v1/
  cd third_party/get_secure_storage_fork_v1
  sed -i '' 's/^name: get_secure_storage$/name: get_secure_storage_fork_v1/' pubspec.yaml
  grep -rl 'package:get_secure_storage/' lib | xargs sed -i '' 's#package:get_secure_storage/#package:get_secure_storage_fork_v1/#g'
  cd ../..
fi

for d in third_party/get_storage third_party/get_secure_storage_gslender; do
  echo "$d @ $(git -C "$d" rev-parse --short HEAD)"
done
flutter pub get
