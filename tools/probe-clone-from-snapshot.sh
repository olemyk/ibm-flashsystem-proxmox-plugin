#!/usr/bin/env bash
#
# probe-clone-from-snapshot.sh — settle every open question about the
# clone-from-snapshot path in one pass, on scratch objects, before anything
# is built on top of it.
#
# WHY THIS EXISTS
#
# `mkvolume` is the one Storage Virtualize command family this plugin has
# never issued. Allocation deliberately uses `mkvdisk`, and the from-snapshot
# form of mkvolume is the single primitive the Kubernetes snapshot design
# requires and nobody here has run. Everything else in that design is either
# already in production (addsnapshot / rmsnapshot / restorefromsnapshot, live
# since 2026-08-12) or verifiable without hardware (the naming contract, in
# tests/t_names.pl).
#
# So this script is the gate. It answers, with raw response bodies:
#
#   D  is POST /rest/v1/mkvolume reachable over REST v1 on this firmware?
#   E  is the snapshot-source form accepted for a LOOSE volume (no volume
#      group)? Every documented IBM example uses a volume group.
#   F  is it accepted in a data reduction pool?
#   G  did -name actually name the VOLUME (not a group)?
#   H  is the result a thinclone or a background copy, and at what rate?
#      IBM's default is 2 MB/s, i.e. hours for a large volume.
#   K  is rmsnapshot REFUSED while a thinclone depends on the snapshot, or
#      accepted-and-deferred?
#   L  if deferred, is the snapshot still visible to a plain lsvolumesnapshot?
#      The plugin treats "no id found" as "already gone -> idempotent", so an
#      invisible-but-undeleted snapshot means every delete reports success
#      while capacity is never freed.
#   M  is restorefromsnapshot permitted on a loose volume?
#   N  does restorefromsnapshot CHANGE vdisk_UID? If it does, every attached
#      host's /dev/mapper entry is stale and the failure mode is a node-wide
#      LVM hang, not an error. This claim exists in exactly ONE place in the
#      whole repository — an unsourced comment in _rescan_scsi — with no test
#      and no changelog entry, and IBM's documentation is silent both ways.
#   O  does rmvdisk succeed on a volume whose only encumbrance is ONE
#      snapshot, with no -force? Silent destruction and a refused delete need
#      OPPOSITE fixes in free_image, so this decides real code. Measured on
#      its own clean volume, because the main scratch volume accumulates a
#      deferred delete and a restore along the way.
#   R  does a BARE rmvdisk (the call free_image actually makes) delete a
#      thinclone, or does that need rmvolume / -force?
#   P  does lsvolumesnapshot honour -filtervalue on this firmware, or accept
#      and ignore it? A silently-ignored filter looks identical to one that
#      worked, which is why the plugin scopes client-side today.
#   Q  does addsnapshot return the new snapshot id in its response body?
#
# D, E, F, K and O are each individually design-killing. M and N decide
# whether in-place rollback is buildable at all.
#
# Every verdict is one of OK / NO / INCONCLUSIVE, and the script exits
# non-zero if anything was NO or INCONCLUSIVE — so it can actually gate.
#
# SAFETY
#
#   - Operates on TWO scratch volumes and ONE clone that it creates itself.
#     Cleanup deletes ONLY objects it recorded creating; a name that already
#     existed is never touched, and the pre-flight fails CLOSED.
#   - Every id fed to a destructive call is resolved from lsvolumesnapshot by
#     snapshot_name AND volume_name — never taken from a response body, and
#     never harvested by substring match. Same rule the plugin's own
#     _snapshots_for follows.
#   - JSON is parsed with perl JSON::PP (core on any PVE node), not sed.
#   - Refuses a pool that is too full, or a size above 8 GiB, and asks for
#     confirmation before the first destructive call.
#   - Requires `fssnapshots 1` on the target storage, so its cleanup path and
#     the plugin's agree about what may exist.
#
# USAGE
#
#   ./probe-clone-from-snapshot.sh                    # k8s-archive, 1 GiB
#   ./probe-clone-from-snapshot.sh k8s-archive 1
#   FSCLONETYPE=clone ./probe-clone-from-snapshot.sh  # test the full-copy path
#   YES=1 ./probe-clone-from-snapshot.sh              # skip the confirmation
#   KEEP=1 ./probe-clone-from-snapshot.sh             # leave objects for inspection
#
# Run from a PVE node, as root (it reads /etc/pve/priv/storage/<id>.pw).
# Record the whole output: the raw bodies are the deliverable, not the verdicts.

set -uo pipefail   # deliberately NOT -e: expected failures ARE the results

STOREID="${1:-k8s-archive}"
SIZE_GIB="${2:-1}"
KEEP="${KEEP:-0}"
YES="${YES:-0}"

MAX_SIZE_GIB=8            # a probe needs 1-2 GiB; refuse a fat-finger
MIN_FREE_MULTIPLE=20      # need 20x the request free, physically
MAX_POOL_PCT=85           # IBM's own physical ceiling

SRC_VOL="vm-9999-clonep0"
DST_VOL="vm-9999-clonep1"
SRC2_VOL="vm-9999-clonep2"   # a CLEAN volume for assertion O
SNAP1="cp1"               # <= 9 chars on a 4-char fsprefix
SNAP2="cp2"

SRC_CREATED=0             # set ONLY after we observe our own creation
DST_CREATED=0
SRC2_CREATED=0
FAILED=0                  # bad()/inconc() bump this; drives the exit code

