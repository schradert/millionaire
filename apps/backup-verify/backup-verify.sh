#!/usr/bin/env bash
# Monthly backup verification. Run by the backup-verify CronJob (nixidy/system/storage/backup-verify.nix),
# procedure from docs/pvc-and-postgres-restore.md and docs/etcd-restore.md.
#
#   restic   restic check --read-data-subset on every VolSync repository
#   volume   restore one rotating volume into a NEW scratch PVC, compare it with the snapshot, delete it
#   database restore one rotating CNPG database into a NEW scratch cluster, count tables and rows, delete it
#   dump     restore the newest in-app dump of a database without CNPG barman (Immich) into a NEW scratch cluster, count tables and rows, delete it
#   etcd     newest etcd snapshot in B2 is younger than ETCD_MAX_AGE_HOURS
#
# Only scratch resources in $NS are created, all labelled, and all deleted on exit (including failures).
# Live PVCs and databases are never read or written; the only live reads are the Kubernetes objects that
# describe the backups. Exit 1 if any check failed (kube-state-metrics sees the Job fail, Prometheus alerts),
# and the failures are POSTed to ntfy.
#
# `backup-verify inspect-volume` is the scratch-volume inspector run in a throwaway pod.
set -uo pipefail

if [ "${1:-}" = inspect-volume ]; then
  cd /data || exit 1
  echo "FILES $(find . -type f | wc -l)"
  echo "BYTES $(find . -type f -printf '%s\n' | awk '{s+=$1} END {print s+0}')"
  find . -type f -size +0 -size -5M | sort | awk '{a[NR]=$0} END {if (NR) for (i=1;i<=3;i++) print "SAMPLE " substr(a[int((NR-1)*i/3)+1],3)}' |
    while read -r tag rel; do echo "$tag $(sha256sum "$rel" | cut -d' ' -f1) $rel"; done
  exit 0
fi

NS=backup-verify # scratch namespace; nothing outside it is ever written
BUCKET=${BUCKET:-trdos-me--volsync}
S3_HOST=${S3_HOST:-s3.us-west-004.backblazeb2.com}
S3_REGION=${S3_REGION:-us-west-004}
MAX_RESTORE_GIB=${MAX_RESTORE_GIB:-10}
ETCD_MAX_AGE_HOURS=${ETCD_MAX_AGE_HOURS:-12}
CHECK_MAX_SUBSET_MIB=${CHECK_MAX_SUBSET_MIB:-2048}
WAIT_RESTORE=${WAIT_RESTORE:-1800}
WAIT_DB=${WAIT_DB:-1500}
DUMP_MAX_AGE_HOURS=${DUMP_MAX_AGE_HOURS:-60}
RUN=$(date -u +%Y%m%d%H%M%S)
PART_OF=app.kubernetes.io/part-of=backup-verify
FAILED=()
SUMMARY=()
export RESTIC_CACHE_DIR=${RESTIC_CACHE_DIR:-/cache}

log() { echo "[$(date -u +%H:%M:%S)] $*"; }
pass() { SUMMARY+=("PASS $*"); log "PASS $*"; }
warn() { SUMMARY+=("WARN $*"); log "WARN $*"; }
fail() { SUMMARY+=("FAIL $*"); FAILED+=("$*"); log "FAIL $*"; }
kn() { kubectl -n "$NS" "$@"; }

cleanup() {
  local rc=0 selector=$1
  log "cleanup ($selector)"
  kn delete clusters.postgresql.cnpg.io -l "$selector" --wait=true --timeout=300s >/dev/null 2>&1 || rc=1
  kn delete replicationdestinations.volsync.backube -l "$selector" --wait=true --timeout=300s >/dev/null 2>&1 || rc=1
  kn delete pods -l "$selector" --wait=true --timeout=120s >/dev/null 2>&1 || rc=1
  kn delete persistentvolumeclaims,secrets -l "$selector" --wait=true --timeout=300s >/dev/null 2>&1 || rc=1
  local left
  left=$(kn get clusters.postgresql.cnpg.io,replicationdestinations.volsync.backube,pods,persistentvolumeclaims,secrets -l "$selector" -o name 2>/dev/null)
  if [ -n "$left" ]; then log "LEFTOVER scratch resources: $left"; rc=1; fi
  return $rc
}
finish() {
  local rc=$?
  trap - EXIT
  [ "$rc" = 143 ] && FAILED+=("verification terminated early (deadline or signal)") && SUMMARY+=("FAIL terminated early")
  cleanup "$PART_OF" || { FAILED+=("cleanup left scratch resources in $NS"); SUMMARY+=("FAIL cleanup left scratch resources in $NS"); }
  report
  [ "${#FAILED[@]}" -eq 0 ] && exit 0
  exit 1
}
trap finish EXIT
trap 'exit 143' TERM INT

