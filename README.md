# Natural Language Compiler (NLC) v0.1
## Conversation → Code: Seed Repositories for Claude Code

**Authors:** neurodivergentai, ChatGPT, Claude — MIT License  
**Implementation Target:** Claude Code in the terminal (implementer)  

**This Script's Role:** Single‑file "Natural‑Language Compiler" (NLC) that converts intent + docs into a structured, testable seed repo.

---

## Abstract

Software teams are increasingly "programming by conversation," using frontier models to sketch, generate, and refine code. While productive, this is often ad‑hoc: instructions are ambiguous, outputs vary, and traceability is poor. We propose a disciplined method that treats natural language as the high‑level source language and the model as a compiler. Our compiler (this script) conducts a short, structured interview; optionally ingests documentation; then emits a repository with contracts, tests, and strict hand‑off instructions optimized for Claude Code in the terminal to implement. Determinism is enforced at the behavioral level via tests and contracts. The repository includes an anti‑cheating policy, a repo‑local task hook for capturing TODOs, and a traceable Intent→Code Map. This document explains the model, lifecycle, architecture, security posture, and how to operate and extend the system.

---

## 1. Introduction & Motivation

Modern LLMs can synthesize code from prose but suffer from ambiguity, stochasticity, and incentive mismatch (e.g., "make the tests pass" can be gamed). Traditional compilers solved similar problems for formal languages with well‑defined inputs, reproducible outputs, and robust error signaling. By reframing the LLM as a Natural‑Language Compiler (NLC), we add the missing discipline:

- Structured input (interview passes; optional doc summarization)
- A strict JSON manifest describing all files to emit
- Contracts + tests as the arbiter of correctness
- Handoff rules that constrain the implementer (Claude Code) to honest, incremental work
- Traceability (Intent→Code Map)

The result is a predictable, auditable, and teachable methodology—usable by professionals and newcomers alike.

---

## 2. Core Metaphor: AI as Compiler

- **Source language:** Natural language (user intent + clarifying Q&A + doc summary)
- **Compiler:** LLM provider you select (OpenAI, Azure OpenAI, Anthropic, Gemini, Mistral, Cohere, Ollama)
- **IR/Artifact:** A JSON manifest with files `{path, content, executable}` plus messages and next_steps
- **Target:** A runnable seed repository with tests, contracts, and instructions aimed at Claude Code

Determinism is not byte‑for‑byte; it is behavioral. We lock behavior with tests/contracts and keep the remainder transparent and traceable.

---

## 3. Lifecycle Overview

1. **Interview (Two Passes).** The script asks compact, high‑signal questions to remove ambiguity. If ambiguity remains, it is recorded as `NLC-AMBIGUITY:<field>` in `messages`.
2. **Documentation (Optional).** The user may point to a docs directory. The script samples head/middle/tail bytes (binary‑safe) to build a summary while preserving originals under `docs/original/`.
3. **Compilation (Multi-Step, Language-Aware).** Phase 1: The model returns a lightweight JSON structure with language-appropriate file paths and descriptions. Phase 2: Each file is generated individually with language-specific prompts for robustness. The script validates JSON, sanitizes paths, writes files, and marks executables.
4. **Handoff Hardening.** The script ensures `CLAUDE.md` exists and injects the anti‑cheating policy and task‑capture protocol. It auto‑installs `tools/task.sh` and `tasks/` if omitted.
5. **Implementation Loop.** You open the repo with Claude Code, follow `CLAUDE.md`, and iterate. The script's Iterate / Fix mode can apply minimal patches based on error logs.

---

## 4. Repository Contract (What We Emit)

A typical seed repo contains:

