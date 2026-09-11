/*
FlashSystem snapshot backend for proxmox-csi-plugin.

WHY THIS FILE EXISTS

Upstream proxmox-csi-plugin refuses CSI snapshots when the Proxmox storage
carries shared == 1 (pkg/csi/controller.go, added in PR #590 and first shipped
in v0.19.1). The guard is not careless: what the driver calls a snapshot is a
full volume copy through PVE's /nodes/{node}/storage/{storage}/content/{volume}
endpoint, which PVE's own source labels "experimental code - do not use", and
PVE::Storage::storage_migrate returns the SOURCE volid unchanged for
same-storage shared volumes. So on shared storage that path creates nothing and
reports success. Removing the guard does not buy slow copies; it buys a no-op.

Meanwhile the array underneath can snapshot properly - instantly, space
efficiently - and the Proxmox storage plugin already drives that. It was simply
unreachable from Kubernetes, because Proxmox exposes no per-volume snapshot
verb: every snapshot endpoint PVE offers is VM-scoped with no disk selector, so
a snapshot of the CSI holder VM would capture every PVC parked on it.

This backend closes the gap by calling four endpoints the FlashSystem storage
plugin adds to the PVE API tree, under /nodes/{node}/flashsystem/{storage}/.

THE PART THAT MATTERS MOST: no array credentials in Kubernetes.

The array password and the storage's fsprefix both stay on the Proxmox side.
This driver authenticates with the SAME Proxmox token it already uses to
provision and attach, and a PVE token is scopeable by ACL to /storage/<id> -
which a Storage Virtualize role cannot be, because ownership groups inherit
from child pools and a typical deployment has none, and snapshots are not an
ownable object type at all. A leaked array credential that can snapshot can
also restorefromsnapshot, which destroys data WITHOUT deleting an object and
so trips no capacity or object-count monitoring.

THE HANDLE, AND THE SILENT-DELETE TRAP IT AVOIDS

A CSI snapshot handle here is:

    <region>//<storage>/fssnap-<array snapshot object name>

Four slash-separated fields, because volume.NewVolumeFromVolumeID splits on "/"
and requires exactly four - a bare id like "42" is rejected as InvalidArgument
at the top of both DeleteSnapshot and the CreateVolume snapshot-source path.
The zone segment is empty, matching VolumeSharedID(), because these storages
are shared.

But parsing is NOT the constraint that bites. Upstream DeleteSnapshot calls
checkVolume() and returns success when that reports NotFound, and checkVolume
resolves through the PVE content listing - which the storage plugin
deliberately never populates with snapshot objects (its volume-name grammar is
dot-free precisely so "<volume>.<snap>" cannot masquerade as a volume). A
well-formed synthetic handle therefore passes the parser and then reports every
deletion as successful having deleted nothing, leaking array capacity silently.

Hence the "fssnap-" marker and the rule that every dispatch happens BEFORE
checkVolume. The marker is the whole reason the handle is not simply the array
name.

STATUS

CreateSnapshot / DeleteSnapshot / ListSnapshots rest on array primitives that
are already in production (addsnapshot, rmsnapshot, lsvolumesnapshot).
CreateVolume-from-snapshot rests on mkvolume, which is the one command family
the storage plugin had never issued - see tools/probe-clone-from-snapshot.sh in
the plugin repository, which must pass before the restore path is trusted.
*/

package csi

import (
	"context"
	"fmt"
	"net/url"
	"strings"

	goproxmox "github.com/sergelogvinov/go-proxmox"
	volume "github.com/sergelogvinov/proxmox-csi-plugin/pkg/utils/volume"
)

const (
	// FSPluginType is the Proxmox storage plugin type this backend serves. It
	// is what the driver dispatches on: storageConfig.PluginType.
	FSPluginType = "flashsystem"

	// fsSnapMarker prefixes the disk segment of a snapshot handle. Without a
	// marker there is no way to tell a snapshot handle from a volume handle
	// before checkVolume() runs - and after it runs, it is too late: NotFound
	// has already been turned into a successful delete.
	fsSnapMarker = "fssnap-"
)

// FSSnapshot is the reply from the plugin's snapshot endpoints.
//
// size_bytes is captured by the array side at snapshot time and is immutable
// thereafter. That is deliberate and not an optimisation: lsvolumesnapshot
// carries no capacity field at all, so reading a size later would return the
// PARENT volume's CURRENT capacity - the wrong number after any expand, and
// CSI requires a restore to be at least the snapshot's size.
type FSSnapshot struct {
	SnapshotName  string `json:"snapshot_name"`
	SourceVolname string `json:"source_volname"`
	SizeBytes     int64  `json:"size_bytes"`
	Ready         int    `json:"ready"`
	State         string `json:"state"`
}

