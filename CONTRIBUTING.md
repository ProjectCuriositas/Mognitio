# Contributing

Write pull request titles and descriptions in English. Keep repository
documentation and code comments in English as well.

Describe the problem, resulting behavior, and relevant validation so a reader
can review the change without access to private discussions or documents.
Use repository-relative paths and examples that work in an ordinary checkout.

Keep public contributions free of personal or machine-specific context:

- Do not include personal names, usernames, hostnames, IP addresses, credentials,
  private repository references, or local installation paths.
- Do not copy private specifications, chat transcripts, machine setup notes,
  or agent session history into a pull request or repository file.
- Describe prerequisites and platform constraints as project requirements.
  Do not frame instructions around a contributor's personal workstation.
- Review logs, screenshots, and generated artifacts for private information
  before including them.

## Language compatibility

Follow the [compatibility policy](COMPATIBILITY.md) when changing language
features. Within a major version, preserve existing source compatibility and
documented behavior alongside replacement features. Document the migration and
next-major removal, and cover both forms with regression tests while both remain
supported. A change that cannot preserve the old behavior must wait for the next
major release.

## Validation

Run the checks appropriate to the change. Compiler or test changes should run:

```sh
sbcl --noinform --script scripts/test.lisp
git diff --check
```

For documentation-only changes, check relative links, code fences, and
whitespace. Report commands, outcomes, and any unverified behavior honestly.
Use sanitized summaries when raw output contains local paths or other
machine-specific details.

See [verification](verification/README.md) for additional checks.
