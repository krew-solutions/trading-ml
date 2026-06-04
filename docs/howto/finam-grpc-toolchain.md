# Finam gRPC adapter: build toolchain

The `trading.finam_grpc` adapter generates its protobuf bindings at build time
and links a gRPC-over-HTTP/2 stack. Two things must be present in the switch
before `dune build` can compile it. This is a one-time setup per switch.

See ADR 0033 for *why* the dependency set looks the way it does (in short:
`grpc-eio`'s declared bounds are stale w.r.t. ocaml 5.4 + `eio 1.x`, so we pull
the modern `h2 0.13` line with the bound overridden and drive the HTTP/2 loop
ourselves).

## 1. `protoc` (the protobuf compiler)

Needed at build time by the codegen rule in `proto/dune`, and by
`ocaml-protoc-plugin`'s build. Any protobuf 3.x+ release works.

Distro package (recommended):

```sh
sudo apt-get install -y protobuf-compiler   # Debian/Ubuntu
```

Or a prebuilt release without root — unzip into a prefix on `PATH`, e.g.
`~/.local`, and (so `ocaml-protoc-plugin`'s build can find the well-known-type
includes) provide a `protobuf.pc` for `pkg-config`:

```sh
ver=35.0
curl -sL -o /tmp/protoc.zip \
  "https://github.com/protocolbuffers/protobuf/releases/download/v${ver}/protoc-${ver}-linux-x86_64.zip"
unzip -o /tmp/protoc.zip -d "$HOME/.local"        # bin/protoc + include/google/protobuf/*
mkdir -p "$HOME/.local/lib/pkgconfig"
cat > "$HOME/.local/lib/pkgconfig/protobuf.pc" <<EOF
prefix=$HOME/.local
includedir=\${prefix}/include
Name: Protocol Buffers
Description: protobuf
Version: ${ver}
Cflags: -I\${includedir}
EOF
export PATH="$HOME/.local/bin:$PATH"
export PKG_CONFIG_PATH="$HOME/.local/lib/pkgconfig:$PKG_CONFIG_PATH"
```

`protoc` must be on `PATH` whenever `dune build` runs the codegen rule.

## 2. The opam packages

```sh
# gRPC core + HTTP/2 stack, keeping eio at 1.x. The override is required:
# grpc 0.2.0 declares a stale `h2 < 0.13` bound, but h2 0.12 needs ocaml < 5.3,
# and h2 0.13 is what supports ocaml 5.4 + eio 1.x.
opam install grpc-eio eio.1.3 h2.0.13.0 h2-eio.0.13.0 \
  --ignore-constraints-on h2,h2-eio

# protobuf codegen plugin (needs protoc per step 1; --assume-depexts skips the
# apt dpkg check when protoc was installed by hand)
opam install --assume-depexts ocaml-protoc-plugin
```

The adapter itself does not use the `grpc-eio` library (it builds its own Eio
HTTP/2 driver on `grpc` core + `h2` + `h2-eio` + `gluten`); installing
`grpc-eio` is just the simplest way to pull the consistent `grpc`/`h2 0.13`
set into the switch.

## 3. Verify

```sh
dune build broker/lib/infrastructure/acl/finam_grpc      # compiles, incl. codegen
dune runtest                                             # finam-grpc unit tests pass

# live transport check (network; no credentials needed — a bogus secret still
# returns a structured gRPC Unauthenticated, proving TLS+h2+framing+codec):
dune exec broker/test/grpc_smoke/finam_grpc_auth_probe.exe
# with real auth: FINAM_SECRET=<portal secret> dune exec ...auth_probe.exe
```
