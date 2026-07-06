# KubeAtlas GitHub Action

[![Marketplace](https://img.shields.io/badge/marketplace-KubeAtlas%20Dependency%20Graph-blue?logo=github)](https://github.com/marketplace/actions/kubeatlas-dependency-graph)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue)](./LICENSE)

Render a [KubeAtlas](https://github.com/lithastra/kubeatlas) dependency
graph from a GitHub Actions workflow.

This action downloads the [`kubectl-atlas`](https://github.com/lithastra/kubeatlas/tree/main/cmd/kubectl-atlas)
plugin, points it at the kubeconfig you provide, and writes the
rendered SVG to disk. A later step can upload it as an artifact,
attach it to a release, post it as a PR comment, or anything else
your workflow does with files.

KubeAtlas is read-only — the action never modifies cluster state.

## Quick start

```yaml
name: Render cluster topology
on: [push]
jobs:
  render:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/setup-kubectl@v4
      - uses: azure/k8s-set-context@v4
        with:
          kubeconfig: ${{ secrets.KUBECONFIG }}
      - uses: lithastra/kubeatlas-action@v1
        with:
          scope: cluster
```

The cluster's dependency graph lands in `kubeatlas.svg` in the
workspace and is uploaded as the `kubeatlas-graph` artifact.

## Inputs

| Input | Default | Description |
|---|---|---|
| `version` | `latest` | `kubectl-atlas` release tag, or `latest` to resolve the newest release. |
| `scope` | `cluster` | What to render. `cluster`, `namespace:<name>`, or `<kind>:<namespace>:<name>`. Use `_` for the namespace of cluster-scoped resources. |
| `kubeconfig` | `` (env) | Path to a kubeconfig file. Empty falls back to `$KUBECONFIG`, then to kubectl's default discovery. |
| `kube-context` | `` | kubeconfig context to target. Empty uses the file's `current-context`. |
| `output` | `kubeatlas.svg` | Where to write the rendered SVG. Parent directories are created. |
| `upload-artifact` | `true` | Upload the SVG as the `kubeatlas-graph` workflow artifact. |
| `policy-report` | `false` | Also run `kubeatlas diagnose` over the same scope and write a Markdown summary of the policy violations (Gatekeeper / Kyverno) KubeAtlas observes. Requires KubeAtlas v1.4+. |

## Outputs

| Output | Description |
|---|---|
| `svg-path` | Absolute path of the rendered SVG. |
| `resolved-version` | The `kubectl-atlas` tag that ended up installed. |
| `policy-report-path` | Absolute path of the Markdown policy-violation summary, or empty when `policy-report` is `false`. |

## Recipes

### Render a namespace and post it as a PR comment

```yaml
jobs:
  diff:
    runs-on: ubuntu-latest
    steps:
      - uses: azure/k8s-set-context@v4
        with:
          kubeconfig: ${{ secrets.KUBECONFIG }}

      - uses: lithastra/kubeatlas-action@v1
        id: render
        with:
          scope: namespace:petclinic
          upload-artifact: 'false'

      - name: Comment on PR
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const fs = require('fs');
            const svg = fs.readFileSync('${{ steps.render.outputs.svg-path }}', 'utf8');
            github.rest.issues.createComment({
              owner: context.repo.owner,
              repo: context.repo.repo,
              issue_number: context.issue.number,
              body: `<details><summary>KubeAtlas: petclinic topology</summary>\n\n${svg}\n\n</details>`,
            });
```

### Add a policy-violation summary to the PR comment

With `policy-report: true` the action also runs `kubeatlas diagnose`
over the same scope and writes a Markdown table of the Gatekeeper
Constraint / Kyverno policy violations it observes. Read the path from
the `policy-report-path` output and append it to your comment body.
Requires KubeAtlas v1.4 or newer.

```yaml
- uses: lithastra/kubeatlas-action@v1
  id: render
  with:
    scope: namespace:petclinic
    upload-artifact: 'false'
    policy-report: 'true'

- name: Comment on PR
  uses: actions/github-script@v7
  env:
    SVG_PATH: ${{ steps.render.outputs.svg-path }}
    POLICY_PATH: ${{ steps.render.outputs.policy-report-path }}
  with:
    script: |
      const fs = require('fs');
      const svg = fs.readFileSync(process.env.SVG_PATH, 'utf8');
      const policy = process.env.POLICY_PATH
        ? fs.readFileSync(process.env.POLICY_PATH, 'utf8')
        : '';
      await github.rest.issues.createComment({
        owner: context.repo.owner,
        repo: context.repo.repo,
        issue_number: context.issue.number,
        body: `<details><summary>KubeAtlas: petclinic topology</summary>\n\n${svg}\n\n</details>\n\n${policy}`,
      });
```

A full workflow is in [`examples/policy-report-comment.yml`](./examples/policy-report-comment.yml).

### Render a single resource

```yaml
- uses: lithastra/kubeatlas-action@v1
  with:
    scope: Deployment:petclinic:api
```

### Pin to a specific KubeAtlas release

```yaml
- uses: lithastra/kubeatlas-action@v1
  with:
    version: v1.3.0
```

## Requirements

- A Linux `runs-on` (the action installs `graphviz` via `apt-get`).
- Network egress to `github.com` and `objects.githubusercontent.com`
  to fetch the `kubectl-atlas` release archive.
- A reachable Kubernetes API server. The action does not stand up a
  cluster for you — use [`helm/kind-action`](https://github.com/helm/kind-action)
  or [`azure/k8s-set-context`](https://github.com/Azure/k8s-set-context)
  to prepare one first.
- Compatible with KubeAtlas v1.4 and v1.5. v1.5 is a non-breaking
  minor release, so the action needs no changes to work with it;
  `policy-report` continues to function unchanged.

## Versioning

Major-version moving tags (`@v1`) and exact tags (`@v1.0.0`) are
both supported. The major-version tag advances on every release in
the same major line; exact tags are immutable.

The action's release cadence is independent of KubeAtlas itself.

## Roadmap

- **Dependency diff vs. base branch.** A future release will run
  the action twice (once for the PR ref, once for `base`) and
  compute a markdown diff of the dependency graph between them. The
  building blocks (the offline `kubectl atlas` render, the
  `/api/v1/snapshots/diff` endpoint) are already shipped in
  KubeAtlas v1.3; the action wires them together.
- **Federation-aware rendering.** When the action is run against
  KubeAtlas v1.3+ with federation enabled, the scope input will
  accept `federation:<cluster1,cluster2>` to render a merged view.

Track progress at [github.com/lithastra/kubeatlas-action/issues](https://github.com/lithastra/kubeatlas-action/issues).

## License

[Apache 2.0](./LICENSE).
