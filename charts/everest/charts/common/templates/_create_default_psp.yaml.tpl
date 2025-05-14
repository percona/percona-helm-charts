# Create default pod scheduling policies.
#
{{- define "everest.createDefaultPsp" }}
apiVersion: everest.percona.com/v1alpha1
kind: PodSchedulingPolicy
metadata:
  name: everest-default-mysql
  finalizers:
    - everest.percona.com/readonly-protection
  annotations:
      "helm.sh/hook": post-install,pre-upgrade
      "helm.sh/resource-policy": keep
      "helm.sh/hook-weight": "-5"
spec:
  engineType: pxc
  affinityConfig:
    pxc:
      engine:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
      proxy:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
---
apiVersion: everest.percona.com/v1alpha1
kind: PodSchedulingPolicy
metadata:
  name: everest-default-postgresql
  finalizers:
    - everest.percona.com/readonly-protection
  annotations:
      "helm.sh/hook": post-install,pre-upgrade
      "helm.sh/resource-policy": keep
      "helm.sh/hook-weight": "-5"
spec:
  engineType: postgresql
  affinityConfig:
    postgresql:
      engine:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
      proxy:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
---
apiVersion: everest.percona.com/v1alpha1
kind: PodSchedulingPolicy
metadata:
  name: everest-default-mongodb
  finalizers:
    - everest.percona.com/readonly-protection
  annotations:
      "helm.sh/hook": post-install,pre-upgrade
      "helm.sh/resource-policy": keep
      "helm.sh/hook-weight": "-5"
spec:
  engineType: psmdb
  affinityConfig:
    psmdb:
      engine:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
      proxy:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
      configServer:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - podAffinityTerm:
                topologyKey: kubernetes.io/hostname
              weight: 1
---
{{- end }}