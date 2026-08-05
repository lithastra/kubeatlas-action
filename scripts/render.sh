#!/usr/bin/env bash
# render.sh — invoke kubectl-atlas in offline mode and capture the
# rendered SVG.
#
# Inputs (environment variables):
#   KUBEATLAS_ACTION_SCOPE        cluster | namespace:<ns> | <kind>:<ns>:<name>
#   KUBEATLAS_ACTION_KUBECONFIG   path to kubeconfig, or empty
#   KUBEATLAS_ACTION_CONTEXT      kubeconfig context, or empty
#   KUBEATLAS_ACTION_OUTPUT       output SVG path (relative or absolute)
#
# Output (written to $GITHUB_OUTPUT):
#   svg-path  absolute path of the rendered SVG

set -euo pipefail

SCOPE="${KUBEATLAS_ACTION_SCOPE:-cluster}"
OUT="${KUBEATLAS_ACTION_OUTPUT:-kubeatlas.svg}"
KCFG="${KUBEATLAS_ACTION_KUBECONFIG:-}"
KCTX="${KUBEATLAS_ACTION_CONTEXT:-}"

# Build the kubectl-atlas argument list from the scope spec. The
# plugin's three forms map straight onto our three scope values; we
# enforce the shape so an unexpected scope fails the step instead
# of running the wrong query silently.
args=()
case "${SCOPE}" in
  cluster)
    args+=(cluster) ;;
  namespace:*)
    ns="${SCOPE#namespace:}"
    [[ -n "${ns}" ]] || { echo "render.sh: namespace scope is missing a name" >&2; exit 2; }
    args+=(namespace "${ns}") ;;
  *:*:*)
    IFS=: read -r kind ns name <<<"${SCOPE}"
    [[ -n "${kind}" && -n "${ns}" && -n "${name}" ]] \
      || { echo "render.sh: resource scope must be <kind>:<namespace>:<name>" >&2; exit 2; }
    args+=("${kind}" "${name}" -n "${ns}") ;;
  *)
    echo "render.sh: unsupported scope ${SCOPE}" >&2; exit 2 ;;
esac

# Cluster-selection flags pass through verbatim — empty values are
# elided so kubectl-atlas falls back to its own discovery.
[[ -n "${KCFG}" ]] && args+=(--kubeconfig "${KCFG}")
[[ -n "${KCTX}" ]] && args+=(--context "${KCTX}")
# CI is headless: never try a browser; the SVG goes to disk.
args+=(--no-browser)

mkdir -p "$(dirname "${OUT}")"
# Run kubectl-atlas in the output directory so the SVG it writes
# (kubeatlas-<scope>.svg) lands beside our requested OUT path; we
# then move it into place. The plugin uses a fixed
# kubeatlas-<scope>.svg name, so the OUT override happens here, not
# in the plugin invocation.
workdir="$(mktemp -d)"
trap 'rm -rf "${workdir}"' EXIT
( cd "${workdir}" && kubectl-atlas "${args[@]}" )

# kubectl-atlas writes kubeatlas-cluster.svg / kubeatlas-<ns>.svg /
# kubeatlas-<name>.svg depending on the scope; find it without
# depending on the name shape (the plugin's output naming is a
# private interface, not something this action should hardcode).
found=$(find "${workdir}" -maxdepth 1 -name 'kubeatlas-*.svg' | head -1)
if [[ -z "${found}" ]]; then
  echo "render.sh: kubectl-atlas produced no SVG" >&2
  exit 1
fi
mv "${found}" "${OUT}"

abs_out="$(readlink -f "${OUT}")"
echo "Rendered ${abs_out}"
echo "svg-path=${abs_out}" >> "${GITHUB_OUTPUT}"
