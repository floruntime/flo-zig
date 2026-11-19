# Changelog

## Unreleased

- The server's op table hash is now `0xdc7e06b2a9f89c65`, the hash of flo `08d51612`; this SDK and older servers refuse each other. Run ids may now be up to 42 bytes (`{prefix}{bits}-{shard}-{term}`); treat them as opaque.
- `StreamSettingsOptions` gains `clear_retention_age` and
  `clear_retention_count`: an alter drops that bound. Leaving a bound 0
  still leaves it as it stands. An alter that sets and clears the same bound
  is `BadRequest`, sent nowhere. The server refuses a create that sends a
  clear, and a `retention_count` of the u64 max ("retention bound too
  large").
- `Reason` names `skipped_by_repair` (38): a repair skipped the log entry or
  channel message that carried the request, so it never runs, on any node.
- A stream deleted and made again under the same name, while the server
  still holds the deleted one's mark, continues its ids past the old
  stream's rather than starting over. The mark goes once its records are
  removed and no group counts it.
- A `groupSteal` naming no records is answered at once: nothing stolen, and
  a lease of zeros.
- The server refuses a processing job whose `name` is over 4096 bytes, and
  a workflow definition whose `version` is over 256 bytes (`BadRequest`).

## 0.1.0-dev.6 - 2026-11-18

Works with flo v0.1.0-dev.19.

- **Breaking:** pinned to the table hash of flo `1fd555dc` (`0xac07f1f7338c66bd`);
  this SDK and older servers refuse each other.
- `ActionRunStatus` gains `held`: why a run's lease, past due, isn't ended
  yet. The end of a run a workflow step called waits for room on the
  calling workflow's shard, and meanwhile the run isn't handed to another
  worker. Null otherwise.
- The action worker sends a complete or fail refused overloaded, without
  running, again, unchanged, with a backoff capped at 5 s, until the server
  takes it or answers otherwise, logging each wait; these resends don't
  count toward the three sends a lost result gets. A stopping worker gives
  up after 10 s. With concurrency 1, where the task runs on the poll
  thread, it heartbeats between tries, so a long wait doesn't get it marked
  unhealthy. Only a report that would end a run a workflow step called,
  refused while the calling workflow's shard has no room for the end, has
  the run's lease held meanwhile; for any other the lease keeps running and
  the run may be handed out again once it ends, so the result is
  at-least-once.
- `QueueRefusalWhy` and `GroupRefusalWhy` name `not_dead` (6): a dead-letter
  requeue or delete named something that isn't dead; and `not_idle` (7): a
  group steal named a record its holder touched within the idle time named.
- New `Stream.groupSteal`: take records another consumer holds and has
  left idle for at least `min_idle_ms`, each named with the deliveries its
  holder has. Idle is the time since the holder's read, a steal or any
  touch. What it takes is leased to the new consumer under one new lease
  (`GroupStealResult.lease`, `stolen` with the new deliveries), to ack, nack
  or touch as after a read; the rest are refused `not_idle`,
  `delivered_again`, `gone`, ... with a reason.
- New `Stream.groupDlqList`, `groupDlqRequeue` and `groupDlqDelete`: page a
  group's dead letters (deliveries, failures, when it died, its last error)
  by an opaque cursor, make them ready again with their failures reset, or
  delete them (`dry_run` says what it would). Requeue and delete take
  records by id, or `.all = true` for the oldest up to `limit`, answering
  applied, refused (`not_dead`, `gone`) and `more`.
- **Breaking:** queue dead letters moved to the server's op table
  (`queue.dlq_list`, 0x185). `dlqList` keeps its name: a page holds up to
  100, oldest dead first, and goes on by an opaque `DlqCursor` (`page.cursor`
  as the next `after`, until null); `total`, `has_more` and `last_seq` are
  gone. `DeadLetter` gains `failures`, `dead_at_ms` (was `moved_at_ms`) and
  `error_message` (its first 256 bytes); `priority` is a `u32`. A queue that
  doesn't exist is `error.NotFound`.
- New `Queue.dlqRequeue` and `dlqDelete`: make dead letters ready again with
  their failures reset, or delete them (`dry_run` says what it would). Each
  takes seqs, or `.all = true` for the oldest up to `limit`, answering
  applied, refused (`not_dead`, `gone`) and `more`.
- New `Stream.create` and `Stream.alter`, taking `StreamSettingsOptions`
  (`partitions`, a create's alone, and `retention_age_s`,
  `retention_count`); `StreamInfo` gains the retention. An alter naming
  `partitions` is `error.BadRequest`, sent nowhere. An alter
  works on a stream an append made (the server used to answer not found).
  Creating a stream again with the settings it has succeeds; with others,
  including after an alter changed them, it is `error.Conflict` ("the stream
  exists with other settings"). A create whose name's 64-bit hash another
  stream's name has is `error.Conflict` too. `info` now requires the
  server's whole answer, retention included.

## 0.1.0-dev.5 - 2026-11-16

- A non-blocking `stream.read` of a stream that isn't there, and a `ts.read`
  of a field with no matching series, are `error.NotFound` (the server now
  answers not found, not an empty result); a blocking read still waits for a
  stream's first append. Catch not found and start again if a reader may
  start first. A not-found marked stale is `error.StaleNotFound`, as for
  `get`: the stream or series may exist but the node that answered hasn't
  seen it yet, so read again.
- New `TimeSeries`: `write`, `read` (one page), `readAll` (an iterator over
  every page), `query` (windows of `window_ns`, with an `Aggregation`),
  `info` (with `oldest_ns`, `newest_ns`) and `floql`. Every time and window
  is Unix nanoseconds as `i64`; a write's
  `time_ns` of 0 takes the server's time, and one before 1970 is refused
  bad_request. A read takes a field, a tag filter, an inclusive ns range, a
  limit (1 to 4096), an `Order` (`oldest_first`, `newest_first`) and an
  opaque cursor; page until the cursor is null. A query window of 0, or one
  making more than 1024 windows, is refused bad_request. FloQL answers in ns
  (a bare number in a FloQL range is still epoch ms), and a raw answer of
  more than 4096 points is refused bad_request.
- **Breaking:** option tags `ts_timestamp` (0x67), `ts_from_ms` (0x60),
  `ts_to_ms` (0x61) and `ts_window_ms` (0x62) are `ts_timestamp_ns`,
  `ts_from_ns`, `ts_to_ns` and `ts_window_ns`, each an i64 of nanoseconds.
- `ProcessingStatusResult` gains `late_edge_ms` and `late_points`, and
  `late()`: at least that many of a job's TS source points came later than
  the edge; null (edge `NO_LATE_EDGE`) when there is no count.
- `StreamWorker.start()` returns `error.NotFound` when a group read is
  answered not found, rather than reading again.
- The `group_held_full` docs say the shard's cap clears as any of its groups
  and queues drain, this group included.
- **Breaking:** pinned to the table hash of flo `ad198c29` (`0x17f3632347cd6dd9`);
  this SDK and older servers refuse each other.
- `Reason` is non-exhaustive: a reason this SDK predates decodes as its number,
  with the status and message in `lastError()`, rather than failing the call as
  `error.IncompleteResponse`.
- New reason `queue_full` (36), under `overloaded`: an enqueue past its queue's
  caps or the shard's. It drains as messages are acked, so the client retries
  it, as before.
- New reason `group_held_full` (37), under `overloaded`: a group read took
  nothing new because the group is at its caps (leased, ready and dead records
  together; dead ones stay until the group is deleted or a trim cuts them), or
  the shard's queues and groups are at their shared cap. `groupRead` returns the
  new `error.GroupHeldFull`, never retried; the stream worker logs it once and
  backs off, as for `limit`.
- `Ran` is non-exhaustive: an unknown value keeps the refusal's status and
  message, and is never retried.
- **Breaking:** a group nack's error travels in the body, up to 1024 bytes
  (`MAX_NACK_ERROR`); a longer one is `error.ValueTooLarge` before sending. The
  `error_text` option tag is gone.
- New `StreamGroupNackOptions.abandon`: hands records back unstarted, ready at
  once, the delivery counted but no failure, so they never dead-letter. It
  takes no `delay_ms`, `dead` or error (`error.BadRequest`). The stream
  worker's `stop()` now abandons its unstarted records rather than nacking them,
  and a record whose handler returns an error after the stop too; the new
  `StreamContext.stopping()` lets a long handler cut itself short.
- A group ack, nack or touch for a group that isn't there is `error.NotFound`
  as a whole, not every record `gone`; the stream worker logs it as such.
- **Breaking:** `PeekedMessage.attempts` and `DeadLetter.attempts` are
  `deliveries`.
- **Breaking:** consumer groups lease records until acked, as queues do.
  `Stream.groupRead` returns a `GroupReadResult`: the records, each with its
  `deliveries`, the read's `lease` (term, index) and `expires_at_ms`.
  `groupAck`, `groupNack` (with `delay_ms`, `dead` and an error) and the new
  `groupTouch` take the lease and the records, name the consumer, and return
  a `GroupReport` of what applied and each record refused, with why; a report
  for a delivery that has moved on applies nothing and says so, without an
  error. A record left past its lease is ready for the next read; one nacked
  or expired `max_deliver` times (5 by default) is dead. New:
  `groupCreate` (a lease of 5 s to 12 h, 30 s by default; 1 to 255 attempts;
  creating again with other settings is `error.Conflict`), `groupDelete` and
  `groupInfo`. A group name is at most 256 bytes.
- **Breaking:** `groupJoin` and `groupLeave` are gone, with
  `StreamGroupJoinOptions`, `StreamGroupAckOptions` and the join, leave, claim
  and configure-sweeper op codes: the server refuses them. The stream worker
  no longer joins or leaves; it acks and nacks naming its read's lease, and
  `StreamWorkerConfig.auto_touch` touches every record of a batch not yet
  reported, waiting ones included, every sixth of the lease (at least 100 ms
  apart, from the batch's arrival), re-paced off each touch answer's expiry;
  it stops only on a stale report, conflict, not_found or bad_request and
  retries anything else with back-off.
  `StreamContext` carries the `lease`, `deliveries()` and `touch()`.
  `groupList` and `groupMembers` now count the consumers holding records.
- **Breaking:** `routing_key` is gone from every KV option type. A key routes
  by its `{tag}`, or the whole key without one: keys stored together share a
  tag. `{}` routes every key with it together; a lone `{` routes by the whole
  key. `KV.begin` takes a key and pins the transaction to its tag;
  `Transaction.routing_key` is gone. Reason 18 is `keys_not_colocated`: a key
  in a transaction that routes elsewhere, refused bad_request without running.
  The largest value is 257,916 bytes and the largest JSON document 256,918.
- New status `limit` (15): `error.Limit`, with reason `memory_budget`,
  `too_many_actions`, `too_many_workflow_definitions` or
  `too_many_workflow_runs` in `lastError()`. The limits are built into the
  server, not settings, and `too_many_actions` counts per shard: retrying won't
  clear it until something is deleted (or, for the memory budget, the node gets
  more memory), so nothing retries it. For the workers, start fails with the limit error; a
  limit hit while running is logged and backed off (once per reason).
- **Breaking:** queues are leased until completed: delivery is at least
  once. `Queue.dequeue` (`0x181`) leases its messages to `options.consumer`
  for `lease_ms` (the server's 30 s by default) and returns their `lease`
  (term, index) and `expires_at_ms`; each `Message` carries `deliveries`.
  `Queue.ack` and `Queue.nack` are gone: `complete` (`0x182`), `fail`
  (`0x183`, with `delay_ms`, `dead` and an error) and the new `touch`
  (`0x184`) name the lease, the messages and the same consumer, and return a
  `QueueReport` of what applied and each message refused, with why (`gone`
  means completed already). `dequeue` with `.ack = true` completes them as they're taken, a one-shot
  consume; if the leader fails in between, they come back once their lease
  runs out.
  The old codes `0x171`, `0x172` and `0x174` are gone.
- **Breaking:** `Queue.dlqRequeue` and `DlqRequeueOptions` are removed: the
  server refuses a requeue as not implemented. The DLQ requeue and delete op
  codes go with them.
- **Breaking:** `Message.priority` is a u32, as the server sends it, and
  `delivery_count` is `deliveries`. `DequeueOptions.block_ms` is a u32
  defaulting to 0, no longer optional.
- `EnqueueOptions.delay_ms` holds a message back, at most a day.
  `Queue.purge` removes a queue's messages and says how many.
- A full queue (past its cap of messages or bytes, or its shard's of
  bytes) refuses an enqueue as `overloaded` without running it; the client
  retries it like any such refusal, then returns `FloError.Overloaded`.
- **Breaking:** `StorageTier` follows the server: hot 0, warm 1, disk 2. A
  tier this SDK predates is kept as its number instead of refusing the read.
- A stream worker reads again, logging a warning, when a group read is
  refused `unavailable` without running (its records are still being read
  from disk): the read claimed nothing.
- Docs: `stale` also marks reads from a node whose log reads are blocked,
  not only a halted shard.
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
  it for good. A task for an action the worker has no handler for fails
  with retry too. `stop()` lets running handlers finish and report.
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
