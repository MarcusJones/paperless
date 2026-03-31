# Use official Node.js 22 slim image as base
FROM node:22-slim

# Install additional dependencies
RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    libssl-dev \
    libffi-dev \
    curl \
    sudo \
    postgresql-client \
    jq \
    unzip \
    dnsutils \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI v2
RUN curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip \
    && unzip -q /tmp/awscliv2.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscliv2.zip

# Create a workspace directory
WORKDIR /workspace

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install devcontainer CLI
RUN npm install -g @devcontainers/cli

# Install commonly used Node.js tools
RUN npm install -g \
    typescript \
    ts-node \
    nodemon \
    prettier \
    eslint

RUN npm install -g pnpm@9.15.4

# Remove the default node user and create vscode user with same UID (1000)
RUN userdel -r node && \
    useradd -ms /bin/bash -u 1000 vscode

# Configure sudo for vscode user
RUN echo "vscode ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Set the working directory
WORKDIR /workspace

# Switch to vscode user
USER vscode

# Add useful bash aliases
RUN echo 'alias ll="ls -la"' >> ~/.bashrc && \
    echo 'alias la="ls -A"' >> ~/.bashrc && \
    echo 'alias l="ls -CF"' >> ~/.bashrc && \
    echo 'alias ..="cd .."' >> ~/.bashrc && \
    echo 'alias ...="cd ../.."' >> ~/.bashrc && \
    echo 'alias ....="cd ../../.."' >> ~/.bashrc && \
    echo 'alias grep="grep --color=auto"' >> ~/.bashrc && \
    echo 'alias fgrep="fgrep --color=auto"' >> ~/.bashrc && \
    echo 'alias egrep="egrep --color=auto"' >> ~/.bashrc && \
    echo 'alias h="history"' >> ~/.bashrc && \
    echo 'alias j="jobs -l"' >> ~/.bashrc && \
    echo 'alias vi="vim"' >> ~/.bashrc && \
    echo 'alias svi="sudo vim"' >> ~/.bashrc && \
    echo 'alias ports="netstat -tulanp"' >> ~/.bashrc && \
    echo 'alias sb="supabase"' >> ~/.bashrc && \
    echo 'alias sbstart="supabase start"' >> ~/.bashrc && \
    echo 'alias sbstop="supabase stop"' >> ~/.bashrc && \
    echo 'alias sbreset="supabase db reset"' >> ~/.bashrc