if [ -t 1 ]; then B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; Z=$'\033[0m'
else B=''; R=''; G=''; Y=''; Z=''; fi
step()   { printf '\n%s== %s%s\n' "$B" "$*" "$Z"; }
say()    { printf '    %s\n' "$*"; }
good()   { printf '%s  OK  %s%s\n' "$G" "$*" "$Z"; }
bad()    { printf '%s  NO  %s%s\n' "$R" "$*" "$Z"; FAILED=$((FAILED+1)); }
inconc() { printf '%s  ??  INCONCLUSIVE: %s%s\n' "$Y" "$*" "$Z"; FAILED=$((FAILED+1)); }
die()    { printf '%s  NO  %s%s\n' "$R" "$*" "$Z"; exit 1; }

[ "$(id -u)" = 0 ]          || die "must run as root (reads /etc/pve/priv/storage/*.pw)"
command -v pvesm >/dev/null || die "pvesm not found — run this on a PVE node"
command -v curl  >/dev/null || die "curl not found"
command -v perl  >/dev/null || die "perl not found"
perl -MJSON::PP -e1 2>/dev/null || die "perl JSON::PP not available"

# ── storage config, straight from storage.cfg ─────────────────────────────
cfg() {
    awk -v id="$STOREID" '
        /^[a-z]+: /      { inblk = ($2 == id); next }
        inblk && NF >= 2 { print $1, $2 }
    ' /etc/pve/storage.cfg | awk -v k="$1" '$1 == k { print $2 }'
}
ADDR="$(cfg fsaddress)"; USER="$(cfg fsuser)"; POOL="$(cfg fspool)"
PREFIX="$(cfg fsprefix)"; IOGRP="$(cfg fsiogrp)"; SNAPS_ON="$(cfg fssnapshots)"
CLONETYPE="${FSCLONETYPE:-$(cfg fsclonetype)}"
[ -n "$IOGRP" ]     || IOGRP=io_grp0
[ -n "$CLONETYPE" ] || CLONETYPE=thinclone

[ -n "$ADDR" ] || die "storage '$STOREID' is not a flashsystem storage in /etc/pve/storage.cfg"
[ "$SNAPS_ON" = 1 ] || die "storage '$STOREID' does not have fssnapshots 1. This probe creates
      snapshots, and cleanup relies on the plugin agreeing they can exist.
      Enable it first:  pvesm set $STOREID --fssnapshots 1"
case "$CLONETYPE" in thinclone|clone) ;; *) die "fsclonetype must be thinclone or clone, got '$CLONETYPE'";; esac
case "$SIZE_GIB" in ''|*[!0-9]*) die "size must be an integer number of GiB";; esac
[ "$SIZE_GIB" -ge 1 ] && [ "$SIZE_GIB" -le "$MAX_SIZE_GIB" ] \
    || die "size ${SIZE_GIB}G is outside 1-${MAX_SIZE_GIB}G. A probe does not need a big volume."

PW_FILE="/etc/pve/priv/storage/${STOREID}.pw"
[ -f "$PW_FILE" ] || die "no password file at $PW_FILE"
PW="$(head -n1 "$PW_FILE")"

SRC_ANAME="${PREFIX:+${PREFIX}-}${SRC_VOL}"
DST_ANAME="${PREFIX:+${PREFIX}-}${DST_VOL}"
SRC2_ANAME="${PREFIX:+${PREFIX}-}${SRC2_VOL}"

step "Target"
say "storage    $STOREID  on $ADDR   pool $POOL   prefix ${PREFIX:-<NONE>}"
say "scratch    $SRC_ANAME  (${SIZE_GIB} GiB)"
say "clone      $DST_ANAME  -type $CLONETYPE  -iogrp $IOGRP"
say "budget     array name is ${#SRC_ANAME} chars; a snapshot name gets $((63 - ${#SRC_ANAME} - 1))"
[ -n "$PREFIX" ] || say "${Y}NOTE: fsprefix is empty, so array names are unnamespaced.${Z}"

