# Security Policy

## Security Maintainer

- **Primary Maintainer:** Mike Rinaldi ([@evilpotato](https://github.com/evilpotato))
- **Contact:** Report vulnerabilities privately via [GitHub Security Advisories](https://github.com/evilpotato/bc250-partial-core-unlock/security/advisories/new). Please do not open public issues for security reports.

## Scope and Security Context

`bc250-partial-core-unlock` provides low-level Linux tooling for AMD BC-250 platforms, including hardware state configuration, core management, and power-state adjustments.

Because utilities in this repository interact directly with privileged system interfaces (such as root-level execution, kernel parameters, PCIe/SMU registers, and hardware configuration states), security and safety are critical priorities. Downstream integrators (such as GUI wrappers and control centers) and end users rely on these tools to execute safely without introducing host vulnerabilities.

## In-Scope Security Issues

We actively monitor for and accept reports regarding:

- **Local Privilege Escalation (LPE):** Unsafe file permissions, insecure temporary file handling, or unquoted/unsanitized path execution when running with elevated privileges (sudo/root).
- **Command Injection / Argument Parsing Flaws:** Any vector where untrusted user or wrapper input passed to scripts or binaries could lead to arbitrary command execution.
- **Memory Safety & Bounds Checking:** Buffer overflows, out-of-bounds reads/writes, or integer overflows in compiled tooling or low-level memory/register operations.
- **Unsafe Hardware State Transitions:** Logic errors that bypass intended safety checks and could result in unrecoverable system states or unintended register writes outside the target AMD BC-250 hardware scope.

## Supported Versions

Security updates and patches are applied to the latest `main` branch and the most recent tagged release. Users and downstream projects are strongly encouraged to track the latest commit on `main`.
