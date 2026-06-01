#!/usr/bin/env bash
# Regenerate the TypeScript footprint contracts from the shared ATD
# source of truth — the same .atd files atdgen consumes for the OCaml
# wire types, so the UI and the backend cannot drift on the footprint
# shape (the motivation for atdts on this slice; ADR 0032 / footprint-UI).
#
# Scope is deliberately narrow: only the footprint integration event and
# the two view models it nests. The rest of the UI's Wire* types remain
# hand-written for now.
#
# atdts must be on PATH (opam install atdts; pinned to 4.1.0 to match the
# atd/atdgen the backend uses). Generated .ts is committed, so a checkout
# without atdts still builds — run this only when a contract changes.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_root="$(cd "$here/.." && pwd)"
repo_root="$(cd "$ui_root/.." && pwd)"

contracts_vm="$repo_root/shared/contracts/order_flow/view_models"
contracts_ie="$repo_root/shared/contracts/order_flow/integration_events"
out="$ui_root/src/app/footprint/generated"

if ! command -v atdts >/dev/null 2>&1; then
  echo "error: atdts not found on PATH (opam install atdts)" >&2
  exit 1
fi

mkdir -p "$out"
# atdts writes <name>.ts beside its input, so generate in a scratch dir
# then move the .ts into the UI tree. Pass all three together so the
# cross-file <ts from=...> imports resolve.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cp "$contracts_vm/instrument_view_model.atd" \
   "$contracts_vm/cluster_view_model.atd" \
   "$contracts_ie/footprint_completed_integration_event.atd" \
   "$tmp/"

(cd "$tmp" && atdts \
  instrument_view_model.atd \
  cluster_view_model.atd \
  footprint_completed_integration_event.atd)

for f in instrument_view_model cluster_view_model footprint_completed_integration_event; do
  mv "$tmp/$f.ts" "$out/$f.ts"
done

echo "generated $out/{instrument_view_model,cluster_view_model,footprint_completed_integration_event}.ts"
