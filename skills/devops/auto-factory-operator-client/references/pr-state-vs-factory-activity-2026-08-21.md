# Session reference: clean PR does not prove active factory work

Observed 2026-08-21 during a living-world mega-PR follow-up. `jleechanorg/worldarchitect.ai#9148` was `OPEN`, `MERGEABLE`, `CLEAN`, and had the `factory` label. The Linux daemon service was active, but the only PR-specific telemetry returned was repeated `SKIPPED_DUPLICATE` events for `jleechanorg/worldarchitect.ai#9148`; no current `TASK_DISPATCHED`, `GATE_ASSESSMENT`, or `READY` event was present.

## Safe interpretation

- Service `active`: daemon process is running.
- PR `MERGEABLE`/clean: GitHub sees no merge blocker.
- Factory label present: the PR is eligible for intake.
- `SKIPPED_DUPLICATE`: the label scan already knows the external ref; it is not evidence of a new adoption or current work.
- Bead identity + `TASK_DISPATCHED`/gate/ready event: the strongest evidence that the factory is actually driving this PR.

Never collapse these states into "the factory is driving the PR." If current telemetry lacks the bead's dispatch/assessment evidence, report the narrower truth and name the next verification point.