report() {
  echo
  echo "=== backup verification $RUN ==="
  printf '%s\n' "${SUMMARY[@]}"
  if [ "${#FAILED[@]}" -gt 0 ] && [ -n "${NTFY_URL:-}" ]; then
    local auth=()
    [ -z "${NTFY_TOKEN:-}" ] || auth=(-H "Authorization: Bearer $NTFY_TOKEN")
    printf '%s\n' "${FAILED[@]}" | curl -sS -m 30 "${auth[@]}" -H "Title: backup verification FAILED" -H "Priority: high" -H "Tags: rotating_light" \
      --data-binary @- "$NTFY_URL" >/dev/null || log "could not POST to ntfy"
  fi
}

restic_env() { # repo-name
  export RESTIC_REPOSITORY="s3:https://$S3_HOST/$BUCKET/$1"
}

# ns<TAB>repository<TAB>sourcePVC for sources that have backed something up. VolSync reports an empty source
# volume as a successful sync ("Directory is empty skipping backup") and never creates the repository.
synced_sources() {
  kubectl get replicationsources.volsync.backube -A -o json |
    jq -r '.items[] | select(.status.lastSyncTime) | select((.status.latestMoverStatus.logs // "") | test("Directory is empty") | not) |
      [.metadata.namespace, .spec.restic.repository, .spec.sourcePVC] | @tsv' | sort
}

