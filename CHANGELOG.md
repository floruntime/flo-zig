# Changelog

## Unreleased

- **Breaking:** pinned to the table hash of flo `3614d95` (`0xc751512225a42d04`);
  this SDK and older servers refuse each other.
- **Breaking:** `FloError.NoNamespace` (status 14) is its own error, apart from
  `NotFound`. Reads, lists and scans in a namespace never created return it;
  a write still creates the namespace.
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
