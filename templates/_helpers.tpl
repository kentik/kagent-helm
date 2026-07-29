{{/*
Expand the name of the chart.
*/}}
{{- define "kagent.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kagent.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kagent.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kagent.labels" -}}
helm.sh/chart: {{ include "kagent.chart" . }}
{{ include "kagent.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kagent.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kagent.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kagent.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kagent.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Validate all chart configuration
*/}}
{{- define "kagent.validate" -}}
{{- /* Validate deployment type */ -}}
{{- $validTypes := list "statefulset" "daemonset" }}
{{- if not (has .Values.deploymentType $validTypes) }}
{{- fail (printf "Invalid deploymentType '%s'. Must be one of: statefulset, daemonset" .Values.deploymentType) }}
{{- end }}
{{- /* Validate required kagent configuration */ -}}
{{- if not (.Values.kagent.companyId | toString | trim) }}
{{- fail "kagent.companyId is required. Provide via: --set-string kagent.companyId=YOUR_COMPANY_ID\nGet your company ID from the Kentik Portal (Settings → Company)" }}
{{- end }}
{{- if not (.Values.kagent.provisioningToken | toString | trim) }}
{{- fail "kagent.provisioningToken is required. Provide via: --set-string kagent.provisioningToken=YOUR_PROVISIONING_TOKEN" }}
{{- end }}
{{- /* Validate replica count for statefulset */ -}}
{{- if eq .Values.deploymentType "statefulset" }}
{{- if not .Values.replicaCount }}
{{- fail (printf "replicaCount is required for deploymentType '%s'. Provide via: --set replicaCount=N" .Values.deploymentType) }}
{{- end }}
{{- if lt (int .Values.replicaCount) 1 }}
{{- fail (printf "replicaCount must be at least 1 for deploymentType '%s', got: %d" .Values.deploymentType (int .Values.replicaCount)) }}
{{- end }}
{{- end }}
{{- /* Validate persistence type for daemonset */ -}}
{{- if eq .Values.deploymentType "daemonset" }}
{{- if .Values.persistence.enabled }}
{{- if and (ne .Values.persistence.type "hostPath") (ne .Values.persistence.type "emptyDir") }}
{{- fail (printf "DaemonSet deployments only support 'hostPath' or 'emptyDir' for persistence.type, got: '%s'. Set persistence.type=hostPath for persistent storage." .Values.persistence.type) }}
{{- end }}
{{- if .Values.persistence.keypair.enabled }}
{{- if and (ne .Values.persistence.keypair.type "hostPath") (ne .Values.persistence.keypair.type "emptyDir") }}
{{- fail (printf "DaemonSet deployments only support 'hostPath' or 'emptyDir' for persistence.keypair.type, got: '%s'." .Values.persistence.keypair.type) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
{{- /* Validate service: at least one capability must be enabled */ -}}
{{- if .Values.service.enabled }}
{{- $svc := .Values.service }}
{{- if not (or ($svc.flowProxy).enabled ($svc.snmpTrap).enabled ($svc.syslog).enabled ($svc.bgp).enabled ($svc.synthetics).enabled ($svc.healthCheck).enabled) }}
{{- fail "service.enabled is true but no capability ports are enabled. Enable at least one of: flowProxy, snmpTrap, syslog, bgp, synthetics, healthCheck" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Kagent container definition (shared across deployment types)
*/}}
{{- define "kagent.container" -}}
{{- $lp := .Values.livenessProbe | default dict }}
{{- $rp := .Values.readinessProbe | default dict }}
- name: kagent
  image: "{{ .Values.image.repository }}:{{ .Values.image.tag | default .Chart.AppVersion }}"
  imagePullPolicy: {{ .Values.image.pullPolicy }}
  env:
  # Required: Company ID for agent scoping
  - name: K_COMPANY_ID
    value: {{ required "kagent.companyId is required" .Values.kagent.companyId | quote }}
  # Required: Provisioning token (injected via Secret)
  - name: K_REGISTER_PROVISIONING_TOKEN
    valueFrom:
      secretKeyRef:
        name: {{ include "kagent.fullname" . }}-provisioning-token
        key: token
  # Core configuration
  - name: K_API_ROOT
    value: {{ .Values.kagent.apiEndpoint | default "grpc.api.kentik.com:443" | quote }}
  - name: K_RELEASE_CHANNEL
    value: {{ .Values.kagent.releaseChannel | default "stable" | quote }}
  - name: K_LOG_LEVEL
    value: {{ .Values.kagent.logLevel | default "info" | quote }}
  - name: K_LOG_DEST
    value: {{ .Values.kagent.logDest | default "stdout" | quote }}
  - name: K_ROOT
    value: "/opt/kentik"
  - name: K_KEYS_DIRECTORY
    value: "/opt/ua/keys"
  - name: K_K8S_HELM
    value: "true"
  # Health check server configuration (auto-enabled when probes or service.healthCheck are enabled)
  {{- $hcSvc := (.Values.service).healthCheck | default dict }}
  {{- if or $lp.enabled $rp.enabled $hcSvc.enabled }}
  - name: K_HC_SERVER_ENABLED
    value: "true"
  - name: K_HC_SERVER_NETWORK
    value: "tcp4"
  - name: K_HC_SERVER_ADDRESS
    value: {{ printf ":%d" (($lp.httpGet | default dict).port | default ($rp.httpGet | default dict).port | default ($hcSvc.port | default 8099) | int) | quote }}
  {{- end }}
  # Disk space reservation
  - name: K_DISK_SPACE_RESERVATION_ENABLED
    value: {{ .Values.kagent.diskReservation.enabled | default "true" | quote }}
  {{- if .Values.kagent.diskReservation.enabled }}
  - name: K_DISK_SPACE_RESERVATION_INITIAL_SIZE
    value: {{ .Values.kagent.diskReservation.initialSize | quote }}
  {{- end }}
  {{- if .Values.configmap.enabled }}
  # Additional config from ConfigMap
  envFrom:
  - configMapRef:
      name: {{ include "kagent.fullname" . }}-config
  {{- end }}
  {{- include "kagent.containerPorts" . | nindent 2 }}
  {{- include "kagent.volumeMounts" . | nindent 2 }}
  securityContext:
    {{- toYaml .Values.securityContext | nindent 4 }}
  resources:
    {{- toYaml .Values.resources | nindent 4 }}
  {{- if $lp.enabled }}
  livenessProbe:
    {{- if $lp.httpGet }}
    httpGet:
      {{- toYaml $lp.httpGet | nindent 6 }}
    {{- end }}
    initialDelaySeconds: {{ $lp.initialDelaySeconds | default 30 }}
    periodSeconds: {{ $lp.periodSeconds | default 10 }}
    timeoutSeconds: {{ $lp.timeoutSeconds | default 5 }}
    failureThreshold: {{ $lp.failureThreshold | default 3 }}
  {{- end }}
  {{- if $rp.enabled }}
  readinessProbe:
    {{- if $rp.httpGet }}
    httpGet:
      {{- toYaml $rp.httpGet | nindent 6 }}
    {{- end }}
    initialDelaySeconds: {{ $rp.initialDelaySeconds | default 5 }}
    periodSeconds: {{ $rp.periodSeconds | default 10 }}
    timeoutSeconds: {{ $rp.timeoutSeconds | default 5 }}
    failureThreshold: {{ $rp.failureThreshold | default 3 }}
  {{- end }}
{{- end }}

{{/*
Check if any service capability port is enabled.
Returns non-empty string (truthy) if at least one is enabled.
*/}}
{{- define "kagent.hasServicePorts" -}}
{{- $svc := .Values.service | default dict -}}
{{- if or ($svc.flowProxy).enabled ($svc.snmpTrap).enabled ($svc.syslog).enabled ($svc.bgp).enabled ($svc.synthetics).enabled ($svc.healthCheck).enabled -}}
true
{{- end -}}
{{- end -}}

{{/*
Container ports for enabled service capabilities.
Ports are rendered whenever a capability is enabled, regardless of service.enabled,
so that kubectl port-forward and pod describe show the listening ports.
*/}}
{{- define "kagent.containerPorts" -}}
{{- $svc := .Values.service | default dict }}
{{- $ports := list }}
{{- $fp := $svc.flowProxy | default dict }}
{{- if $fp.enabled }}
{{- $ports = append $ports (dict "name" "flow-proxy" "containerPort" ($fp.targetPort | default ($fp.port | default 9995) | int) "protocol" ($fp.protocol | default "UDP")) }}
{{- end }}
{{- $st := $svc.snmpTrap | default dict }}
{{- if $st.enabled }}
{{- $ports = append $ports (dict "name" "snmp-trap" "containerPort" ($st.targetPort | default ($st.port | default 162) | int) "protocol" ($st.protocol | default "UDP")) }}
{{- end }}
{{- $sl := $svc.syslog | default dict }}
{{- if $sl.enabled }}
{{- $syslogPort := $sl.targetPort | default ($sl.port | default 514) | int }}
{{- $protocols := $sl.protocols | default (list "UDP" "TCP") }}
{{- range $protocols }}
{{- $ports = append $ports (dict "name" (printf "syslog-%s" (lower .)) "containerPort" $syslogPort "protocol" .) }}
{{- end }}
{{- end }}
{{- $bgp := $svc.bgp | default dict }}
{{- if $bgp.enabled }}
{{- $ports = append $ports (dict "name" "bgp" "containerPort" ($bgp.targetPort | default ($bgp.port | default 179) | int) "protocol" ($bgp.protocol | default "TCP")) }}
{{- end }}
{{- $syn := $svc.synthetics | default dict }}
{{- if $syn.enabled }}
{{- $ports = append $ports (dict "name" "synthetics" "containerPort" ($syn.targetPort | default ($syn.port | default 9977) | int) "protocol" ($syn.protocol | default "UDP")) }}
{{- end }}
{{- $hc := $svc.healthCheck | default dict }}
{{- if $hc.enabled }}
{{- $ports = append $ports (dict "name" "health-check" "containerPort" ($hc.targetPort | default ($hc.port | default 8099) | int) "protocol" ($hc.protocol | default "TCP")) }}
{{- end }}
{{- if $ports }}
ports:
{{- range $ports }}
- name: {{ .name }}
  containerPort: {{ .containerPort }}
  protocol: {{ .protocol }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Pod spec common fields (shared across deployment types)
*/}}
{{- define "kagent.podSpec" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
  {{- toYaml . | nindent 2 }}
{{- end }}
serviceAccountName: {{ include "kagent.serviceAccountName" . }}
securityContext:
  {{- toYaml .Values.podSecurityContext | nindent 2 }}
containers:
{{- include "kagent.container" . | nindent 0 }}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- with .Values.affinity }}
affinity:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- if eq .Values.deploymentType "daemonset" }}
# Default tolerations for control-plane nodes
tolerations:
- key: node-role.kubernetes.io/control-plane
  operator: Exists
  effect: NoSchedule
