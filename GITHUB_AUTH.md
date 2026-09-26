# GitHub App Authentication & Setup Guide

This document describes how GitHub authentication (for `gh` CLI and `git`) is configured in `agentbox` and how all agents operating across any repository in the organization should reuse the org-wide GitHub App identity.

---

## 1. Organization-Wide Shared Setup

The GitHub App is installed across the **entire organization**. All agent workspaces across different repositories reuse this single identity for opening pull requests, pushing branches, and interacting with the GitHub API.

### Host Credentials Location
The credentials already exist on the host machine at:
```
~/.config/agentbox/gh-app/
├── client-id          # GitHub App Client ID
└── private-key.pem    # RSA private key (.pem)
```

> **Note for Agents:** Do not create new GitHub Apps or personal access tokens. Bind-mount this existing host directory into your container to immediately gain organization-wide GitHub access.

---

## 2. Devcontainer Setup (For Other Repositories)

To set up an agent in another repository to use this shared GitHub App authentication, configure `.devcontainer/devcontainer.json`:

```jsonc
{
  "name": "agent-workspace",
  "image": "ghcr.io/crowdprobe/agentbox:core",
  "runArgs": [
    "--cap-drop=ALL",
    "--cap-add=NET_ADMIN",
    "--cap-add=NET_RAW",
    "--cap-add=SETUID",
    "--cap-add=SETGID",
    "--cap-add=AUDIT_WRITE"
  ],
  "mounts": [
    "source=${localEnv:HOME}/.config/agentbox/gh-app,target=/run/secrets/agentbox-gh-app,type=bind,readonly"
  ],
  "containerEnv": {
    "ALLOWED_DOMAINS": "api.anthropic.com,github.com,api.github.com"
  },
  "postStartCommand": "sudo -n /usr/local/bin/init-firewall.sh \"$ALLOWED_DOMAINS\" && agentbox-gh-token setup"
}
```

### CLI / `docker run` Equivalent

```bash
docker run --rm -it \
  --cap-drop=ALL --cap-add=NET_ADMIN --cap-add=NET_RAW \
  --cap-add=SETUID --cap-add=SETGID --cap-add=AUDIT_WRITE \
  -v "$PWD:/workspace" \
  -v "$HOME/.config/agentbox/gh-app:/run/secrets/agentbox-gh-app:ro" \
  ghcr.io/crowdprobe/agentbox:core \
  bash -c 'sudo init-firewall.sh "api.anthropic.com,github.com,api.github.com" && agentbox-gh-token setup && bash'
```

---

## 3. How Authentication Works Under the Hood

```
Host: ~/.config/agentbox/gh-app/
         │ (bind-mount :ro)
         ▼
Container: /run/secrets/agentbox-gh-app/
  ├── client-id
  └── private-key.pem
         │
         ▼
┌────────────────────────────────────────────────────────┐
│  /usr/local/bin/agentbox-gh-token                      │
│  - Signs RS256 JWT using client-id & private-key.pem   │
│  - Queries GET /app/installations for installation ID  │
│  - Calls POST /app/installations/:id/access_tokens     │
│  - Caches 1-hour token in /run/agentbox-gh/token.json  │
└───────────────────┬────────────────────────────────────┘
                    │
       ┌────────────┴────────────┐
       ▼                         ▼
┌──────────────┐         ┌──────────────────────────────┐
│  /usr/local/ │         │  /usr/local/bin/             │
│  bin/gh      │         │  git-credential-agentbox     │
│  (wrapper)   │         │  (git credential helper)     │
│  Exports     │         │  Provides token for          │
│  $GH_TOKEN   │         │  https://github.com/ pushes  │
└──────────────┘         └──────────────────────────────┘
```

1. **Token Minting (`agentbox-gh-token`)**:
   - Generates an RS256 JWT valid for 9 minutes using `client-id` and `private-key.pem`.
   - Obtains an installation access token valid for 1 hour from the GitHub API.
   - Caches the token and automatically refreshes it when under 10 minutes of lifetime remain.
2. **GitHub CLI (`gh`)**:
   - `/usr/local/bin/gh` wraps the upstream binary (`/opt/gh/bin/gh`).
   - If `GH_TOKEN` is not already set and `/run/secrets/agentbox-gh-app` exists, it automatically sets `GH_TOKEN="$(agentbox-gh-token)"`.
3. **Git Operations (`git`)**:
   - System git configuration routes `https://github.com` credential requests to `/usr/local/bin/git-credential-agentbox`.
   - The credential helper responds with `username=x-access-token` and `password=<installation-token>` for seamless `git fetch` and `git push`.
4. **Bot Identity Setup (`agentbox-gh-token setup`)**:
   - Running `agentbox-gh-token setup` configures `git config user.name` and `user.email` to match the bot's username and noreply address (`<slug>[bot]` and `<bot-id>+<slug>[bot]@users.noreply.github.com`).
5. **Security Isolation**:
   - Under rootless Docker, `/run/secrets/agentbox-gh-app/private-key.pem` is owned by container root (0:0). The unprivileged `agent` user (UID 1000) requests tokens via passwordless sudo to `agentbox-gh-token`, preventing the agent from directly extracting the private key.

---

## 4. Verification in Container

Once mounted and started, agents can verify access with:

```bash
# 1. Verify token generation
agentbox-gh-token

# 2. Verify bot identity
agentbox-gh-token identity

# 3. Verify gh CLI authentication
gh auth status

# 4. Verify git identity
git config user.name
git config user.email
```
