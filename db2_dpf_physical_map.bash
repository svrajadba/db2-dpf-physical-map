#!/bin/bash
[ -n "$BASH_VERSION" ] || exec bash "$0" "$@"
# =============================================================================
# db2_dpf_physical_map.bash  (v4)
# Reports what exists for a DB2 LUW DPF database whose logical partitions all
# live on the same server:
#
#   Instance -> Host -> Logical partition (port) -> DB path / Log path / Archive
#            -> Storage group paths -> Partition group -> Tablespace
#            -> Container -> Filesystem -> Mount/Device
#
# Report only: no validation, no recommendations.
# Usage : ./db2_dpf_physical_map.sh <DBNAME> [outfile]
# Run as: DB2 instance owner (db2profile sourced)
# Use bash to call this script
# =============================================================================

DB=${1:?"Usage: $0 <DBNAME> [outfile]"}
OUT=${2:-db2_dpf_map_${DB}_$(date +%Y%m%d_%H%M%S).txt}
TMP=$(mktemp -d /tmp/dpfmap.XXXXXX)
TO=${DB2_QUERY_TIMEOUT:-60}
INST=${DB2INSTANCE:-$(id -un)}
trap 'rm -rf "$TMP"; exec >&- 2>&-; wait' EXIT

: > "$TMP/warnings.txt"
: > "$TMP/part_fs.txt"

exec > >(tee "$OUT") 2>&1

hr()   { printf '%*s\n' 100 '' | tr ' ' '='; }
sec()  { echo; hr; echo "## $*"; hr; }
warn() { echo "    !! WARN: $*"; echo "$*" >> "$TMP/warnings.txt"; }

# NOTE: db2 CLP calls are made DIRECTLY (no timeout wrapper): the CLP back-end
# session is tied to the parent PID of the 'db2' command (SQL1024N otherwise).
# CLP return codes: 0 ok, 1 no rows, 2 warning, 4/8 error.

# --- connect to a specific logical partition and VERIFY we landed there ------
conn() {
  export DB2NODE=$1
  db2 terminate >/dev/null 2>&1
  db2 connect to "$DB" >"$TMP/conn.log" 2>&1 || { sed 's/^/    /' "$TMP/conn.log"; return 1; }
  db2 -x "values current dbpartitionnum" >"$TMP/cur.txt" 2>&1
  local cur; cur=$(tr -d ' \n' <"$TMP/cur.txt")
  [ "$cur" = "$1" ] || { echo "    connected, but verify returned: $(cat "$TMP/cur.txt") (expected partition $1)"; return 1; }
}

# --- filesystem info for a path; robust to spaces in mount points ------------
# sets: MNT FSDEV FST SZ USED PCT
fsinfo() {
  local p=$1 line
  MNT=; FSDEV=; FST=; SZ=; USED=; PCT=
  if command -v findmnt >/dev/null 2>&1; then
    MNT=$(findmnt -n -o TARGET  -T "$p" 2>/dev/null)
    FSDEV=$(findmnt -n -o SOURCE -T "$p" 2>/dev/null)
    FST=$(findmnt -n -o FSTYPE  -T "$p" 2>/dev/null)
  fi
  line=$(df -Pk "$p" 2>/dev/null | awk 'NR==2')
  if [ -z "$MNT" ]; then
    FSDEV=$(awk '{print $1}' <<<"$line")
    MNT=$(awk '{$1=$2=$3=$4=$5=""; sub(/^ +/,""); print}' <<<"$line")
    FST=$(mount 2>/dev/null | awk -v m="$MNT" '$3==m {print $5; exit}')
  fi
  read -r SZ USED PCT < <(awk '{printf "%.0fG %.0fG %s\n",$2/1048576,$3/1048576,$5}' <<<"$line")
}