// FSDeleteResult is the reply from the snapshot delete endpoint.
//
// The plugin signals three outcomes as HTTP 200 bodies rather than as status
// codes, so this MUST be decoded: {deleted:1} is a real deletion, "absent" is
// the idempotent no-op the spec wants reported as success, and anything else
// (notably "not-ours") is a refusal that must not be read as freed capacity.
type FSDeleteResult struct {
	Deleted int    `json:"deleted"`
	Reason  string `json:"reason"`
}

// FSVolume is the reply from the volume-from-snapshot endpoint.
type FSVolume struct {
	Volname       string `json:"volname"`
	ArrayName     string `json:"array_name"`
	SizeBytes     int64  `json:"size_bytes"`
	SourceVolname string `json:"source_volname"`
	CloneType     string `json:"clone_type"`
}

// FSSnapshotHandle builds the CSI snapshot handle for an array snapshot object.
//
// The zone segment is left empty on purpose: these storages are shared, and a
// populated zone would send checkVolume down its single-node path and
// additionally require that zone to be a live cluster node.
func FSSnapshotHandle(region, storage, arraySnapName string) string {
	return fmt.Sprintf("%s//%s/%s%s", region, storage, fsSnapMarker, arraySnapName)
}

// FSArraySnapName recovers the array snapshot object name from a parsed handle,
// reporting false when the handle is not one of ours.
//
// Call this BEFORE checkVolume in every code path. That ordering is the point
// of the marker.
func FSArraySnapName(vol *volume.Volume) (string, bool) {
	disk := vol.Disk()
	if !strings.HasPrefix(disk, fsSnapMarker) {
		return "", false
	}

	name := strings.TrimPrefix(disk, fsSnapMarker)
	if name == "" {
		return "", false
	}

	return name, true
}

// fsNode picks a node to address the plugin endpoints through.
//
// The endpoints are proxyto => 'node' because the array credential is readable
// only on a node (root-only /etc/pve/priv/storage/<id>.pw). Any node carrying
// the storage will do - it is shared - so prefer the volume's own node when the
// handle names one and otherwise take the first node that reports the storage
// available.
func fsNode(ctx context.Context, cl *goproxmox.APIClient, vol *volume.Volume) (string, error) {
	if node := vol.Node(); node != "" {
		return node, nil
	}

	nodes, err := cl.GetNodesForStorage(ctx, vol.Storage())
	if err != nil {
		return "", fmt.Errorf("failed to list nodes for storage %s: %w", vol.Storage(), err)
	}

	if len(nodes) == 0 {
		return "", fmt.Errorf("no node has storage %s available", vol.Storage())
	}

	return nodes[0], nil
}

func fsBase(node, storage string) string {
	return fmt.Sprintf("/nodes/%s/flashsystem/%s", node, url.PathEscape(storage))
}

// FSCreateSnapshot snapshots one volume on the array.
//
// Idempotent by name on the array side: a retry recomputes the same
// deterministic array object and returns it rather than cutting a second
// snapshot. The array side also refuses - rather than aliasing - when the
// derived array name is already in use by a DIFFERENT volume, which is the
// failure mode a truncated deterministic name has to defend against: treating
// a collision as "already exists" would hand back a handle pointing at another
// PersistentVolumeClaim's snapshot, and a later restore would silently serve
// someone else's data.
func FSCreateSnapshot(
	ctx context.Context,
	cl *goproxmox.APIClient,
	vol *volume.Volume,
	csiName string,
) (*FSSnapshot, error) {
	node, err := fsNode(ctx, cl, vol)
	if err != nil {
		return nil, err
	}

	snap := &FSSnapshot{}
	params := map[string]string{
		"volname": vol.Disk(),
		"name":    csiName,
	}

	if err := cl.Client.Post(ctx, fsBase(node, vol.Storage())+"/snapshot", params, snap); err != nil {
		return nil, err
	}

	if snap.SnapshotName == "" {
		return nil, fmt.Errorf("flashsystem: snapshot endpoint returned no snapshot_name for %s", vol.Disk())
	}

	return snap, nil
}

