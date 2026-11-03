# BeDigit Stack binaries

Self-contained builds of open-source servers, used by [BeDigit Stack](https://bedigit.com). This repository holds only build recipes. Each recipe downloads an upstream source release, verifies its checksum, and compiles it so the result runs from any folder, with nothing else installed.

| Component | License | Bundled, linked statically |
|---|---|---|
| Nginx | BSD-2-Clause | PCRE2, zlib, OpenSSL |
| Apache httpd | Apache-2.0 | APR, APR-util, PCRE2, zlib, Expat, OpenSSL |

Each archive includes the license of everything inside it, in `licenses/`.

## Platforms

macOS 11 or newer on Intel and Apple Silicon, and Linux with glibc 2.35 or newer on x86-64 and arm64.

## Build locally

```bash
./recipes/build-nginx.sh
```

The result lands in `dist/`. A build fails if the binary links a library that a customer's machine might not have.

## Release

Run the **Build a component** workflow from the Actions tab, and turn on **publish** once the builds look right. Releases are tagged `<component>-<version>`, and the BeDigit Stack manifest pins each file by SHA-256.

## Update a source

Change the version, URL and checksum together in `recipes/versions.env`. Compare the checksum with the one upstream publishes, where it publishes one.
