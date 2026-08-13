# Public-facing README Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the internal Japanese experiment-oriented README with an accurate English entry point for public users and contributors.

**Architecture:** Keep `README.md` focused on product orientation and safe operation. Summarize experimental modes in one table, link detailed evidence to `docs/validation/`, and derive every command, option, configuration field, and limitation from the current implementation.

**Tech Stack:** Markdown, Swift CLI parser, `just`, JSON configuration, repository validation documents

---

## Task 1: Rewrite the public README

**Files:**
- Modify: `README.md`
- Reference: `Sources/IrodoriVoiceChangerCLI/CLI.swift`
- Reference: `justfile`
- Reference: `config/irodori-voicechanger.example.json`
- Reference: `docs/validation/2026-08-12-initial-baseline.md`
- Reference: `docs/validation/2026-08-12-stable-prefix-shadow.md`
- Reference: `docs/validation/2026-08-13-early-finalize-shadow.md`
- Reference: `docs/validation/2026-08-13-smart-turn-native-replay.md`

- [x] **Step 1: Replace the README structure**

Use these headings in this order:

```markdown
# Irodori VoiceChanger
## Status
## How it works
## Features
## Requirements
## Quick start
## Live use
## Reproducible WAV replay
## Experimental shadow modes
## Telemetry and privacy
## Known limitations
## Validation evidence
## Development
## License
```

State near the top that the project is an experimental macOS 26 PoC, the normal path uses only Apple Speech final results, and shadow modes do not change audible output unless a command explicitly says otherwise.

- [x] **Step 2: Document setup and normal operation**

Include copy-pasteable commands for `just bootstrap`, `just build-app`, `config init`, `devices`, `config validate`, `doctor`, `doctor --synthesize`, `just run`, replay variants, and reports. Document `irodori.base_url` and `audio.output_device_uid`, including HTTPS and loopback HTTP constraints and the no-speaker-fallback behavior.

- [x] **Step 3: Consolidate the experiments**

Use one table with these rows and boundaries:

| Mode | Command | Purpose | Audible or remote effect |
|---|---|---|---|
| Stable-prefix measurement | configuration only | Observe stable partial prefixes | None |
| Prefix synthesis shadow | `--shadow-synthesize-prefix` | Measure candidate synthesis | Sends one candidate to the configured Irodori server; discards audio |
| Silence endpoint shadow | `--shadow-endpoint-ms` | Measure a fixed-silence boundary | None |
| Apple early-finalize replay | `--shadow-early-finalize-ms` | Measure Apple finalization mechanics | Calls Apple finalize during replay; no synthesis or playback |
| Smart Turn shadow | `--shadow-smart-turn` | Classify semantic endpoint candidates | None; never calls Apple finalize or Irodori |

Follow the table with the validated conclusion that fixed-WAV promise does not establish safe live semantic endpointing, so active Smart Turn finalization is not exposed.

- [x] **Step 4: Document privacy, limitations, and evidence**

List the telemetry fields at category level and explicitly exclude transcripts, input/generated audio, voice IDs, device IDs, endpoints, credentials, and response bodies. State that the server currently returns audio only after full synthesis, hot-unplug recovery is not implemented, and 12-step quality is retained. Link the three experiment validation reports and the baseline report rather than duplicating their full measurements.

## Task 2: Verify the README against the repository

**Files:**
- Verify: `README.md`

- [x] **Step 1: Check commands, flags, and configuration names**

Run:

```bash
rg -n 'shadow-smart-turn|shadow-synthesize-prefix|shadow-endpoint-ms|shadow-early-finalize-ms|show-transcript|live-output|synthesize' README.md Sources/IrodoriVoiceChangerCLI/CLI.swift
rg -n 'base_url|output_device_uid|num_steps|schedule|style' README.md config/irodori-voicechanger.example.json
```

Expected: every README option and configuration field has a matching implementation or versioned example; `--smart-turn-finalize` is absent from the README.

- [x] **Step 2: Check public prose and links**

Run:

```bash
rg -n '[ぁ-んァ-ヶ一-龠]' README.md
rg -n 'TBD|TODO|PLACEHOLDER|--smart-turn-finalize' README.md
```

Expected: both commands return no matches. Manually verify every relative documentation link resolves inside the repository.

- [x] **Step 3: Run repository gates**

Run:

```bash
just check
git diff --check
```

Expected: formatting, lint, warnings-as-errors build, all tests, coverage, secret scanning, justfile validation, release app build/signing, and whitespace validation pass.

- [x] **Step 4: Commit the README change**

```bash
git add README.md docs/superpowers/plans/2026-08-13-public-readme.md
git commit -m "Rewrite README for public users"
```