- key: node-role.kubernetes.io/master
  operator: Exists
  effect: NoSchedule
{{- with .Values.tolerations }}
{{- toYaml . | nindent 0 }}
{{- end }}
{{- else }}
{{- with .Values.tolerations }}
tolerations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
{{- $podVolumes := include "kagent.podVolumes" . }}
{{- if $podVolumes }}
volumes:
{{- $podVolumes | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Volume mounts shared across deployment patterns
*/}}
{{- define "kagent.volumeMounts" -}}
volumeMounts:
- name: data
  mountPath: /opt/kentik
{{- if .Values.persistence.keypair.enabled }}
{{- if eq .Values.persistence.keypair.type "secret" }}
- name: keypair-secret
  mountPath: /opt/ua/keys
  readOnly: true
{{- else }}
- name: keys
  mountPath: /opt/ua/keys
{{- end }}
{{- else }}
- name: data
  mountPath: /opt/ua/keys
  subPath: keys
{{- end }}
{{- end }}

{{/*
Pod volumes for non-StatefulSet workloads
*/}}
{{- define "kagent.podVolumes" -}}
{{- if ne .Values.deploymentType "statefulset" }}
{{- /* Data volume configuration */ -}}
{{- if .Values.persistence.enabled }}
{{- if eq .Values.persistence.type "hostPath" }}
- name: data
  hostPath:
    path: {{ .Values.persistence.hostPath.path }}
    type: {{ .Values.persistence.hostPath.type | default "DirectoryOrCreate" }}
{{- else if eq .Values.persistence.type "pvc" }}
- name: data
  persistentVolumeClaim:
    claimName: {{ include "kagent.fullname" . }}-data
{{- else }}
- name: data
  emptyDir: {}
{{- end }}
{{- else }}
- name: data
  emptyDir: {}
{{- end }}
{{- /* Keypair volume configuration */ -}}
{{- if .Values.persistence.keypair.enabled }}
{{- if eq .Values.persistence.keypair.type "secret" }}
- name: keypair-secret
  secret:
{{/*    Bind first key from Secret as keys volume*/}}
    secretName: {{ include "kagent.fullname" . }}-0-secret
    defaultMode: 0400
{{- else if eq .Values.persistence.keypair.type "hostPath" }}
- name: keys
  hostPath:
    path: {{ .Values.persistence.keypair.hostPath.path }}
    type: {{ .Values.persistence.keypair.hostPath.type | default "DirectoryOrCreate" }}
{{- else if eq .Values.persistence.keypair.type "pvc" }}
- name: keys
  persistentVolumeClaim:
    claimName: {{ include "kagent.fullname" . }}-keys
{{- else }}
- name: keys
  emptyDir: {}
{{- end }}
{{- end }}
{{- end }}
{{- end }}
