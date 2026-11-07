# BeDigit Stack binaries

Self-contained builds of open-source servers, used by [BeDigit Stack](https://bedigit.com). This repository holds only build recipes. Each recipe downloads an upstream source release, verifies its checksum, and compiles it so the result runs from any folder, with nothing else installed.

| Component | License | Bundled, linked statically |
|---|---|---|
| Nginx | BSD-2-Clause | PCRE2, zlib, OpenSSL |
| Apache httpd | Apache-2.0 | APR, APR-util, PCRE2, zlib, Expat, OpenSSL |
| MariaDB 12.3, 11.8, 11.4, 10.11 | GPL-2.0 | OpenSSL, zlib, PCRE2 |
| Redis | AGPL-3.0 (one of the three licenses it offers) | Its own vendored libraries, without its optional modules |
| Valkey | BSD-3-Clause | Its own vendored libraries |
| PHP | PHP-3.01 | Built by [static-php-cli](https://github.com/crazywhalecc/static-php-cli). Each extension is its own file, with its libraries linked into it, and the source of everything is in the same release |

Apache httpd for Windows isn't built here. Its release is an unmodified copy of the [Apache Lounge](https://www.apachelounge.com/download/) build, along with its checksums and signature, published by the **Mirror Apache for Windows** workflow. That workflow refuses a file that doesn't match the checksum and signing key pinned in `recipes/versions.env`.

Each archive includes the license of everything inside it, in `licenses/`.

## Platforms

macOS 11 or newer on Intel and Apple Silicon, and Linux with glibc 2.35 or newer on x86-64 and arm64. MariaDB is built for macOS only, because MariaDB publishes its own Linux builds.

## Build locally

```bash
./recipes/build-nginx.sh
```

MariaDB takes the series to build, and needs CMake and a current Bison:

```bash
./recipes/build-mariadb.sh 11.8
```

The result lands in `dist/`. A build fails if the binary links a library that a customer's machine might not have.

## Release

Run the **Build a component** workflow from the Actions tab, and turn on **publish** once the builds look right. Releases are tagged `<component>-<version>`, and the BeDigit Stack manifest pins each file by SHA-256.

PHP has its own **Build PHP** workflow, which takes a list of exact versions and leaves a draft release for each, for the owner to publish. To rebuild a version already published, such as to add an extension, give a **revision** above 1: the release is then tagged `php-<version>-<revision>`, so the published files, which the manifest pins, never change. The workflow refuses to upload into a published release.

For MariaDB, Redis and Valkey, test the build first, then run **Publish a build with its source** with that run's ID. It publishes those exact archives along with the source, which the GPL and AGPL call for.

## Update a source

Change the version, URL and checksum together in `recipes/versions.env` (MariaDB has only a version and checksum per series). Compare the checksum with the one upstream publishes, where it publishes one.
