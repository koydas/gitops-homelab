# ADR-0025: Host-Level Auto-Extend for Root Disk, with a Prometheus Backstop Alert

**Date:** 2026-08-20
**Status:** Accepted

---

## Context

On 2026-08-19 the root disk (`/dev/mapper/ubuntu--vg-ubuntu--lv`, ext4, on `ubuntu-vg`) filled
to 97% (89G/98G used, 3.7G free). This was not a leak in any single app — the breakdown was
legitimate: Whisper's PyTorch-based image (~15G writable layer), the 3 Ollama models (~13G on
their PVC), and containerd's own image/snapshot store (~16G content + 26G overlayfs). It was
simply more real footprint than the original 100G root LV had room for.

At 97% full, kubelet's image garbage collection started failing outright
(`"Image garbage collection failed multiple times in a row... freed 0 bytes"`), which
destabilized containerd/kubelite (observed `kine.sock` gRPC connection resets) and caused
cascading pod restarts across the node — `ollama-chat` 91 times, `homelab-gateway` 91-92 times,
`metallb-speaker`/`controller` 97-98 times over their respective uptimes. The visible symptom
was intermittent blank-page failures on `ollama-chat` (`192.168.1.244`) — invisible to
point-in-time health checks (curl tests during triage all returned 200 OK) because the
instability was intermittent, not constant.

The immediate fix was manual: `vgs` showed `ubuntu-vg` was only 100G-of-235G allocated (135G
free), so the root LV was extended online (`lvextend -L +100G` + `resize2fs`, no downtime) to
197G, 48% used. See `.ai-reports/2026-08-20-1312-panne-ollama-chat-disque-plein.md` for the
full incident writeup.

That fix bought headroom but not durability — the same growth pattern (image churn from
frequent ArgoCD git-source redeploys, potential future Ollama models, growing Mongo/Prometheus
data) will eventually refill any fixed allocation again. The user asked specifically for the
disk to *self-heal* going forward, with Grafana as the only acceptable visibility channel (no
email/webhook — Alertmanager has no configured receiver, see ADR-0012's Consequences).

---

## Decision

Two layers, matching the "primary defense + visible backstop" shape already used for other
node-level concerns in this repo:

1. **`auto-extend-root.timer`** — a systemd timer (host-level, `/etc/systemd/system/`, not
   GitOps-managed) running `/usr/local/sbin/auto-extend-root.sh` every 15 minutes. When root
   usage is >= 80%, it extends the LV by +20G out of the VG's free extents and grows the ext4
   filesystem online, automatically, no manual step. It always keeps at least 5G unallocated in
   the VG as a reserve, and does nothing (rather than draining the VG to zero) once that reserve
   would be breached.

2. **`apps/monitoring/disk-space-rules.yaml`** — a `PrometheusRule` (GitOps-managed, same
   pattern as the dcgm `ServiceMonitor` in ADR-0012/0021) firing `RootDiskSpaceWarning` at 85%
   and `RootDiskSpaceCritical` at 92%. Under normal operation these should never fire, since
   auto-extend acts first at 80%. If either does fire, it means auto-extend either isn't running
   or has exhausted the VG's free space — i.e. the point where self-healing stops being possible
   and a human actually needs to look, visible on the existing Grafana instance
   (`192.168.1.242`) with no new notification channel required.

---

## Considered Alternatives

### Prometheus alert + Alertmanager notification (email/webhook) only, no auto-remediation
Rejected per explicit user preference: they wanted the fix applied without manual intervention,
not just a faster notification of the same manual-fix workflow that already happened once.
Setting up a receiver (SMTP creds or a webhook URL) would also have been the first new external
credential this monitoring stack holds — avoided since the auto-extend approach removes the need
for it entirely.

### In-cluster CronJob instead of a host-level systemd timer
Rejected: extending an LVM volume group and growing the root filesystem is inherently a host
operation on `shamel-server` itself, not a cluster workload — it would need a privileged pod
with hostPath access to `/dev` and the host's mount namespace, which is a much larger security
surface (a GitOps-managed manifest with host root access) for no real benefit over a systemd
timer that already runs as root as a matter of course. Same reasoning as ADR-0017's `ClusterPolicy`
patch being kept host-level rather than templated into Git.

### No reserve floor (auto-extend until the VG is fully consumed)
Rejected: would silently consume 100% of the VG's free space over repeated small growth events
with no signal that it was happening, right up until the exact moment it can no longer help —
the worst possible time to first notice. A fixed 5G reserve plus the backstop alert means there
is always a visible warning window before auto-extend's capacity actually runs out.

### One large extend instead of an ongoing timer
Considered simply allocating most of the 135G-free VG to root immediately and calling it done
(similar to the manual 2026-08-19 fix, just bigger). Rejected as the sole fix: it delays the
same problem rather than solving it — the underlying growth pattern (image churn, model growth)
doesn't stop, so a fixed allocation refills eventually regardless of size. The recurring timer
keeps adapting as long as VG space allows, rather than requiring another manual intervention
(or another ADR) next time.

---

## Consequences

**Good:**
- Disk-full-triggered outages (per ADR context) should no longer recur under normal growth —
  the timer acts automatically before usage reaches the level that previously destabilized
  containerd/kubelite.
- No new external dependency or credential (SMTP, webhook) added to the monitoring stack.
- The backstop alert reuses the existing Grafana/Prometheus stack (ADR-0012) with no new
  infrastructure — just a `PrometheusRule` in the existing GitOps pattern.

**Neutral:**
- Like ADR-0017's `ClusterPolicy` time-slicing patch, `auto-extend-root.timer`/`.service` and
  the script itself are host-level and **not** tracked in this Git repo — they survive reboots
  (systemd unit, enabled) but not a full OS reinstall. Re-installing them after a rebuild is a
  manual step (script + two unit files, see this ADR and the runbook).
- The VG's free space is finite (35G remaining as of this ADR, after the 2026-08-19 manual
  +100G extend). Auto-extend can absorb further growth several more times at +20G per event, but
  it is not infinite — eventually either the reserve is hit (backstop alert fires) or the disk
  itself needs to grow (a larger underlying volume, or a second disk).

**Negative:**
- A growing root filesystem is one-way — `resize2fs`/`lvextend` grow online, but shrinking an
  in-use ext4 root volume back down is far riskier and not something this ADR attempts. Disk
  space given back to root via auto-extend is not recoverable without significant manual work,
  even if the underlying usage that triggered it later drops (e.g. old container images finally
  get garbage-collected).
- Auto-extend fixes the symptom (running out of room) but does nothing about the underlying
  growth rate — if image churn or model growth accelerates, it will consume the remaining 35G
  of VG headroom faster, bringing the backstop-alert date closer rather than further away.
