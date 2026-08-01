# Pi Codex compaction verification

This record contains version-scoped maintainer evidence for the stable mechanism owned by [Architecture - Pi Codex server compaction](../architecture.md#pi-codex-server-compaction).
It is not a second behavior specification.

## Verified versions

Verified on 2026-08-01:

```text
pi=0.83.0
codex=codex-cli 0.146.0
remote_compaction_v2                 stable             true
openai-node=6.26.0
responses/compact
```

The exact local probes were:

```sh
printf 'pi='; pi --version
printf 'codex='; codex --version
codex features list | awk '$1 == "remote_compaction_v2" { print }'
printf 'openai-node='; node -p "require('/Users/dangngo/.npm-global/lib/node_modules/@earendil-works/pi-coding-agent/node_modules/openai/package.json').version"
strings "$(command -v codex)" | grep -o 'responses/compact' | LC_ALL=C sort -u
```

No authentication values are printed by these probes.

## Source evidence

Pi 0.83.0's complete [compaction documentation](https://github.com/earendil-works/pi/blob/v0.83.0/packages/coding-agent/docs/compaction.md) describes its structured plain-text checkpoint, split-turn handling, previous-summary update, file tracking, usage field, and `session_before_compact` interception.
The installed `dist/core/compaction/compaction.js` and `dist/core/extensions/types.d.ts` confirm those behaviors and confirm that returning no compaction from the hook leaves stock compaction in control.
Pi's [extension documentation](https://github.com/earendil-works/pi/blob/v0.83.0/packages/coding-agent/docs/extensions.md) identifies `ctx.model`, resolved model authentication, cancellation signals, and the session lifecycle as public extension surfaces.
Pi's [custom-provider documentation](https://github.com/earendil-works/pi/blob/v0.83.0/packages/coding-agent/docs/custom-provider.md) identifies `openai-codex-responses` as the Codex Responses API and documents usage accounting and abort-aware provider calls.
The installed custom-compaction and custom-provider examples were reviewed in full before implementation.

Codex 0.146.0's official [`CompactClient`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/codex-api/src/endpoint/compact.rs) posts to `responses/compact` and returns response items.
Its canonical [`CompactionInput`](https://github.com/openai/codex/blob/rust-v0.146.0/codex-rs/codex-api/src/common.rs) carries model, input, instructions, tools, parallel-tool, reasoning, service-tier, and prompt-cache fields.
The installed binary independently reports `remote_compaction_v2` as stable and contains the same route.

OpenAI Node 6.26.0's official [`responses.compact`](https://github.com/openai/openai-node/blob/v6.26.0/src/resources/responses/responses.ts#L213-L229) posts to `/responses/compact`.
The same version's [`CompactedResponse`](https://github.com/openai/openai-node/blob/v6.26.0/src/resources/responses/responses.ts#L245-L271) documents retained user items followed by one compaction item and optional usage accounting.
Its [`ResponseCompactionItem`](https://github.com/openai/openai-node/blob/v6.26.0/src/resources/responses/responses.ts#L1604-L1649) documents opaque encrypted content and replay input shape.
The OpenAI [conversation-state guide](https://platform.openai.com/docs/guides/conversation-state#compaction-advanced) is the public API guide linked by that version-matched SDK.

## Live route evidence

The source citations above describe the SDK-documented contract, not the ChatGPT Codex backend the extension actually calls, so the compact leg was probed once against the real route on 2026-08-01 with an existing local ChatGPT session.
The probe sent synthetic single-file content invented for the probe, and only status codes, field names, item types, and value kinds were recorded; no credentials, no opaque bytes, and no session content were captured.

The compact leg accepts the extension's Codex-native body, with and without a `tools` array:

```text
POST https://chatgpt.com/backend-api/codex/responses/compact
body keys: model, input, instructions, tools, parallel_tool_calls, reasoning
with-tools    -> 200  output item types: message, message, compaction_summary
without-tools -> 200  output item types: message, message, compaction_summary
response keys: created_at, id, object, output, usage
usage keys:    input_tokens, input_tokens_details, output_tokens, output_tokens_details, total_tokens
terminal item keys: encrypted_content (string), id, type
```

Two facts corrected the implementation.
`parallel_tool_calls` and `reasoning` are accepted rather than rejected, which is why those Codex-native fields are retained.
The terminal opaque item is typed `compaction_summary` on this route, not the `compaction` documented by openai-node 6.26.0, and the installed Codex 0.146.0 binary contains both strings; validating only the documented type made every real compaction fall back silently, so the extension now accepts either type.

Replaying that unmodified output as the prefix of an ordinary Codex Responses request was probed on the same route family and streamed to completion:

```text
POST https://chatgpt.com/backend-api/codex/responses  -> 200
events: response.created, response.in_progress, response.output_item.added,
        response.content_part.added, response.output_text.delta, response.output_text.done,
        response.content_part.done, response.output_item.done, response.completed
```

This confirms the two-leg bridge end to end: the compact leg produces an opaque item and the replay leg consumes it.
The probe was a one-off compatibility check and is not part of the test suite, which stays credential-free.

## Behavioral evidence

The focused lifecycle test runs the tracked extension through Pi's public `session_before_compact` registration with mocked HTTP responses and no real credentials.
It covers compatible server-compaction success, both accepted opaque item types, active-tool schema forwarding and its omission for tool-free spans, rejection of foreign-provider tool payloads, non-Codex bypass, authentication failure, cancellation, endpoint failure, malformed compact output, malformed bridge output, the rate-limited operator fallback warning and the silent paths that must not raise it, repeated compaction after a fresh extension instance, previous-summary and file-list persistence, split turns, usage accounting, and all three trigger reasons.

```sh
bin/fm-test-run.sh tests/fm-pi-codex-compaction.test.sh
```

The verified result was:

```text
ok - Pi Codex compaction uses server output with safe stock fallback and restart persistence
FM_TEST_SUMMARY total=1 failed=0 skipped_gate=0
```

Every tracked Pi extension, including `.pi/extensions/fm-codex-compaction.ts`, is copied into the existing strict no-emit check in `tests/fm-pi-primary-types.test.sh`.
The new extension was also checked directly with TypeScript 5.9.3 under that test's strict NodeNext options and exited zero with no diagnostics.
