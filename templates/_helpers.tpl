{{/*
Standard name/label helpers, scoped to this chart's own resources
(argus-mcp Deployment/Service/RBAC and the shared config/secret). The
librechat subchart has its own identical set under "librechat.*" — these
are deliberately separate so the two don't collide.
*/}}

{{- define "argus.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "argus.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "argus.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "argus.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "argus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "argus.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
argus-mcp-specific name (a sub-component of this release, distinct from
any other component that might one day be added).
*/}}
{{- define "argus.mcp.fullname" -}}
{{- printf "%s-argus-mcp" (include "argus.fullname" .) | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "argus.mcp.selectorLabels" -}}
{{ include "argus.selectorLabels" . }}
app.kubernetes.io/component: argus-mcp
{{- end -}}

{{- define "argus.mcp.labels" -}}
{{ include "argus.labels" . }}
app.kubernetes.io/component: argus-mcp
{{- end -}}

{{/*
Namespace the ARGUS MCP pod/Service/ServiceAccount are deployed into —
always the release namespace, standard Helm behavior.
*/}}
{{- define "argus.mcp.namespace" -}}
{{- .Release.Namespace -}}
{{- end -}}

{{/*
Namespace the RBAC Role grants pod access to — this is about IOCs the
Kubernetes provider watches, which may be a *different* namespace than
where the ARGUS pod itself runs (e.g. ARGUS lives in "mcp-system", IOCs
run in "accelerator"). Falls back to the release namespace if unset.
Only meaningful when argusMcp.rbac.clusterWide is false.
*/}}
{{- define "argus.mcp.watchedNamespace" -}}
{{- .Values.argusMcp.backends.kubernetes.namespaceDefault | default .Release.Namespace -}}
{{- end -}}

{{/*
vLLM service name/namespace helpers. Fixed (non-release-templated) name,
same reasoning as resourceNames.configYaml/credentialsSecret at the top of
values.yaml: this is meant to be a facility-wide singleton, installed by
exactly one argus-helm-chart release into its own dedicated namespace
(vllmService.namespace, independent of .Release.Namespace), then referenced
by every other beamline's own llm.endpoints via its Service DNS name.
*/}}
{{- define "argus.vllm.fullname" -}}
argus-vllm
{{- end -}}

{{- define "argus.vllm.namespace" -}}
{{- .Values.vllmService.namespace | default .Release.Namespace -}}
{{- end -}}

{{- define "argus.vllm.selectorLabels" -}}
app.kubernetes.io/name: argus-vllm
{{- end -}}

{{- define "argus.vllm.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "argus.vllm.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/component: vllm
{{- end -}}

{{/*
The vLLM Service's in-cluster base URL, usable directly as an
llm.endpoints[].baseURL.
*/}}
{{- define "argus.vllm.baseUrl" -}}
{{- printf "http://%s.%s.svc.cluster.local:%v/v1" (include "argus.vllm.fullname" .) (include "argus.vllm.namespace" .) .Values.vllmService.service.port -}}
{{- end -}}

{{/*
Reuse an already-deployed value for a Secret key across `helm upgrade`
instead of regenerating it every time (which would force-logout every
LibreChat session and could leave previously-encrypted stored credentials
undecryptable). `lookup` returns an empty map when there's no live
cluster context (e.g. `helm template`), in which case we always fall back
to the freshly-generated value — that's fine for offline rendering/CI.

Usage: {{ include "argus.secretValue" (list $ "JWT_SECRET" (randAlphaNum 64)) }}
*/}}
{{- define "argus.secretValue" -}}
{{- $ctx := index . 0 -}}
{{- $key := index . 1 -}}
{{- $fallback := index . 2 -}}
{{- $secretName := $ctx.Values.resourceNames.credentialsSecret -}}
{{- $existing := lookup "v1" "Secret" $ctx.Release.Namespace $secretName -}}
{{- if and $existing $existing.data (hasKey $existing.data $key) -}}
{{- index $existing.data $key | b64dec -}}
{{- else -}}
{{- $fallback -}}
{{- end -}}
{{- end -}}
