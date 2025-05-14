{{- define "olm.namespace" -}}
{{- default .Release.Namespace .Values.namespace | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "olm.certs" }}
{{- $tls := .Values.packageserver.tls }}
{{- $psSvcName := printf "packageserver-service" }}
{{- $psSvcNameWithNS := ( printf "%s.%s" $psSvcName .Values.namespace ) }}
{{- $psFullName := ( printf "%s.svc" $psSvcNameWithNS ) }}
{{- $psAltNames := list $psSvcName $psSvcNameWithNS $psFullName }}
{{- $psCA := genCA $psSvcName 3650 }}
{{- $psCert := genSignedCert $psFullName nil $psAltNames 3650 $psCA }}
{{- if (and $tls.caCert $tls.tlsCert $tls.tlsKey) }}
caCert: {{ $tls.caCert | b64enc }}
tlsCert: {{ $tls.tlsCert | b64enc }}
tlsKey: {{ $tls.tlsKey | b64enc }}
{{- else }}
caCert: {{ $psCA.Cert | b64enc }}
tlsCert: {{ $psCert.Cert | b64enc }}
tlsKey: {{ $psCert.Key | b64enc }}
{{- end }}
commonName: {{ $psSvcName }}
altNames:
{{- range $n := $psAltNames }}
- {{ $n }}
{{- end }}
- localhost
{{- end }}