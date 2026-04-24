# How to work with Gospel specifications

How to run the Gospel type-checker over annotated `.mli` files, add a
new specification, and work around the limitations of the current
Gospel release.

[Gospel][gospel] is a tool-agnostic specification language for OCaml.
You write contracts — `requires`, `ensures`, `raises`, `modifies` — in
`(*@ … *)` comments inside `.mli` signatures, and downstream tools
consume them: `gospel check` validates them syntactically and
name-resolves them against the OCaml types; [Ortac][ortac] translates
them into runtime assertions for property tests; [Cameleer][cameleer]
maps a subset into [Why3][why3] for proof. This repo currently wires
only `gospel check`.

[gospel]: https://github.com/ocaml-gospel/gospel
[ortac]: https://github.com/ocaml-gospel/ortac
[cameleer]: https://github.com/ocaml-gospel/cameleer
[why3]: https://why3.lri.fr/

## Run the checker

```bash
dune build @gospel
```

The `@gospel` alias walks every `.mli` under `lib/domain/` and runs
`gospel check` on files that carry at least one `(*@ … *)` block.
Exit status is `0` iff every annotation parses and every name inside
it resolves. A malformed annotation — misspelled exception, typo in a
field reference, reference to a non-existent function — fails the
alias with a pointed diagnostic.

## Add a new specification

1. Pick an `.mli` file under `lib/domain/`.
2. Below the `val` declaration, open a `(*@ … *)` block:

   ```ocaml
   val div : t -> t -> t
   (** Raises [Division_by_zero] if [b] is [zero]. *)
   (*@ r = div a b
       raises Division_by_zero -> b.raw = 0 *)
   ```

   Shape: `<result_var> = <fn_name> <arg_vars>` on the first line,
   then `requires` / `ensures` / `raises` clauses. See the
   [Gospel language reference][gospel-lang] for the full grammar.

3. `dune build @gospel` — the new file is picked up automatically
   (selection is driven by the presence of `(*@` in the source, not
   by a list).

4. If the check fails with
   `Error: Symbol Foo not found in scope`, you likely referenced an
   OCaml identifier Gospel can't resolve — either a typo, or one of
   the known limitations below.

[gospel-lang]: https://ocaml-gospel.github.io/gospel/language/syntax

## Known limitations of Gospel 0.3.1

### `Format.formatter` crashes the type-checker

Gospel's internal stdlib stub doesn't include `Format`. Any `.mli`
referencing `Format.formatter` crashes `gospel check` with
`File "src/typing.ml", line 721, … Assertion failed`.

**Mitigation.** The `@gospel` alias skips `.mli` files that have no
`(*@` annotation, so `pp`-only modules don't block the build. If you
want to annotate one of them, first strip `Format.formatter` from
the signature (replace `pp : Format.formatter -> t -> unit` with
`pp : t -> string` at the boundary, or move it to a companion
`*_pp.mli`).

### No understanding of dune-wrapped libraries

By default, a dune `(library (name core))` implicitly wraps
submodules as `Core.Decimal`, `Core.Instrument`, etc. Gospel doesn't
know this convention — pointing `--load-path` at `lib/domain/core/`
finds the sibling `.mli` files but not their wrapped namespace.
`engine/portfolio.mli` writes `Core.Instrument.t` in its types; a
plain `gospel check` fails with `Error: No module with name Core`.

**Mitigation.** `tools/gospel_wrap.sh` generates a synthesized
`core.mli` wrapper: one `module <Cap> : sig … end` block per
submodule, in topological order, with `Format.formatter` lines
stripped. The rule in `lib/domain/engine/gospel_stubs/dune` runs it
before `gospel check`, and the engine alias passes
`-L gospel_stubs` so the synthesized file is on the load path.

### `model` declarations don't cross files

A `(*@ model raw : integer *)` declaration on `Decimal.t` in
`decimal.mli` isn't visible when another file references
`Decimal.t`. The sibling file sees the OCaml type but not its
logical projection — `c.high.raw` fails with *Symbol raw not found
in scope*.

**Mitigation.** Each consumer declares a local logical abstraction:

```ocaml
(*@ function dec_raw (d : Decimal.t) : integer *)
```

`candle.mli` and `engine/portfolio.mli` carry such a declaration.
The two logical functions are disconnected from each other and from
Decimal's own `raw` — they're just abstract handles. Adequate for
`gospel check` (which only resolves names) but insufficient for
Ortac-generated runtime checks.

### No `module rec`

Gospel rejects mutually recursive module declarations
(`module rec A … and B …`), so the wrapper generator topologically
sorts modules by intra-library references. Circular references
between two modules in the same library are unsupported.

### Dune ignores subdirs starting with `_`

A generated-artifact subdir named `_gospel_stubs/` would be invisible
to dune — its internal rules wouldn't register. The synthesized
wrapper therefore lives in `gospel_stubs/` (no leading underscore).

## How the wiring fits together

```
dune-project
  └── (depends … (gospel (>= 0.3.1)))

lib/domain/core/dune
  └── (rule (alias gospel) …)        ; checks *.mli with (*@ annotations

lib/domain/engine/dune
  └── (rule (alias gospel) …)        ; depends on gospel_stubs/core.mli

lib/domain/engine/gospel_stubs/dune
  └── (rule (target core.mli) …)     ; invokes tools/gospel_wrap.sh

tools/gospel_wrap.sh
  └── python3 generator: topo-sort + strip Format.formatter
```

Adding a new library under `lib/domain/` that wants specs:

- Copy the `core/dune` pattern if the specs reference only
  intra-library types.
- Copy the `engine/` pattern (including a `gospel_stubs/` subdir) if
  specs reference types from another dune-wrapped library.

## Troubleshooting

**`Error: Symbol X not found in scope`** — check the Gospel
[symbols-in-scope][gospel-scope] reference. Most common causes: typo
in exception name, reference to a record field that doesn't exist on
the result type, use of an OCaml identifier that Gospel doesn't
model (e.g. anything from `Format`, `Printf`, `Buffer`).

**`gospel: internal error, … Assertion failed`** — almost always
the `Format.formatter` crash above. Confirm with
`grep -n Format.formatter <file>`; if present, either remove the
annotation from that file or move the `pp` signature out.

**`Error: No module with name Core`** — `gospel check` ran without
the synthesized wrapper on its load path. If you're invoking gospel
by hand (not via `dune build @gospel`), point it at the wrapper:

```bash
dune build lib/domain/engine/gospel_stubs/core.mli
gospel check -L lib/domain/engine/gospel_stubs -L lib/domain/engine \
  lib/domain/engine/portfolio.mli
```

**The alias passes but I expected it to fail** — confirm your
annotation actually contains `(*@` (not e.g. `(*&` or `(*! `); the
file selector is a literal grep. Confirm the file lives under
`lib/domain/`; files elsewhere are not in the alias's scope.

[gospel-scope]: https://ocaml-gospel.github.io/gospel/language/scope
