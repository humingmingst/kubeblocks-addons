{{/*
Expand the name of the chart.
*/}}
{{- define "apecloud-mysql.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "apecloud-mysql.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "apecloud-mysql.labels" -}}
helm.sh/chart: {{ include "apecloud-mysql.chart" . }}
{{ include "apecloud-mysql.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "apecloud-mysql.selectorLabels" -}}
app.kubernetes.io/name: {{ include "apecloud-mysql.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "apecloud-mysql.annotations" -}}
helm.sh/resource-policy: keep              
{{- end }}

{{/*
Generate scripts configmap
*/}}
{{- define "apecloud-mysql.extend.scripts" -}}
{{- range $path, $_ :=  $.Files.Glob "scripts/**" }}
{{ $path | base }}: |-
{{- $.Files.Get $path | nindent 2 }}
{{- end }}
{{- end }}

{{/*
Backup Tool image
*/}}
{{- define "apecloud-mysql.bakcupToolImage" -}}
{{ .Values.backupTool.image.registry | default ( .Values.image.registry | default "docker.io" ) }}/{{ .Values.backupTool.image.repository}}:{{ .Values.backupTool.image.tag }}
{{- end }}


{{- define "apecloud-mysql.spec.common" -}}
provider: kubeblocks.io
description: ApeCloud MySQL is a database that is compatible with MySQL syntax and achieves high availability through the utilization of the RAFT consensus protocol.
serviceKind: mysql
serviceVersion: 8.0.30
services:
  - name: default
    spec:
      ports:
        - name: mysql
          port: 3306
          targetPort: mysql
    roleSelector: leader
  - name: replication
    serviceName: replication
    spec:
      ports:
        - name: paxos
          port: 13306
          targetPort: paxos
    podService: true
    disableAutoProvision: true
logConfigs:
  {{- range $name,$pattern := .Values.logConfigs }}
  - name: {{ $name }}
    filePathPattern: {{ $pattern }}
  {{- end }}
scripts:
  - name: apecloud-mysql-scripts
    templateRef: {{ include "apecloud-mysql.cmScriptsName" . }}
    namespace: {{ .Release.Namespace }}
    volumeName: scripts
    defaultMode: 0555  # for read and execute, mysql container switched user account.
systemAccounts:
  - name: root
    initAccount: true
    passwordGenerationPolicy:
      length: 16
      numDigits: 8
      numSymbols: 0
      letterCase: MixedCases
  - name: kbadmin
    statement: CREATE USER ${KB_ACCOUNT_NAME} IDENTIFIED BY '${KB_ACCOUNT_PASSWORD}'; GRANT ALL PRIVILEGES ON ${ALL_DB} TO ${KB_ACCOUNT_NAME};
    passwordGenerationPolicy: &defaultPasswordGenerationPolicy
      length: 16
      numDigits: 8
      numSymbols: 0
      letterCase: MixedCases
  - name: kbdataprotection
    statement: CREATE USER ${KB_ACCOUNT_NAME} IDENTIFIED BY '${KB_ACCOUNT_PASSWORD}';GRANT RELOAD, LOCK TABLES, PROCESS, REPLICATION CLIENT ON ${ALL_DB} TO ${KB_ACCOUNT_NAME}; GRANT LOCK TABLES,RELOAD,PROCESS,REPLICATION CLIENT, SUPER,SELECT,EVENT,TRIGGER,SHOW VIEW ON ${ALL_DB} TO ${KB_ACCOUNT_NAME};
    passwordGenerationPolicy: *defaultPasswordGenerationPolicy
  - name: kbprobe
    statement: CREATE USER ${KB_ACCOUNT_NAME} IDENTIFIED BY '${KB_ACCOUNT_PASSWORD}'; GRANT REPLICATION CLIENT, PROCESS ON ${ALL_DB} TO ${KB_ACCOUNT_NAME}; GRANT SELECT ON performance_schema.* TO ${KB_ACCOUNT_NAME};
    passwordGenerationPolicy: *defaultPasswordGenerationPolicy
  - name: kbmonitoring
    statement: CREATE USER ${KB_ACCOUNT_NAME} IDENTIFIED BY '${KB_ACCOUNT_PASSWORD}'; GRANT REPLICATION CLIENT, PROCESS ON ${ALL_DB} TO ${KB_ACCOUNT_NAME}; GRANT SELECT ON performance_schema.* TO ${KB_ACCOUNT_NAME};
    passwordGenerationPolicy: *defaultPasswordGenerationPolicy
  - name: kbreplicator
    statement: CREATE USER ${KB_ACCOUNT_NAME} IDENTIFIED BY '${KB_ACCOUNT_PASSWORD}'; GRANT REPLICATION SLAVE ON ${ALL_DB} TO ${KB_ACCOUNT_NAME} WITH GRANT OPTION;
    passwordGenerationPolicy: *defaultPasswordGenerationPolicy
roles:
  - name: leader
    serviceable: true
    writable: true
    votable: true
  - name: follower
    serviceable: true
    writable: false
    votable: true
  - name: learner
    serviceable: false
    writable: false
    votable: false
lifecycleActions:
  roleProbe:
    periodSeconds: {{ .Values.roleProbe.periodSeconds }}
    timeoutSeconds: {{ .Values.roleProbe.timeoutSeconds }}
    exec:
      container: mysql
      command:
        - /tools/dbctl
        - --config-path
        - /tools/config/dbctl/components
        - wesql
        - getrole
  memberLeave:
    exec:
      container: mysql
      command:
        - /tools/dbctl
        - --config-path
        - /tools/config/dbctl/components
        -  wesql
        - leavemember
  accountProvision:
    exec:
      container: mysql
      image: {{ .Values.image.registry | default "docker.io" }}/{{ .Values.image.repository }}:8.0.30-5.beta3.20240330.g94d1caf.15
      command:
        - bash
        - -c
        - |
          set -ex
          ALL_DB='*.*'
          eval statement=\"${KB_ACCOUNT_STATEMENT}\"
          mysql -u${MYSQL_ROOT_USER} -p${MYSQL_ROOT_PASSWORD} -P3306 -h127.0.0.1 -e "${statement}"
      targetPodSelector: Role
      matchingKey: leader 
exporter:
  containerName: mysql-exporter
  scrapePath: /metrics
  scrapePort: http-metrics
serviceRefDeclarations:
  - name: etcd
    serviceRefDeclarationSpecs:
      - serviceKind: etcd
        serviceVersion: "^*"
    optional: true
vars:
  - name: MYSQL_ROOT_USER
    valueFrom:
      credentialVarRef:
        # it will match a comp in the cluster with cmpd name starting with "apecloud-mysql"
        compDef: {{ include "apecloud-mysql.cmpdNameApecloudMySQLPrefix" . }}
        name: root
        optional: false
        username: Required
  - name: MYSQL_ROOT_PASSWORD
    valueFrom:
      credentialVarRef:
        compDef: {{ include "apecloud-mysql.cmpdNameApecloudMySQLPrefix" . }}
        name: root
        optional: false
        password: Required
  - name: REPLICATION_ENDPOINT
    valueFrom:
      serviceVarRef:
        name: replication
        optional: true
        host: Required
        loadBalancer: Required
  - name: SERVICE_ETCD_ENDPOINT
    valueFrom:
      serviceRefVarRef:
        name: etcd
        endpoint: Required
        optional: true
  - name: LOCAL_ETCD_POD_FQDN
    valueFrom:
      componentVarRef:
        compDef: {{ .Values.etcd.etcdCmpdName }}
        optional: true
        podFQDNs: Required
  - name: LOCAL_ETCD_PORT
    valueFrom:
      serviceVarRef:
        compDef: {{ .Values.etcd.etcdCmpdName }}
        name: headless
        optional: true
        port: 
          name: client
          option: Optional
  - name: MY_POD_LIST
    valueFrom:
      componentVarRef:
        optional: false
        podNames: Required
  - name: MY_COMP_NAME
    valueFrom:
      componentVarRef:
        optional: false
        shortName: Required
  - name: MY_COMP_REPLICAS
    valueFrom:
      componentVarRef:
        optional: false
        replicas: Required
  - name: MY_CLUSTER_NAME
    valueFrom:
      clusterVarRef:
        clusterName: Required
  - name: MY_CLUSTER_UID
    valueFrom:
      clusterVarRef:
        optional: false
        clusterUID: Required
  ## the mysql primary pod name which is dynamically selected, caution to use it
  - name: MYSQL_LEADER_POD_NAME
    valueFrom:
      componentVarRef:
        optional: true
        podNamesForRole:
          role: leader
          option: Optional
  - name: SYNCER_HTTP_PORT
    value: "3601"
{{- end -}}

{{- define "apecloud-mysql.spec.runtime.mysql" -}}
env:
  - name: SERVICE_PORT
    value: "3306"
  - name: MYSQL_PORT
    value: "3306"
  - name: MYSQL_CONSENSUS_PORT
    value: "13306"
  - name: MYSQL_ROOT_HOST
    value: {{ .Values.auth.rootHost | default "%" | quote }}
  - name: MYSQL_DATABASE
    value: {{- if .Values.auth.createDatabase }} {{ .Values.auth.database | quote }}  {{- else }} "" {{- end }}
  - name: CLUSTER_ID
    value: {{ .Values.cluster.clusterId | default "1" | quote }}
  - name: CLUSTER_START_INDEX
    value: {{ .Values.cluster.clusterStartIndex | default "1" | quote }}
  - name: MYSQL_TEMPLATE_CONFIG
    value: {{ if .Values.cluster.templateConfig }}{{ .Values.cluster.templateConfig }}{{ end }}
  - name: MYSQL_CUSTOM_CONFIG
    value: {{ if .Values.cluster.customConfig }}{{ .Values.cluster.customConfig }}{{ end }}
  - name: MYSQL_DYNAMIC_CONFIG
    value: {{ if .Values.cluster.dynamicConfig }}{{ .Values.cluster.dynamicConfig }}{{ end }}
  - name: KB_EMBEDDED_WESQL
    value: {{ .Values.cluster.kbWeSQLImage | default "1" | quote }}
  - name: KB_MYSQL_VOLUME_DIR
    value: {{ .Values.mysqlConfigs.dataMountPath }}
  - name: KB_MYSQL_CONF_FILE
    value: "/opt/mysql/my.cnf"
  - name: KB_MYSQL_CLUSTER_UID
    value: $(KB_CLUSTER_UID)
  - name: KB_MYSQL_N
    value: $(KB_COMP_REPLICAS)
  - name: CLUSTER_DOMAIN
    value: {{ .Values.clusterDomain }}
  - name: MY_POD_NAME
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.name
  - name: MY_POD_UID
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: metadata.uid
  - name: MY_POD_IP
    valueFrom:
      fieldRef:
        apiVersion: v1
        fieldPath: status.podIP
  - name: KB_SERVICE_CHARACTER_TYPE
    value: wesql
  - name: PATH
    value: /tools/xtrabackup/bin:/tools/:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
volumeMounts:
  - mountPath: {{ .Values.mysqlConfigs.dataMountPath }}
    name: data
  - mountPath: /opt/mysql
    name: mysql-config
  - name: scripts
    mountPath: /scripts
  - name: annotations
    mountPath: /etc/annotations
  - mountPath: /tools
    name: tools
ports:
  - containerPort: 3306
    name: mysql
  - containerPort: 13306
    name: paxos
lifecycle:
  preStop:
    exec:
      command: [ "/scripts/pre-stop.sh" ]
{{- end -}}

{{- define "apecloud-mysql.spec.runtime.vtablet" -}}
ports:
  - containerPort: 15100
    name: vttabletport
  - containerPort: 16100
    name: vttabletgrpc
env:
  - name: CELL
    value: {{ .Values.wesqlscale.cell | default "zone1" | quote }}
  - name: VTTABLET_PORT
    value: "15100"
  - name: VTTABLET_GRPC_PORT
  - name: VTCTLD_HOST
    value: "$(KB_CLUSTER_NAME)-wescale-ctrl-headless"
  - name: VTCTLD_WEB_PORT
    value: "15000"
  - name: SERVICE_PORT
    value: "$(VTTABLET_PORT)"
command: ["/scripts/vttablet.sh"]
volumeMounts:
  - name: scripts
    mountPath: /scripts
  - name: mysql-scale-config
    mountPath: /conf
  - name: data
    mountPath: /vtdataroot
{{- end }}


{{- define "apecloud-mysql.spec.runtime.exporter" -}}
command: [ "/scripts/exporter_start.sh" ]
env:
  - name: MYSQLD_EXPORTER_USER
    value: $(MYSQL_ROOT_USER)
  - name: MYSQLD_EXPORTER_PASSWORD
    value: $(MYSQL_ROOT_PASSWORD)
  - name: EXPORTER_WEB_PORT
    value: "{{ .Values.metrics.service.port }}"
image: {{ .Values.metrics.image.registry | default ( .Values.image.registry | default "docker.io" ) }}/{{ .Values.metrics.image.repository }}:{{ default .Values.metrics.image.tag }}
imagePullPolicy: IfNotPresent
ports:
  - name: http-metrics
    containerPort: {{ .Values.metrics.service.port }}
volumeMounts:
  - name: scripts
    mountPath: /scripts
{{- end -}}

{{- define "apecloud-mysql.spec.runtime.volumes" -}}
{{- if .Values.logCollector.enabled }}
- name: log-data
  hostPath:
    path: /var/log/kubeblocks
    type: DirectoryOrCreate
{{- end }}
{{- end -}}