# ── JSON helpers (perl JSON::PP, not sed) ─────────────────────────────────
# j_field <key>            : top-level field, from an object or a 1-elem array
# j_count                  : number of records
# j_snap <sname> <vname> <field>
#     the ONE field of the ONE record whose snapshot_name AND volume_name both
#     match exactly. Prints nothing if zero or more than one record matches.
#     This is the only way a snapshot id is ever obtained here.
# NB: these read STDIN explicitly rather than using perl's -n loop. Under -n,
# @ARGV is the list of INPUT FILES, so passing the key as an argument makes
# perl try to open it and every helper silently returns empty.
j_field() {
    perl -MJSON::PP -e '
        my ($k) = @ARGV;
        local $/; my $in = <STDIN>;
        my $d = eval { decode_json($in) } or exit 0;
        $d = $d->[0] if ref $d eq "ARRAY" && @$d == 1;
        exit 0 if ref $d ne "HASH";
        my $v = $d->{$k};
        print $v if defined $v && !ref $v;
    ' -- "$1"
}
j_count() {
    perl -MJSON::PP -e '
        local $/; my $in = <STDIN>;
        my $d = eval { decode_json($in) } or do { print 0; exit 0 };
        print ref $d eq "ARRAY" ? scalar @$d : 1;
    '
}
# The ONE record whose snapshot_name AND volume_name both match exactly.
# Prints nothing if zero, or more than one, record matches — an ambiguous
# match must never yield an id that reaches a destructive call.
j_snap() {
    perl -MJSON::PP -e '
        my ($sn, $vn, $f) = @ARGV;
        local $/; my $in = <STDIN>;
        my $d = eval { decode_json($in) } or exit 0;
        $d = [ $d ] if ref $d eq "HASH";
        exit 0 if ref $d ne "ARRAY";
        my @m = grep {
            ref $_ eq "HASH"
            && defined $_->{snapshot_name} && $_->{snapshot_name} eq $sn
            && defined $_->{volume_name}   && $_->{volume_name}   eq $vn
        } @$d;
        exit 0 if @m != 1;
        my $v = $m[0]{$f};
        print $v if defined $v && !ref $v;
    ' -- "$1" "$2" "$3"
}
# The one lsvolumepopulation record for a given volume, as compact JSON.
pop_for() {
    perl -MJSON::PP -e '
        my ($v) = @ARGV;
        local $/; my $in = <STDIN>;
        my $d = eval { decode_json($in) } // []; $d = [ $d ] if ref $d eq "HASH";
        return if ref $d ne "ARRAY";
        for my $r (@$d) {
            next if ref $r ne "HASH";
            next unless ($r->{volume_name} // "") eq $v;
            print encode_json($r); last;
        }
    ' -- "$1"
}

# Pretty-print every record whose snapshot_name starts "<aname>." — raw, for
# the operator to paste into UPSTREAM.md.
j_rows_for() {
    perl -MJSON::PP -e '
        my ($aname) = @ARGV;
        local $/; my $in = <STDIN>;
        my $d = eval { decode_json($in) } // []; $d = [ $d ] if ref $d eq "HASH";
        return if ref $d ne "ARRAY";
        for my $r (@$d) {
            next if ref $r ne "HASH";
            next unless ($r->{snapshot_name} // "") =~ /^\Q$aname\E\./;
            print "      ", encode_json($r), "\n";
        }
    ' -- "$1"
}

# ── REST transport ─────────────────────────────────────────────────────────
TOKEN=""
# HTTP status of the last fs() call.
#
# This CANNOT be a plain variable. Every call site wraps fs() in $(...) or a
# pipeline, and both are subshells — so an assignment inside fs() is discarded
# when that subshell exits and the parent's copy stays empty for the whole run.
# That made fs_ok() always false and killed the probe at step 0 against a
# perfectly healthy array, printing "lsmdiskgrp failed (HTTP )" next to the
# successful body. The status therefore crosses the subshell boundary through
# the filesystem, and is read with fs_http() rather than expanded directly.
FS_HTTP_FILE="$(umask 077; mktemp "${TMPDIR:-/tmp}/fsprobe-http.XXXXXX")" \
    || { echo "cannot create a temp file for the HTTP status" >&2; exit 1; }
# Superseded by `trap cleanup EXIT` once cleanup() is defined; until then this
# is what removes the file when a pre-flight check dies.
trap 'rm -f "$FS_HTTP_FILE"' EXIT
fs_http() { cat "$FS_HTTP_FILE" 2>/dev/null || printf '000'; }
# Returns non-zero rather than dying, so cleanup's `|| true` actually works.
# The password goes in via `curl -K -` (config on stdin), NOT as -H on the
# command line: an argv header puts the array's password in /proc/<pid>/cmdline
# and in `ps` output for the life of the request, readable by any local user.
auth() {
    local body
    body="$(printf 'header = "X-Auth-Username: %s"\nheader = "X-Auth-Password: %s"\n' \
        "$USER" "$PW" \
      | curl -sk --connect-timeout 10 --max-time 30 -K - \
        -X POST "https://${ADDR}:7443/rest/v1/auth")" || return 1
    TOKEN="$(printf '%s' "$body" | j_field token)"
    [ -n "$TOKEN" ]
}
# fs <command> [<target>] [<json body>] — prints the RAW body, and records
# the HTTP status where fs_http()/fs_ok() can read it (see FS_HTTP_FILE).
fs() {
    local cmd="$1" target="${2-}" body="${3-}"
    [ -n "$body" ] || body='{}'
    local url="https://${ADDR}:7443/rest/v1/${cmd}"
    [ -n "$target" ] && url="${url}/${target}"
    local out
    out="$(curl -sk --connect-timeout 10 --max-time 120 -w $'\n%{http_code}' \
        -X POST "$url" -H "X-Auth-Token: ${TOKEN}" \
        -H 'Content-Type: application/json' -H 'Accept: application/json' \
        -d "$body")" || { printf '000' >"$FS_HTTP_FILE"; return 0; }
    printf '%s' "${out##*$'\n'}" >"$FS_HTTP_FILE"
    printf '%s' "${out%$'\n'*}"
}
fs_ok()   { case "$(fs_http)" in 2*) return 0;; *) return 1;; esac; }
has_cmmvc() { grep -qi 'CMMVC' <<<"${1-}"; }

# Resolve a snapshot id STRICTLY, from a fresh listing. Never from a response
# body: a create response's `id` is not guaranteed to be the snapshot's, and
# this value is passed to rmsnapshot and restorefromsnapshot.
snap_id_of() {           # <volume aname> <snapshot name>
    local vname="$1" sname="$2" lsv id
    lsv="$(fs lsvolumesnapshot)"
    fs_ok || return 1
    id="$(printf '%s' "$lsv" | j_snap "$sname" "$vname" snapshot_id)"
    [ -n "$id" ] || return 1
    printf '%s' "$id"
}
snap_id()    { snap_id_of "$SRC_ANAME" "$1"; }
snap_field() { fs lsvolumesnapshot | j_snap "$1" "$SRC_ANAME" "$2"; }
vol_exists() {   # 0 = exists, 1 = absent, 2 = cannot tell
    local j; j="$(fs lsvdisk "$1" '{"bytes":true}')"
    if fs_ok; then [ -n "$(printf '%s' "$j" | j_field name)" ] && return 0 || return 1; fi
    has_cmmvc "$j" && return 1
    return 2
}

