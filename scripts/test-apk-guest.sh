#!/bin/sh
# Run inside a disposable guest with the release repository at the given path.
set -e
repository=${1:?usage: test-apk-guest.sh LOCAL_REPOSITORY}
test -s "$repository/x86_64/APKINDEX.tar.gz"
mkdir -p /etc/apk/keys
cp "$repository"/keys/*.pub /etc/apk/keys/
apk --no-network --repositories-file /dev/null --repository "$repository" update
apk --no-network --repositories-file /dev/null list --installed
apk --no-network --repositories-file /dev/null --repository "$repository" add --simulate zsh
apk --no-network --repositories-file /dev/null --repository "$repository" add zsh
apk --no-network --repositories-file /dev/null list --installed zsh-nommu
test -x /bin/zsh
/bin/zsh -f -c 'print APK_ZSH_EXEC_PASS'
echo APK_GUEST_INSTALL_PASS
