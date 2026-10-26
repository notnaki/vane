# Security policy

## Report a vulnerability privately

Please [report a vulnerability through GitHub's private reporting form](https://github.com/notnaki/vane/security/advisories/new).
Do not disclose security vulnerabilities in public issues or pull requests.
Use the [public issue tracker](https://github.com/notnaki/vane/issues) for ordinary
bugs and feature requests, without sensitive information.

Include the Vane version/build, macOS version, steps to reproduce, expected and
observed behavior, and potential impact. A minimal proof of concept helps; remove
passwords, tokens, personal browsing data, and private documents from examples.

We aim to acknowledge reports within **7 days**. This is a target, not a guaranteed
response or fix deadline. We will use the private report to discuss reproduction,
progress, and coordinated disclosure. Please allow time to investigate and make a
fix available before publishing details.

## Scope

Reports about Vane's own code are in scope, including saved passwords and autofill,
browser imports, certificate exceptions, permission prompts, extension consent and
installation, and the updater. Vane's handling of untrusted websites and extensions
is also in scope.

Vane uses the system WebKit engine. Report vulnerabilities in WebKit or macOS to
[Apple Security](https://support.apple.com/en-us/102549). Report vulnerabilities
inside third-party extensions to their maintainers. If you are unsure whether a
problem belongs to Vane, report it privately here and we can help identify the
appropriate project.

## Supported versions

Security fixes target the **latest stable Vane release**. Older releases do not
receive security backports; update to the
[latest release](https://github.com/notnaki/vane/releases/latest).
Reports affecting development or prerelease builds are welcome, but those builds
are not a separately supported security release line.

Keep macOS and its system WebKit up to date as well; a Vane update does not replace
Apple's security updates.