auth || die "auth failed against ${ADDR}:7443 as ${USER}"
good "authenticated"

# ── pre-flight, failing CLOSED ────────────────────────────────────────────
for n in "$SRC_ANAME" "$DST_ANAME" "$SRC2_ANAME"; do
    vol_exists "$n"; rc=$?
    [ "$rc" = 0 ] && die "array object '$n' already exists. Remove it, or edit SRC_VOL/DST_VOL."
    [ "$rc" = 2 ] && die "cannot determine whether '$n' exists (HTTP $(fs_http)). Refusing to guess."
done
good "neither scratch name exists"

# ── cleanup: deletes ONLY what we recorded creating ───────────────────────
cleanup() {
    local rc=$?
    if [ "$KEEP" = 1 ]; then
        step "Cleanup skipped (KEEP=1)"
        [ "$DST_CREATED" = 1 ] && say "created, still present: $DST_ANAME"
        [ "$SRC_CREATED" = 1 ] && say "created, still present: ${STOREID}:${SRC_VOL}"
        rm -f "$FS_HTTP_FILE"; exit "$rc"
    fi
    step "Cleanup"
    if ! auth; then
        bad "cannot re-authenticate to clean up. ORPHANED OBJECTS, remove by hand:"
        [ "$DST_CREATED" = 1 ] && say "  array volume  $DST_ANAME"
        [ "$SRC_CREATED" = 1 ] && say "  pvesm free ${STOREID}:${SRC_VOL}   (and its snapshots)"
        rm -f "$FS_HTTP_FILE"; exit "$rc"
    fi
    # Clone first: a thinclone pins its snapshot.
    if [ "$DST_CREATED" = 1 ]; then
        say "rmvolume $DST_ANAME -> $(fs rmvolume "$DST_ANAME" '{"removehostmappings":true}') [$(fs_http)]"
        if vol_exists "$DST_ANAME"; then
            say "rmvdisk  $DST_ANAME -> $(fs rmvdisk "$DST_ANAME" '{"force":true}') [$(fs_http)]"
        fi
    fi
    # Our two snapshots, by exact name + volume_name. Never a substring sweep.
    if [ "$SRC_CREATED" = 1 ]; then
        for s in "$SNAP1" "$SNAP2"; do
            local id; id="$(snap_id "${SRC_ANAME}.${s}")" || continue
            say "rmsnapshot ${SRC_ANAME}.${s} (id $id) -> $(fs rmsnapshot '' "{\"snapshotid\":\"${id}\"}") [$(fs_http)]"
        done
        say "pvesm free ${STOREID}:${SRC_VOL}"
        pvesm free "${STOREID}:${SRC_VOL}" 2>&1 | sed 's/^/      /'
        if vol_exists "$SRC_ANAME"; then
            say "still present, forcing: $(fs rmvdisk "$SRC_ANAME" '{"force":true}') [$(fs_http)]"
        fi
    fi
    if [ "$SRC2_CREATED" = 1 ]; then
        local id2; id2="$(snap_id_of "$SRC2_ANAME" "${SRC2_ANAME}.${SNAP1}")" || id2=""
        [ -n "$id2" ] && say "rmsnapshot ${SRC2_ANAME}.${SNAP1} -> $(fs rmsnapshot '' "{\"snapshotid\":\"${id2}\"}") [$(fs_http)]"
        say "pvesm free ${STOREID}:${SRC2_VOL}"
        pvesm free "${STOREID}:${SRC2_VOL}" 2>&1 | sed 's/^/      /'
        if vol_exists "$SRC2_ANAME"; then
            say "still present, forcing: $(fs rmvdisk "$SRC2_ANAME" '{"force":true}') [$(fs_http)]"
        fi
    fi
    say "done"
    rm -f "$FS_HTTP_FILE"; exit "$rc"
}
# EXIT only. `trap cleanup EXIT INT TERM` runs cleanup TWICE on Ctrl-C,
# because the INT handler's exit re-fires EXIT.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# ══════════════════════════════════════════════════════════════════════════
step "A. The not-found contract the plugin now depends on"
# csi_volume_from_snapshot asks the array whether the CALLER'S chosen volume
# name is already taken, before mkvolume. Storage Virtualize answers a missing
# object with an ERROR STATUS carrying CMMVC5754E, not an empty 2xx body - and
# an earlier cut of the plugin treated every non-2xx as "cannot verify" and
# aborted. That refused every restore into a fresh name, which is what
# Kubernetes always does: K10 mints the PV name before it asks for the clone.
#
# So pin the contract here rather than assuming it. If a future firmware
# answers differently, this assertion is what tells you before a restore does.
NOPE="${SRC_ANAME}-does-not-exist"
NF="$(fs lsvdisk "$NOPE" '{"bytes":true}')"
NF_H="$(fs_http)"
say "lsvdisk <absent>   [HTTP $NF_H]"
say "raw: $NF"
if fs_ok; then
    inconc "A  lsvdisk on a missing object returned 2xx - the plugin expects a"
    inconc "   non-2xx with CMMVC5754E. Check csi_volume_from_snapshot's"
    inconc "   existence check still reads this correctly."