// FSDeleteSnapshot removes one array snapshot by its array-side name.
//
// Idempotent on absence, which the CSI spec requires of DeleteSnapshot: the
// plugin reports deleted=0 with a reason rather than erroring, and a snapshot
// outside the storage's own prefix is reported as not-ours and left untouched.
func FSDeleteSnapshot(
	ctx context.Context,
	cl *goproxmox.APIClient,
	vol *volume.Volume,
	arraySnapName string,
) error {
	node, err := fsNode(ctx, cl, vol)
	if err != nil {
		return err
	}

	// Delete carries no body in this client, so the name goes in the query
	// string. It is an array object name - alphanumerics, dot, underscore,
	// hyphen - but escape it rather than trusting that.
	path := fmt.Sprintf("%s/snapshot?snapname=%s",
		fsBase(node, vol.Storage()), url.QueryEscape(arraySnapName))

	// DECODE THE REPLY. Passing nil here would be the same silent-delete bug
	// the marker and the dispatch ordering exist to prevent, one layer down:
	// the client's handleResponse returns early when the target is nil ("if
	// nil passed don't bother to do any unmarshalling"), so the plugin's
	// refusal - which arrives as a 200 with {deleted: 0, reason: ...} - would
	// be thrown away and every outcome would look like a successful delete.
	res := &FSDeleteResult{}
	if err := cl.Client.Delete(ctx, path, res); err != nil {
		return err
	}

	if res.Deleted == 1 {
		return nil
	}

	// Genuine absence is the ONE non-deletion the CSI spec requires to be
	// reported as success: "if a snapshot corresponding to the specified
	// snapshot_id does not exist ... the Plugin MUST reply 0 OK".
	if res.Reason == "absent" {
		return nil
	}

	// Anything else - notably "not-ours", a handle naming a snapshot on
	// another storage - must surface, so the VolumeSnapshotContent keeps its
	// finalizer and the leak stays visible instead of being reported as freed.
	reason := res.Reason
	if reason == "" {
		reason = "the plugin reported neither a deletion nor a reason"
	}

	return fmt.Errorf("flashsystem: refused to delete snapshot %s: %s", arraySnapName, reason)
}

// FSListSnapshots lists this storage's array snapshots, optionally narrowed to
// one volume. Scoped by the storage's fsprefix on the array side, so the rest
// of the array's snapshot namespace - the Proxmox VM estate's, and any other
// consumer sharing the array - is never reported or acted on.
//
// Upstream ListSnapshots is Unimplemented, so this is also the read half of
// orphan reconciliation: without it there is no way to diff array state against
// VolumeSnapshotContent objects, and on a data reduction pool a leaked snapshot
// holds physical capacity in a pool shared with production workloads.
func FSListSnapshots(
	ctx context.Context,
	cl *goproxmox.APIClient,
	region string,
	storage string,
	sourceVolname string,
) ([]FSSnapshot, error) {
	nodes, err := cl.GetNodesForStorage(ctx, storage)
	if err != nil {
		return nil, err
	}

	if len(nodes) == 0 {
		return nil, fmt.Errorf("no node has storage %s available", storage)
	}

	path := fsBase(nodes[0], storage) + "/snapshot"
	if sourceVolname != "" {
		path += "?volname=" + url.QueryEscape(sourceVolname)
	}

	snaps := []FSSnapshot{}
	if err := cl.Client.Get(ctx, path, &snaps); err != nil {
		return nil, err
	}

	return snaps, nil
}

// FSVolumeFromSnapshot has the array populate a NEW volume from an existing
// snapshot, and returns the Proxmox volume name it landed under.
//
// The array does the copying, so nothing streams through Proxmox and there is
// no four-minute task ceiling. Because the storage plugin's list_images
// enumerates the array rather than any local metadata, the result is visible to
// Proxmox immediately with nothing else to update - which is what makes the
// restore path cheap.
//
// NOT YET HARDWARE-VALIDATED: this is the one call that rests on mkvolume.
func FSVolumeFromSnapshot(
	ctx context.Context,
	cl *goproxmox.APIClient,
	region string,
	storage string,
	arraySnapName string,
	targetVolname string,
) (*FSVolume, error) {
	nodes, err := cl.GetNodesForStorage(ctx, storage)
	if err != nil {
		return nil, err
	}

	if len(nodes) == 0 {
		return nil, fmt.Errorf("no node has storage %s available", storage)
	}

	out := &FSVolume{}
	// The TARGET name is ours, not the plugin's. The driver has already minted
	// this volume name and put it in the PersistentVolume's volumeHandle before
	// asking for the restore, so a plugin that minted its own would produce a
	// volume this driver cannot address.
	params := map[string]string{
		"snapname": arraySnapName,
		"volname":  targetVolname,
	}

	if err := cl.Client.Post(ctx, fsBase(nodes[0], storage)+"/volume-from-snapshot", params, out); err != nil {
		return nil, err
	}

	if out.Volname == "" {
		return nil, fmt.Errorf("flashsystem: volume-from-snapshot returned no volname for %s", arraySnapName)
	}

	return out, nil
}

// FSIsAlreadyExists reports whether an error from the plugin is the
// cross-volume name collision described on FSCreateSnapshot, which CSI maps to
// gRPC ALREADY_EXISTS rather than to a generic internal error. The plugin tags
// that one message so this does not have to parse CMMVC codes.
func FSIsAlreadyExists(err error) bool {
	return err != nil && strings.Contains(err.Error(), "ALREADY_EXISTS")
}
