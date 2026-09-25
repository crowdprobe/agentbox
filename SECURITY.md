# Security policy

## Reporting a vulnerability

Report vulnerabilities through **private vulnerability reporting**. On this repository, go to
[Security → Report a vulnerability](https://github.com/crowdprobe/agentbox/security/advisories/new).
Please don't open a public issue for a security problem.

Please include:
- the affected tier and tag or digest
- how to reproduce the problem
- the impact you observed

We aim to acknowledge reports within a few days.

## Scope

In scope:
- the published images
- the egress firewall (`init-firewall.sh`)
- the build and publish workflows
- anything that could let an image or a workflow run unreviewed code or leak credentials

Out of scope: vulnerabilities in upstream packages that already have a fix. The daily rebuild picks those up automatically. Newly disclosed ones are visible under code-scanning alerts.

## Supported versions

Only the latest build of each tier (`:<tier>`) is supported. Dated tags (`:<tier>-YYYYMMDD-HHmmss`, one per build, never overwritten) are kept for rollback and don't receive fixes.
