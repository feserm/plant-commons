{{/* Routing helpers, used by routing.yaml */}}
{{- define "pc.routingMeta" -}}
labels:
  {{- include "pc.labels" . | nindent 2 }}
  {{- with .ctx.Values.routing.labels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- with .ctx.Values.routing.annotations }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
{{- define "pc.route" -}}
- kind: Rule
  match: {{ printf "Host(`%s`) && PathPrefix(`%s`)" .host .prefix | quote }}
  {{- with .middlewares }}
  middlewares:
    {{- range . }}
    - name: {{ . }}
    {{- end }}
  {{- end }}
  services:
    - name: {{ .svc }}
      port: {{ .port }}
{{- end -}}