elif printf '%s' "$NF" | grep -q 'CMMVC5754E'; then
    good "A  absent object -> HTTP $NF_H + CMMVC5754E, as the plugin expects"
else
    bad "A  absent object -> HTTP $NF_H but NO CMMVC5754E. The plugin treats"
    bad "   only CMMVC5754E (and its own 'not found') as absence and fails"
    bad "   CLOSED otherwise, so every restore into a fresh name will refuse."
fi

step "0. Baseline — pool state, and the capacity guard"
BASE="$(fs lsmdiskgrp "$POOL" '{"bytes":true}')"
fs_ok || die "lsmdiskgrp failed (HTTP $(fs_http)): $BASE"
DRP="$(printf '%s' "$BASE" | j_field data_reduction)"
PCAP="$(printf '%s' "$BASE" | j_field physical_capacity)"
PFREE="$(printf '%s' "$BASE" | j_field physical_free_capacity)"
say "data_reduction     ${DRP:-<absent>}"
say "warning threshold  $(printf '%s' "$BASE" | j_field warning)"
say "physical_capacity  ${PCAP:-<absent>}"
say "physical_free      ${PFREE:-<absent>}"
say "raw: $BASE"

if [ "$DRP" = yes ]; then good "this IS a data reduction pool — assertion F is live"
else inconc "F: '$POOL' is not a DRP (data_reduction=${DRP:-absent}), so F is untested here"; fi

NEED=$(( SIZE_GIB * MIN_FREE_MULTIPLE ))
if [ -n "$PFREE" ] && [ -n "$PCAP" ] && [ "$PCAP" -gt 0 ] 2>/dev/null; then
    FREE_GIB=$(( PFREE / 1073741824 ))
    USED_PCT=$(( (PCAP - PFREE) * 100 / PCAP ))
    say "physical used      ${USED_PCT}%   free ${FREE_GIB} GiB"
    [ "$USED_PCT" -le "$MAX_POOL_PCT" ] \
        || die "pool is ${USED_PCT}% physical (ceiling ${MAX_POOL_PCT}%). Pick a slacker tier."
    [ "$FREE_GIB" -ge "$NEED" ] \
        || die "only ${FREE_GIB} GiB physically free; want ${NEED} GiB for a ${SIZE_GIB} GiB probe."
    good "capacity guard passed"
else
    inconc "pool did not report physical capacity; capacity guard skipped"
fi

if [ "$YES" != 1 ]; then
    printf '\n%sAbout to create %s (%s GiB) and a %s in %s. Continue? [y/N] %s' \
        "$B" "$SRC_ANAME" "$SIZE_GIB" "$CLONETYPE" "$POOL" "$Z"
    read -r ans || ans=n
    case "$ans" in y|Y|yes|YES) ;; *) echo "aborted"; exit 1;; esac
fi

step "1. Allocate the scratch volume through PVE (exercises alloc_image)"
if ! pvesm alloc "$STOREID" 9999 "$SRC_VOL" "${SIZE_GIB}G" 2>&1 | sed 's/^/    /'; then
    die "pvesm alloc failed — nothing was created"
fi
vol_exists "$SRC_ANAME" || die "pvesm alloc reported success but '$SRC_ANAME' is not on the array"
SRC_CREATED=1
SRCJ="$(fs lsvdisk "$SRC_ANAME" '{"bytes":true}')"
SRC_ID="$(printf '%s' "$SRCJ" | j_field id)"
SRC_UID_BEFORE="$(printf '%s' "$SRCJ" | j_field vdisk_UID)"
[ -n "$SRC_ID" ] || die "no vdisk id for '$SRC_ANAME'"
say "vdisk id     $SRC_ID"
say "vdisk_UID    $SRC_UID_BEFORE"
say "capacity     $(printf '%s' "$SRCJ" | j_field capacity)"
good "scratch volume created"

step "2. addsnapshot  (Q: does the response carry the new id?)"
ADD="$(fs addsnapshot '' "{\"name\":\"${SRC_ANAME}.${SNAP1}\",\"volumes\":\"${SRC_ID}\"}")"
say "raw: $ADD   [HTTP $(fs_http)]"
fs_ok || die "addsnapshot failed: $ADD"
ADD_ID="$(printf '%s' "$ADD" | j_field id)"
SNAP_ID="$(snap_id "${SRC_ANAME}.${SNAP1}")" \
    || die "snapshot ${SRC_ANAME}.${SNAP1} not resolvable by name+volume_name after addsnapshot"
say "resolved id  $SNAP_ID  (from lsvolumesnapshot, name+volume_name)"
if [ -n "$ADD_ID" ] && [ "$ADD_ID" = "$SNAP_ID" ]; then
    good "Q  addsnapshot's response id ($ADD_ID) IS the snapshot id — the plugin's scan is avoidable"
elif [ -n "$ADD_ID" ]; then
    bad "Q  addsnapshot returned id=$ADD_ID but the snapshot is $SNAP_ID — do NOT trust the body"
else
    say "Q  no id in the response body; the name scan is required"
fi
say "snapshot state: $(snap_field "${SRC_ANAME}.${SNAP1}" state)"
say "size mismatch : $(snap_field "${SRC_ANAME}.${SNAP1}" volume_size_mismatch)"
say "raw row:"
fs lsvolumesnapshot | j_rows_for "$SRC_ANAME"
say "(volume_size_mismatch above decides whether volume_rollback_is_possible can work"
say " off the unfiltered listing, or whether the field is detailed-view only.)"