# ---------------------------------------------------------------- 1. Instance
sec "1. INSTANCE / HOST"
echo "Date        : $(date)"
echo "Host        : $(hostname -f 2>/dev/null || hostname)"
echo "Instance    : $INST"
echo "Inst home   : $HOME"
echo "OS          : $(uname -sr)"
echo "CPU / Mem   : $(nproc 2>/dev/null) cores / $(free -g 2>/dev/null | awk '/Mem:/{print $2" GB"}')"
echo
db2level | grep -E "Informational|Product is|level identifier|Fix Pack|tokens"
echo
echo "--- db2nodes.cfg ($(readlink -f "$HOME/sqllib/db2nodes.cfg" 2>/dev/null)) ---"
NODECFG=$HOME/sqllib/db2nodes.cfg
[ -r "$NODECFG" ] || { echo "Cannot read $NODECFG - not a DPF instance owner shell?"; exit 3; }
cat "$NODECFG"
echo
echo "--- FCM ports in /etc/services ---"
grep -iE "^(DB2_|db2c_)${INST}" /etc/services
echo
echo "--- Logical port -> FCM service -> port ---"
printf "%-10s %-10s %-25s %s\n" "PARTITION" "LOGPORT" "SERVICE" "PORT"
while read -r pn _host lp; do
  [[ "$pn" =~ ^[0-9]+$ ]] || continue
  if [ "$lp" = "0" ]; then
    SVC="DB2_${INST}"
  else
    SVC="DB2_${INST}_${lp}"
  fi
  PORT=$(awk -v s="$SVC" '$1==s {print $2}' /etc/services)
  printf "%-10s %-10s %-25s %s\n" "$pn" "$lp" "$SVC" "${PORT:-<not in /etc/services>}"
done < "$NODECFG"
echo
echo "--- Listening TCP sockets ---"
if command -v ss >/dev/null 2>&1; then ss -lnt 2>/dev/null
elif command -v netstat >/dev/null 2>&1; then netstat -lnt 2>/dev/null
else echo "ss/netstat not available"; fi
echo
echo "--- db2set -all ---"
db2set -all
echo
echo "--- DBM CFG (key items) ---"
db2 get dbm cfg | grep -iE "SVCENAME|DFTDBPATH|DIAGPATH|FCM_NUM_BUFFERS|FCM_NUM_CHANNELS|INSTANCE_MEMORY|NUMDB"

PARTS=$(awk '$1 ~ /^[0-9]+$/ {print $1}' "$NODECFG" | sort -n | uniq)
DIAGPATH=$(db2 get dbm cfg | awk -F'= ' '/\(DIAGPATH\)/ {print $2}' | awk '{print $1}')

# ---------------------------------------------------------- 2. DB directory
sec "2. DATABASE DIRECTORY ENTRY (catalog partition)"
db2 list db directory | awk -v db="$DB" '
  /Database alias/ {a=(toupper($NF)==toupper(db))}
  a {print}
' | head -20

# ----------------------- pick the first reachable partition for catalog views
BASE=
for N in $PARTS; do
  if conn "$N"; then BASE=$N; break; else warn "partition $N not reachable for catalog queries"; fi
done
[ -n "$BASE" ] || { echo "No partition reachable - aborting."; exit 2; }
echo "(catalog views read via partition $BASE)"

# ----------------------------------------------------- 3. Partition groups
sec "3. DATABASE PARTITION GROUPS -> PARTITIONS"
db2 "select cast(rtrim(pg.dbpgname) as varchar(30)) as PGNAME,
            coalesce(char(d.dbpartitionnum),'-') as PART, d.in_use as IN_USE
       from syscat.dbpartitiongroups pg
       left join syscat.dbpartitiongroupdef d on d.dbpgname = pg.dbpgname
      order by pg.dbpgname, d.dbpartitionnum"

sec "3a. PARTITION GROUP -> TABLESPACE -> BUFFERPOOL / STORAGE GROUP"
db2 "select cast(rtrim(ts.dbpgname) as varchar(20)) as PGNAME,
            cast(rtrim(ts.tbspace) as varchar(24)) as TBSPACE,
            case ts.tbspacetype when 'D' then 'DMS' when 'S' then 'SMS' end as TYPE,
            case ts.datatype when 'A' then 'REG' when 'L' then 'LARGE'
                 when 'T' then 'SYSTMP' when 'U' then 'USRTMP' else ts.datatype end as CONTENT,
            ts.pagesize as PGSZ, ts.extentsize as EXT,
            cast(rtrim(bp.bpname) as varchar(20)) as BUFFERPOOL,
            cast(rtrim(ts.sgname) as varchar(20)) as STOGROUP
       from syscat.tablespaces ts
       left join syscat.bufferpools bp on bp.bufferpoolid = ts.bufferpoolid
      order by 1,2"

sec "3b. BUFFERPOOLS (and per-partition overrides)"
db2 "select cast(rtrim(bpname) as varchar(24)) as BPNAME, npages,
            case when npages = -2 then 'AUTOMATIC' else 'FIXED' end as SIZING,
            pagesize,
            coalesce(cast(rtrim(ngname) as varchar(24)),'(all partitions)') as PGNAME
       from syscat.bufferpools"
