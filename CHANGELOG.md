# Changelog

## Unreleased

- **Breaking:** pinned to the table hash of flo `bdb66a0` (`0xa8de7758afa69427`);
  this SDK and older servers refuse each other.
- `FloError.NoNamespace` (status 14) is its own error, apart from `NotFound`.
  Reads in a missing namespace return it from the server version that adds it;
  until then they answer as an empty namespace.
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