rotate() { # picks entries from stdin starting at a monthly-rotating offset, one per line
  local lines n off
  mapfile -t lines
  n=${#lines[@]}
  [ "$n" -gt 0 ] || return 0
  off=$(($(date +%s) / 2592000 % n))
  for ((k = 0; k < n; k++)); do echo "${lines[$(((off + k) % n))]}"; done
}

wait_for() { # seconds description command...
  local limit=$1 what=$2 t=0
  shift 2
  until "$@"; do
    t=$((t + 10))
    if [ "$t" -gt "$limit" ]; then log "timeout waiting for $what"; return 1; fi
    sleep 10
  done
}

# ---- 1. restic check on every VolSync repository --------------------------------------------------
check_restic() {
  local ns repo pvc size mib out rc nsnap ok=0 bad=0 never
  while IFS=$'\t' read -r ns repo pvc; do
    restic_env "$repo"
    out=$(restic stats --mode raw-data --json 2>&1 </dev/null)
    size=$(echo "$out" | tail -n 1 | jq -r '.total_size // empty' 2>/dev/null)
    if [ -z "$size" ]; then fail "restic $ns/$repo: cannot read the repository: $(echo "$out" | tail -n 2 | tr '\n' ' ' | cut -c1-300)"; bad=$((bad + 1)); continue; fi
    # A repository without snapshots is an empty source volume (nothing was ever backed up): nothing to check.
    nsnap=$(restic snapshots --json 2>/dev/null </dev/null | jq 'length' 2>/dev/null)
    if [ "${nsnap:-1}" = 0 ]; then warn "restic $ns/$repo: repository has no snapshots (source volume empty)"; continue; fi
    mib=$((size / 100 / 1048576))
    [ "$mib" -lt 16 ] && mib=16
    [ "$mib" -gt "$CHECK_MAX_SUBSET_MIB" ] && mib=$CHECK_MAX_SUBSET_MIB
    rc=1
    for attempt in 1 2; do
      out=$(timeout 3000 restic check --read-data-subset="${mib}M" 2>&1 </dev/null)
      rc=$?
      [ "$rc" -eq 0 ] && break
      echo "$out" | grep -q "locked" || break
      sleep 120
    done
    if [ "$rc" -eq 0 ]; then
      ok=$((ok + 1)); log "restic ok $ns/$repo ($((size / 1048576)) MiB raw, read ${mib}M)"
    else
      bad=$((bad + 1)); fail "restic check $ns/$repo: $(echo "$out" | tail -n 3 | tr '\n' ' ')"
    fi
  done < <(synced_sources)
  [ "$bad" -eq 0 ] && pass "restic check: $ok repositories, 1% (max ${CHECK_MAX_SUBSET_MIB}M) of data read each"
  while read -r never reason; do warn "restic $never: $reason"; done < <(
    kubectl get replicationsources.volsync.backube -A -o json |
      jq -r '.items[] | select((.status.lastSyncTime | not) or ((.status.latestMoverStatus.logs // "") | test("Directory is empty"))) |
        "\(.metadata.namespace)/\(.spec.restic.repository) " + (if .status.lastSyncTime then "source volume is empty, nothing backed up" else "never synced" end)')
}

# ---- 2. rotating scratch volume restore -----------------------------------------------------------
make_secret() { # name key=value...
  local name=$1 d kv
  shift
  d=$(mktemp -d)
  for kv in "$@"; do printf '%s' "${kv#*=}" > "$d/${kv%%=*}"; done
  kn create secret generic "$name" --from-file="$d" >/dev/null && kn label secret "$name" "$PART_OF" "backup-verify-run=$RUN" >/dev/null
  local rc=$?
  rm -rf "$d"
  return $rc
}

mover_done() {
  local r
  r=$(kn get replicationdestination "$1" -o jsonpath='{.status.latestMoverStatus.result}' 2>/dev/null)
  [ "$r" = Successful ] && return 0
  if [ "$r" = Failed ]; then MOVER_FAILED=1; return 0; fi
  return 1
}

check_volume() {
  local sel ns repo pvc size files name gi out exp_files exp_bytes got_files got_bytes
  sel=$(synced_sources | rotate | while IFS=$'\t' read -r ns repo pvc; do
    if [ -n "${VERIFY_VOLUME:-}" ] && [ "$repo" != "$VERIFY_VOLUME" ]; then continue; fi
    restic_env "$repo"
    st=$(restic stats latest --mode restore-size --json 2>/dev/null </dev/null) || continue
    size=$(echo "$st" | jq -r .total_size)
    files=$(echo "$st" | jq -r .total_file_count)
    [ "${files:-0}" -gt 0 ] || continue
    if [ "$size" -le $((MAX_RESTORE_GIB * 1073741824)) ] || [ -n "${VERIFY_VOLUME:-}" ]; then
      printf '%s\t%s\t%s\t%s\n' "$ns" "$repo" "$pvc" "$size"
      break
    fi
  done)
  if [ -z "$sel" ]; then fail "volume: no restorable repository found (<= ${MAX_RESTORE_GIB}GiB)"; return; fi
  IFS=$'\t' read -r ns repo pvc size <<< "$sel"
  name="bv-$RUN-vol"
  log "volume restore: $ns/$pvc from repository $repo ($((size / 1048576)) MiB)"
  gi=$((size * 5 / 4 / 1073741824 + 1))
  restic_env "$repo"
  make_secret "$name" "RESTIC_REPOSITORY=$RESTIC_REPOSITORY" "RESTIC_PASSWORD=$RESTIC_PASSWORD" \
    "AWS_ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" "AWS_SECRET_ACCESS_KEY=$AWS_SECRET_ACCESS_KEY" "AWS_DEFAULT_REGION=$S3_REGION" ||
    { fail "volume $repo: cannot create scratch secret"; return; }
  kn apply -f - >/dev/null <<YAML || { fail "volume $repo: cannot create scratch PVC/destination"; return; }
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: $name, labels: {app.kubernetes.io/part-of: backup-verify, backup-verify-run: "$RUN"}}
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: ceph-block
  resources: {requests: {storage: ${gi}Gi}}
---
apiVersion: volsync.backube/v1alpha1
kind: ReplicationDestination
metadata: {name: $name, labels: {app.kubernetes.io/part-of: backup-verify, backup-verify-run: "$RUN"}}
spec:
  trigger: {manual: bv-$RUN}
  restic:
    repository: $name
    copyMethod: Direct
    destinationPVC: $name
    moverSecurityContext: {runAsUser: 101, runAsGroup: 101, fsGroup: 101}
YAML
  MOVER_FAILED=0
  if ! wait_for "$WAIT_RESTORE" "restore into $name" mover_done "$name" || [ "$MOVER_FAILED" = 1 ]; then
    fail "volume $ns/$repo: VolSync restore did not succeed ($(kn get replicationdestination "$name" -o jsonpath='{.status.latestMoverStatus.logs}' 2>/dev/null | tail -n 3 | tr '\n' ' '))"
    return
  fi
  kn apply -f - >/dev/null <<YAML || { fail "volume $repo: cannot start inspector pod"; return; }
apiVersion: v1
kind: Pod
metadata: {name: $name-inspect, labels: {app.kubernetes.io/part-of: backup-verify, backup-verify-run: "$RUN"}}
spec:
  restartPolicy: Never
  securityContext: {runAsUser: 101, runAsGroup: 101, fsGroup: 101, runAsNonRoot: true, seccompProfile: {type: RuntimeDefault}}
  containers:
  - name: inspect
    image: $SELF_IMAGE
    args: [inspect-volume]
    securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: [ALL]}}
    volumeMounts: [{name: data, mountPath: /data, readOnly: true}]
  volumes: [{name: data, persistentVolumeClaim: {claimName: $name, readOnly: true}}]