db2 "select cast(rtrim(b.bpname) as varchar(24)) as BPNAME, d.dbpartitionnum as PART, d.npages
       from syscat.bufferpooldbpartitions d, syscat.bufferpools b
      where b.bufferpoolid=d.bufferpoolid order by 1,2" 2>/dev/null

sec "3c. STORAGE GROUPS"
db2 "select sgid, cast(rtrim(sgname) as varchar(24)) as SGNAME, defaultsg, overhead, devicereadrate
       from syscat.stogroups" 2>/dev/null

# --------------------------------------------------- 4. Per partition detail
sec "4. PER-PARTITION PHYSICAL DEPENDENCY TREE"
FAILED=""

for N in $PARTS; do
  echo
  echo "################################################################################"
  HOSTPORT=$(awk -v n="$N" '$1==n {print $2" / logical port "$3}' "$NODECFG")
  echo "# DATABASE PARTITION $N      host/port: $HOSTPORT"
  echo "################################################################################"

  if ! conn "$N"; then
    warn "partition $N unreachable - section skipped"
    FAILED="$FAILED $N"
    continue
  fi

  # --- [a] db paths (kept as TYPE|PATH in a file; also feeds the FS map)
  echo "[a] Database directory paths"
  db2 -x "select rtrim(type)||'|'||rtrim(path) from sysibmadm.dbpaths where dbpartitionnum=$N order by type" \
      > "$TMP/dbp_$N.txt" 2>"$TMP/err_$N.txt"; rc=$?
  [ $rc -le 2 ] || warn "DBPATHS query failed on partition $N: $(head -1 "$TMP/err_$N.txt")"
  sed -i 's/[[:space:]]*$//' "$TMP/dbp_$N.txt"

  # extra paths from DB CFG / DBM CFG
  db2 get db cfg for "$DB" > "$TMP/dbcfg_$N.txt" 2>&1
  awk -F'= ' '/Overflow log path/ {gsub(/[ \t]+$/,"",$2); if($2!="") print "OVERFLOWLOGPATH|"$2}
              /Mirror log path/   {gsub(/[ \t]+$/,"",$2); if($2!="") print "MIRRORLOGPATH|"$2}
              /\(LOGARCHMETH1\)/  {gsub(/[ \t]+$/,"",$2); if($2 ~ /^DISK:/) {sub(/^DISK:/,"",$2); print "LOGARCHMETH1_PATH|"$2}}
              /\(LOGARCHMETH2\)/  {gsub(/[ \t]+$/,"",$2); if($2 ~ /^DISK:/) {sub(/^DISK:/,"",$2); print "LOGARCHMETH2_PATH|"$2}}' \
      "$TMP/dbcfg_$N.txt" >> "$TMP/dbp_$N.txt"
  [ -n "$DIAGPATH" ] && echo "DIAGPATH|$DIAGPATH" >> "$TMP/dbp_$N.txt"

  sed 's/^\([^|]*\)|/    \1 -> /' "$TMP/dbp_$N.txt"

  echo "[b] Log / archive settings"
  grep -iE "Path to log files|Overflow log path|Mirror log path|First active log|LOGARCHMETH|LOGFILSIZ|LOGPRIMARY|LOGSECOND|NEWLOGPATH" \
      "$TMP/dbcfg_$N.txt" | sed 's/^/    /'

  echo "[c] Automatic storage paths for this partition"
  db2 -x "select '    '||rtrim(storage_group_name)||' -> '||rtrim(db_storage_path)||'  ['||rtrim(db_storage_path_state)||']'
            from table(admin_get_storage_paths(null,$N))" 2>/dev/null | sed 's/[[:space:]]*$//'

  echo "[d] Tablespace state / size on this partition"
  db2 -x "select '    '||rtrim(tbsp_name)||'  state='||rtrim(tbsp_state)||'  pagesize='||cast(tbsp_page_size as varchar(10))||
                 '  total_pages='||cast(tbsp_total_pages as varchar(20))||'  used_pages='||cast(tbsp_used_pages as varchar(20))
            from table(mon_get_tablespace(null,$N)) order by tbsp_name" 2>/dev/null | sed 's/[[:space:]]*$//'

  echo "[e] Tablespace -> Container -> Filesystem -> Device"
  db2 -x "select rtrim(tbsp_name)||'|'||rtrim(container_name)||'|'||rtrim(container_type)||'|'||
                 cast(total_pages as varchar(20))||'|'||cast(usable_pages as varchar(20))||'|'||rtrim(accessible)
            from table(mon_get_container(null,$N))
           order by tbsp_name, container_id" > "$TMP/cont_$N.txt" 2>"$TMP/err_$N.txt"; rc=$?
  [ $rc -le 2 ] || { warn "MON_GET_CONTAINER failed on partition $N: $(head -1 "$TMP/err_$N.txt")"; : > "$TMP/cont_$N.txt"; }
  sed -i 's/[[:space:]]*$//' "$TMP/cont_$N.txt"

  PREV=""
  # redirect (not pipe) => loop runs in the current shell
  while IFS='|' read -r TS CPATH CTYPE TP UP ACC; do
    [ -z "$TS" ] && continue
    if [ "$TS" != "$PREV" ]; then echo "    TABLESPACE $TS"; PREV=$TS; fi
    if [ -e "$CPATH" ]; then
      fsinfo "$CPATH"
      printf "      +- %-60s [%s pages=%s usable=%s acc=%s]\n" "$CPATH" "$CTYPE" "$TP" "$UP" "$ACC"
      printf "         +- FS mount: %-15s dev: %-45s type: %-6s size: %s used: %s (%s)\n" \
             "$MNT" "$FSDEV" "$FST" "$SZ" "$USED" "$PCT"
      echo "$N|$MNT|$FSDEV|CONTAINER $TS: $CPATH" >> "$TMP/part_fs.txt"
    else
      printf "      +- %-60s [%s] (path not visible from this shell)\n" "$CPATH" "$CTYPE"
    fi
  done < "$TMP/cont_$N.txt"

  echo "[f] Filesystem of db / log / archive / diag paths"
  while IFS='|' read -r R P; do
    [ -d "$P" ] || continue
    fsinfo "$P"
    printf "    %-18s %-55s mount: %-15s dev: %s\n" "$R" "$P" "$MNT" "$FSDEV"
    echo "$N|$MNT|$FSDEV|$R: $P" >> "$TMP/part_fs.txt"
  done < "$TMP/dbp_$N.txt"
