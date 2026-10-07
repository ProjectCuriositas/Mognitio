# Compatibility policy

## Scope

Starting with 1.0.0, Mognitio guarantees backward source compatibility within
each major version series. This covers documented language features, including
syntax, typing rules, language semantics, and standard-library interfaces and
behavior used by Mognitio programs.

A valid program using the documented features of an earlier release in a major
series must remain valid and retain its documented behavior in later releases
of that same series. A minor or patch release must not silently reinterpret
existing code or turn it into an error.

Before 1.0.0, backward compatibility is not guaranteed. This policy does not
establish binary/ABI compatibility or stability of compiler internals. The
independently versioned VS Code extension retains its own compatibility table.

## Replacing a language feature

When a replacement for an existing feature is introduced in a major series:

1. Keep the old and new forms usable from the release that introduces the
   replacement through the remainder of that major series.
2. Preserve the old form's documented meaning during that period. Marking a
   form as deprecated does not permit rejecting it within the same major series.
3. End support for the replaced old form at the next major release. Compatibility
   support is not carried forward indefinitely across major versions.
4. If old and new behavior cannot coexist without breaking existing programs,
   defer the incompatible change to the next major release.

This rule applies to syntax changes and other potentially breaking language
changes. Compatibility is more than accepting the old syntax: its documented
typing and runtime behavior must also be preserved while it is supported.

A feature that has not been replaced or retired does not become invalid merely
because the major version changes. New features are supported from their
introduction onward; earlier compiler releases do not have to accept them.

## Example: a syntax replacement in 1.x

If a new syntax replaces an old syntax in 1.3.0:

| Compiler version | Old syntax | New syntax |
| --- | --- | --- |
| 1.0.x through 1.2.x | Supported | Not yet supported |
| 1.3.0 and later 1.x releases | Supported with its existing meaning | Supported |
| 2.0.0 and later 2.x releases | Rejected as a syntax error | Supported |

The compatibility period ends at the major-version boundary, regardless of
which 1.x release introduced the replacement. The same rule applies to later
major series.

## Change documentation and validation

A replacement must identify the old feature, its replacement, the release that
introduces the replacement, the major release that removes the old feature,
and the migration steps. Include this information in the change documentation
and relevant release notes.

While both forms are supported, regression tests must cover both forms and
preservation of the old form's documented behavior. The next major release
must document the removal and validate the intended rejection or other
specified failure of programs that still depend on the removed feature.
