# argus-helm-chart

A Helm chart that deploys [LibreChat](https://www.librechat.ai/) as an
AI control-room assistant, with:

- **Multiple LLM backends**, declared as a list (`llm.endpoints`) instead
  of hand-editing `librechat.yaml`.
- **Multiple MCP servers**, generically pluggable (`mcpServers`), with
  [ARGUS](https://github.com/infn-epics/argus-mcp-server) — the
  accelerator-control MCP server — getting first-class treatment: this
  chart deploys it (Deployment/Service/RBAC) and wires its 8 backend
  services (EPICS, Archiver Appliance, ChannelFinder, Kubernetes, ArgoCD,
  Logbook, Elasticsearch, Documentation) from typed values.
- **Either local email/password auth or OIDC/OAuth2 SSO** (or both at
  once), via `auth.mode`.

It depends on the [official LibreChat Helm chart](https://github.com/danny-avila/LibreChat/tree/main/helm/librechat)
for LibreChat itself (and its MongoDB/Meilisearch/Redis/RAG-API
dependencies) rather than reimplementing any of that — see
[docs/architecture.md](docs/architecture.md) for exactly how the two
compose.

## Quickstart

```bash
helm dependency build .

# 1. Build & push the ARGUS MCP image (no default registry is assumed)
docker build -t <your-registry>/argus-mcp-server:latest ../argus-mcp-server
docker push <your-registry>/argus-mcp-server:latest

# 2. Install
helm install my-argus . \
  -f examples/values-basic-auth.yaml \
  --set argusMcp.image.repository=<your-registry>/argus-mcp-server \
  --set secrets.data.OPENAI_API_KEY=sk-...
```

See `examples/` for ready-to-adapt overlays:
- `values-basic-auth.yaml` — local login only, single LLM, EPICS-only ARGUS backend
- `values-oauth2.yaml` — OIDC SSO only, local login disabled
- `values-multi-llm-multi-mcp.yaml` — 3 LLM providers + ARGUS (fully wired) + a generic MCP server example

## Values reference

### `librechat.*` — passthrough to the upstream subchart

Anything not called out below uses the
[upstream chart's own defaults](https://github.com/danny-avila/LibreChat/blob/main/helm/librechat/values.yaml)
(ingress, resources, autoscaling, Mongo/Meilisearch/Redis sizing, ...) and
can be overridden the normal Helm way, e.g.:

```yaml
librechat:
  ingress:
    hosts:
      - host: chat.example.org
        paths: [{ path: /, pathType: ImplementationSpecific }]
  mongodb:
    persistence:
      size: 20Gi
```

Do **not** override `librechat.librechat.existingConfigYaml`,
`librechat.global.librechat.existingSecretName`, or
`librechat.meilisearch.auth.existingMasterKeySecret` — they're wired to
resources this chart renders itself (`resourceNames.*`).

### `llm.endpoints` — LLM providers

A list; each entry becomes one `endpoints.custom[]` block in the rendered
`librechat.yaml`. Any OpenAI-compatible or Anthropic-compatible API works.

| Field | Required | Notes |
|---|---|---|
| `name` | yes | display name in LibreChat's model picker |
| `apiKeySecretKey` | yes | key name in `secrets.data` holding the real API key |
| `baseURL` | yes | |
| `provider` | no | set to `anthropic` for native Anthropic API; omit for OpenAI-compatible |
| `models.default` | yes | list of model IDs |
| `models.fetch` | no | let LibreChat query the provider's `/models` endpoint |
| `titleConvo`, `titleModel`, `modelDisplayLabel`, `iconURL`, `headers` | no | see [LibreChat's custom endpoint schema](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/custom_endpoint) |

### `mcpServers` — additional MCP servers

A map; each **enabled** entry is merged verbatim into `mcpServers.<key>`
in the rendered `librechat.yaml` (same shape LibreChat itself expects —
see [MCP Servers Object Structure](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/mcp_servers)).
Use `${VAR_NAME}` in `headers`/`env` to reference a key from `secrets.data`.
The `ragflow` entry ships disabled as a worked example; add as many other
entries as you need.

### `argusMcp` — the ARGUS MCP server

Deployed by this chart when `argusMcp.enabled: true` (default). See
[values.yaml](values.yaml) for the full field list; every field under
`argusMcp.backends.*` maps 1:1 onto `argus-mcp-server`'s own
[`.env.example`](../argus-mcp-server/.env.example) — leave a backend's
fields blank to leave it `unconfigured` (ARGUS degrades gracefully rather
than erroring; see that repo's `docs/providers.md`).

- `argusMcp.image.repository` **must be set** — no default is assumed.
- `argusMcp.backends.kubernetes` needs no kubeconfig: ARGUS runs under
  its own in-cluster ServiceAccount, scoped by this chart's RBAC to
  `pods` (get/list/watch/delete) and `pods/log` (get) — nothing else.
  `argusMcp.rbac.clusterWide: true` switches from a namespaced
  Role/RoleBinding to a ClusterRole/ClusterRoleBinding for sites where
  IOCs span multiple namespaces.

### `auth` — authentication

```yaml
auth:
  mode: basic   # basic | oauth2 | both
```

- `basic`: local email/password login (`auth.basic.*` controls
  registration/password-reset/unverified-email toggles).
- `oauth2`: OIDC SSO only, local login disabled (`auth.oauth2.*` — works
  with any compliant IdP: Keycloak, Auth0, Azure AD, Okta, ...).
- `both`: local login stays available alongside SSO.

### `secrets.data` — credentials

Merged into the single rendered Secret alongside auto-generated
JWT/CREDS/Meilisearch keys. **Never commit real values** — pass via
`--set secrets.data.KEY=value` or a separate, untracked values file (or
set `secrets.existingSecret` to reuse a Secret you manage outside this
chart, e.g. via Sealed Secrets/External Secrets/SOPS).

## Development

```bash
helm dependency build .
helm lint .
helm template . -f examples/values-basic-auth.yaml
helm template . -f examples/values-oauth2.yaml
helm template . -f examples/values-multi-llm-multi-mcp.yaml
```

## Operational notes

- **One release per namespace.** The ConfigMap/Secret this chart renders
  use fixed names, not release-name-templated ones — see
  [docs/architecture.md](docs/architecture.md) for why. Installing a
  second release in the same namespace will collide.
- **Upgrades don't rotate secrets.** JWT/CREDS/Meilisearch keys are
  generated once and preserved across `helm upgrade` (checked via
  `lookup` against the live Secret) — regenerating them would force-logout
  every session and could leave previously-stored encrypted credentials
  undecryptable.
- **`restart_ioc`** (one of ARGUS's MCP tools) deletes the target pod so
  its controller recreates it — the RBAC Role grants exactly `delete` on
  `pods`, nothing broader.