done

# ------------------------------------------- 5. Filesystem -> partitions map
sec "5. FILESYSTEM -> PARTITIONS / OBJECTS MAP"
sort -u "$TMP/part_fs.txt" | awk -F'|' '
  { k=$2"|"$3
    if(!((k,$1) in s)){s[k,$1]=1; p[k]=p[k]" "$1; c[k]++}
    o[k]=o[k] sprintf("\n      P%s  %s", $1, $4) }
  END { for(k in p){ split(k,a,"|")
          printf "\nMOUNT %s  DEVICE %s  #PARTS %d  PARTITIONS%s%s\n", a[1], a[2], c[k], p[k], o[k] } }'

# --------------------------------------------------- 6. Block device stack
sec "6. BLOCK DEVICE STACK (LVM / multipath / disks)"
lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>/dev/null || echo "lsblk not available"
echo
echo "--- mounted filesystems used by DB2 ---"
while IFS= read -r M; do
  [ -n "$M" ] && findmnt -n -o TARGET,SOURCE,FSTYPE,OPTIONS "$M" 2>/dev/null
done < <(cut -d'|' -f2 "$TMP/part_fs.txt" | sort -u)

# --------------------------------------------------- 7. Runtime processes
sec "7. RUNTIME: DB2 PROCESSES PER PARTITION"
if command -v db2_ps >/dev/null 2>&1; then
  echo "(db2_ps)"
  if command -v timeout >/dev/null 2>&1; then timeout "$TO" db2_ps | cut -c1-160 | head -80; else db2_ps | cut -c1-160 | head -80; fi
else
  echo "(db2_ps not found - falling back to ps; the number after db2sysc is the partition)"
  ps -u "$(id -un)" -o pid,ppid,etime,args 2>/dev/null | grep -E "db2sysc|db2agent|db2fmp" | grep -v grep | cut -c1-160 | head -80
fi
echo
echo "--- Shared memory segments owned by instance user ---"
ipcs -m 2>/dev/null | awk -v u="$(id -un)" 'NR<=3 || $3==u'

# --------------------------------------------------------------- summary
sec "8. RUN SUMMARY"
RC=0
if [ -n "$FAILED" ]; then echo "Partitions skipped (unreachable):$FAILED"; RC=2; else echo "All partitions reachable."; fi
if [ -s "$TMP/warnings.txt" ]; then echo "Warnings:"; sed 's/^/  - /' "$TMP/warnings.txt"; [ $RC -eq 0 ] && RC=1; else echo "No warnings."; fi

db2 terminate >/dev/null 2>&1
echo
echo "Report written to: $OUT"
exit $RC
