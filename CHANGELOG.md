# Changelog

## Unreleased

- **Breaking:** pinned to the table hash of flo `723fd758` (`0xc688167b51fcc846`);
  this SDK and older servers refuse each other.
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
  `StreamWorkerConfig.auto_touch` touches each record every sixth of its lease
  (at least 100 ms apart, from the batch's arrival) while its handler runs.
  `StreamContext` carries the `lease`, `deliveries()` and `touch()`.
  `groupList` and `groupMembers` now count the consumers holding records.
- **Breaking:** `routing_key` is gone from every KV option type. A key routes
  by its `{tag}`, or the whole key without one: keys stored together share a
  tag. `KV.begin` takes a key and pins the transaction to its tag;
  `Transaction.routing_key` is gone. Reason 18 is `keys_not_colocated`: a key
  in a transaction that routes elsewhere, refused bad_request without running.
  The largest value is 257,916 bytes and the largest JSON document 256,918.
- New status `limit` (15): `error.Limit`, with reason `memory_budget`,
  `too_many_actions`, `too_many_workflow_definitions` or
  `too_many_workflow_runs` in `lastError()`. Terminal: retrying won't clear it
  until something is deleted, the node gets more room, or a setting is raised,
  so nothing retries it. The workers back off a poll refused this way and log
  it once per reason.
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
