# Directory converter

This project walks an input tree with an explicit breadth-first queue. It adds
`# Converted\n` to regular UTF-8 files, creates corresponding directories,
and skips child symlinks and other targets. Empty directories are preserved.

```sh
mgn run mognitio.toml -- input output
mgn build mognitio.toml -o convert-tree
./convert-tree input output
```

The output parent must exist. For the first successful run, use an absent or
empty output tree physically independent of the input. A second run may reuse
the previous outputs when neither those outputs nor the input tree has changed.
Success is silent with status 0. Invalid arguments return 2; conversion failure
returns 1 and leaves earlier successful writes and directory creations in place.

`joinPath` combines text lexically. It does not normalize `..`, resolve links,
or confine access to a directory. Existing output symlinks, hardlinks or mount
aliases can redirect writes to an input or another output. The application does
not detect those aliases, remove stale files, roll back, or synchronize storage.

The [reference suite](../../tests/v013-reference.py) prepares isolated fixtures,
checks exact file bytes, ordering, empty directories and skipped entries, reruns
without changing the outputs, exercises partial failures and calls the same
converter from language tests. Fixture creation and deletion belong to the host
harness; no temporary-directory or removal API is added to the language.
