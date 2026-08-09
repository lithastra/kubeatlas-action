#!/usr/bin/env bash
# policy-report.sh — render a Markdown summary of the policy
# violations KubeAtlas observes in the target cluster, for the action
# to append to a PR comment.
#
# The render binary is the `kubeatlas` CLI (not the kubectl plugin):
# its `diagnose --format json` runs an offline scan and emits a
# `policyViolations` array that normalises Gatekeeper and Kyverno
# violation status into one shape. We fetch that binary on demand —
# only when policy-report is enabled — so the default render path
# stays a single download.
#
# Inputs (environment variables):
#   KUBEATLAS_ACTION_SCOPE             cluster | namespace:<ns> | <kind>:<ns>:<name>
#   KUBEATLAS_ACTION_KUBECONFIG        path to kubeconfig, or empty
#   KUBEATLAS_ACTION_CONTEXT           kubeconfig context, or empty
#   KUBEATLAS_ACTION_RESOLVED_VERSION  the tag the install step resolved (e.g. v1.4.0)
#   KUBEATLAS_POLICY_REPORT_OUTPUT     Markdown output path (default policy-report.md)
#   KUBEATLAS_POLICY_REPORT_JSON       test seam: read diagnose JSON from this file
#                                      instead of running kubeatlas (skips the download)
#
# Output (written to $GITHUB_OUTPUT, when set):
#   policy-report-path  absolute path of the Markdown summary

set -euo pipefail

REPO="lithastra/kubeatlas"
SCOPE="${KUBEATLAS_ACTION_SCOPE:-cluster}"
KCFG="${KUBEATLAS_ACTION_KUBECONFIG:-}"
KCTX="${KUBEATLAS_ACTION_CONTEXT:-}"
OUT="${KUBEATLAS_POLICY_REPORT_OUTPUT:-policy-report.md}"

command -v jq >/dev/null || { echo "policy-report.sh: jq is required" >&2; exit 1; }

# diagnose_json prints the diagnose report as JSON on stdout. In a test
# run KUBEATLAS_POLICY_REPORT_JSON short-circuits the cluster scan so
# the rendering logic can be exercised against a fixture in CI.
diagnose_json() {
  if [[ -n "${KUBEATLAS_POLICY_REPORT_JSON:-}" ]]; then
    cat "${KUBEATLAS_POLICY_REPORT_JSON}"
    return
  fi
  install_kubeatlas
  # Map the action's scope spec onto diagnose's namespace flags.
  # diagnose is namespace- or cluster-scoped; a single-resource scope
  # reports that resource's namespace (the policy story is per-resource
  # within a namespace, not narrower).
  local dargs=()
  case "${SCOPE}" in
    cluster) dargs+=(--all-namespaces) ;;
    namespace:*)
      ns="${SCOPE#namespace:}"
      [[ -n "${ns}" ]] || { echo "policy-report.sh: namespace scope is missing a name" >&2; exit 2; }
      dargs+=(-n "${ns}") ;;
    *:*:*)
      IFS=: read -r _ ns _ <<<"${SCOPE}"
      [[ -n "${ns}" ]] || { echo "policy-report.sh: resource scope must be <kind>:<namespace>:<name>" >&2; exit 2; }
      dargs+=(-n "${ns}") ;;
    *)
      echo "policy-report.sh: unsupported scope ${SCOPE}" >&2; exit 2 ;;
  esac
  [[ -n "${KCFG}" ]] && dargs+=(--kubeconfig "${KCFG}")
  [[ -n "${KCTX}" ]] && dargs+=(--context "${KCTX}")
  dargs+=(--format json)
  kubeatlas diagnose "${dargs[@]}"
}

