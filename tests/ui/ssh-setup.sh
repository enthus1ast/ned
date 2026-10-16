#!/bin/bash
# ssh-setup.sh — the SSH server the remote-folder tests talk to: sshd on 127.0.0.1:2222, and three hosts added to
# ~/.ssh/config: devbox (you, with a key), devboxpw (a key whose passphrase is s3cretpass) and fishbox (you again,
# under a second user name whose login shell is fish — made with sudo when fish is installed).
# Meant for CI or a throwaway machine: it changes ~/.ssh/config. Then run the tests with NED_TEST_SSH=1.
set -e
D=${NED_SSHD_DIR:-/tmp/ned-sshd}
mkdir -p "$D" ~/.ssh
chmod 700 ~/.ssh
SSHD=$(command -v sshd || echo /usr/sbin/sshd)
[ -f "$D/host_key" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/host_key"
[ -f "$D/id" ] || ssh-keygen -q -t ed25519 -N '' -f "$D/id"
[ -f "$D/id_pw" ] || ssh-keygen -q -t ed25519 -N 's3cretpass' -f "$D/id_pw"
cat "$D/id.pub" "$D/id_pw.pub" > "$D/authorized_keys"
chmod 600 "$D/authorized_keys"
cat > "$D/sshd_config" <<EOT
Port 2222
ListenAddress 127.0.0.1
HostKey $D/host_key
PubkeyAuthentication yes
PasswordAuthentication no
AuthorizedKeysFile $D/authorized_keys
StrictModes no
UsePAM no
PidFile $D/sshd.pid
EOT
me=$(id -un)
fishuser=$me
if command -v fish > /dev/null; then
  if ! getent passwd nedfish > /dev/null; then
    sudo useradd -o -u "$(id -u)" -g "$(id -g)" -d "$HOME" -M -s "$(command -v fish)" nedfish || true
  fi
  getent passwd nedfish > /dev/null && fishuser=nedfish
fi
if [ "$(id -u)" = 0 ]; then "$SSHD" -f "$D/sshd_config" -E "$D/sshd.log"
else sudo "$SSHD" -f "$D/sshd_config" -E "$D/sshd.log"; fi
for h in devbox devboxpw fishbox; do
  grep -q "^Host $h\$" ~/.ssh/config 2>/dev/null && { echo "~/.ssh/config already has $h"; continue; }
  key=$D/id; user=$me; extra=""
  [ $h = devboxpw ] && key=$D/id_pw
  [ $h = fishbox ] && user=$fishuser
  printf 'Host %s\n  HostName 127.0.0.1\n  Port 2222\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n  UserKnownHostsFile %s/known_hosts\n\n' \
    $h "$user" "$key" "$D" >> ~/.ssh/config
done
chmod 600 ~/.ssh/config
ssh -o BatchMode=yes devbox true && echo "ok: ssh devbox works — run the tests with NED_TEST_SSH=1"