```
<project>/
  README.md                # Intent→Code Map; run instructions; handoff steps
  CLAUDE.md                # Policy: no test gaming; incremental work; task capture
  nlc.yaml                 # Goal, non_goals, interfaces, constraints, tests
  contracts/               # Optional: OpenAPI, Protobuf, JSON Schema, interface defs
  tests/
    smoke.sh               # Executable minimal test (required); more tests encouraged
  src/, include/, man/     # Language-specific scaffolding for implementation
  tools/
    nlc_claude.sh          # Emits prompt blocks for Claude Code
    task.sh                # Repo-local task logger (portable ID + locking)
  tasks/
    tasks.md               # Human‑readable task log
    tasks.json             # Machine‑readable log (if jq available)
  docs/
    summary.md             # Summarized design signal from your corpus
    original/              # Exact copy of provided docs (no loss)
```

### 4.1 JSON Manifest Schema (Model Output)

**Phase 1 (Structure):** Language-aware file list with appropriate extensions and build systems.

```json
{
  "project": "kebab-case-name",
  "files": [
    {"path": "README.md", "type": "documentation", "description": "Project overview with intent→code map", "executable": false},
    {"path": "tests/smoke.sh", "type": "test", "description": "Basic functionality test", "executable": true}
  ],
  "messages": ["NLC-AMBIGUITY:... (if any)", "Info, warnings, decisions"],
  "next_steps": ["Run make test", "Open CLAUDE.md", "Start Claude Code"]
}
```

**Phase 2 (Individual files):** Each file is generated separately with full content for robustness and token efficiency.

The script rejects non‑JSON outputs and saves them for debugging.

### 4.2 Intent→Code Map

`README.md` links requirements to artifacts (files/functions/tests). This de‑mystifies the generator's decisions and anchors future changes.

---

## 5. Policy & Integrity: Preventing "Test Gaming"

`CLAUDE.md` includes a policy block that Claude Code must follow:

- **No cheating:** Do not mock/bypass to "pretend pass." Run tests honestly and report failures.
- **Small steps:** Work in PR‑sized increments; run `make test` after each change.
- **Traceability:** Keep the Intent→Code Map in `README.md` current.
- **Task capture:** Whenever creating a TODO/FIXME/stub or deferring work, run:
  ```bash
  tools/task.sh "Short title" "Details"
  ```

---

## 6. Task Integration & Hooks

Every repo includes `tools/task.sh` for capturing deferred work:

- Repo‑local logging: Appends to `tasks/tasks.md`
- JSON logging: Optional machine‑readable `tasks.json` (if `jq` present)
- Locking: Uses `flock` or mkdir‑based fallback for concurrent safety
- Optional integration: If `NLC_TASK_COMMAND` is set, the script pipes title + details via stdin to your external tool (safer than argv)

This provides Claude a single, reliable command to turn TODOs into trackable tasks.

---

## 7. Language Support

NLC automatically adapts to the selected programming language, generating appropriate file structures and build systems:

- **C/C++:** main.c/main.cpp + Makefile (gcc/clang/g++)
- **Python:** main.py + requirements.txt 
- **Go:** main.go + go.mod
- **Rust:** main.rs + Cargo.toml
- **TypeScript:** main.ts + package.json

The system prompts, file extensions, and build configurations are dynamically selected based on the language choice during project setup. This eliminates hardcoded references to specific languages in generated documentation and ensures consistency between specifications and implementation.

---

## 8. Providers & Configuration

NLC supports: OpenAI, Azure OpenAI, Anthropic (Claude), Gemini, Mistral, Cohere, and Ollama (local).  
The Settings menu interactively captures the right fields (including Azure deployment vs. model).

- Provider-specific parsing: The script extracts text using the correct schema for each API family
- Retries: Exponential backoff (bounded) on transient failures
- Error capture: Non‑2xx responses are saved to `~/.nlc/work/last_error.json` with hints

---

## 9. Token Budgeting, Pacing, and Safe Truncation

- Estimation: Roughly `chars/4 ≈ tokens`. Good enough for budgets/pacing
- Budgets: Optional Max tokens per request; if exceeded, the user can opt to truncate the user block
- Safe truncation: The script trims to a byte count then backs up to a word boundary to avoid malformed prompts
- **Pacing:** Optional tokens‑per‑minute throttling plus a millisecond floor between calls

