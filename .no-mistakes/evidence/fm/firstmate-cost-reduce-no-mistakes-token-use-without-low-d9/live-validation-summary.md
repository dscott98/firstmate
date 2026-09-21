# Bounded live validation

The real Codex CLI loaded the current Firstmate instructions and selected modes for eight intake requests. It invoked the real `bin/fm-brief.sh` with an isolated `FM_HOME` for each request. Generated briefs and full CLI transcripts are retained alongside this report.

| Request | Agent-selected and emitted mode |
| --- | --- |
| README typo | direct-PR |
| Contributor meeting clarification | direct-PR |
| Release-note date correction | direct-PR |
| Internal credential rotation / authorization | no-mistakes |
| Complex internal concurrent scheduler / rollback | no-mistakes |
| User-visible total calculation | no-mistakes |
| Firstmate landed-work guard | no-mistakes |
| Unknown script callers and effects | no-mistakes |

A second live Codex evaluation chose the existing task and branch for a small follow-up and one validation after the final correction. This proves the agent decision only: no follow-up commit, worker steering, or final pipeline validation was executed.

Actual routine-versus-review model routing was not exercised. The assigned phase prohibits starting another pipeline, executing other pipeline phases, and modifying global configuration. The outer executor must supply an authorized isolated run with the documented profiles and retain model-launch and final-head evidence.

Commands executed:

- `codex exec --ephemeral --ignore-user-config --disable hooks --sandbox workspace-write --json -o <evidence>/classification-response.json -` with classification-prompt.txt on stdin.
- Agent-selected calls: `FM_HOME=<worktree>/.test-live-cost/home bash bin/fm-brief.sh <case> sample --mode <selected-mode>`.
- Python checked agent decisions against expected classifications and verified the generated public delivery-contract fields; classification-results.json records the outputs.
- `codex exec --ephemeral --ignore-user-config --disable hooks --sandbox read-only --json -o <evidence>/followup-response.json -` with followup-prompt.txt on stdin.
- `bash tests/fm-task-delivery.test.sh` passed. Its stubbed harness tests are supplementary evidence, not live product proof.

No UI changes or screenshots apply. No source changes were made. Temporary generated home removed after copying evidence.
