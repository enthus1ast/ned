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
# A locked account cannot log in over SSH, even with a key.
sudo=()
if [ "$(id -u)" != 0 ]; then sudo=(sudo); fi
for user in "$me" "$fishuser"; do
  if "${sudo[@]}" passwd -S "$user" | grep -q ' L '; then
    hash=$(openssl rand -base64 32 | openssl passwd -6 -stdin)
    "${sudo[@]}" usermod -p "$hash" "$user"
  fi
done
# (sshd will not start without its privilege separation folder, which a machine whose ssh service has never run — a
# fresh CI runner — may not have yet)
if [ "$(id -u)" = 0 ]; then mkdir -p /run/sshd && chmod 755 /run/sshd; "$SSHD" -f "$D/sshd_config" -E "$D/sshd.log"
else sudo mkdir -p /run/sshd && sudo chmod 755 /run/sshd; sudo "$SSHD" -f "$D/sshd_config" -E "$D/sshd.log"; fi
for h in devbox devboxpw fishbox; do
  grep -q "^Host $h\$" ~/.ssh/config 2>/dev/null && { echo "~/.ssh/config already has $h"; continue; }
  key=$D/id; user=$me; extra=""
  [ $h = devboxpw ] && key=$D/id_pw
  [ $h = fishbox ] && user=$fishuser
  printf 'Host %s\n  HostName 127.0.0.1\n  Port 2222\n  User %s\n  IdentityFile %s\n  IdentitiesOnly yes\n  StrictHostKeyChecking no\n  UserKnownHostsFile %s/known_hosts\n\n' \
    $h "$user" "$key" "$D" >> ~/.ssh/config
done
chmod 600 ~/.ssh/config
if ssh -o BatchMode=yes -o ConnectTimeout=10 devbox true; then
  echo "ok: ssh devbox works — run the tests with NED_TEST_SSH=1"
else
  echo "ssh devbox does not work — what sshd said ($D/sshd.log):" >&2
  cat "$D/sshd.log" >&2 2>/dev/null || sudo cat "$D/sshd.log" >&2
  exit 1
fi
