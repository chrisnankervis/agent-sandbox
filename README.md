# Agent Sandbox

This repository builds a reusable [Docker Sandbox](https://docs.docker.com/ai/sandboxes/customize/) for running Codex with more autonomy without giving it the same administrative scope as the host user. It puts the agent behind Docker Sandbox's microVM isolation, mounts only the intended workspace and credentials, and still provides the tools needed for real development work. The goal is to give Codex enough freedom to be useful but with a tighter boundary around the files, credentials, and host state it can reach.

## How It Works

This repository combines a [Template](https://docs.docker.com/ai/sandboxes/customize/templates/) with a thin [Kit](https://docs.docker.com/ai/sandboxes/customize/kits/):

- `Dockerfile` extends the [Codex base image](https://docs.docker.com/ai/sandboxes/agents/codex/#base-image) and installs the durable tools and runtimes used across projects, so Docker can cache the heavier environment layers and new sandboxes start from a known baseline.
- `kit/` uses the [kit specification](https://docs.docker.com/ai/sandboxes/customize/kit-reference/) for creation-time customization, such as injecting a snapshot of the host's global Codex instructions into `/home/agent/.codex/AGENTS.md`.
- `validate.sh` checks that the expected tools and configuration are present in the created sandbox.

The template carries the stable base environment, while the kit carries lighter personal or sandbox-specific configuration that should be applied when the sandbox is created.

### What's Included

| Group | Tools | Notes |
| --- | --- | --- |
| Package Managers | `homebrew`, `build-essential`, `bubblewrap` | `build-essential` and `bubblewrap` are Homebrew's recommended Linux dependencies. |
| Runtimes | `nvm`, `node` | Node.js is installed as the current LTS release via NVM. |
| Development Tools | `openssh-client` | Provides the SSH transport and signing support Git needs to use Docker Sandbox's forwarded SSH agent. |
| Development Tools | `awscli` | Installed via Homebrew for AWS access from the sandbox. |
| Development Tools | `go` | Installed via Homebrew for Go development. |
| Development Tools | `hugo` | Installed via Homebrew for static site work. |

## Security Considerations

- `PROJECT_DIR` is mounted read-write. Codex can read, modify, and delete files within that directory.
- The host path supplied as `USER_DIR` is stored in the locally built image's metadata. Do not publish the image if that path is considered sensitive.
- Git operations and commit signing use the host's forwarded SSH agent when `SSH_AUTH_SOCK` is available. Private SSH keys remain on the host.
  - Commits are signed with a dedicated SSH signing key configured in Git. The sandbox receives the public key in Git config and an `allowed_signers` file for local verification, but the private signing key remains in the host SSH agent.
  - `openssh-client` is installed and GitHub HTTPS, HTTP, and Git protocol remotes are rewritten to SSH in the sandbox's system Git config. This prevents HTTPS credential prompts from tools such as Homebrew, NVM, and Codex plugin sync from appearing inside the Codex conversation window, stealing focus, and making keyboard input unreliable, while still keeping credentials in the forwarded host agent.
  - A GitHub personal access token is optional. It is only needed for tools such as `gh` that access the GitHub API; `gh` is not currently bundled with this template.
- `$USER_DIR/.aws-sandbox` is mounted read-only, so Codex can read its AWS credentials but cannot modify the host files.
  - Users are expected to create separate, least-privilege credentials for the sandbox and store them as the directory's only profile, named `sandbox`
  - Do not reuse or expose the host's complete `~/.aws` directory.
- Removing and recreating the sandbox deletes its VM-local files, configuration, command history, and Codex conversation history. Mounted project files remain on the host.

## Setup

### 1. Install the Prerequisites

- Install and start Docker Desktop.
- Install `sbx` v0.35.0 or newer and authenticate it.
- Ensure local kits are enabled. They are enabled by default in current `sbx` releases.

Run the remaining commands from the root of this repository.

### 2. Configure Docker Sandboxes

Enable clipboard image pasting:

```bash
sbx settings set clipboard.imagePaste true
```

> [!WARNING]
> Docker documents this as enabling Codex image paste, but the current base image
> runs Codex 0.142.4 and may still fail with an X11 clipboard timeout. Wait for
> upstream Codex support before relying on it.

If Git is configured through SSH on the host, no GitHub secret is required for normal Git operations. Docker Sandboxes forwards the host SSH agent when `SSH_AUTH_SOCK` is set.

To use `gh` or other GitHub API clients, optionally register the token already managed by the host GitHub CLI:

```bash
gh auth token | sbx secret set -g github
```

### 3. Set the Host Paths

Set these variables in the shell used to prepare, build, create, and validate the sandbox:

```bash
export USER_DIR="$HOME"
export PROJECT_DIR="$HOME/Code"
```

`USER_DIR` contains the host's `.codex` and `.aws-sandbox` directories. `PROJECT_DIR` is the workspace exposed to Codex. Re-export both variables when continuing from a new shell.

### 4. Prepare the AWS Profile

AWS is not an `sbx secret` service. AWS authentication can require an access key ID, secret access key, and session token rather than a single bearer token.

Create a dedicated directory containing only a profile named `sandbox`:

```text
$USER_DIR/.aws-sandbox/
├── config
└── credentials
```

If the host's existing `.aws` directory already contains only the profile that will be used by Codex, copy the two configuration files and rename the copied profile to `sandbox`. The resulting files should follow this shape:

```ini
# $USER_DIR/.aws-sandbox/config
[profile sandbox]
region = your-region
output = json
```

```ini
# $USER_DIR/.aws-sandbox/credentials
[sandbox]
aws_access_key_id = ...
aws_secret_access_key = ...
```

### 5. Prepare SSH Commit Signing

Create a dedicated SSH key for commit signing if one does not already exist:

```bash
ssh-keygen -t ed25519 -C "$(git config --global user.email) signing" -f "$USER_DIR/.ssh/id_ed25519_signing"
ssh-add "$USER_DIR/.ssh/id_ed25519_signing"
```

Register the public key with GitHub as an SSH signing key:

```bash
cat "$USER_DIR/.ssh/id_ed25519_signing.pub"
```

In GitHub, add it under Settings → SSH and GPG Keys → New SSH Key, with the key type set to Signing Key.

If the key already exists, make sure it is loaded in the host SSH agent:

```bash
ssh-add "$USER_DIR/.ssh/id_ed25519_signing"
```

### 6. Prepare the Codex Kit

The kit carries three pieces of personal configuration into the sandbox:

- The host's global Codex instructions.
- The name, email, and SSH signing settings from the host's global Git configuration.
- The public SSH signing key in an `allowed_signers` file so Git can verify SSH signatures locally.

Prepare the files and validate the kit:

```bash
cp "$USER_DIR/.codex/AGENTS.md" kit/files/home/.codex/AGENTS.md
test -n "$(git config --global user.name)"
test -n "$(git config --global user.email)"
SIGNING_KEY="$(cat "$USER_DIR/.ssh/id_ed25519_signing.pub")"
test -n "$SIGNING_KEY"
git config --file kit/files/home/.gitconfig user.name "$(git config --global user.name)"
git config --file kit/files/home/.gitconfig user.email "$(git config --global user.email)"
git config --file kit/files/home/.gitconfig gpg.format ssh
git config --file kit/files/home/.gitconfig user.signingkey "key::$SIGNING_KEY"
git config --file kit/files/home/.gitconfig commit.gpgsign true
git config --file kit/files/home/.gitconfig tag.gpgsign true
git config --file kit/files/home/.gitconfig gpg.ssh.allowedSignersFile /home/agent/.ssh/allowed_signers
mkdir -p kit/files/home/.ssh
printf "%s %s\n" "$(git config --global user.email)" "$SIGNING_KEY" > kit/files/home/.ssh/allowed_signers
sbx kit validate ./kit
```

| Configuration | Host Source | Prepared Kit File | Sandbox Destination |
| --- | --- | --- | --- |
| Codex Instructions | `$USER_DIR/.codex/AGENTS.md` | `kit/files/home/.codex/AGENTS.md` | `/home/agent/.codex/AGENTS.md` |
| Git Identity | Global `user.name` and `user.email` | `kit/files/home/.gitconfig` | `/home/agent/.gitconfig` |
| SSH Signing | `$USER_DIR/.ssh/id_ed25519_signing.pub` | `kit/files/home/.gitconfig` and `kit/files/home/.ssh/allowed_signers` | `/home/agent/.gitconfig` and `/home/agent/.ssh/allowed_signers` |

The prepared files contain personal configuration and are intentionally ignored by Git. Neither exists in a fresh clone, and preparing the kit does not make them eligible for a commit.

These files are snapshots, not live links. Changes on the host do not update the kit, and preparing the kit again does not update an existing sandbox. Repeat these commands and recreate the sandbox to apply changes.

### 7. Build and Load the Template

Build the Codex-derived image with Docker Desktop:

```bash
docker build \
  --build-arg USER_DIR="$USER_DIR" \
  -t agent-sandbox-template:latest \
  .
```

Docker Sandboxes has a separate image store from Docker Desktop. Export the image to a temporary archive and load it:

```bash
docker image save agent-sandbox-template:latest \
  -o /tmp/agent-sandbox-template.tar
sbx template load /tmp/agent-sandbox-template.tar
```

Delete the transfer archive after it loads successfully:

```bash
rm /tmp/agent-sandbox-template.tar
```

### 8. Create the Sandbox

> [!WARNING]
> Replacing an existing sandbox deletes its Codex conversation history and anything created outside of `$PROJECT_DIR`. Finish or record anything needed from existing conversations before removing it.

```bash
sbx create \
  --name agent-sandbox \
  --template agent-sandbox-template:latest \
  --kit ./kit \
  codex \
  "$PROJECT_DIR" \
  "$USER_DIR/.aws-sandbox:ro"
```

The AWS mount is read-only and the template selects the `sandbox` profile through `AWS_CONFIG_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, and `AWS_PROFILE`.

### 9. Validate the Sandbox

```bash
./validate.sh agent-sandbox
```

### 10. Run Codex

```bash
sbx run --name agent-sandbox
```
