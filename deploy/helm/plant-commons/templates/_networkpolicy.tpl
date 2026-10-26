{{/* NetworkPolicy helpers, used by networkpolicy.yaml */}}
{{- define "pc.peer" -}}
podSelector:
  matchLabels:
    {{- include "pc.selectorLabels" . | nindent 4 }}
{{- end -}}
{{- define "pc.policy" -}}
{{- /* pc.policy (dict "ctx" $ "c" "backend" "ingress" <list of rules> "egress" <list of rules> "egressOn" bool) */ -}}
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ include "pc.name" . }}
  labels:
    {{- include "pc.labels" . | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "pc.selectorLabels" . | nindent 6 }}
  policyTypes:
    - Ingress
    {{- if .egressOn }}
    - Egress
    {{- end }}
  ingress:
    {{- if .ingress }}
    {{- toYaml .ingress | nindent 4 }}
    {{- else }} []
    {{- end }}
  {{- if .egressOn }}
  egress:
    - to:
        {{- toYaml .ctx.Values.networkPolicy.egress.dns | nindent 8 }}
      ports:
        - {port: 53, protocol: UDP}
        - {port: 53, protocol: TCP}
    {{- with .egress }}
    {{- toYaml . | nindent 4 }}
    {{- end }}
  {{- end }}
{{- end -}}
