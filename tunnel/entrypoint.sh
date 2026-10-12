#!/bin/sh
# Forwards port 11434 of this container to Ollama on the server.
set -eu

: "${SSH_HOST:?SSH_HOST is not set}"
: "${REMOTE_PORT:=11434}"

# ssh refuses config and keys owned by another user, which is what a bind
# mount looks like under rootful Docker. Work from a private copy.
rm -rf /root/.ssh
cp -rL /host-ssh /root/.ssh
chown -R root:root /root/.ssh
chmod -R go-rwx /root/.ssh

exec ssh -N \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o StrictHostKeyChecking=yes \
  -L "0.0.0.0:11434:127.0.0.1:${REMOTE_PORT}" \
  "$SSH_HOST"
