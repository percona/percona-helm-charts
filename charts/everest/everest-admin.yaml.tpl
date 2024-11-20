admin:
  passwordHash: {{ .Values.server.initialAdminPassword | default (randAlphaNum 64) }}
  enabled: true
  capabilities:
    - login
