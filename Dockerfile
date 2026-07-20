FROM docker/sandbox-templates:codex-docker

SHELL ["/bin/bash", "-e", "-o", "pipefail", "-c"]

USER root

# The sandbox image currently uses Ubuntu Ports over HTTP. HTTPS works both in
# Docker builds and through the Docker Sandbox forward proxy. The Docker APT
# source is unnecessary because the codex-docker base already contains Docker.
RUN sed -i \
      's|http://ports.ubuntu.com/ubuntu-ports|https://ports.ubuntu.com/ubuntu-ports|g' \
      /etc/apt/sources.list /etc/apt/sources.list.d/*.sources /etc/apt/sources.list.d/*.list \
      2>/dev/null || true; \
    for source in /etc/apt/sources.list.d/docker.sources /etc/apt/sources.list.d/docker.list; do \
      if [[ -f "$source" ]]; then mv "$source" "$source.disabled"; fi; \
    done; \
    apt-get update; \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      build-essential \
      bubblewrap \
      ca-certificates \
      curl \
      git \
      openssh-client; \
    rm -rf /var/lib/apt/lists/*

USER agent

RUN curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh \
      -o /tmp/install-homebrew.sh; \
    NONINTERACTIVE=1 /bin/bash /tmp/install-homebrew.sh; \
    rm /tmp/install-homebrew.sh; \
    /home/linuxbrew/.linuxbrew/bin/brew install awscli go hugo; \
    /home/linuxbrew/.linuxbrew/bin/brew cleanup

ENV NVM_DIR=/home/agent/.nvm

RUN curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh \
      -o /tmp/install-nvm.sh; \
    PROFILE=/dev/null bash /tmp/install-nvm.sh; \
    rm /tmp/install-nvm.sh; \
    unset NPM_CONFIG_PREFIX; \
    source "$NVM_DIR/nvm.sh"; \
    nvm install --lts; \
    nvm alias default 'lts/*'; \
    node --version; \
    npm --version; \
    npm cache clean --force

ARG USER_DIR
RUN test -n "$USER_DIR"
ENV USER_DIR="$USER_DIR"

USER root

RUN git config --system --add url."ssh://git@github.com/".insteadOf https://github.com/; \
    git config --system --add url."ssh://git@github.com/".insteadOf http://github.com/; \
    git config --system --add url."ssh://git@github.com/".insteadOf git://github.com/

ENV GIT_ASKPASS=/bin/false
ENV SSH_ASKPASS=/bin/false
ENV GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new"

RUN cat >> /etc/sandbox-persistent.sh <<'EOF'
if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
  eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
fi
export NVM_DIR="$HOME/.nvm"
unset NPM_CONFIG_PREFIX
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"
if [ -d "$USER_DIR/.aws-sandbox" ]; then
  export AWS_CONFIG_FILE="$USER_DIR/.aws-sandbox/config"
  export AWS_SHARED_CREDENTIALS_FILE="$USER_DIR/.aws-sandbox/credentials"
  export AWS_PROFILE=sandbox
fi
EOF

USER agent
