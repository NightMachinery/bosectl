# Agent instructions for bosectl

## Install after changes stabilize

Install the latest build locally once a change has stabilized (feature works,
verified against the headphones, committed):

```sh
./install.sh          # builds release and installs to ~/.local/bin/bosectl
bosectl --version     # must match `let version` in Sources/bosectl/main.swift
```

`bosectl` on `PATH` is the tool used day to day; a stale binary there means
fixes and new flags silently don't exist for the user. Do this after the final
commit of a change, not while iterating.

## Layout

- `Sources/BMAP`: wire format, payload layouts and the typed `Headphones` API.
  No I/O, so everything here is unit-tested offline (`swift test`) against
  scripted and simulated devices.
- `Sources/BMAPBluetooth`: IOBluetooth discovery, the baseband link, and the
  RFCOMM `Session` that implements `Requester`; CoreBluetooth listening for
  advertisements (`Nearby`) and the experimental BMAP-over-LE `LESession`.
- `Sources/bosectl`: the command-line interface (swift-argument-parser).

## Conventions

- Shared with sonyctl: results on stdout (one JSON value under `--json`),
  diagnostics on stderr, exit status 0 ok / 1 failure / 2 usage / 3 not
  connected, and no command brings the Bluetooth link up unless asked to
  (`connect`, `--auto-connect`).
- Bump `let version` in `Sources/bosectl/main.swift` for user-visible changes.
- Releases are cut by pushing a `v*` tag, which triggers
  `.github/workflows/release.yml`. Tagging publishes a public GitHub Release;
  confirm with the user before doing it.
- This repo is public: never commit personal identifiers (real device
  addresses or names, hostnames, email, capture dumps). Use placeholders such
  as `00:11:22:33:44:55` and discover devices at runtime.
- Protocol knowledge may come from any existing implementation, but code is
  written here from scratch; never paste code from projects without a
  compatible license.
- Do not name third-party projects, their authors or their URLs anywhere in
  the repo: code, docs or commit messages. Credit prior work in general terms
  ("several open-source projects").
- Verify against real hardware where possible. The headphones must be linked
  to this Mac, and the Bose app on a phone may compete for the control channel.
- Keep `readme.org` and `docs/protocol.org` updated alongside code changes.
