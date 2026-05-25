# 0031. Layered runtime configuration precedence

- Status: accepted
- Date: 2026-05-25
- Deciders: @emacsway

## Context

Runtime configuration (`Trading_config.t` — broker selection +
credentials, server host/port, engine, watchlist, logging) is resolved
from several sources at process start. The mechanism was introduced in
commit `09aad21` ("config: layered configuration with JSON file + env +
CLI overlays") but **shipped without an ADR**; the precedence contract
lived only in `loader.mli` and the commit message. This ADR records the
decision and corrects an implementation gap that violated it.

ADR 0014 governs a different concern — it makes ATD the single source of
truth for **cross-BC wire contracts** (Commands, Integration Events,
View Models) to prevent producer/consumer drift. `trading_config.atd`
reuses the same atdgen tooling for its *type*, but the runtime config is
not a cross-BC message; its **loading precedence** is out of 0014's
scope and is the subject here.

## Decision

Configuration is composed from four layers, lowest to highest
precedence:

```
default.config.json  (committed)
  │ overridden by
local.config.json    (gitignored; path via --config / TRADING_CONFIG / ./config/local.config.json)
  │ overridden by
environment variables (FINAM_ACCOUNT_ID/SECRET, BCS_CLIENT_ID/SECRET,
  │                     ALOR_PORTFOLIO/SECRET/EXCHANGE, LOG_LEVEL)
  │ overridden by
per-invocation CLI flags (--broker, --account, --secret, --exchange,
                          --port, --log-level, ...)
```

So: **a local file overrides the committed default; environment
variables override the local file; CLI flags override the environment.**
Defaults live in `default.config.json` (not in `~default` ATD
annotations) so changing a default is an ops edit, not a recompile.

### Broker variant vs. credential fields

The broker is a sum-type variant (`Finam | Bcs | Alor | Synthetic`)
whose payload carries credentials. Two distinct rules apply:

- **Variant selection** is made by the file layer or a CLI `--broker`
  flag only. **Environment variables never select a variant** — an
  `FINAM_*` env var must not silently swap a BCS-configured book. Env
  vars only populate credential *fields* of the already-selected
  variant.
- **Credential fields** follow the full precedence per field:
  `CLI flag > env var > local file > default`.

### Why this needed a fix

The original implementation applied the env overlay to the
**file-layer** config and then merged the CLI overlay on top, where
`Merger.merge_broker` **replaces the broker variant wholesale**. So
whenever `--broker X` appeared on the CLI, the sparse CLI variant
(credential fields `None` unless `--account` / `--secret` were also
passed) replaced the env-enriched broker from the lower layers, dropping
the env credentials entirely. The documented "env overrides credentials"
held only when the broker was *not* named on the CLI — and the Alor
variant was never wired into the env overlay at all.

The fix resolves the broker explicitly in `Loader.load`, bypassing the
whole-variant replacement: the variant is taken from the CLI (else the
file layer), and each credential field is resolved
`CLI ?? env ?? file`. This honours the contract for every variant,
including a CLI-selected one, and covers Finam / BCS / Alor uniformly.

## Consequences

- The four-layer precedence is now an explicit, recorded decision, not
  tribal knowledge in a commit message.
- `serve` honours `FINAM_ACCOUNT_ID` / `FINAM_SECRET` / `BCS_*` /
  `ALOR_*` env vars regardless of whether the broker is named on the
  CLI or in a config file — matching the error messages and `--help`
  that have always promised it. The previous `cmd_serve`-local env
  fallback is removed in favour of the loader doing it for every
  consumer.
- Empty env vars are treated as unset (so a cleared variable does not
  shadow a file/default value), consistent with the broker adapters'
  own env handling.
- The no-broker-swap guard is preserved: env credentials enrich only the
  selected variant; they cannot conjure or switch one.
- Regression coverage: the config loader test suite gains cases for a
  CLI-selected broker enriched by env, CLI overriding env, and the Alor
  variant — the gap that let the original defect ship green (the prior
  "env overrides credentials" test exercised only the file-selected
  path).

## References

- Commit `09aad21` — introduced the layered loader (without an ADR;
  this ADR records and corrects it).
- ADR 0014 — ATD wire contracts (the type-generation tooling the config
  schema reuses; distinct from this loading-precedence concern).
- ADR 0030 — Alor adapter (whose `ALOR_PORTFOLIO` / `ALOR_SECRET` /
  `ALOR_EXCHANGE` env vars are wired into the loader here).
