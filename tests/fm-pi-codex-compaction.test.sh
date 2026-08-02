#!/usr/bin/env bash
# Behavioral lifecycle checks for the tracked Pi -> Codex server-compaction bridge.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pi-codex-compaction)
EXT="$ROOT/.pi/extensions/fm-codex-compaction.ts"
PI_PACKAGE_DIR=${FM_PI_PACKAGE_DIR:-"$(npm root -g 2>/dev/null)/@earendil-works/pi-coding-agent"}

cleanup() {
  fm_test_cleanup
}
trap cleanup EXIT

# Pi resolves extension imports through jiti aliases that cover only the pi-ai
# root, /compat, /oauth, and /providers/all. Node/tsc resolution through
# node_modules accepts far more, so the tracked file must be proven loadable by
# Pi's own loader, not just by a symlinked package tree.
run_extension_loader_tests() {
  local out out_file status
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi extension loader test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/dist/core/extensions/loader.js" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent loader not found"
    return 0
  fi

  mkdir -p "$TMP_ROOT/loader"
  out_file="$TMP_ROOT/loader/node.out"
  FM_PI_LOADER="$PI_PACKAGE_DIR/dist/core/extensions/loader.js" FM_EXT="$EXT" \
    node --input-type=module >"$out_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";

const loader = await import(pathToFileURL(process.env.FM_PI_LOADER).href);
const { extensions, errors } = await loader.loadExtensions([process.env.FM_EXT], process.cwd());
if (errors.length > 0) {
  throw new Error(`Pi's extension loader rejected the tracked extension: ${errors.map((entry) => String(entry.error)).join("; ")}`);
}
if (extensions.length !== 1) {
  throw new Error(`Pi's extension loader produced ${extensions.length} extensions`);
}
JS
  status=$?
  out=$(<"$out_file")
  [ "$status" -eq 0 ] || fail "Pi Codex compaction extension does not load in Pi: $out"
  [ -z "$out" ] || fail "Pi extension loader check printed output: $out"
  pass "Pi Codex compaction extension loads through Pi's own extension loader aliases"
}

