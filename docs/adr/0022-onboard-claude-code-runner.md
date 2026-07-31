# ADR-0022: Onboard `claude-code-runner` as a suspended CronJob template

**Date:** 2026-07-31
**Status:** Accepted

---

## Context

The idea of running Claude Code inside the cluster for occasional CI/automation tasks (code
review, one-off scripted fixes) came up with no concrete first use case yet. `claude
setup-token` produces a 1-year-lived OAuth token, but it authenticates against the same
subscription quota (5-hour rolling + weekly limits) as interactive use — that only matters at
volume, and "a few specific cases, not continuous" doesn't approach it, so the token was worth
plumbing in now rather than waiting for the first concrete task.

## Decision

`apps/claude-code-runner/` onboards a **plain-manifest** app (own `Namespace` + a `CronJob`,
no `Application` pointer needed — `root`'s `directory.recurse: true` over `apps/` applies
these directly, same pattern as `whisper`/`piper`'s raw manifests) rather than a git-source
Application: there's no custom app code or CI build to point at, just a stock `node:22-slim`
image that installs `@anthropic-ai/claude-code` from npm at container start.

The `CronJob` (`cronjob-template.yaml`) ships with `suspend: true` and an inert weekly
schedule — ArgoCD keeps it reconciled but it never fires on its own. It exists to prove the
image, auth wiring, and invocation shape (`kubectl create job --from=cronjob/...`) are correct,
not to run anything yet. Its `CLAUDE_PROMPT`/`CLAUDE_ALLOWED_TOOLS` env vars default to an
inert placeholder; a real task means overriding both for that specific case rather than
leaving a generic prompt permanently wired up.

The OAuth token is **not** git-managed, following the existing "don't trust
git/chart-templated secrets" rule (Grafana admin-password incident, `docs/runbook.md`): create
it once out-of-band —

```bash
sudo microk8s kubectl create secret generic claude-code-oauth-token \
  -n claude-code-runner \
  --from-literal=CLAUDE_CODE_OAUTH_TOKEN=<token from `claude setup-token`>
```

`apps/appproject.yaml` gets namespace `claude-code-runner` added to `destinations`, no
`sourceRepos`/`clusterResourceWhitelist` change needed (no external repo, everything
namespace-scoped).

## Alternatives Considered

- **`ANTHROPIC_API_KEY` (pay-per-token) instead of the OAuth token** — rejected for now: better
  suited to sustained/high-volume automation with its own separate quota, but "a few specific
  cases" won't meaningfully dent the subscription's interactive quota, and the OAuth token
  needs no separate billing setup. Worth revisiting if usage grows into a real background
  service.
- **A bespoke Docker image (built + pushed to GHCR via CI), like `ollama-chat`/`piper`/
  `homelab-gateway`** — rejected: there's no app-specific code to build yet; a stock Node image
  installing the CLI at container start is enough plumbing until a concrete task exists that
  might actually need a customized image (e.g. baked-in project checkouts or extra tooling).
- **An always-on Deployment instead of an ad hoc Job/CronJob** — rejected: Claude Code's
  headless mode (`claude -p`) is a single run-to-completion invocation per task, not a
  long-lived server process; a `CronJob` template triggered on demand fits that shape and costs
  nothing while idle.

## Consequences

**Good:**
- Ready to run a real automation the moment one exists — just override
  `CLAUDE_PROMPT`/`CLAUDE_ALLOWED_TOOLS` (and `--output-format`/tool list as needed) on a
  triggered Job, no new plumbing required.
- Zero standing cost: suspended, no image build/CI, no dedicated IP or ingress.

**Neutral:**
- The token lives only in the cluster (`kubectl create secret`, out-of-band) — losing the
  cluster's etcd/backup means regenerating it via `claude setup-token` again; not written down
  anywhere else, deliberately (same handling as the Grafana admin-credentials secret).

**Negative:**
- No CI validation of the actual prompt/tool-list at invocation time (unlike the git-source
  apps' `docker-publish.yml` pattern) — each ad hoc run's correctness is on whoever triggers
  it, not caught by `validate.yml` (ADR-0009 only validates manifest schema, not runtime
  prompts).