YAML
  inspect_done() { [[ "$(kn get pod "$name-inspect" -o jsonpath='{.status.phase}' 2>/dev/null)" =~ ^(Succeeded|Failed)$ ]]; }
  wait_for 900 "inspector pod" inspect_done
  out=$(kn logs "$name-inspect" 2>/dev/null)
  got_files=$(echo "$out" | awk '$1=="FILES"{print $2}')
  got_bytes=$(echo "$out" | awk '$1=="BYTES"{print $2}')
  if [ -z "$got_files" ]; then fail "volume $ns/$repo: inspector produced no output"; return; fi
  restic_env "$repo"
  restic ls latest --json 2>/dev/null | jq -c 'select(.type == "file") | [.path, .size]' > /tmp/ls.json
  exp_files=$(wc -l < /tmp/ls.json)
  exp_bytes=$(jq -s 'map(.[1]) | add // 0' /tmp/ls.json)
  if [ "$got_files" != "$exp_files" ] || [ "$got_bytes" != "$exp_bytes" ]; then
    fail "volume $ns/$repo: restored $got_files files / $got_bytes bytes, snapshot has $exp_files / $exp_bytes"
    return
  fi
  local bad=0 n=0 tag sha rel path want
  while read -r tag sha rel; do
    [ "$tag" = SAMPLE ] || continue
    path=$(jq -r --arg rel "/$rel" 'select(.[0] | endswith($rel)) | .[0]' /tmp/ls.json | head -n 1)
    want=$(restic dump latest "$path" 2>/dev/null </dev/null | sha256sum | cut -d' ' -f1)
    n=$((n + 1))
    [ "$want" = "$sha" ] || { bad=$((bad + 1)); fail "volume $ns/$repo: sha256 differs for $rel"; }
  done <<< "$out"
  [ "$bad" -eq 0 ] && pass "volume restore $ns/$pvc (repository $repo): $got_files files, $got_bytes bytes match the snapshot, $n sampled checksums equal"
  # state: scratch objects are deleted by cleanup on exit
}

# ---- 3. rotating scratch CNPG restore -------------------------------------------------------------
psql_scratch() { # pod db sql
  kn exec "$1" -c postgres -- psql -U postgres -d "$2" -Atq -c "$3"
}

cluster_healthy() { [ "$(kn get cluster "$1" -o jsonpath='{.status.phase}' 2>/dev/null)" = "Cluster in healthy state" ]; }