step "2b. P — is -filtervalue honoured, or accepted and ignored?"
ALL_N="$(fs lsvolumesnapshot | j_count)"
FILT="$(fs lsvolumesnapshot '' "{\"filtervalue\":\"volume_name=${SRC_ANAME}\"}")"
FILT_H="$(fs_http)"; FILT_N="$(printf '%s' "$FILT" | j_count)"
say "unfiltered rows: $ALL_N     filtered rows: $FILT_N   [HTTP $FILT_H]"
if ! fs_ok; then
    good "P  -filtervalue is REJECTED (HTTP $FILT_H) — client-side scoping is required"
elif [ "$ALL_N" -gt 1 ] && [ "$FILT_N" -lt "$ALL_N" ]; then
    good "P  -filtervalue is HONOURED — _snapshots_for could bound its listing"
elif [ "$ALL_N" -le 1 ]; then
    inconc "P  only $ALL_N snapshot(s) on the array, so a filter cannot be seen to narrow anything"
else
    bad "P  -filtervalue accepted but returned all $ALL_N rows — SILENTLY IGNORED."
    say "    Never pass it: a filter that no-ops looks exactly like one that worked."
fi

step "3. THE KILL SHOT — mkvolume -type $CLONETYPE from that snapshot"
MKBODY="{\"type\":\"${CLONETYPE}\",\"pool\":\"${POOL}\",\"fromsourcevolume\":\"${SRC_ANAME}\",\"fromsnapshotid\":\"${SNAP_ID}\",\"name\":\"${DST_ANAME}\",\"iogrp\":\"${IOGRP}\"}"
say "body: $MKBODY"
MKV="$(fs mkvolume '' "$MKBODY")"
MKV_H="$(fs_http)"
say "raw: $MKV   [HTTP $MKV_H]"

if vol_exists "$DST_ANAME"; then
    DST_CREATED=1
    DSTJ="$(fs lsvdisk "$DST_ANAME" '{"bytes":true}')"
    good "D  mkvolume IS reachable over REST v1"
    good "E  the snapshot-source form works on a LOOSE volume (no volume group)"
    [ "$DRP" = yes ] && good "F  accepted in a data reduction pool"
    good "G  -name named the VOLUME: $(printf '%s' "$DSTJ" | j_field name)"
    say "new vdisk id    $(printf '%s' "$DSTJ" | j_field id)"
    say "new vdisk_UID   $(printf '%s' "$DSTJ" | j_field vdisk_UID)"
    say "capacity        $(printf '%s' "$DSTJ" | j_field capacity)"
    MG="$(printf '%s' "$DSTJ" | j_field mdisk_grp_name)"
    say "mdisk_grp_name  $MG"
    if [ "$MG" = many ]; then
        bad "the clone is MIRRORED (mdisk_grp_name=many). list_images filters server-side on"
        say "    that field, so a mirrored clone is INVISIBLE to PVE. Pin a single pool."
    elif [ "$MG" != "$POOL" ]; then
        bad "the clone landed in '$MG', not the requested '$POOL'"
    fi

    step "3b. Visibility — does PVE see it with nothing to update?"
    if pvesm list "$STOREID" | grep -q "$DST_VOL"; then
        good "list_images surfaced it: $(pvesm list "$STOREID" | grep "$DST_VOL")"
    else
        bad "NOT visible in 'pvesm list $STOREID' — check the volname grammar and fsprefix"
    fi

    step "3c. H — population type and rate"
    # NB lsvolumepopulation's positional argument is a population_mapping_id,
    # NOT a volume name — putting the volume in the URL path returns an error
    # or an empty body, which reads identically to "no population in
    # progress". Call it bare and filter client-side.
    POPJ="$(fs lsvolumepopulation '' '{"bytes":true}')"
    say "raw (all mappings): $POPJ   [HTTP $(fs_http)]"
    if fs_ok; then
        POPROW="$(printf '%s' "$POPJ" | pop_for "$DST_ANAME")"
        if [ -n "$POPROW" ]; then
            say "row: $POPROW"
            for k in volume_name volume_type source_snapshot data_to_move rate estimated_completion_time; do
                say "$(printf '%-26s' "$k") $(printf '%s' "$POPROW" | j_field "$k")"
            done
            good "H  population reported above"
            say "    IBM's default copy rate is 2 MB/s — for -type clone, hours per 100 GiB."
        else
            good "H  no population mapping for '$DST_ANAME' — consistent with an instant thinclone"
            say "    (For -type clone this would instead mean the copy already finished.)"
        fi
    else
        inconc "H  lsvolumepopulation not answerable (HTTP $(fs_http))"
    fi
else
    bad "D/E/F/G  mkvolume did NOT produce '$DST_ANAME' (HTTP $MKV_H)"
    say "    The raw response above is the answer. Read the CMMVC code and decide which of:"
    say "      D  unreachable over REST v1              -> drive the CLI over SSH instead"
    say "      E  loose volumes refused                 -> the plugin must own volume groups"
    say "      F  the DRP refuses this parameter set    -> compare against a standard pool"
    say "      G  -name named a group, not a volume     -> a chvdisk -name follow-up is needed"
    say "    Steps 4-6 still run: they answer questions free_image and rollback need regardless."
fi