# install_kubeatlas fetches the kubeatlas CLI archive for the resolved
# version, verifies its sha256 against the release checksums, and puts
# the binary on PATH. Mirrors scripts/install.sh's verification so a
# tampered download fails before it runs.
install_kubeatlas() {
  command -v kubeatlas >/dev/null && return

  local want="${KUBEATLAS_ACTION_RESOLVED_VERSION:-}"
  if [[ -z "${want}" || "${want}" == "latest" ]]; then
    want="$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
      | sed -nE 's/.*"tag_name": *"([^"]+)".*/\1/p' | head -1)"
  fi
  [[ -n "${want}" ]] || { echo "policy-report.sh: could not resolve a kubeatlas version" >&2; exit 1; }

  local semver os arch_raw arch
  semver="${want#v}"
  os="$(uname -s | tr '[:upper:]' '[:lower:]')"
  arch_raw="$(uname -m)"
  case "${arch_raw}" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo "policy-report.sh: unsupported arch ${arch_raw}" >&2; exit 1 ;;
  esac

  local archive url tmp bin_dir
  archive="kubeatlas_${semver}_${os}_${arch}.tar.gz"
  url="https://github.com/${REPO}/releases/download/${want}/${archive}"
  tmp="$(mktemp -d)"
  bin_dir="${HOME}/.kubeatlas-action/bin"

  # Keep cleanup inside a subshell whose EXIT trap runs while tmp is
  # still in scope. A RETURN trap outlived this local variable and
  # failed under `set -u` after install_kubeatlas returned.
  (
    trap 'rm -rf "${tmp}"' EXIT

    echo "Downloading ${url}" >&2
    curl -fsSL -o "${tmp}/${archive}" "${url}"
    curl -fsSL -o "${tmp}/checksums.txt" \
      "https://github.com/${REPO}/releases/download/${want}/checksums.txt"
    ( cd "${tmp}" && grep -F "${archive}" checksums.txt | sha256sum -c - ) >&2

    tar -xzf "${tmp}/${archive}" -C "${tmp}"
    mkdir -p "${bin_dir}"
    mv "${tmp}/kubeatlas" "${bin_dir}/kubeatlas"
  )

  chmod +x "${bin_dir}/kubeatlas"
  export PATH="${bin_dir}:${PATH}"
  [[ -n "${GITHUB_PATH:-}" ]] && echo "${bin_dir}" >> "${GITHUB_PATH}"
}

# render_markdown turns a diagnose JSON document (stdin) into the
# Markdown summary written to OUT. A binary that predates the
# policyViolations field (older than v1.4) emits no such key — we say so
# rather than silently claim a clean cluster.
render_markdown() {
  local diag
  diag="$(cat)"

  if ! jq -e 'type == "object"' >/dev/null <<<"${diag}"; then
    echo "policy-report.sh: diagnose did not return a JSON object" >&2
    return 1
  fi

  {
    echo "### KubeAtlas policy report"
    echo

    if [[ "$(jq 'has("policyViolations")' <<<"${diag}")" != "true" ]]; then
      echo "_Policy reporting needs KubeAtlas v1.4 or newer; the installed CLI does not emit it._"
      return
    fi

    local count
    count="$(jq '.policyViolations | length' <<<"${diag}")"
    if [[ "${count}" -eq 0 ]]; then
      echo "✅ No policy violations in the \`${SCOPE}\` scope."
      return
    fi

    echo "⚠️ **${count} policy violation(s)** in the \`${SCOPE}\` scope:"
    echo
    echo "| Policy | Resource | Message |"
    echo "| --- | --- | --- |"
    jq -r '.policyViolations[]
      | "| \(.policy) | \(.resource) | \((.message // "") | gsub("[|\n]"; " ")) |"' <<<"${diag}"
  } > "${OUT}"
}

diagnose_output="$(diagnose_json)"
render_markdown <<<"${diagnose_output}"

abs_out="$(readlink -f "${OUT}")"
echo "Wrote policy report ${abs_out}"
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  echo "policy-report-path=${abs_out}" >> "${GITHUB_OUTPUT}"
fi