check_database() {
  local sel ns src name json image storage dest endpoint server libs pod dbs db tables rows prev prev_tables
  sel=$(kubectl get clusters.postgresql.cnpg.io -A -o json |
    jq -r '.items[] | select(.spec.backup.barmanObjectStore != null and .status.lastSuccessfulBackup != null) | [.metadata.namespace, .metadata.name] | @tsv' |
    sort | rotate | while IFS=$'\t' read -r ns src; do
      if [ -n "${VERIFY_DATABASE:-}" ] && [ "$src" != "$VERIFY_DATABASE" ]; then continue; fi
      printf '%s\t%s\n' "$ns" "$src"
      break
    done)
  if [ -z "$sel" ]; then fail "database: no CNPG cluster with a completed backup found"; return; fi
  IFS=$'\t' read -r ns src <<< "$sel"
  json=$(kubectl -n "$ns" get cluster "$src" -o json)
  image=$(jq -r .spec.imageName <<< "$json")
  storage=$(jq -r '.spec.storage.size' <<< "$json")
  dest=$(jq -r .spec.backup.barmanObjectStore.destinationPath <<< "$json")
  endpoint=$(jq -r .spec.backup.barmanObjectStore.endpointURL <<< "$json")
  server=$(jq -r --arg n "$src" '.spec.backup.barmanObjectStore.serverName // $n' <<< "$json")
  libs=$(jq -c '.spec.postgresql.shared_preload_libraries // []' <<< "$json")
  name="bv-$RUN-db"
  log "database restore: $ns/$src (image $image, $storage) into scratch cluster $name"
  make_secret "$name" "ACCESS_KEY_ID=$AWS_ACCESS_KEY_ID" "ACCESS_SECRET_KEY=$AWS_SECRET_ACCESS_KEY" ||
    { fail "database $src: cannot create scratch secret"; return; }
  # No backup section: the scratch cluster never writes to the bucket.
  kn apply -f - >/dev/null <<YAML || { fail "database $src: cannot create scratch cluster"; return; }
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: $name, labels: {app.kubernetes.io/part-of: backup-verify, backup-verify-run: "$RUN"}}
spec:
  instances: 1
  imageName: $image
  storage: {size: $storage, storageClass: ceph-block}
  postgresql: {shared_preload_libraries: $libs}
  bootstrap: {recovery: {source: $src}}
  externalClusters:
  - name: $src
    barmanObjectStore:
      destinationPath: $dest
      endpointURL: $endpoint
      serverName: $server
      s3Credentials:
        accessKeyId: {name: $name, key: ACCESS_KEY_ID}
        secretAccessKey: {name: $name, key: ACCESS_SECRET_KEY}