step "4. K/L — rmsnapshot while the clone may still depend on it"
BEFORE_STATE="$(snap_field "${SRC_ANAME}.${SNAP1}" state)"
say "state before: ${BEFORE_STATE:-<absent>}"
RMS="$(fs rmsnapshot '' "{\"snapshotid\":\"${SNAP_ID}\"}")"
RMS_H="$(fs_http)"
say "raw: $RMS   [HTTP $RMS_H]"
# Branch on the RESPONSE first — refused vs accepted — and only then on
# visibility. Absence of a CMMVC code is not evidence of success.
if ! fs_ok || has_cmmvc "$RMS"; then
    if [ "$DST_CREATED" = 1 ]; then
        good "K  rmsnapshot REFUSED while a $CLONETYPE depends on the snapshot"
        say "    So a CSI DeleteSnapshot must return FailedPrecondition, and free_image's"
        say "    delete-then-reap ordering is the right shape."
    else
        bad "K  rmsnapshot refused even though no clone exists (HTTP $RMS_H) — unrelated failure"
    fi
else
    AFTER_STATE="$(snap_field "${SRC_ANAME}.${SNAP1}" state)"
    if [ -n "$AFTER_STATE" ]; then
        good "K  rmsnapshot ACCEPTED and DEFERRED — state is now '$AFTER_STATE'"
        good "L  a deferred snapshot IS visible to a plain lsvolumesnapshot"
        say "    So the plugin's 'no id found -> already gone -> idempotent' stays honest."
    elif [ "$DST_CREATED" = 1 ]; then
        bad "L  the snapshot VANISHED from a plain lsvolumesnapshot while a $CLONETYPE still"
        say "    depends on it. If the array merely deferred it, every delete reports success"
        say "    while physical capacity is never freed. Cross-check with -showhidden:"
        fs lsvolumesnapshot '' '{"showhidden":true}' | j_rows_for "$SRC_ANAME"
    else
        good "K/L  rmsnapshot succeeded and the snapshot is gone (no clone depended on it)"
    fi
fi

# Remove the clone BEFORE step 6, so O is measured on a volume whose only
# remaining dependency is its own snapshot — which is exactly what free_image
# faces. Leaving it alive would also make step 6 delete a thinclone's parent.
if [ "$DST_CREATED" = 1 ]; then
    step "5a. R — delete the clone with the call free_image actually makes"
    # free_image issues a BARE rmvdisk (no -force). Whether that works on a
    # thinclone is a production question the probe must answer, so try it
    # first and report it, THEN fall back to whatever tears the object down.
    RMC="$(fs rmvdisk "$DST_ANAME" '{}')"
    RMC_H="$(fs_http)"
    say "rmvdisk (bare) -> $RMC  [HTTP $RMC_H]"
    if vol_exists "$DST_ANAME"; then
        bad "R  a bare rmvdisk does NOT delete a $CLONETYPE."
        say "    free_image will therefore fail on any restored volume. It needs rmvolume,"
        say "    or -force, or the dependency cleared first. Decide before shipping."
        say "rmvolume -> $(fs rmvolume "$DST_ANAME" '{"removehostmappings":true}')  [$(fs_http)]"
        if vol_exists "$DST_ANAME"; then
            say "rmvdisk -force -> $(fs rmvdisk "$DST_ANAME" '{"force":true}')  [$(fs_http)]"
        fi
    else
        good "R  a bare rmvdisk deletes a $CLONETYPE — free_image needs no change for clones"
    fi
    if vol_exists "$DST_ANAME"; then
        bad "the clone could not be removed; skipping O to avoid a confounded result"
        SKIP_O=1
    else
        good "clone removed"
        DST_CREATED=0
    fi
fi

step "5b. M/N — restorefromsnapshot on a loose volume, and the vdisk_UID"
ADD2="$(fs addsnapshot '' "{\"name\":\"${SRC_ANAME}.${SNAP2}\",\"volumes\":\"${SRC_ID}\"}")"
say "raw: $ADD2   [HTTP $(fs_http)]"
SNAP2_ID="$(snap_id "${SRC_ANAME}.${SNAP2}")" || SNAP2_ID=""
if [ -z "$SNAP2_ID" ]; then
    inconc "M/N  could not create or resolve a second snapshot; restore untested"
else
    say "snapshot id  $SNAP2_ID"
    RES="$(fs restorefromsnapshot '' "{\"snapshotid\":\"${SNAP2_ID}\",\"volumes\":\"${SRC_ID}\"}")"
    RES_H="$(fs_http)"
    say "raw: $RES   [HTTP $RES_H]"
    if ! fs_ok || has_cmmvc "$RES"; then
        bad "M  restorefromsnapshot REFUSED on a loose volume (HTTP $RES_H)"
        say "    In-place rollback is then unavailable for loose volumes, and"
        say "    volume_snapshot_rollback needs a volume group. Read the CMMVC code."
        inconc "N  not evaluated: the restore did not run"
    else
        good "M  restorefromsnapshot accepted on a loose volume"
        # Poll to completion. A single sample 5s in would call an asynchronous
        # identity swap "preserved" and be exactly wrong.
        DONE=0
        for i in $(seq 1 60); do
            PJ="$(fs lsvolumepopulation '' '{"bytes":true}')"
            PROW="$(printf '%s' "$PJ" | pop_for "$SRC_ANAME")"
            if ! fs_ok || [ -z "$PROW" ]; then
                DONE=1; break        # no population mapping = nothing in flight
            fi
            say "  t+$((i*5))s  type=$(printf '%s' "$PROW" | j_field volume_type)" \
                "to_move=$(printf '%s' "$PROW" | j_field data_to_move)"
            sleep 5
        done
        SRC_UID_AFTER="$(fs lsvdisk "$SRC_ANAME" '{"bytes":true}' | j_field vdisk_UID)"
        say "vdisk_UID before  $SRC_UID_BEFORE"
        say "vdisk_UID after   $SRC_UID_AFTER"
        if [ "$DONE" != 1 ]; then
            inconc "N  restore still in flight after 300s — UID comparison is not yet meaningful"
            say "    Re-read lsvdisk once lsvolumepopulation is empty, then compare."
        elif [ -z "$SRC_UID_AFTER" ]; then
            inconc "N  could not read vdisk_UID after the restore"
        elif [ "$SRC_UID_BEFORE" = "$SRC_UID_AFTER" ]; then
            good "N  vdisk_UID is PRESERVED across a completed in-place restore"
            say "    So /dev/mapper/3<uid> stays valid, and the _rescan_scsi comment"
            say "    ('a volume whose vdisk_UID differs after a rollback') is wrong for this"
            say "    firmware. Correct that comment and cite this run."
        else
            bad "N  vdisk_UID CHANGED across an in-place restore"
            say "    Every attached host's /dev/mapper entry is now stale, and the failure"
            say "    mode is a node-wide LVM hang under queue_if_no_path, not an error."
            say "    In-place rollback MUST detach every host first. Do not automate it."
        fi
    fi