run_extension_lifecycle_tests() {
  local fixture out out_file status
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "skip: node or npm not found for Pi Codex compaction test"
    return 0
  fi
  if [ ! -f "$PI_PACKAGE_DIR/package.json" ]; then
    echo "skip: installed @earendil-works/pi-coding-agent package not found"
    return 0
  fi

  fixture="$TMP_ROOT/lifecycle"
  mkdir -p "$fixture/.pi/extensions" "$fixture/node_modules/@earendil-works"
  cp "$EXT" "$fixture/.pi/extensions/fm-codex-compaction.ts"
  ln -s "$PI_PACKAGE_DIR" "$fixture/node_modules/@earendil-works/pi-coding-agent"
  ln -s "$PI_PACKAGE_DIR/node_modules/@earendil-works/pi-ai" "$fixture/node_modules/@earendil-works/pi-ai"
  printf '%s\n' '{"type":"module"}' >"$fixture/package.json"

  out_file="$fixture/node.out"
  EXT="$fixture/.pi/extensions/fm-codex-compaction.ts" node --input-type=module >"$out_file" 2>&1 <<'JS'
import { pathToFileURL } from "node:url";
import { zstdDecompressSync } from "node:zlib";

const extension = await import(`${pathToFileURL(process.env.EXT).href}?test=${Date.now()}`);

const zeroUsage = {
  input: 0,
  output: 0,
  cacheRead: 0,
  cacheWrite: 0,
  totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
};
const model = {
  id: "gpt-5.4",
  name: "Codex fixture model",
  api: "openai-codex-responses",
  provider: "openai-codex",
  baseUrl: "https://chatgpt.com/backend-api",
  reasoning: true,
  thinkingLevelMap: { minimal: "low" },
  input: ["text"],
  cost: { input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0 },
  contextWindow: 200000,
  maxTokens: 32000,
};
const nonCodexModel = { ...model, api: "openai-responses", provider: "openai" };
const token = [
  Buffer.from("{}", "utf8").toString("base64url"),
  Buffer.from(JSON.stringify({
    "https://api.openai.com/auth": { chatgpt_account_id: "account_fixture" },
  }), "utf8").toString("base64url"),
  "fixture-signature",
].join(".");

function makeExtension() {
  const handlers = {};
  extension.default({
    on(event, candidate) {
      handlers[event] = candidate;
    },
  });
  if (!handlers.session_before_compact) throw new Error("extension did not register session_before_compact");
  if (!handlers.before_provider_request) throw new Error("extension did not register before_provider_request");
  return handlers;
}

function makeHandler() {
  return makeExtension().session_before_compact;
}

const readTool = {
  type: "function",
  name: "read",
  description: "Read a file.",
  parameters: { type: "object", properties: { path: { type: "string" } } },
  strict: false,
};

function makeMessages(label = "first") {
  return [
    { role: "user", content: `Please inspect ${label}.`, timestamp: 1 },
    {
      role: "assistant",
      content: [
        { type: "text", text: `Inspecting ${label}.` },
        { type: "toolCall", id: `call_${label}|fc_${label}`, name: "read", arguments: { path: `${label}.txt` } },
      ],
      api: "openai-codex-responses",
      provider: "openai-codex",
      model: "gpt-5.4",
      usage: zeroUsage,
      stopReason: "toolUse",
      timestamp: 2,
    },
    {
      role: "toolResult",
      toolCallId: `call_${label}|fc_${label}`,
      toolName: "read",
      content: [{ type: "text", text: `${label} contents` }],
      details: {},
      isError: false,
      timestamp: 3,
    },
  ];
}

function preparation(overrides = {}) {
  return {
    firstKeptEntryId: "kept-1",
    messagesToSummarize: makeMessages(),
    turnPrefixMessages: [],
    isSplitTurn: false,
    tokensBefore: 90000,
    previousSummary: undefined,
    fileOps: {
      read: new Set(["first.txt", "read-only.txt"]),
      written: new Set(),
      edited: new Set(["first.txt"]),
    },
    settings: { enabled: true, reserveTokens: 16384, keepRecentTokens: 20000 },
    ...overrides,
  };
}

function context({ activeModel = model, auth = { ok: true, apiKey: token }, authCounter, notices } = {}) {
  return {
    model: activeModel,
    thinkingLevel: "medium",
    ui: {
      notify(message, type) {
        if (notices) notices.push({ message, type });
      },
    },
    modelRegistry: {
      async getApiKeyAndHeaders() {
        if (authCounter) authCounter.count += 1;
        return auth;
      },
    },
  };
}

function event(overrides = {}) {
  const controller = overrides.controller ?? new AbortController();
  return {
    type: "session_before_compact",
    preparation: preparation(),
    branchEntries: [],
    customInstructions: "Preserve exact failures",
    reason: "manual",
    willRetry: false,
    signal: controller.signal,
    ...overrides,
  };
}

function structuredSummary(label) {
  return `## Goal\nContinue ${label}.\n\n## Constraints & Preferences\n- Keep exact behavior.\n\n## Progress\n### Done\n- [x] Compacted ${label}.\n\n### In Progress\n- [ ] Continue.\n\n### Blocked\n- (none)\n\n## Key Decisions\n- **Bridge**: Replay server output.\n\n## Next Steps\n1. Continue ${label}.\n\n## Critical Context\n- auth ${token}`;
}

function prefixSummary(label) {
  return `## Original Request\nHandle ${label}.\n\n## Early Progress\n- Read the prefix.\n\n## Context for Suffix\n- Continue after ${label}.`;
}

function compactPayload(label = "server") {
  return {
    id: `cmp_${label}`,
    object: "response.compaction",
    output: [
      { type: "message", role: "user", content: [{ type: "input_text", text: `retained ${label}` }] },
      { type: "compaction_summary", id: `cmp_item_${label}`, encrypted_content: `opaque-${label}` },
    ],
    usage: {
      input_tokens: 100,
      output_tokens: 10,
      total_tokens: 110,
      input_tokens_details: { cached_tokens: 20 },
      output_tokens_details: { reasoning_tokens: 2 },
    },
  };
}

function sseResponse(summary, label = "bridge") {
  const events = [
    {
      type: "response.output_item.added",
      output_index: 0,
      item: { type: "message", id: `msg_${label}`, role: "assistant", status: "in_progress", content: [] },
    },
    { type: "response.output_text.delta", output_index: 0, content_index: 0, delta: summary },
    {
      type: "response.completed",
      response: {
        id: `resp_${label}`,
        status: "completed",
        output: [],
        usage: {
          input_tokens: 50,
          output_tokens: 25,
          total_tokens: 75,
          input_tokens_details: { cached_tokens: 5 },
          output_tokens_details: { reasoning_tokens: 3 },
        },
      },
    },
  ];
  const body = `${events.map((item) => `data: ${JSON.stringify(item)}\n\n`).join("")}data: [DONE]\n\n`;
  return new Response(body, { status: 200, headers: { "content-type": "text/event-stream" } });
}

function installFetch({ summaries = [structuredSummary("success")], compact = compactPayload(), failCompact = false } = {}) {
  const calls = [];
  let summaryIndex = 0;
  globalThis.fetch = async (input, init = {}) => {
    const url = String(input);
    const headers = new Headers(init.headers);
    const rawBody = headers.get("content-encoding") === "zstd"
      ? zstdDecompressSync(Buffer.from(init.body)).toString("utf8")
      : String(init.body ?? "{}");
    const body = JSON.parse(rawBody);
    calls.push({ url, body, headers, signal: init.signal });
    if (url.endsWith("/codex/responses/compact")) {
      if (failCompact) throw new Error("fixture endpoint unavailable");
      const payload = typeof compact === "function" ? compact(calls.length) : compact;
      return new Response(JSON.stringify(payload), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }
    if (url.endsWith("/codex/responses")) {
      const summary = summaries[summaryIndex++];
      return sseResponse(summary, `bridge_${summaryIndex}`);
    }
    throw new Error(`unexpected URL: ${url}`);
  };
  return calls;
}

// Compatible success uses the genuine endpoint, preserves Pi's cut metadata and
// tool-call structure, accounts for both calls, and never persists auth or opaque bytes.
{
  const calls = installFetch();
  const successEvent = event();
  const result = await makeHandler()(successEvent, context());
  if (!result?.compaction) throw new Error(`compatible Codex model did not compact after ${calls.length} request(s): ${calls.map((call) => call.url).join(", ")}`);
  if (calls.length !== 2) throw new Error(`compatible success made ${calls.length} requests`);
  if (!calls.every((call) => call.signal === successEvent.signal)) {
    throw new Error("Pi cancellation signal was not passed through both server calls");
  }
  if (calls[0].url !== "https://chatgpt.com/backend-api/codex/responses/compact") {
    throw new Error(`wrong server-compaction URL: ${calls[0].url}`);
  }
  if (!calls[0].body.input.some((item) => item.type === "function_call")) {
    throw new Error("server compaction lost assistant tool calls");
  }
  if (!calls[0].body.input.some((item) => item.type === "function_call_output")) {
    throw new Error("server compaction lost tool results");
  }
  if (!calls[1].body.input.some((item) => item.type === "compaction_summary")) {
    throw new Error("bridge request did not replay the opaque compaction item");
  }
  if (!JSON.stringify(calls[1].body.input).includes("Additional focus: Preserve exact failures")) {
    throw new Error("manual custom instructions were not preserved");
  }
  if (result.compaction.firstKeptEntryId !== "kept-1" || result.compaction.tokensBefore !== 90000) {
    throw new Error("Pi cut point or token count changed");
  }
  if (result.compaction.summary.includes(token) || result.compaction.summary.includes("opaque-server")) {
    throw new Error("credential or opaque item leaked into persisted summary");
  }
  if (JSON.stringify(result.compaction.details).includes("opaque-server") ||
      result.compaction.details?.opaqueReplayPersisted !== false) {
    throw new Error("details overclaimed native opaque replay");
  }
  if (result.compaction.usage?.totalTokens !== 185) {
    throw new Error(`combined usage was not preserved: ${JSON.stringify(result.compaction.usage)}`);
  }
  if (!result.compaction.summary.includes("<read-files>\nread-only.txt") ||
      !result.compaction.summary.includes("<modified-files>\nfirst.txt")) {
    throw new Error("file-operation tracking was not appended");
  }
}

// Unsupported models bypass both auth and network so Pi remains the owner.
{
  let fetches = 0;
  let authCalls = 0;
  globalThis.fetch = async () => { fetches += 1; throw new Error("must not fetch"); };
  const result = await makeHandler()(event(), context({
    activeModel: nonCodexModel,
    authCounter: { get count() { return authCalls; }, set count(value) { authCalls = value; } },
  }));
  if (result !== undefined || fetches !== 0 || authCalls !== 0) {
    throw new Error("non-Codex bypass did work before returning Pi fallback");
  }
}

// Missing/resolution-failed auth falls back before any request.
{
  let fetches = 0;
  globalThis.fetch = async () => { fetches += 1; throw new Error("must not fetch"); };
  const result = await makeHandler()(event({ reason: "threshold" }), context({ auth: { ok: false, error: "fixture auth absent" } }));
  if (result !== undefined || fetches !== 0) throw new Error("auth failure did not return Pi fallback");
}

// An already-aborted lifecycle never resolves auth or reaches the endpoint.
{
  const controller = new AbortController();
  controller.abort();
  const authCounter = { count: 0 };
  let fetches = 0;
  globalThis.fetch = async () => { fetches += 1; throw new Error("must not fetch"); };
  const result = await makeHandler()(event({ controller, reason: "overflow", willRetry: true }), context({ authCounter }));
  if (result !== undefined || fetches !== 0 || authCounter.count !== 0) {
    throw new Error("abort did not leave Pi's compaction lifecycle untouched");
  }
}

// Endpoint failures and malformed compact responses return no custom result.
{
  let calls = installFetch({ failCompact: true });
  let result = await makeHandler()(event(), context());
  if (result !== undefined || calls.length !== 1) throw new Error("endpoint failure did not fall back");

  calls = installFetch({ compact: { output: [{ type: "message", role: "user", content: [] }] } });
  result = await makeHandler()(event(), context());
  if (result !== undefined || calls.length !== 1) throw new Error("malformed server output did not fall back");
}

// Malformed bridge text also leaves stock compaction in control.
{
  const calls = installFetch({ summaries: ["unstructured bridge text"] });
  const result = await makeHandler()(event(), context());
  if (result !== undefined || calls.length !== 2) throw new Error("malformed bridge output did not fall back");
}

// A fresh extension instance after restart receives the persisted Pi summary,
// updates it remotely, and carries extension-owned file history forward.
{
  installFetch({ summaries: [structuredSummary("before restart")] });
  const first = await makeHandler()(event(), context());
  if (!first?.compaction) throw new Error("first persisted compaction failed");

  const calls = installFetch({ summaries: [structuredSummary("after restart")] });
  const nextPreparation = preparation({
    firstKeptEntryId: "kept-2",
    previousSummary: first.compaction.summary,
    messagesToSummarize: makeMessages("second"),
    fileOps: {
      read: new Set(["second.txt"]),
      written: new Set(["new.txt"]),
      edited: new Set(),
    },
  });
  const branchEntries = [{
    type: "compaction",
    id: "previous-compaction",
    details: first.compaction.details,
  }];
  const second = await makeHandler()(
    event({ preparation: nextPreparation, branchEntries, reason: "threshold" }),
    context(),
  );
  if (!second?.compaction) throw new Error("restart compaction failed");
  if (!JSON.stringify(calls[0].body.input).includes("Previous Pi checkpoint to preserve and update")) {
    throw new Error("previous summary was not supplied to server compaction");
  }
  const details = second.compaction.details;
  if (!details.readFiles.includes("read-only.txt") || !details.readFiles.includes("second.txt")) {
    throw new Error(`read-file persistence failed: ${JSON.stringify(details)}`);
  }
  if (!details.modifiedFiles.includes("first.txt") || !details.modifiedFiles.includes("new.txt")) {
    throw new Error(`modified-file persistence failed: ${JSON.stringify(details)}`);
  }
}

// Split turns retain Pi's two-summary structure and overflow retry metadata is
// left to Pi by returning only CompactionResult fields supported by the hook.
{
  const calls = installFetch({
    summaries: [structuredSummary("split history"), prefixSummary("split prefix")],
    compact(callNumber) { return compactPayload(`split_${callNumber}`); },
  });
  const splitPreparation = preparation({
    isSplitTurn: true,
    turnPrefixMessages: makeMessages("prefix"),
  });
  const result = await makeHandler()(
    event({ preparation: splitPreparation, reason: "overflow", willRetry: true }),
    context(),
  );
  if (!result?.compaction || calls.length !== 4) throw new Error("split-turn bridge did not run two server compactions");
  if (!result.compaction.summary.includes("**Turn Context (split turn):**") ||
      !result.compaction.summary.includes("## Original Request")) {
    throw new Error("split-turn summary shape was not preserved");
  }
  if (result.compaction.usage?.totalTokens !== 370) {
    throw new Error(`split usage was not combined: ${JSON.stringify(result.compaction.usage)}`);
  }
}

// The SDK-documented `compaction` item type is accepted alongside the live
// `compaction_summary` type the ChatGPT Codex route actually returns.
{
  const calls = installFetch({
    compact: {
      output: [
        { type: "message", role: "user", content: [{ type: "input_text", text: "retained sdk" }] },
        { type: "compaction", id: "cmp_item_sdk", encrypted_content: "opaque-sdk" },
      ],
    },
  });
  const result = await makeHandler()(event(), context());
  if (!result?.compaction || calls.length !== 2) throw new Error("SDK-documented compaction item type was rejected");
}

// Active Pi tool schemas observed on Pi's provider requests are sent with the
// compacted span whenever that span replays function calls.
{
  const handlers = makeExtension();
  handlers.before_provider_request({ type: "before_provider_request", payload: { model: "gpt-5.4", tools: [readTool] } });
  let calls = installFetch();
  let result = await handlers.session_before_compact(event(), context());
  if (!result?.compaction) throw new Error("tool-carrying compaction failed");
  if (JSON.stringify(calls[0].body.tools) !== JSON.stringify([readTool])) {
    throw new Error(`active tool schemas were not sent: ${JSON.stringify(calls[0].body.tools)}`);
  }

  calls = installFetch();
  const toollessPreparation = preparation({
    messagesToSummarize: [{ role: "user", content: "No tools were used here.", timestamp: 1 }],
  });
  result = await handlers.session_before_compact(event({ preparation: toollessPreparation }), context());
  if (!result?.compaction) throw new Error("tool-free compaction failed");
  if (calls[0].body.tools !== undefined) throw new Error("tool schemas were sent for a span with no function calls");
}

// Payloads that are not OpenAI Responses tool schemas never reach the endpoint.
{
  const handlers = makeExtension();
  handlers.before_provider_request({
    type: "before_provider_request",
    payload: { tools: [{ name: "read", input_schema: { type: "object" } }] },
  });
  const calls = installFetch();
  const result = await handlers.session_before_compact(event(), context());
  if (!result?.compaction) throw new Error("foreign tool payload broke compaction");
  if (calls[0].body.tools !== undefined) throw new Error("foreign-provider tool payload was forwarded");
}

// A compatible remote attempt that falls back warns the operator exactly once
// per rate-limit window, without secrets or response bodies.
{
  const notices = [];
  const handler = makeHandler();
  installFetch({ failCompact: true });
  await handler(event(), context({ notices }));
  if (notices.length !== 1 || notices[0].type !== "warning") {
    throw new Error(`fallback did not produce one operator warning: ${JSON.stringify(notices)}`);
  }
  if (notices[0].message.includes(token) || notices[0].message.includes("fixture endpoint unavailable")) {
    throw new Error("operator warning leaked a secret or a response body");
  }
  installFetch({ failCompact: true });
  await handler(event(), context({ notices }));
  if (notices.length !== 1) throw new Error("operator warning was not rate limited");
}

// One malformed bridge summary disables only this session's Codex bridge, tells
// the operator once, and leaves later compactions entirely to Pi.
{
  const notices = [];
  const handler = makeHandler();
  let calls = installFetch({ summaries: ["unstructured bridge text"] });
  let result = await handler(event(), context({ notices }));
  if (result !== undefined || calls.length !== 2) throw new Error("malformed bridge output did not fall back");
  if (notices.length !== 1 || notices[0].type !== "warning" || !notices[0].message.includes("disabled")) {
    throw new Error(`malformed bridge did not announce the session disable: ${JSON.stringify(notices)}`);
  }
  if (notices[0].message.includes(token) || notices[0].message.includes("unstructured bridge text")) {
    throw new Error("disable notice leaked a secret or a response body");
  }

  calls = installFetch();
  result = await handler(event({ reason: "threshold" }), context({ notices }));
  if (result !== undefined || calls.length !== 0) {
    throw new Error("disabled bridge still attempted server compaction");
  }
  if (notices.length !== 1) throw new Error("disabled bridge warned the operator more than once");
}

// The disable is per session: a fresh extension instance may use the bridge again.
{
  const handler = makeHandler();
  installFetch({ summaries: ["unstructured bridge text"] });
  await handler(event(), context());
  const calls = installFetch();
  const result = await makeHandler()(event(), context());
  if (!result?.compaction || calls.length !== 2) throw new Error("bridge disable leaked across sessions");
}

// Incompatible models, auth failures, and cancellation stay silent because they
// are not evidence that server compaction is broken.
{
  const notices = [];
  globalThis.fetch = async () => { throw new Error("must not fetch"); };
  await makeHandler()(event(), context({ activeModel: nonCodexModel, notices }));
  await makeHandler()(event(), context({ auth: { ok: false, error: "fixture auth absent" }, notices }));
  const controller = new AbortController();
  controller.abort();
  await makeHandler()(event({ controller }), context({ notices }));
  if (notices.length !== 0) throw new Error(`silent paths notified the operator: ${JSON.stringify(notices)}`);
}
JS
  status=$?
  out=$(<"$out_file")
  [ "$status" -eq 0 ] || fail "Pi Codex compaction lifecycle failed: $out"
  [ -z "$out" ] || fail "Pi Codex compaction lifecycle printed output: $out"
  pass "Pi Codex compaction uses server output with safe stock fallback and restart persistence"
}

run_extension_loader_tests
run_extension_lifecycle_tests