YAML
  if ! wait_for "$WAIT_DB" "cluster $name healthy" cluster_healthy "$name"; then
    fail "database $ns/$src: scratch cluster never became healthy ($(kn get cluster "$name" -o jsonpath='{.status.phase}' 2>/dev/null))"
    return
  fi
  pod="$name-1"
  dbs=$(psql_scratch "$pod" postgres "select datname from pg_database where not datistemplate and datname <> 'postgres'")
  if [ -z "$dbs" ]; then fail "database $ns/$src: restored cluster has no user database"; return; fi
  # CNPG's recovery also creates an empty default database (`app`); only databases with tables count.
  local line="" bad=0 nonempty=0
  for db in $dbs; do
    tables=$(psql_scratch "$pod" "$db" "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
    if ! [ "${tables:-0}" -gt 0 ] 2>/dev/null; then line="$line $db: empty (skipped);"; continue; fi
    nonempty=$((nonempty + 1))
    rows=$(psql_scratch "$pod" "$db" "select coalesce(sum((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint), 0) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
    line="$line $db: $tables tables ${rows:-?} rows;"
    # Compare with the previous run for this database, kept in a ConfigMap; never the live database.
    prev=$(kn get configmap backup-verify-state -o jsonpath="{.data.db-$ns-$src-$db}" 2>/dev/null)
    prev_tables=${prev%% *}
    if [ -n "$prev_tables" ] && [ "$tables" -lt "$prev_tables" ]; then
      bad=1; fail "database $ns/$src/$db: $tables tables, previous verification had $prev_tables"
    fi
    kn patch configmap backup-verify-state --type=merge -p "{\"data\":{\"db-$ns-$src-$db\":\"$tables ${rows:-0}\"}}" >/dev/null 2>&1 ||
      kn create configmap backup-verify-state --from-literal="db-$ns-$src-$db=$tables ${rows:-0}" >/dev/null 2>&1
  done
  if [ "$nonempty" -eq 0 ]; then fail "database $ns/$src: restored cluster has no database with tables:$line"; bad=1; fi
  [ "$bad" -eq 0 ] && pass "database restore $ns/$src from B2 (base backup + WAL):$line"
}

# ---- 3b. scratch restore of in-app dumps (databases without CNPG barman) --------------------------
# DUMP_SOURCES: whitespace separated `namespace/cluster|restic-repository|dump path regex` entries, e.g.
#   media/immich|volsync--immich--immich-server|^/backups/.*\.sql\.gz$
# The newest matching file in the latest snapshot of the repository is streamed with `restic dump` into a NEW
# scratch cluster (same image, preload libraries, bootstrap database and owner as the live one), gunzipped and
# loaded with psql inside the scratch pod. The live cluster is only read as a Kubernetes object.
check_dump_one() { # entry
  local ns src repo re entry=$1 json image storage libs uid gid db owner name pod ls path mtime age tables rows prev prev_tables rc out bad=0
  IFS='|' read -r ns repo re <<< "$entry"
  src=${ns#*/}
  ns=${ns%/*}
  json=$(kubectl -n "$ns" get cluster "$src" -o json 2>/dev/null) || { fail "dump $ns/$src: cluster not found"; return; }
  image=$(jq -r .spec.imageName <<< "$json")
  storage=$(jq -r .spec.storage.size <<< "$json")
  libs=$(jq -c '.spec.postgresql.shared_preload_libraries // []' <<< "$json")
  uid=$(jq -r '.spec.postgresUID // 26' <<< "$json")
  gid=$(jq -r '.spec.postgresGID // 26' <<< "$json")
  db=$(jq -r '.spec.bootstrap.initdb.database // "app"' <<< "$json")
  owner=$(jq -r '.spec.bootstrap.initdb.owner // "app"' <<< "$json")
  restic_env "$repo"
  ls=$(restic ls latest --json 2>/dev/null </dev/null | jq -c --arg re "$re" 'select(.type == "file") | select(.path | test($re)) | [.path, .mtime, .size]' | sort | tail -n 1)
  if [ -z "$ls" ]; then fail "dump $ns/$src: no file matching $re in the latest snapshot of $repo"; return; fi
  path=$(jq -r '.[0]' <<< "$ls")
  mtime=$(jq -r '.[1]' <<< "$ls")
  age=$(( ($(date +%s) - $(date -d "$mtime" +%s)) / 3600 ))
  if [ "$age" -gt "$DUMP_MAX_AGE_HOURS" ]; then fail "dump $ns/$src: newest dump in B2 ($path) is ${age}h old (limit ${DUMP_MAX_AGE_HOURS}h)"; return; fi
  name="bv-$RUN-dump"
  log "dump restore: $ns/$src from $repo:$path (${age}h old) into scratch cluster $name (image $image, $storage)"
  kn apply -f - >/dev/null <<YAML || { fail "dump $src: cannot create scratch cluster"; return; }
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata: {name: $name, labels: {app.kubernetes.io/part-of: backup-verify, backup-verify-run: "$RUN"}}
spec:
  instances: 1
  imageName: $image
  postgresUID: $uid
  postgresGID: $gid
  storage: {size: $storage, storageClass: ceph-block}
  postgresql: {shared_preload_libraries: $libs}
  bootstrap: {initdb: {database: $db, owner: $owner}}
YAML
  if ! wait_for "$WAIT_DB" "cluster $name healthy" cluster_healthy "$name"; then
    fail "dump $ns/$src: scratch cluster never became healthy ($(kn get cluster "$name" -o jsonpath='{.status.phase}' 2>/dev/null))"
    return
  fi
  pod="$name-1"
  # The search_path rewrite is the one Immich documents for restoring its dumps. pipefail makes a failing
  # restic dump or psql fail the pipeline.
  out=$(restic dump latest "$path" 2>/tmp/dump.err </dev/null |
    kn exec -i "$pod" -c postgres -- bash -c "gunzip | sed \"s/SELECT pg_catalog.set_config('search_path', '', false);/SELECT pg_catalog.set_config('search_path', 'public, pg_catalog', true);/g\" | psql -U postgres -d $db -v ON_ERROR_STOP=1 -q -o /dev/null" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "dump $ns/$src: loading $path failed (exit $rc): $(echo "$out" "$(tail -n 2 /tmp/dump.err)" | tail -n 3 | tr '\n' ' ' | cut -c1-400)"
    return
  fi
  tables=$(psql_scratch "$pod" "$db" "select count(*) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
  rows=$(psql_scratch "$pod" "$db" "select coalesce(sum((xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', schemaname, tablename), false, true, '')))[1]::text::bigint), 0) from pg_tables where schemaname not in ('pg_catalog','information_schema')")
  if ! [ "${tables:-0}" -gt 0 ] 2>/dev/null || ! [ "${rows:-0}" -gt 0 ] 2>/dev/null; then
    fail "dump $ns/$src: restored database $db has ${tables:-?} tables and ${rows:-?} rows"
    return
  fi
  prev=$(kn get configmap backup-verify-state -o jsonpath="{.data.dump-$ns-$src-$db}" 2>/dev/null)
  prev_tables=${prev%% *}
  if [ -n "$prev_tables" ] && [ "$tables" -lt "$prev_tables" ]; then bad=1; fail "dump $ns/$src/$db: $tables tables, previous verification had $prev_tables"; fi
  kn patch configmap backup-verify-state --type=merge -p "{\"data\":{\"dump-$ns-$src-$db\":\"$tables $rows\"}}" >/dev/null 2>&1 ||
    kn create configmap backup-verify-state --from-literal="dump-$ns-$src-$db=$tables $rows" >/dev/null 2>&1
  [ "$bad" -eq 0 ] && pass "dump restore $ns/$src from B2 ($path, ${age}h old): database $db has $tables tables, $rows rows"
}

check_dump() {
  local entry
  if [ -z "${DUMP_SOURCES:-}" ]; then fail "dump: DUMP_SOURCES is empty"; return; fi
  for entry in $DUMP_SOURCES; do
    check_dump_one "$entry"
    cleanup "$PART_OF" || fail "cleanup after dump restore of ${entry%%|*} left scratch resources"
  done
}

# ---- 4. newest etcd snapshot in B2 ----------------------------------------------------------------
check_etcd() {
  local xml newest age
  xml=$(curl -sS -m 60 --fail --aws-sigv4 "aws:amz:$S3_REGION:s3" -u "$AWS_ACCESS_KEY_ID:$AWS_SECRET_ACCESS_KEY" \
    "https://$S3_HOST/$BUCKET?list-type=2&prefix=etcd/") || { fail "etcd: cannot list s3://$BUCKET/etcd/"; return; }
  newest=$(echo "$xml" | grep -o '<LastModified>[^<]*' | cut -d'>' -f2 | sort | tail -n 1)
  if [ -z "$newest" ]; then fail "etcd: no snapshots under s3://$BUCKET/etcd/"; return; fi
  age=$(( ($(date +%s) - $(date -d "$newest" +%s)) / 60 ))
  if [ "$age" -gt $((ETCD_MAX_AGE_HOURS * 60)) ]; then
    fail "etcd: newest snapshot in B2 is $((age / 60))h$((age % 60))m old (limit ${ETCD_MAX_AGE_HOURS}h), $newest"
  else
    pass "etcd: newest snapshot in B2 is $((age / 60))h$((age % 60))m old (limit ${ETCD_MAX_AGE_HOURS}h), $(echo "$xml" | grep -o '<Key>' | wc -l) objects"
  fi
}

log "backup verification $RUN"
cleanup "$PART_OF" || log "sweep of earlier scratch resources incomplete"
for step in ${STEPS:-etcd restic volume database}; do
  case "$step" in
    etcd) check_etcd ;;
    restic) check_restic ;;
    volume) check_volume ;;
    database) check_database ;;
    dump) check_dump ;;
  esac
  # scratch resources of a finished step are deleted before the next starts
  cleanup "$PART_OF" || fail "cleanup after $step left scratch resources"
done
