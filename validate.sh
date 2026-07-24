#!/usr/bin/env bash
set -euo pipefail

SANDBOX_NAME="${1:-agent-sandbox}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_AGENTS="$SCRIPT_DIR/kit/files/home/.codex/AGENTS.md"

sbx exec "$SANDBOX_NAME" bash -lc '
set -euo pipefail

test "$(id -un)" = agent
test -f "$HOME/.codex/AGENTS.md"
test -f "$HOME/.gitconfig"
test -f "$HOME/.ssh/allowed_signers"
test -n "$(git config --global user.name)"
test -n "$(git config --global user.email)"
test "$(git config --global gpg.format)" = ssh
case "$(git config --global user.signingkey)" in
  key::ssh-*) ;;
  *) exit 1 ;;
esac
test "$(git config --global commit.gpgsign)" = true
test "$(git config --global tag.gpgsign)" = true
test "$(git config --global --path gpg.ssh.allowedSignersFile)" = "$HOME/.ssh/allowed_signers"

command -v brew
command -v bwrap
command -v gcc
command -v make
command -v aws
command -v go
command -v hugo
command -v nvm
command -v node
command -v npm
command -v codex

brew --version
bwrap --version
gcc --version | head -n 1
aws --version
test -n "$USER_DIR"
test -n "${SSH_AUTH_SOCK:-}"
test -S "$SSH_AUTH_SOCK"
ssh-add -L >/dev/null
test "${GIT_ASKPASS:-}" = /bin/false
test "${SSH_ASKPASS:-}" = /bin/false
test "${GIT_SSH_COMMAND:-}" = "ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"
git config --system --get-all url.ssh://git@github.com/.insteadOf | grep -Fx https://github.com/
git config --system --get-all url.ssh://git@github.com/.insteadOf | grep -Fx http://github.com/
git config --system --get-all url.ssh://git@github.com/.insteadOf | grep -Fx git://github.com/
test "$AWS_CONFIG_FILE" = "$USER_DIR/.aws-sandbox/config"
test "$AWS_SHARED_CREDENTIALS_FILE" = "$USER_DIR/.aws-sandbox/credentials"
test "$AWS_PROFILE" = sandbox
test -r "$AWS_CONFIG_FILE"
test -r "$AWS_SHARED_CREDENTIALS_FILE"
test "$(aws configure list-profiles)" = sandbox
go version
hugo version
nvm --version
node --version
npm --version
codex --version

# The signed commit is created in a throwaway repo under /tmp and removed when
# this validation shell exits, so validation never mutates the mounted project.
tmpdir="$(mktemp -d)"
trap '\''rm -rf "$tmpdir"'\'' EXIT
git -C "$tmpdir" init -q
git -C "$tmpdir" config user.name "$(git config --global user.name)"
git -C "$tmpdir" config user.email "$(git config --global user.email)"
git -C "$tmpdir" config gpg.format ssh
git -C "$tmpdir" config user.signingkey "$(git config --global user.signingkey)"
git -C "$tmpdir" config commit.gpgsign true
git -C "$tmpdir" config gpg.ssh.allowedSignersFile "$HOME/.ssh/allowed_signers"
git -C "$tmpdir" commit --allow-empty -S -m "test: verify ssh signing"
git -C "$tmpdir" log --show-signature -1 | grep -F "Good \"git\" signature"
'

EXPECTED_HASH="$(shasum -a 256 "$EXPECTED_AGENTS" | awk '{print $1}')"
ACTUAL_HASH="$(sbx exec "$SANDBOX_NAME" shasum -a 256 /home/agent/.codex/AGENTS.md | awk '{print $1}')"
test "$EXPECTED_HASH" = "$ACTUAL_HASH"

EXPECTED_ALLOWED_SIGNERS="$SCRIPT_DIR/kit/files/home/.ssh/allowed_signers"
EXPECTED_ALLOWED_SIGNERS_HASH="$(shasum -a 256 "$EXPECTED_ALLOWED_SIGNERS" | awk '{print $1}')"
ACTUAL_ALLOWED_SIGNERS_HASH="$(sbx exec "$SANDBOX_NAME" shasum -a 256 /home/agent/.ssh/allowed_signers | awk '{print $1}')"
test "$EXPECTED_ALLOWED_SIGNERS_HASH" = "$ACTUAL_ALLOWED_SIGNERS_HASH"

test "$(sbx settings get clipboard.imagePaste)" = true
