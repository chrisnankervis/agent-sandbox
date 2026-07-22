# Agent Sandbox

This repository is an attempt to make it safer to run Codex autonomously in “YOLO mode” by placing the agent inside a [customized Docker Sandbox](https://docs.docker.com/ai/sandboxes/customize/) and limiting the host state exposed to it.

It also provides a reproducible working environment. When a new project needs another dependency or tool, that requirement can be added here and included in the next sandbox build.

## How It Works

This repository combines a [Docker Sandbox template](https://docs.docker.com/ai/sandboxes/customize/templates/) with a thin [mixin kit](https://docs.docker.com/ai/sandboxes/customize/kits/):

- `Dockerfile` extends `docker/sandbox-templates:codex-docker` and is built into the custom template image. It installs the durable tools and runtimes used across projects, so Docker can cache the heavier environment layers and new sandboxes start from a known baseline.
- `kit/` uses the [Docker Sandbox kit specification](https://docs.docker.com/ai/sandboxes/customize/kit-reference/) for creation-time customization, such as injecting a snapshot of the host's global Codex instructions into `/home/agent/.codex/AGENTS.md`.
- `validate.sh` checks that the expected tools and configuration are present in the created sandbox.

The split is intentional: the template carries the stable base environment, while the kit carries lighter personal or sandbox-specific configuration that should be applied when the sandbox is created.

The template currently includes:

- Homebrew
- `build-essential` and Bubblewrap
- `openssh-client`
- AWS CLI
- Go
- Hugo
- NVM and the current Node.js LTS release
- The Codex agent and private Docker Engine inherited from the Docker template

## Security Considerations

- `PROJECT_DIR` is mounted read-write. Codex can read, modify, and delete files within that directory.
- `$USER_DIR/.aws-sandbox` is mounted read-only, so Codex can read its AWS credentials but cannot modify the host files. Users are expected to create separate, least-privilege credentials for the sandbox and store them as the directory's only profile, named `sandbox`; do not reuse or expose the host's complete `~/.aws` directory.
- Git operations use the host's forwarded SSH agent when `SSH_AUTH_SOCK` is available. Private SSH keys remain on the host.
  - `openssh-client` is installed and GitHub HTTPS, HTTP, and Git protocol remotes are rewritten to SSH in the sandbox's system Git config. This bypasses HTTPS credential prompts from tools such as Homebrew, NVM, and Codex plugin sync while still keeping credentials in the forwarded host agent.
- A GitHub personal access token is optional. It is only needed for tools such as `gh` that access the GitHub API; `gh` is not currently bundled with this template.
- The host path supplied as `USER_DIR` is stored in the locally built image's metadata. Do not publish the image if that path is considered sensitive.
- Removing and recreating the sandbox deletes its VM-local files, configuration, command history, and Codex conversation history. Mounted project files remain on the host.

## Future Work

- Support verified Git commits with GPG signing from inside the sandbox.

## Setup

### 1. Install the Prerequisites

- Install and start Docker Desktop.
- Install `sbx` v0.35.0 or newer and authenticate it.
- Ensure local kits are enabled. They are enabled by default in current `sbx` releases.

Run the remaining commands from the root of this repository.

### 2. Set the Host Paths

Set these variables in the shell used to prepare, build, create, and validate the sandbox:

```bash
export USER_DIR="$HOME"
export PROJECT_DIR="$HOME/Code"
```

`USER_DIR` contains the host's `.codex` and `.aws-sandbox` directories. `PROJECT_DIR` is the workspace exposed to Codex. Re-export both variables when continuing from a new shell.

### 3. Prepare the AWS Profile

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

### 4. Prepare the Codex Kit

The kit carries two pieces of personal configuration into the sandbox:

- The host's global Codex instructions.
- The name and email from the host's global Git configuration.

Prepare both files and validate the kit:

```bash
cp "$USER_DIR/.codex/AGENTS.md" kit/files/home/.codex/AGENTS.md
test -n "$(git config --global user.name)"
test -n "$(git config --global user.email)"
git config --file kit/files/home/.gitconfig user.name "$(git config --global user.name)"
git config --file kit/files/home/.gitconfig user.email "$(git config --global user.email)"
sbx kit validate ./kit
```

| Configuration | Host Source | Prepared Kit File | Sandbox Destination |
| --- | --- | --- | --- |
| Codex instructions | `$USER_DIR/.codex/AGENTS.md` | `kit/files/home/.codex/AGENTS.md` | `/home/agent/.codex/AGENTS.md` |
| Git identity | Global `user.name` and `user.email` | `kit/files/home/.gitconfig` | `/home/agent/.gitconfig` |

The prepared files contain personal configuration and are intentionally ignored by Git. Neither exists in a fresh clone, and preparing the kit does not make them eligible for a commit.

These files are snapshots, not live links. Changes on the host do not update the kit, and preparing the kit again does not update an existing sandbox. Repeat these commands and recreate the sandbox to apply changes.

### 5. Configure Docker Sandboxes

Enable clipboard image pasting:

```bash
sbx settings set clipboard.imagePaste true
```

If Git is configured through SSH on the host, no GitHub secret is required for normal Git operations. Docker Sandboxes forwards the host SSH agent when `SSH_AUTH_SOCK` is set.

To use `gh` or other GitHub API clients, optionally register the token already managed by the host GitHub CLI:

```bash
gh auth token | sbx secret set -g github
```

Global secrets apply to newly created sandboxes. To add the token to an existing sandbox instead, use:

```bash
gh auth token | sbx secret set agent-sandbox github
```

### 6. Build and Load the Template

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

### 7. Create the Sandbox

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

> [!WARNING]
> Replacing an existing sandbox deletes its Codex conversation history. Finish or record anything needed from existing conversations before removing it.

### 8. Validate the Sandbox

```bash
./validate.sh agent-sandbox
```

### 9. Run Codex

```bash
sbx run --name agent-sandbox
```