fi

step "6. O — rmvdisk on a volume whose ONLY encumbrance is one snapshot"
# Deliberately a FRESH volume. Measuring O on SRC would be confounded: by now
# SRC carries SNAP1 (deleted in step 4, possibly only deferred into
# dependent_deleting) and SNAP2 (used for the restore in 5b), so a refusal
# could not be attributed to "has a snapshot". free_image faces the simple
# case, so test the simple case.
if ! pvesm alloc "$STOREID" 9999 "$SRC2_VOL" "${SIZE_GIB}G" 2>&1 | sed 's/^/    /'; then
    inconc "O  could not allocate a clean scratch volume"
elif ! vol_exists "$SRC2_ANAME"; then
    inconc "O  pvesm alloc reported success but '$SRC2_ANAME' is absent"
else
    SRC2_CREATED=1
    SRC2_ID="$(fs lsvdisk "$SRC2_ANAME" '{"bytes":true}' | j_field id)"
    A3="$(fs addsnapshot '' "{\"name\":\"${SRC2_ANAME}.${SNAP1}\",\"volumes\":\"${SRC2_ID}\"}")"
    say "addsnapshot -> $A3  [HTTP $(fs_http)]"
    S3="$(snap_id_of "$SRC2_ANAME" "${SRC2_ANAME}.${SNAP1}")" || S3=""
    if [ -z "$S3" ]; then
        inconc "O  could not create/resolve a snapshot on the clean volume"
    else
        say "snapshot present: ${SRC2_ANAME}.${SNAP1} (id $S3)"
        say "This is exactly what 'pvesm free' and a CSI DeleteVolume reach."
        RMV="$(fs rmvdisk "$SRC2_ANAME" '{}')"
        RMV_H="$(fs_http)"
        say "raw: $RMV   [HTTP $RMV_H]"
        vol_exists "$SRC2_ANAME"; ex=$?
        if [ "$ex" = 0 ]; then
            good "O  rmvdisk was REFUSED while a snapshot exists (the safe direction)"
            say "    So free_image must clear the volume's own snapshots and retry — which is"
            say "    what it now does. A stuck delete, not silent destruction."
        elif [ "$ex" = 1 ] && fs_ok; then
            bad "O  rmvdisk SUCCEEDED with a snapshot present and no -force."
            say "    Deleting a PVC therefore destroys its snapshots silently. Consider"
            say "    reclaimPolicy: Retain on the Kubernetes tiers; free_image's reap becomes"
            say "    unnecessary but harmless."
            SRC2_CREATED=0    # gone; do not try to free it again
        else
            inconc "O  cannot determine the outcome (HTTP $RMV_H / exists=$ex)"
        fi
    fi
fi

step "Summary"
say "The raw bodies above are the deliverable — paste them into UPSTREAM.md."
say
say "Not covered here, because it needs a scratch VM rather than only the array:"
say "  I  does activate_volume attach the clone? (there is a SECOND snapshot"
say "     refusal in activate_volume, not only in path())"
say "  J  does a -type clone read correctly BEFORE its population completes?"
say
say "Both, once this passes, with a diskless scratch VM — note --full 0 is"
say "REQUIRED, since a full clone never calls the plugin's clone hook:"
say "  qm create 9998 --name clone-probe --memory 512"
say "  pvesm alloc $STOREID 9998 vm-9998-cp0 ${SIZE_GIB}G"
say "  qm set 9998 --scsi1 ${STOREID}:vm-9998-cp0     # triggers activate_volume"
say "  dd if=/dev/urandom of=\$(pvesm path ${STOREID}:vm-9998-cp0) bs=1M count=64 oflag=direct"
say "  qm snapshot 9998 s1"
say "  qm clone 9998 9997 --snapshot s1 --full 0      # <- clone_image, end to end"
say "  # then read the pattern back from the clone and compare"

if [ "$FAILED" -gt 0 ]; then
    printf '\n%s%s assertion(s) failed or were inconclusive — this is NOT a pass.%s\n' "$R" "$FAILED" "$Z"
    exit 1
fi
printf '\n%sAll assertions answered affirmatively.%s\n' "$G" "$Z"