This helps avoid accidental over‑spend and improves reliability.

---

## 10. Security Posture

- Path sanitization: Prevents writes outside the project root
- No auto‑execution: Files are written non‑executable unless flagged
- Docs preservation: Originals are copied under `docs/original/` for auditability
- External hooks are opt‑in: `NLC_TASK_COMMAND` is under user control and receives only stdin

---

## 11. Operating the System

1. Run the script: `bash nlc.sh`
2. Settings: Choose provider, enter keys, (optional) set token caps/pacing and `NLC_TASK_COMMAND`
3. Start New Project: Provide project name, language, one‑sentence intent. Optionally point to docs
4. Answer Q&A: Keep answers concise. The script records the transcript
5. Review Output: Inspect the generated repo. `README.md` includes the Intent→Code Map; `CLAUDE.md` defines policy
6. Use with Claude Code:
   - Navigate to the generated project directory
   - Start Claude Code in that directory
   - Run `/init` to analyze the codebase
   - Say "use nlc_claude.sh" or run `./tools/nlc_claude.sh` for project context
   - Claude Code will have full project understanding and can implement features
7. Run Tests: `make test` to validate implementations
8. Iterate / Fix: If you hit errors, use the script's Iterate mode: paste logs, select files to touch, apply the patch manifest

---

## 12. Scaling & Extensions

- **Contracts:** For larger systems, encode APIs and schemas under `contracts/` (OpenAPI, Protobuf, JSON Schema)
- **CI/CD:** Plug tests into CI to lock behavioral determinism
- **Local models:** With `ollama`, you can keep conversations private for sensitive early drafts
- **Provider mix:** Use Claude here (conversation compiler) and Claude Code as implementer; or swap the conversation provider to suit your needs

---

## 13. Limitations & Future Work

- Token estimation is coarse; the script warns but cannot guarantee exact budget adherence
- Some provider responses may still violate the JSON contract; the script saves raw failures for manual correction
- Locking uses `flock` or a lock‑directory fallback; on unusual filesystems this may need tuning
- Future: structured multi‑round planning manifests, richer test harness templates per language, and template libraries per domain

---

## 14. Appendix

### 14.1 Minimal `CLAUDE.md` Policy Block (ensured by script)

```markdown
## Claude Code Policy (NLC)

**Your role**: Claude Code in the terminal — implementer, not planner.

**Do not cheat**:
- Do not game tests or bypass checks.
- Do not mock functionality to fake a pass.
- Always run the test suite honestly and report failures truthfully.

**Work protocol**:
- Make small, PR-sized changes.
- Run `make test` after each change.
- Keep the Intent→Code Map in README.md aligned with any behavior change.

**Task capture**:
- Whenever you add a TODO/FIXME or leave a stub, create a task:
  `tools/task.sh "<short title>" "<details>"`.

**Source of truth**:
- Defer to `nlc.yaml`, `contracts/`, and `tests/`.
- Update them when scope or behavior changes.
```

### 14.2 `tools/task.sh` Behavior (installed if absent)

- Accepts `Title` and `Details`
- Writes Markdown (always), and JSON if `jq` is present; backs up malformed DBs
- Uses `flock` or `mkdir` lock. Supports `NLC_TASK_DRYRUN=1` for self‑test
- If `NLC_TASK_COMMAND` is set, it reads `Title\nDetails\n` from stdin and invokes your handler

### 14.3 JSON Manifest Validation

- The script strips markdown fences, parses JSON with `jq`, and aborts on errors
- Failed bodies are saved to `~/.nlc/work/model_*.json` to aid recovery

### 14.4 Example `Makefile` Targets (typical)

```makefile
test:
	sh tests/smoke.sh

clean:
	rm -f build/* *.tmp

all: test
```

---

**End of Natural Language Compiler Documentation**