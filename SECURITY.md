# Security

## Reporting a problem

Please report security problems privately, not in a public issue. Use GitHub's private
vulnerability reporting on this repository ("Report a vulnerability" under the Security tab), or
write to security@tryhushy.com.

Include what you found, how to reproduce it, and the version or commit. We will acknowledge the
report within five working days and keep you informed until it is fixed.

## Scope

In scope: the app and the command-line tools in this repository, including how they store data on
the Mac, what they send over the network, the MCP helper's access to notes, and the paste and
clipboard handling.

Out of scope: the maintainers' hosted services (account service, model host, website). Report
problems there privately in the same way, but do not test against those services without
permission.

## What the app sends

A build from this source sends nothing to the maintainers (BUILDING.md, "Services"). The
maintainers' signed build sends only what the person turned on, and Settings → Privacy & security
shows each item.
