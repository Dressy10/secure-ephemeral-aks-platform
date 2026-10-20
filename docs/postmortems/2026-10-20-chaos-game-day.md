# Postmortem: chaos game day, 2026-10-20

Status: complete. Type: planned exercise (no customer impact). Blameless: this document is about the system and our measurement, not about people.

## Summary
We injected three faults into the ledger service in `payments` on a live two-node AKS cluster: one pod killed, all pods killed, and 400 ms of network latency. The service behaved as designed in all three. The exercise also exposed two problems in how we measured it, and, unplanned, a delivery-pipeline bug that was delaying every change by about eight minutes. All three are fixed or have an action item below.

Steady state before each experiment: 3 ledger replicas, `Healthy`, about 2.5 requests per second from an in-cluster load generator (closed loop, one request at a time), p50 around 7 ms.

## Impact
No customer impact (synthetic traffic only). Measured from the client:

| Experiment | Hypothesis (written before the run) | Result |
|---|---|---|
| Kill 1 of 3 pods | client error rate under 1% | 0 or 1 failed request in about 110 to 120 (two runs), outage 1 s or less. Confirmed. |
| Kill all 3 pods | recovers unaided within 60 s | 5 to 7 failed requests (about 4 to 6% of a 45 s window), outage about 3 s in all three runs. Confirmed, large margin. |
| +400 ms latency, 88 s | requests succeed, most exceed the 250 ms threshold | 0 failures, but every request was slow (p50 about 810 ms, p99 1.0 to 1.5 s) and client throughput fell about 63% (2.5 to 0.9 requests per second). Confirmed, and worse than predicted. |

Figures are from two or three runs each (see `docs/metrics/gameday-results.json`). Every failure count was cross-checked against the raw load-generator log.

For the all-pods kill: replacement pods started 2 s after the kill and each passed Kyverno signature verification at admission, so the admission policy did not slow recovery.

## Timeline (UTC, from cluster events)
- 14:21:35 Experiment 1 submitted. 14:21:58 pod killed (23 s injection lag). 14:21:59 replacement started.
- 14:24:59 Experiment 2 submitted. 14:25:27 all three pods killed (28 s lag). 14:25:29 three replacements started. 14:25:27 to 14:25:29 failed requests (connection refused).
- 14:29:12 Experiment 3 submitted. 14:29:30 latency applied (18 s lag). 14:30:58 latency removed (88 s active).

## What went well
- Self-healing worked with no human action. The Rollout replaced killed pods within about 2 seconds.
- Admission control stayed out of the recovery path.
- With three replicas, losing one pod cost a single request.
- Metrics, SLO rules and the audit log were all present, so the exercise was measurable.

## What went wrong

### 1. Our first MTTR numbers were wrong
The game-day script reported MTTRs of 24 s and 31 s. It measured from when the experiment was submitted, but Chaos Mesh takes 18 to 28 s to inject the fault. The first failure lined up exactly with the real kill event. The true outage was about 1 s and 3 s. We caught this only because the first failure came suspiciously late and we compared it to cluster event times.

### 2. The latency result was understated by about four times
The script reported 26.5% slow requests. It averaged fault and non-fault time, and the load generator is closed-loop (one request at a time), so it takes far fewer samples while the service is slow. During the fault itself, 100% of requests were slow. This is the coordinated-omission problem.

### 3. Unplanned finding: every change was delayed by about eight minutes
While investigating why the earlier rollback demo took 628 s, we found Flux's `apps` kustomization was timing out on its health check for 10 minutes, then retrying 10 minutes later. Cause: Argo Rollouts reports `status.observedGeneration` as a string, Flux's health checker expects an integer, so the Rollout showed `Unknown` forever. A trivial change took 504 s to reach the cluster. After setting `wait = false` on that kustomization it took 73 s.

### 4. The corrected script was also wrong once, and so were two of our own numbers
- A second full run of the fixed script reported 0 failed requests for the all-pods kill. The raw load-generator log shows 6 connection failures in that same fault. We could not find the cause. A standalone re-run, with the script now printing the exact window it used, matched the raw log (7 failures, 3 s outage).
- In the first write-up we stated a 5 requests per second baseline and an 82% throughput drop. The real baseline is about 2.5 requests per second, so the drop is about 63%. We found this only when re-reading the raw log while debugging the discrepancy above.

## Contributing factors
- We trusted a derived metric (MTTR) without checking it against an independent source.
- The load generator's design was never reviewed for sampling bias.
- The Flux health check had never been exercised with a change arriving while a previous reconcile was still waiting.

## Action items
| # | Action | Status |
|---|---|---|
| 1 | Make `scripts/game-day.ps1` take fault windows from cluster events, not submission time | in this change |
| 2 | Replace the closed-loop load generator with a fixed-rate (open-loop) one, so slow periods are sampled fairly | open |
| 3 | The latency alert only fires after 10 minutes. An 88 s total-latency incident would never page. Add a fast-burn latency alert with a short window and test it with this experiment | open |
| 4 | Spread the three replicas across both nodes (topology spread constraints). A node loss today could take two pods at once. Verify with a node-drain experiment | open |
| 5 | Flux: `apps` health gating disabled (done). Add a regression check that a no-op change reaches the cluster in under 2 minutes | partly done (manual probe) |
| 6 | Make the game-day script self-checking: compare its failed-request count with a raw count of non-2xx lines across all fault windows, and fail loudly on a mismatch. Find the cause of the run 2 discrepancy | open |

## Limits of this exercise
Single run on one cluster with one client, so the numbers are indicative, not statistical. The cluster was two small nodes, and node-level failures were not tested. We did not verify that alerts fired during the experiments.

## Lessons
- Write the hypothesis before the run, then report against it. Two of ours were confirmed outright, but "worse than predicted" is also a finding.
- Cross-check derived numbers against a raw source before publishing them. We needed to do this three times in one day.
- A game day is also a test of the tooling around the system, and found a real delivery bug here.
