# Changelog

## Unreleased

- **Breaking:** pinned to the table hash of flo `e63add5` (`0x7eb599c24442118b`);
  this SDK and older servers refuse each other.
- **Breaking:** the action reports follow the server's new ops (await
  `0x30A`, complete `0x30B`, fail `0x30C`, touch `0x30D`), with typed bodies;
  the old codes are gone. A task carries its delivery (`namespace`,
  `deliveries`, `term`, `index`, `lease_ms`), and `complete`, `fail` and
  `touch` take a `Delivery` (`task.delivery()`) and echo it, keyed by the run.
  `TaskAssignment.task_id` is `run_id` and `task_type` is `action`.
- **Breaking:** a report for a delivery that has moved on is
  `FloError.StaleReport` (conflict, reason `stale_report`); a resend of one
  that already applied answers ok.
- **Breaking:** `touch` takes no extend length and returns the lease's
  expiry; `ctx.touch()` likewise. `auto_touch` touches every sixth of the
  task's own lease (at least 100 ms apart), counted from when it arrived. A
  run is held at most 12 h from its delivery, whatever the touches. `fail`
  takes `abandoned` and `delay_ms`, and `retry` defaults to true, as on the
  server. `complete`'s outcome defaults to `""` (success).
- `awaitTask` takes a `request_key`: a retry with the same key gets the
  delivery the first try got. `ActionWorker` sends one with every poll and
  keeps it until an await is answered, so a refused or lost poll is sent
  again with it.
- **Breaking:** `ActionRegisterOptions.timeout_ms` defaults to 0, the
  server's 300 s lease, not 30 s.
- A handler error fails the run with retry; only `error.NonRetryable` fails
  it for good. A task for an action the worker has no handler for is handed
  back (abandoned). `stop()` lets running handlers finish and report.
- `Actions.info` reads an action's definition, run counts and latency;
  `getStatus` carries a completed run's `outcome`.
- **Breaking:** `listActions` returns each action's definition (`actions`:
  version, owner, timeout, attempts, created), not just names.
- An action's timeout is its lease: the server takes 5000 to 43200000 ms,
  and 0 for 300000. An owner is at most 256 bytes.
- **Breaking:** `Queue.peek` uses the server's peek (`0x180`) and returns a
  `PeekResult` (`messages`, `more`); the old peek, which answered empty, is
  gone. The limit is 1 to 100.
- **Breaking:** `Queue.dlqList` sends its `limit` and `after` in the value,
  as the server reads them, and returns a `DlqPage` (`letters`, `total`,
  `has_more`, `last_seq`).
- `Stream.groupList` and `Stream.groupMembers` list a stream's consumer
  groups and a group's members.
- `Processing.remove` removes a stopped, cancelled or failed job; a running
  one is refused (reason `job_running`).
- **Breaking:** `Processing.status` reads the job's runtime on the answering
  node and its definition (`yaml`); `failure_reason` is `reason`, which also
  says why a node holds a running job. List entries carry `batch_size` and
  `records_processed`, and workflow definitions `enabled`.
- KV docs: a refused condition or `cas_version` still costs a commit, and
  inside a transaction it is refused at commit, not at the op. A
  transaction holds 64 ops and 256 KiB by default, both operator settings.
- **Breaking:** reads, lists and scans in a namespace never created now
  return `FloError.NoNamespace` (status 14), where they answered empty or
  `NotFound`; a write still creates the namespace.
- A run id chosen at start (`.run_id`) is found by status, history, signal
  and cancel on any shard, and a later start of the same id on another
  workflow is refused as `FloError.Conflict`. Two starts of one id sent at
  once can both run; a lookup by the id then refuses it as `Conflict`.
- **Breaking:** `Workflow.listRuns` returns a page (`runs`, `has_more`,
  `cursor`), newest first, instead of raw bytes, and takes a `cursor` and a
  `search`; `status_filter` is renamed `status`. A page can be short while
  `has_more` is set.
- **Breaking:** `Stream.info` of a stream that doesn't exist is
  `FloError.NotFound`, not an empty stream. `StreamInfo` carries `first_id`
  and `last_id`, which `Stream.info` had set but the type lacked, so the call
  did not compile.
- **Breaking:** the cluster op codes follow the server: promote `0x032`,
  remove `0x033`, repair_skip `0x034`.
- **Breaking:** the retired namespace settings ops are dropped;
  `namespace_ensure` is added.
- **Breaking:** a `kv.scan` cursor's length prefix is a u16, so a cursor can
  hold a whole key.
- `Actions.listActions` lists a namespace's action names a page at a time,
  with a name prefix and a cursor.
- **Breaking:** `Workflow.listDefinitions` returns a page (`definitions`,
  `has_more`, `cursor`) callers continue from.
- **Breaking:** `Processing.list`'s page field `entries` is renamed `jobs`.
- `Stream.delete` deletes a stream.
- List answers whose cursor contradicts `has_more`, or that carry bytes past
  the cursor, are refused.
