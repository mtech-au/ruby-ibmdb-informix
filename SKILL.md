---
name: ibm-db-informix
description: Install, build, and configure the mtech ibm_db fork in Informix (IDS) ODBC mode — IBM_DB_INFORMIX build flag, CSDK requirements, database.yml keys, and known limitations. Use when adding this gem to a project, writing Dockerfiles for it, configuring database connections, or debugging install/connect failures.
---

# ibm_db — Informix (IDS) fork: install and usage

This project uses a fork of the `ibm_db` gem (https://github.com/mtech-au/ruby-ibmdb-informix)
that can build its native extension against the **Informix CSDK ODBC driver**
(native SQLI over `onsoctcp`) instead of the default IBM DB2 CLI driver (DRDA).
The Informix mode is opt-in at **gem install time** via the `IBM_DB_INFORMIX`
environment variable. Without it, the gem behaves like upstream `ibm_db`
(downloads the DB2 clidriver and builds against it).

## Requirements (Informix mode)

- **Linux only.** `extconf` exits with an error on any other platform.
  x86_64 is the verified architecture; CSDK 4.50.13.10+ also ships an aarch64
  build (untested with this gem so far), enabling native builds on Apple
  Silicon Docker and Graviton. With the 12.10 Docker-image CSDK route
  (x86_64-only), use `--platform linux/amd64` on ARM hosts.
- **A pre-installed Informix CSDK** (or full IDS server install). Nothing is
  downloaded during the build. The directory must contain `incl/cli` (with
  `infxcli.h`) and `lib/cli` (with `libthcli.so` or `libifcli.so`).
- Ruby >= 2.5 with dev headers (`ruby-dev`) and a C toolchain (`build-essential`).
- Rails/ActiveRecord 7.2.x if using the adapter.

## Build-time environment variables

| Variable | Required | Meaning |
|---|---|---|
| `IBM_DB_INFORMIX` | yes | Set to `1`, `true`, or `yes` to select the Informix ODBC build. Anything else (or unset) builds the default DB2/DRDA driver. |
| `INFORMIXDIR` | yes* | Path to the CSDK/IDS installation (e.g. `/opt/informix`). |
| `IBM_DB_INFORMIX_HOME` | no | Alternative to `INFORMIXDIR`; takes precedence if both are set. |

The build bakes an rpath (`DT_RPATH`, transitive) to `$INFORMIXDIR/lib/cli`,
`lib/esql`, and `lib` into `ibm_db.so`, so `LD_LIBRARY_PATH` is not needed at
runtime — **but the CSDK must stay at the same path it had at build time.**

## Installing

### Gemfile (git source)

```ruby
gem 'ibm_db',
    git: 'https://github.com/mtech-au/ruby-ibmdb-informix.git',
    branch: 'master',
    glob: 'IBM_DB_Adapter/ibm_db/*.gemspec'
```

The `glob:` option is required — the gem lives in the `IBM_DB_Adapter/ibm_db/`
subdirectory of the repo, which Bundler's default gemspec search does not reach.

### Selecting the Informix build

Either export the variables before installing:

```bash
export IBM_DB_INFORMIX=1
export INFORMIXDIR=/opt/informix
bundle install
```

or persist the flag in Bundler config (still needs `INFORMIXDIR` in the env):

```bash
bundle config set build.ibm_db --enable-informix
```

Confirm the mode after install — the extension exposes a constant:

```ruby
require 'ibm_db'
IBM_DB::INFORMIX_ODBC   # => true when built in Informix mode, false for DB2/DRDA
```

If the gem was previously installed in DB2 mode, force a rebuild
(`gem pristine ibm_db` or reinstall) after setting the variables — the driver
choice is compiled in.

### Getting the CSDK

IBM's CSDK download portal requires an interactive IBMid login, so automated
installs must source the CSDK from somewhere else. Two routes, in order of
preference:

#### Route A (preferred): CSDK 4.50 tarball from the internal S3 bucket

The CSDK 4.50.13.10 installer tarballs (x86_64 **and** aarch64, ~75 MB each)
are hosted in a private company S3 bucket. Do **not** commit these tarballs to
project repositories — the CSDK is IBM-licensed proprietary software and the
bucket is the single controlled distribution point.

```dockerfile
FROM ruby:3.2 AS app
ARG TARGETARCH
# Presigned URL or bucket path injected at build time; needs read access to the bucket.
ARG CSDK_BASE_URL   # e.g. https://<bucket>.s3.<region>.amazonaws.com/csdk
# Keep INFORMIXDIR identical between build and runtime — the rpath is baked in.
ENV INFORMIXDIR=/opt/informix IBM_DB_INFORMIX=1
RUN case "$TARGETARCH" in amd64) A=x86_64 ;; arm64) A=aarch64 ;; esac \
 && curl -fsSL "$CSDK_BASE_URL/ibm.csdk.4.50.13.10.Linux.64.${A}.tar" -o /tmp/csdk.tar \
 && mkdir /tmp/csdk && tar -xf /tmp/csdk.tar -C /tmp/csdk \
 && /tmp/csdk/installclientsdk -i silent -DLICENSE_ACCEPTED=TRUE \
      -DUSER_INSTALL_DIR=$INFORMIXDIR \
 && rm -rf /tmp/csdk /tmp/csdk.tar
# ... bundle install ...
```

Notes:
- Running the installer implies acceptance of the IBM license
  (`-DLICENSE_ACCEPTED=TRUE`); that acceptance belongs to whoever builds the
  image, which is another reason to gate bucket access rather than vendor the
  tarball into repos.
- CSDK 4.50.xC4+ requires OpenSSL >= 1.0 on the system (any current
  Debian/Ubuntu base is fine).
- The aarch64 build makes native ARM (Apple Silicon Docker, Graviton)
  possible; it has not yet been smoke-tested against this gem — verify before
  relying on it in production.

#### Route B: copy from the 12.10 Docker image (x86_64 only, no credentials needed)

The only public Docker image that bundles a full CSDK is
`ibmcom/informix-developer-database:12.10.FC12W1DE`; a multi-stage copy from
it needs no S3 access or IBMid:

```dockerfile
FROM ibmcom/informix-developer-database:12.10.FC12W1DE AS csdk

FROM ruby:3.2 AS app
# Keep the same INFORMIXDIR path in every stage — the rpath is baked at build time.
ENV INFORMIXDIR=/opt/informix IBM_DB_INFORMIX=1
COPY --from=csdk /opt/ibm/informix/incl $INFORMIXDIR/incl
COPY --from=csdk /opt/ibm/informix/lib  $INFORMIXDIR/lib
COPY --from=csdk /opt/ibm/informix/gls  $INFORMIXDIR/gls
COPY --from=csdk /opt/ibm/informix/msg  $INFORMIXDIR/msg
COPY --from=csdk /opt/ibm/informix/etc  $INFORMIXDIR/etc
# ... bundle install ...
```

Notes (verified on clean ubuntu:24.04 / ruby images, amd64):
- No extra apt packages are needed beyond `ruby-dev`/`build-essential`; the
  CSDK libraries resolve fully against base glibc.
- At runtime only `lib`, `gls`, `msg`, `etc` are needed (~110 MB); `incl` is
  build-only. Keep `INFORMIXDIR` set in the runtime environment.
- The 14.10 and v15 images do **not** ship the CSDK; only
  `12.10.FC12W1DE` does. The 12.10 CSDK client works fine against IDS 12 and 14
  servers (verified).
- This image is x86_64-only: use `--platform linux/amd64` on ARM hosts (or
  use Route A, which has an aarch64 tarball).

## Usage

### Requiring the library

- `require 'ibm_db'` — low-level native driver only (`IBM_DB.connect`, etc.).
- `require 'IBM_DB'` — driver **plus** the ActiveRecord adapter. Use this
  (or the Gemfile entry with Rails) for Rails apps.

### Rails `database.yml` (Informix mode)

```yaml
production:
  adapter: ibm_db
  database: mydb
  username: informix
  password: <%= ENV["INFORMIX_PASSWORD"] %>
  informix_server: ol_informix1210   # REQUIRED: the INFORMIXSERVER name
  host: ids.example.com              # omit to resolve via $INFORMIXDIR/etc/sqlhosts
  service: 9088                      # port; also accepts `port:`; default 9088
  protocol: onsoctcp                 # default onsoctcp
  client_locale: en_US.8859-1        # optional
  db_locale: en_US.8859-1            # optional
```

Key differences from the stock DB2 configuration:

- **`informix_server` is mandatory** when the driver is built in Informix mode;
  the adapter raises `informix_server (the INFORMIXSERVER name) must be
  specified...` without it.
- `host`/`service`/`protocol` are optional **only** if the server entry exists
  in `$INFORMIXDIR/etc/sqlhosts`; otherwise provide all of `host` and
  `service` (`protocol` defaults to `onsoctcp`).
- DB2-only keys (`security`, `authentication`, `timeout` as CONNECTTIMEOUT)
  are ignored/not sent in Informix mode — the CSDK ODBC driver rejects them.

### Low-level driver connection string

```ruby
conn = IBM_DB.connect(
  "SERVER=ol_informix1210;DATABASE=mydb;HOST=ids.example.com;SERVICE=9088;" \
  "PROTOCOL=onsoctcp;UID=informix;PWD=secret;", '', ''
)
```

## Known limitations (Informix ODBC mode)

- **`rake db:create` / `db:drop` do not work** — CREATE/DROP DATABASE fails at
  the driver level (Informix error -11060) over this ODBC path. Create
  databases server-side (e.g. `dbaccess`) instead; migrations work normally.
- Server-only connections (no database) are unsupported.
- No LOB locators: Informix reports TEXT/BYTE columns as
  LONGVARCHAR/LONGVARBINARY; they are fetched as ordinary long values.
- ANSI (non-Unicode) build only — wide-char (`SQLWCHAR`) entry points are
  deliberately not used; set `client_locale`/`db_locale` for non-default
  character sets.

## Troubleshooting install failures

- `IBM_DB_INFORMIX=1 requires the INFORMIXDIR ... environment variable` —
  `INFORMIXDIR`/`IBM_DB_INFORMIX_HOME` unset or empty in the environment
  Bundler runs in (watch out for `sudo`/CI stripping env).
- `.../incl/cli not found` or `infxcli.h not found` — `INFORMIXDIR` points at a
  server-only install or an incomplete CSDK copy.
- `Unable to locate the Informix CSDK ODBC driver (libthcli/libifcli)` —
  `lib/cli` missing from the CSDK tree.
- `Informix ODBC mode ... only supported on Linux` — build inside a Linux
  container; there is no CSDK for macOS in this mode (Linux tarballs exist
  for x86_64 and, from CSDK 4.50.13.10, aarch64).
- Adapter connects but libraries fail to load at runtime — the CSDK moved or
  is absent at the build-time `INFORMIXDIR` path; rebuild the gem
  (`gem pristine ibm_db`) with the correct path.
