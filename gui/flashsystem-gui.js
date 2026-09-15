// ---------------------------------------------------------------------------
// GUI add/edit support for the custom `flashsystem` storage type.
//
// Proxmox's Datacenter > Storage "Add"/"Edit" dialogs are defined entirely in
// the pve-manager frontend (pvemanagerlib.js), which has NO plugin API - so a
// custom backend storage plugin never appears in the "Add" menu and has no
// edit form. This file fills that gap: it defines an ExtJS input panel and
// registers the `flashsystem` type in PVE.Utils.storageSchema.
//
// It is appended to /usr/share/pve-manager/js/pvemanagerlib.js by
// install-flashsystem-gui.sh, which also installs an APT post-invoke hook to
// re-append it after pve-manager upgrades (those rewrite that file). Run the
// installer on EVERY node. See UPSTREAM.md section 2 ("GUI Add/Edit dialogs").
//
// Field/idiom conventions mirror PVE 9.x PVE.storage.CIFSInputPanel:
//   - fixed-on-edit fields render as a textfield on create, displayfield on edit
//   - the password is blank on edit and dropped when left empty (= "unchanged")
// ---------------------------------------------------------------------------

Ext.define('PVE.storage.FlashSystemInputPanel', {
    extend: 'PVE.panel.StorageBase',

    onGetValues: function (values) {
        let me = this;
        // Leave the password blank to keep the current one. The plugin prefers
        // the root-only /etc/pve/priv/storage/<id>.pw file over a plaintext
        // value in storage.cfg anyway, so blank is the recommended case.
        if (values.fspassword?.length === 0) {
            delete values.fspassword;
        }
        if (values.fsiogrp?.length === 0) {
            delete values.fsiogrp;
        }
        // LOCAL PATCH (see UPSTREAM.md): a host-cluster-mapped volume is
        // visible to every node by construction, so this storage type is
        // inherently shared. Without this, GUI-created storages defaulted to
        // shared=0 and migration would try to copy the disk instead of
        // handing over the multipath map.
        if (me.isCreate) {
            values.shared = 1;
        }
        return me.callParent([values]);
    },

    initComponent: function () {
        let me = this;

        me.column1 = [
            {
                // fixed => 1 in the plugin: settable only at creation time.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fsaddress',
                value: '',
                fieldLabel: gettext('Management address'),
                allowBlank: false,
            },
            {
                // fixed => 1 in the plugin: settable only at creation time.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fspool',
                value: '',
                fieldLabel: gettext('Pool (mdiskgrp)'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                name: 'fshostgroup',
                value: '',
                fieldLabel: gettext('Host cluster'),
                allowBlank: false,
            },
            {
                // LOCAL PATCH (fsprefix, see UPSTREAM.md): fixed => 1 in the
                // plugin, so create-only. Required by policy here, not by the
                // plugin schema: pools are shared between clusters, and a
                // storage created without a prefix can never gain one — the
                // 2026-08-12 trial storage had to be created from the CLI
                // because this field was missing.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fsprefix',
                value: '',
                emptyText: gettext('e.g. the cluster name'),
                fieldLabel: gettext('Prefix'),
                allowBlank: false,
            },
        ];

        me.column2 = [
            {
                xtype: 'pveContentTypeSelector',
                name: 'content',
                value: 'images',
                multiSelect: true,
                // LOCAL PATCH (see UPSTREAM.md): only offer what the plugin's
                // plugindata declares. The unrestricted selector listed ISO,
                // backup, templates and snippets — all file-storage content
                // that a raw-block plugin cannot hold, failing only at submit.
                cts: ['images', 'rootdir'],
                fieldLabel: gettext('Content'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                name: 'fsuser',
                value: '',
                fieldLabel: gettext('REST username'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                inputType: 'password',
                name: 'fspassword',
                value: '',
                emptyText: me.isCreate
                    ? gettext('optional - prefer the .pw file')
                    : gettext('unchanged'),
                fieldLabel: gettext('REST password'),
                allowBlank: true,
            },
            {
                xtype: 'textfield',
                name: 'fsiogrp',
                value: '',
                emptyText: 'io_grp0',
                fieldLabel: gettext('I/O group'),
                allowBlank: true,
            },
        ];

        me.advancedColumn1 = [
            {
                xtype: 'proxmoxcheckbox',
                name: 'fssnapshots',
                uncheckedValue: 0,
                fieldLabel: gettext('Array snapshots'),
                boxLabel: gettext('enable (validate firmware first)'),
            },
            {
                // LOCAL PATCH (fsthin, see UPSTREAM.md): thin-provision NEW
                // volumes (mkvdisk -rsize 2% -autoexpand). Existing volumes
                // keep their allocation. Thin = overcommit — make sure
                // array-side physical-free alerting exists before enabling
                // on pools shared with other workloads.
                xtype: 'proxmoxcheckbox',
                name: 'fsthin',
                uncheckedValue: 0,
                fieldLabel: gettext('Thin provision'),
                boxLabel: gettext('new volumes only'),
            },
        ];

        me.callParent();
    },
});

// Register the type so it shows in the "Add" dropdown and gets an Edit dialog.
// storageSchema is a plain object on the PVE.Utils singleton, already defined
// by the time this appended code runs.
if (typeof PVE !== 'undefined' && PVE.Utils && Ext.isObject(PVE.Utils.storageSchema)) {
    PVE.Utils.storageSchema.flashsystem = {
        name: 'IBM FlashSystem',
        ipanel: 'FlashSystemInputPanel',
        faIcon: 'database',
    };
}

// ---------------------------------------------------------------------------
// LOCAL PATCH (health panel, see UPSTREAM.md section 3): a "FlashSystem" tab
// on the storage view showing array health and capacity, fed by the
// GET /nodes/{node}/flashsystem/{storage}/health endpoint that
// install-flashsystem-api.sh registers. Read-only; sections degrade
// independently when the array is slow or unreachable.
// ---------------------------------------------------------------------------

Ext.define('PVE.storage.FlashSystemHealthPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveFlashSystemHealthPanel',

    scrollable: true,
    bodyPadding: 15,
    html: '<div class="fs-root fs-health fs-muted">' + gettext('Loading...') + '</div>',

    tbar: [
        {
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('panel').reloadHealth();
            },
        },
    ],

    fmtBytes: function(v) {
        if (v === undefined || v === null) { return '-'; }
        return Proxmox.Utils.format_size(v);
    },

    esc: Ext.htmlEncode,

    // Storage Virtualize event timestamps are YYMMDDHHMMSS.
    fmtEventTime: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t || ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    renderHealth: function(d) {
        let me = this;
        let e = me.esc;
        let h = [];
        let UI = PVE.FlashSystemUI;
        UI.ensureStyles();
        let row = (k, v) => `<tr><td class="fs-muted" style="white-space:nowrap;">${e(k)}</td><td>${v}</td></tr>`;
        let head = t => `<div class="fs-sec-h" style="margin-top:14px;">${e(t)}</div>`;

        if (d.system) {
            h.push(head(gettext('System')));
            h.push('<table class="fs-tbl">');
            h.push(row(gettext('Name'), e(d.system.name || '-')));
            h.push(row(gettext('Product'), e(d.system.product_name || '-')));
            h.push(row(gettext('Firmware'), e(d.system.code_level || '-')));
            h.push('</table>');
        }

        if (d.pool) {
            let p = d.pool;
            let pct = p.provision_used_pct || 0;
            let color = pct >= 90 ? 'var(--fs-crit)' : (pct >= 75 ? 'var(--fs-warn)' : 'var(--fs-ok)');
            h.push(head(gettext('Pool') + ' ' + (d.pool_name || p.name || '')));
            h.push('<div class="fs-bar" style="max-width:420px;">'
                + `<i style="width:${Math.min(pct, 100)}%;background:${color};"></i></div>`);
            h.push(`<div class="fs-muted" style="font-size:12px;margin-top:4px;">`
                + `${pct}% ${e(gettext('of physical'))}</div>`);
            h.push('<table class="fs-tbl" style="margin-top:6px;">');
            h.push(row(gettext('Physical (usable)'),
                `${me.fmtBytes(p.provision_used)} / ${me.fmtBytes(p.provision_total)} (${me.fmtBytes(p.provision_free)} ${e(gettext('free'))})`));
            if (p.physical_capacity && p.capacity && +p.capacity !== +p.physical_capacity) {
                h.push(row(gettext('Effective (after reduction)'),
                    `${me.fmtBytes(p.capacity - p.free_capacity)} / ${me.fmtBytes(p.capacity)}`));
            }
            if (p.data_reduction) {
                h.push(row(gettext('Data reduction'), e(p.data_reduction)));
            }
            if (p.status) {
                h.push(row(gettext('Status'), e(p.status)));
            }
            h.push('</table>');
        }

        if (d.volumes) {
            h.push(head(gettext('Volumes')));
            h.push('<table>');
            h.push(row(gettext('This storage'),
                `${d.volumes.ours} (${me.fmtBytes(d.volumes.ours_provisioned)} ${e(gettext('provisioned'))})`));
            h.push(row(gettext('Whole pool'), `${d.volumes.pool_total}`));
            // An unprefixed storage shares the pool's namespace with every
            // other consumer and cannot be isolated from them. fsprefix is
            // fixed at creation, so this only gets more expensive to fix.
            h.push(row(gettext('Array name prefix'), d.prefix
                ? e(d.prefix)
                : UI.icon('warn')
                  + e(gettext('none — objects are unprefixed and share the pool namespace'))));
            h.push('</table>');
        }

        if (d.ports) {
            let ok = d.ports.active === d.ports.total;
            h.push(head(gettext('FC ports')));
            h.push(`<div>${ok ? '' : UI.icon('warn')}`
                + `${d.ports.active} / ${d.ports.total} ${e(gettext('active'))}</div>`);
        }

        // Ranked consumers for THIS storage — same rows the volume count was
        // taken from, so no extra array traffic.
        if (d.top && d.top.volumes && d.top.volumes.length) {
            h.push(head(gettext('Largest volumes')));
            h.push(PVE.FlashSystemUI.renderTop(d.top, 'health', me.topSort));
        }

        if (d.events) {
            // Alerts only. The array's unfixed log is mostly informational
            // chatter (copy-format notices, SAS discovery) — showing that raw
            // count would bury a real pool-space warning under four figures.
            let alerts = d.events.alerts || 0;
            h.push(head(gettext('Array alerts')));
            h.push('<div>'
                + (alerts === 0
                    ? UI.icon('ok') + e(gettext('No unfixed alerts'))
                    : UI.icon('crit') + `<b>${alerts}</b> ${e(gettext('unfixed'))}`)
                // Shown only when the whole unfixed log was fetched: under the
                // server-side alert filter those informational events are not
                // in the payload, and printing 0 would claim there are none.
                + (d.events.unfixed_total === undefined
                    ? ''
                    : ` <span class="fs-muted">(${d.events.unfixed_total} ${e(gettext('unfixed events array-wide, incl. informational'))})</span>`)
                + '</div>');
            if (alerts > 0 && d.events.recent && d.events.recent.length) {
                h.push('<table style="font-size:12px;margin-top:6px;">');
                d.events.recent.forEach(ev => {
                    h.push(row(me.fmtEventTime(ev.last_timestamp) || ev.sequence_number || '',
                        `<b>${e(ev.error_code || '')}</b> ${e(ev.description || '')}`
                        + (ev.object_name ? ` <span class="fs-dim">(${e(ev.object_name)})</span>` : '')));
                });
                h.push('</table>');
            }
        }

        if (d.errors) {
            h.push(head(gettext('Sections unavailable')));
            h.push('<table style="font-size:12px;">');
            Object.keys(d.errors).forEach(k => h.push(row(k, e(d.errors[k]))));
            h.push('</table>');
        }

        return '<div class="fs-root fs-health">' + h.join('') + '</div>';
    },

    reloadHealth: function() {
        let me = this;
        let sel = me.pveSelNode ? me.pveSelNode.data : {};
        let nodename = me.nodename || sel.node;
        let storage = me.storage || sel.storage;
        if (!nodename || !storage) {
            me.update('<div>' + gettext('No storage selected.') + '</div>');
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${nodename}/flashsystem/${storage}/health`,
            method: 'GET',
            waitMsgTarget: me,
            success: function(response) {
                me.healthData = response.result.data || {};
                me.update(me.renderHealth(me.healthData));
            },
            failure: function(response) {
                me.update('<div class="fs-root fs-err">'
                    + Ext.htmlEncode(response.htmlStatus || gettext('Query failed'))
                    + '</div>');
            },
        });
    },

    listeners: {
        activate: function() {
            this.reloadHealth();
        },
        // Same delegated sort as the datacenter panel; the server already
        // returns largest-first, so this is convenience only.
        click: {
            element: 'body',
            fn: function(ev) {
                let me = this;
                let el = ev.getTarget('[data-fssort]', 6);
                if (!el) { return; }
                let key = el.getAttribute('data-fssort');
                if (!key || !me.healthData) { return; }
                me.topSort = me.topSort && me.topSort.key === key
                    ? { key: key, dir: me.topSort.dir === 'asc' ? 'desc' : 'asc' }
                    : { key: key, dir: 'desc' };
                me.update(me.renderHealth(me.healthData));
            },
        },
    },
});

// Mount the tab: PVE.panel.Config consumes `me.items` assembled by
// PVE.storage.Browser BEFORE calling its own initComponent, so intercepting
// Config.initComponent lets us add a tab without re-implementing the
// browser's item assembly. Guarded so any ExtJS-internals drift in a future
// pve-manager degrades to "no tab", never a broken storage view.
// VALIDATE: tested against pve-manager 9.2; re-check after major upgrades.
Ext.define('PVE.storage.FlashSystemConfigOverride', {
    override: 'PVE.panel.Config',
    initComponent: function() {
        let me = this;
        try {
            let sel = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data : {};
            if (Ext.isArray(me.items)) {
                if (sel.type === 'storage' && sel.plugintype === 'flashsystem') {
                    // Per-storage health tab.
                    me.items.push({
                        xtype: 'pveFlashSystemHealthPanel',
                        title: 'FlashSystem',
                        itemId: 'flashsystemhealth',
                        iconCls: 'fa fa-heartbeat',
                        nodename: sel.node,
                        storage: sel.storage,
                    });
                } else if (me.hstateid === 'dctab' || sel.id === 'root') {
                    // Datacenter-wide overview. This MUST hook PVE.panel.Config
                    // rather than PVE.dc.Config: the latter assigns me.items = []
                    // as the first statement of its own initComponent, i.e. after
                    // an override on it would have run, so the entry would be
                    // discarded silently.
                    let caps = Ext.state.Manager.get('GuiCap') || {};
                    let maySee = (caps.storage
                            && (caps.storage['Datastore.Audit'] || caps.storage['Datastore.Allocate']))
                        || (caps.dc && caps.dc['Sys.Audit']);
                    if (maySee) {
                        let item = {
                            xtype: 'pveDcFlashSystemOverview',
                            title: 'FlashSystem',
                            itemId: 'flashsystem',
                            iconCls: 'fa fa-hdd-o',
                        };
                        // Sit next to Ceph, where people already look for
                        // storage-fabric status; then Storage; else append.
                        let idx = -1;
                        ['ceph', 'storage'].forEach(function(id) {
                            if (idx < 0) {
                                idx = me.items.findIndex(function(it) { return it && it.itemId === id; });
                            }
                        });
                        if (idx >= 0) {
                            me.items.splice(idx + 1, 0, item);
                        } else {
                            me.items.push(item);
                        }
                    }
                }
            }
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('flashsystem config tab:', err);
        }
        me.callParent();
    },
});

// ---------------------------------------------------------------------------
// LOCAL PATCH (performance + consumption, see UPSTREAM.md section 4): shared
// rendering for the sections that appear in BOTH the storage tab and the
// datacenter overview — ranked volume/VM consumption and array performance.
//
// The two panels' existing formatters were deliberately duplicated (a dozen
// lines each, one of them production-validated). These sections are ~150
// lines, so they live once, here, and both panels call in.
// ---------------------------------------------------------------------------

Ext.define('PVE.FlashSystemUI', {
    singleton: true,
    // ---- stylesheet -------------------------------------------------------
    //
    // Injected once, rather than 100+ inline style attributes. The important
    // part is that NOTHING here hardcodes a light or dark value: PVE ships
    // both themes, and the earlier inline styling assumed dark, so a
    // #2a2a2a bar track and a #444 border rendered as smudges on the default
    // light theme.
    //
    // Two rules keep it theme-proof without detecting the theme at all:
    //   * text is `currentColor`, and muted text is `opacity`, which is
    //     relative to whatever the theme already chose;
    //   * lines and fills are rgba(128,128,128,a) — a neutral grey reads
    //     correctly over white and over near-black alike.
    // Only the four semantic hues are absolute, and they are mid-tones with
    // enough contrast on both grounds. They are used on icons and bars, not
    // on body text, so legibility never depends on them.
    CSS: [
        '.fs-root{--fs-line:rgba(128,128,128,.30);--fs-soft:rgba(128,128,128,.16);',
        '--fs-fill:rgba(128,128,128,.10);--fs-track:rgba(128,128,128,.22);',
        '--fs-ok:#3ba55d;--fs-warn:#c8860d;--fs-crit:#d9534f;--fs-accent:#4b8fc7;',
        'font-size:13px;line-height:1.45;}',
        '.fs-root .fs-title{font-size:15px;font-weight:600;margin:0 0 1px;}',
        '.fs-sub{opacity:.62;font-size:12px;margin-bottom:10px;}',
        '.fs-muted{opacity:.62;}',
        '.fs-dim{opacity:.42;}',
        '.fs-ok{color:var(--fs-ok);}.fs-warn{color:var(--fs-warn);}.fs-crit{color:var(--fs-crit);}',
        '.fs-array{margin-bottom:26px;}',
        '.fs-card{border:1px solid var(--fs-line);border-radius:5px;padding:11px 13px;',
        'margin-top:12px;background:var(--fs-fill);}',
        '.fs-card-h{display:flex;justify-content:space-between;align-items:baseline;',
        'gap:14px;margin-bottom:7px;}',
        '.fs-card-h b{font-size:13px;}',
        '.fs-status{display:flex;flex-wrap:wrap;gap:3px 20px;font-size:12px;margin-bottom:4px;}',
        '.fs-sec{margin-top:13px;}',
        '.fs-sec-h{font-size:10.5px;text-transform:uppercase;letter-spacing:.06em;',
        'opacity:.55;font-weight:600;margin-bottom:4px;}',
        '.fs-bar{height:10px;border-radius:5px;background:var(--fs-track);',
        'overflow:hidden;max-width:560px;}',
        '.fs-bar>i{display:block;height:100%;border-radius:5px;}',
        '.fs-tiles{display:grid;grid-template-columns:repeat(auto-fill,minmax(150px,1fr));gap:8px;}',
        '.fs-tile{border:1px solid var(--fs-soft);border-radius:4px;padding:6px 9px 7px;}',
        '.fs-tile-l{font-size:11px;opacity:.62;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}',
        '.fs-tile-v{font-size:19px;font-weight:600;font-variant-numeric:tabular-nums;line-height:1.3;}',
        '.fs-tile-v small{font-size:11px;font-weight:400;opacity:.6;margin-left:2px;}',
        '.fs-tile-p{font-size:10.5px;opacity:.5;white-space:nowrap;font-variant-numeric:tabular-nums;}',
        '.fs-tile svg{display:block;margin-top:2px;}',
        '.fs-tbl{width:100%;border-collapse:collapse;font-size:12px;}',
        '.fs-tbl th{text-align:left;font-weight:600;font-size:10.5px;opacity:.6;',
        'padding:0 10px 3px 0;white-space:nowrap;border-bottom:1px solid var(--fs-soft);}',
        '.fs-tbl th.fs-s{cursor:pointer;}.fs-tbl th.fs-s:hover{opacity:.95;}',
        '.fs-tbl td{padding:3px 10px 3px 0;border-bottom:1px solid var(--fs-soft);}',
        '.fs-tbl tr:last-child td{border-bottom:none;}',
        '.fs-tbl tbody tr:hover td{background:var(--fs-fill);}',
        '.fs-num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap;}',
        // Guest and volume are the two columns that wreck row rhythm: a
        // guest label carries VMID + name + node, and a CSI volume name is 48
        // characters. Both stay on one line; the volume truncates with its
        // full value in a tooltip.
        '.fs-tbl td.fs-g{white-space:nowrap;}',
        '.fs-tbl td.fs-v{max-width:280px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;}',
        '.fs-tile-p{overflow:hidden;text-overflow:ellipsis;}',
        '.fs-w100{width:100%;}',
        '.fs-pill{display:inline-block;font-size:10px;padding:0 5px;border-radius:8px;',
        'border:1px solid var(--fs-line);opacity:.75;white-space:nowrap;margin-left:4px;}',
        '.fs-alert{border:1px solid var(--fs-crit);border-radius:5px;padding:7px 10px;margin-top:10px;}',
        '.fs-alert-h{font-weight:600;font-size:12px;margin-bottom:4px;}',
        '.fs-note{font-size:11px;opacity:.6;margin-top:8px;max-width:700px;}',
        '.fs-ev{font-size:11.5px;opacity:.72;margin-left:20px;font-variant-numeric:tabular-nums;}',
        '.fs-err{color:var(--fs-crit);}',
    ].join(''),

    // Idempotent: the panel re-renders constantly and the installer appends
    // this file once per node, but a reload must not stack stylesheets.
    ensureStyles: function() {
        try {
            if (document.getElementById('fs-plugin-styles')) { return; }
            let el = document.createElement('style');
            el.id = 'fs-plugin-styles';
            el.textContent = this.CSS;
            document.head.appendChild(el);
        } catch (err) {
            // No document (tests) or a locked-down head — the panel degrades
            // to unstyled markup, which is still readable.
        }
    },

    esc: Ext.htmlEncode,

    bytes: function(v) {
        if (v === undefined || v === null) { return '&ndash;'; }
        return Ext.htmlEncode(Proxmox.Utils.format_size(v));
    },

    // Thousands separators matter here: five- and six-figure IOPS are the
    // normal reading, and an unseparated 106400 is genuinely hard to size up
    // at a glance against a peak of 1064.
    num: function(v) {
        if (v === undefined || v === null) { return '&ndash;'; }
        let n = Number(v);
        if (!isFinite(n)) { return Ext.htmlEncode(String(v)); }
        return Ext.htmlEncode(n.toLocaleString(undefined, { maximumFractionDigits: 2 }));
    },

    // Storage Virtualize timestamps are YYMMDDHHMMSS, for both event log and
    // statistic peak times.
    //
    // Peaks get the time alone: stat_peak covers the last FIVE MINUTES, so the
    // date is always today and always redundant - and printing it was what
    // pushed the peak line out of its tile.
    stampTime: function(t) {
        let m = /^\d{6}(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        return m ? `${m[1]}:${m[2]}:${m[3]}` : this.stamp(t);
    },

    stamp: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t ? Ext.htmlEncode(String(t)) : ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    // VMID -> name/node, from the resource store the GUI already keeps warm.
    // This is the join that turns "vm-124-disk-0" into something an operator
    // can act on; the API cannot do it, because VM names are PVE's, not the
    // array's. Guarded: without the store we still render VMIDs.
    vmIndex: function() {
        let map = Object.create(null);
        try {
            PVE.data.ResourceStore.each(function(rec) {
                let d = rec.data;
                if (d.type === 'qemu' || d.type === 'lxc') {
                    map[d.vmid] = { name: d.name, node: d.node, type: d.type };
                }
            });
        } catch (err) {
            // resource store not ready — VMIDs only
        }
        return map;
    },

    vmLabel: function(vmid, idx) {
        let e = Ext.htmlEncode;
        let info = idx[vmid];
        if (!info) { return String(vmid); }
        let bits = [];
        if (info.name) { bits.push(e(info.name)); }
        if (info.node) { bits.push(e(info.node)); }
        if (!bits.length) { return String(vmid); }
        return `${vmid} <span class="fs-muted">${bits.join(' &middot; ')}</span>`;
    },

    sortRows: function(rows, key, dir) {
        let mul = dir === 'asc' ? 1 : -1;
        return rows.slice().sort(function(a, b) {
            let x = a[key], y = b[key];
            if (x === undefined || x === null) { return 1; }
            if (y === undefined || y === null) { return -1; }
            if (typeof x === 'number' && typeof y === 'number') { return (x - y) * mul; }
            return String(x).localeCompare(String(y)) * mul;
        });
    },

    // Clickable column header. The panel owns the sort state and re-renders;
    // if the delegated handler never fires the table still shows the
    // server's ordering, which is already highest-first.
    th: function(label, key, tableId, state, cls) {
        let e = Ext.htmlEncode;
        let active = state && state.key === key;
        let caret = active ? (state.dir === 'asc' ? ' &#9650;' : ' &#9660;') : '';
        return `<th class="fs-s${cls ? ' ' + cls : ''}" data-fssort="${e(key)}"`
            + ` data-fstable="${e(tableId)}">${e(label)}${caret}</th>`;
    },

    fillBar: function(pct) {
        let p = Math.max(0, Math.min(100, Number(pct) || 0));
        let v = p >= 90 ? 'var(--fs-crit)' : (p >= 75 ? 'var(--fs-warn)' : 'var(--fs-ok)');
        return `<span class="fs-bar" style="width:64px;display:inline-block;vertical-align:middle;`
            + `height:8px;margin-right:6px;"><i style="width:${p}%;background:${v};"></i></span>`
            + `<span class="fs-num">${p}%</span>`;
    },

    icon: function(kind) {
        let map = {
            ok: 'fa-check-circle fs-ok',
            warn: 'fa-exclamation-triangle fs-warn',
            crit: 'fa-exclamation-triangle fs-crit',
            info: 'fa-info-circle fs-muted',
        };
        return `<i class="fa ${map[kind] || map.info}"></i> `;
    },

    // Ranked consumers. `top` is the API's per-pool (or per-storage) block.
    renderTop: function(top, tableId, state) {
        let me = this;
        let e = Ext.htmlEncode;
        if (!top) { return ''; }
        me.ensureStyles();
        let idx = me.vmIndex();
        let h = [];

        // Volumes needing attention come FIRST and unconditionally - they are
        // not ranked by size and must not depend on making the top ten. A
        // 32 GiB offline volume in a pool whose largest is 2 TB would never
        // appear otherwise, and fast_write_state=corrupt arrives WITH
        // status=online, so the status column alone renders it as healthy
        // while it is actually waiting on recovervdisk.
        let att = top.attention || [];
        if (att.length) {
            h.push('<div class="fs-alert"><div class="fs-alert-h fs-crit">'
                + me.icon('crit') + e(gettext('Needs attention'))
                + (top.attention_total > att.length
                    ? ` <span class="fs-muted">(${e(gettext('showing'))} ${att.length} `
                      + `${e(gettext('of'))} ${top.attention_total})</span>`
                    : '')
                + '</div><table class="fs-tbl"><tbody>');
            att.forEach(function(v) {
                let flags = [];
                if (v.status && String(v.status).toLowerCase() !== 'online') {
                    flags.push(e(v.status));
                }
                if (v.fast_write_state) {
                    // Not a performance hint: this one needs recovervdisk or
                    // repairvdiskcopy before the guest will start.
                    flags.push(e(gettext('fast-write')) + ' ' + e(v.fast_write_state)
                        + ' &mdash; ' + e(gettext('needs recovervdisk')));
                }
                h.push('<tr>'
                    + `<td class="fs-g">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td class="fs-v" title="${e(v.name || '')}">${e(v.name || '')}</td>`
                    + `<td class="fs-muted">${e(v.storage || '')}</td>`
                    + `<td class="fs-num">${me.bytes(v.capacity)}</td>`
                    + `<td class="fs-crit">${flags.join(' &middot; ')}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        let vols = top.volumes || [];
        if (vols.length) {
            if (state && state.key) { vols = me.sortRows(vols, state.key, state.dir); }
            // Fill is only knowable for space-efficient volumes: a fully
            // allocated volume reserves its whole size, so the array has no
            // "how full" to report and the number that matters is the size.
            let anyFill = vols.some(function(v) { return v.fill_pct !== undefined; });
            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext('Largest volumes'))}</div>`);
            h.push('<table class="fs-tbl fs-w100"><thead><tr>');
            h.push(me.th(gettext('Guest'), 'vmid', tableId, state));
            h.push(me.th(gettext('Volume'), 'name', tableId, state));
            h.push(me.th(gettext('Storage'), 'storage', tableId, state));
            h.push(me.th(gettext('Provisioned'), 'capacity', tableId, state, 'fs-num'));
            if (anyFill) { h.push(me.th(gettext('Used'), 'used', tableId, state)); }
            h.push('</tr></thead><tbody>');
            vols.forEach(function(v) {
                h.push('<tr>'
                    + `<td class="fs-g">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td class="fs-v" title="${e(v.name || '')}">${e(v.name || '')}`
                        + (v.status && String(v.status).toLowerCase() !== 'online'
                            ? ` <span class="fs-crit">${e(v.status)}</span>` : '')
                        + (v.thin ? `<span class="fs-pill">${e(gettext('thin'))}</span>` : '')
                    + '</td>'
                    + `<td class="fs-muted">${e(v.storage || '')}</td>`
                    + `<td class="fs-num">${me.bytes(v.capacity)}</td>`
                    + (anyFill
                        ? '<td>'
                            + (v.fill_pct === undefined
                                ? '<span class="fs-dim">&ndash;</span>'
                                : `${me.fillBar(v.fill_pct)} <span class="fs-muted">${me.bytes(v.used)} `
                                  + e(v.fill_basis === 'allocated'
                                      ? gettext('of allocated')
                                      : gettext('of provisioned')) + '</span>')
                            + '</td>'
                        : '')
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        let fill = top.fill;
        if (fill && !fill.available) {
            let why = {
                // The important one: every tier on the validation cluster
                // is a DRP, so this is the normal path there.
                'data-reduction-pool': gettext(
                    'Per-volume fill is not reported for volumes in a data reduction pool '
                    + '- the array leaves those fields blank. Sizes above are provisioned capacity.'),
                'query-failed': gettext('The per-volume fill query failed; sizes above are provisioned capacity.'),
                'pool-capacity-unavailable': gettext(
                    'Pool capacity was unavailable, so per-volume fill was not queried.'),
            }[fill.reason] || gettext('Per-volume fill is unavailable.');
            h.push(`<div class="fs-note">${me.icon('info')}${e(why)}</div>`);
        }

        let vms = top.vms || [];
        if (vms.length > 1) {
            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext('By guest'))}</div>`);
            h.push('<table class="fs-tbl"><tbody>');
            vms.forEach(function(v) {
                h.push('<tr>'
                    + `<td class="fs-g">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td class="fs-muted">${Number(v.disks) || 0} ${e(gettext('disks'))}</td>`
                    + `<td class="fs-num">${me.bytes(v.capacity)}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        // Other storages of OURS sharing this pool. Only the storage-scoped
        // view carries this; it is typically a CSI storage sitting on the
        // same tier, and counting it as another tenant sends a capacity
        // question to the storage team that belongs to one's own Kubernetes.
        let sib = top.siblings;
        if (sib && sib.count) {
            h.push(`<div class="fs-note">`
                + `${e(gettext('Other storages of this cluster in the same pool'))}: `
                + `<b>${sib.count}</b> ${e(gettext('volumes'))}, ${me.bytes(sib.capacity)} `
                + `<span class="fs-dim">(${e(gettext('see Datacenter → FlashSystem for the breakdown'))})</span>`
                + '</div>');
        }

        // Other tenants. On a pool shared with VMware or another cluster this
        // is regularly the largest consumer, and omitting it would point the
        // operator at the wrong place entirely.
        let f = top.foreign;
        if (f && f.count) {
            h.push(`<div class="fs-sec"><div class="fs-sec-h">`
                + `${e(gettext('Not managed by this cluster'))}</div>`
                + `<div class="fs-muted" style="font-size:12px;">`
                + `<b>${f.count}</b> ${e(gettext('volumes'))}, ${me.bytes(f.capacity)}</div>`);
            let named = (f.volumes || []).filter(function(v) { return v.name; });
            if (named.length) {
                h.push('<table class="fs-tbl"><tbody>');
                named.forEach(function(v) {
                    h.push(`<tr><td class="fs-v" title="${e(v.name)}">${e(v.name)}</td>`
                        + `<td class="fs-num">${me.bytes(v.capacity)}</td></tr>`);
                });
                h.push('</tbody></table>');
            }
            h.push('</div>');
        }
        return h.join('');
    },

    // Metric groups mirroring the array GUI's Performance tab. Front-end
    // first: that is what the guests actually experience, and comparing it
    // with the back-end rows is how you tell "the array is busy" from "the
    // drives are struggling".
    PERF_GROUPS: [
        { label: 'Volumes (front end)', spark: true, metrics: [
            { k: 'vdisk_r_io', l: 'Read IOPS' }, { k: 'vdisk_w_io', l: 'Write IOPS' },
            { k: 'vdisk_r_mb', l: 'Read', u: 'MB/s' }, { k: 'vdisk_w_mb', l: 'Write', u: 'MB/s' },
            { k: 'vdisk_r_ms', l: 'Read latency (ms)' },
            { k: 'vdisk_w_ms', l: 'Write latency (ms)' } ] },
        { label: 'MDisks (back end)', metrics: [
            { k: 'mdisk_r_io', l: 'Read IOPS' }, { k: 'mdisk_w_io', l: 'Write IOPS' },
            { k: 'mdisk_r_mb', l: 'Read', u: 'MB/s' }, { k: 'mdisk_w_mb', l: 'Write', u: 'MB/s' },
            { k: 'mdisk_r_ms', l: 'Read latency (ms)' },
            { k: 'mdisk_w_ms', l: 'Write latency (ms)' } ] },
        { label: 'Drives', metrics: [
            { k: 'drive_r_io', l: 'Read IOPS' }, { k: 'drive_w_io', l: 'Write IOPS' },
            { k: 'drive_r_ms', l: 'Read latency (ms)' },
            { k: 'drive_w_ms', l: 'Write latency (ms)' } ] },
        { label: 'Interfaces', metrics: [
            { k: 'fc_io', l: 'FC IOPS' }, { k: 'fc_mb', l: 'FC', u: 'MB/s' },
            { k: 'iscsi_io', l: 'iSCSI IOPS' }, { k: 'iscsi_mb', l: 'iSCSI', u: 'MB/s' },
            { k: 'sas_io', l: 'SAS IOPS' }, { k: 'sas_mb', l: 'SAS', u: 'MB/s' } ] },
        { label: 'System', metrics: [
            { k: 'cpu_pc', l: 'CPU', u: '%' },
            { k: 'compression_cpu_pc', l: 'Compression CPU', u: '%' },
            { k: 'total_cache_pc', l: 'Cache', u: '%' },
            { k: 'write_cache_pc', l: 'Write cache', u: '%' },
            { k: 'power_w', l: 'Power', u: 'W' }, { k: 'temp_c', l: 'Temperature', u: 'C' } ] },
    ],

    // Inline SVG — no library, no external fetch, and it inherits the theme's
    // text colour through currentColor rather than picking one.
    sparkline: function(values) {
        if (!values || values.length < 2) { return ''; }
        let nums = values.map(Number).filter(function(v) { return isFinite(v); });
        if (nums.length < 2) { return ''; }
        let max = Math.max.apply(null, nums);
        let min = Math.min.apply(null, nums);
        let span = (max - min) || 1;
        let w = 100, hh = 16;
        let step = w / (nums.length - 1);
        let pts = nums.map(function(v, i) {
            return (i * step).toFixed(1) + ',' + (hh - ((v - min) / span) * hh).toFixed(1);
        }).join(' ');
        return `<svg width="100%" height="${hh}" viewBox="0 0 ${w} ${hh}" `
            + `preserveAspectRatio="none" style="opacity:.75;">`
            + `<polyline points="${pts}" fill="none" stroke="var(--fs-accent)" `
            + `stroke-width="1.5" vector-effect="non-scaling-stroke"/></svg>`;
    },

    renderPerformance: function(d) {
        let me = this;
        let e = Ext.htmlEncode;
        let h = [];
        if (!d || d.error) {
            return `<div class="fs-err">${(d && d.error) || e(gettext('Query failed'))}</div>`;
        }
        me.ensureStyles();
        let stats = (d.performance && d.performance.stats) || {};
        let hist = d.history || {};
        let nodeRows = (d.nodes && d.nodes.nodes) || [];

        // Only claim nothing was reported when nothing was. Printing this
        // above a per-canister table full of live numbers reads as a bug in
        // the panel rather than as a partial answer.
        if (!Object.keys(stats).length && !nodeRows.length) {
            h.push(`<div class="fs-muted">${e(gettext('No performance statistics reported.'))}</div>`);
        }

        // Two things the reader has to know to trust these numbers.
        //
        // The unit: RESOLVED 2026-09-15, by IBM, with array output rather than
        // documentation. The *_ms statistics are MILLISECONDS. IBM's own 8.7
        // docs contradict themselves - the stat_name descriptions say
        // microseconds, the attribute table says milliseconds, and the
        // Performance statistics page says the CLI always shows microseconds -
        // and guessing wrong is a 1000x error, so these were rendered
        // unlabelled until someone with the array could settle it.
        //
        // The attribute table is the correct one. On 9.1.0.2:
        //     mdisk_ms  0.000  10.103     -> 10.103 ms
        //     drive_ms  0.618   0.790     ->  0.790 ms, i.e. 790 microseconds
        // and on an older V7000 at 8.3.1.10 the same fields are integers with
        // no decimal place (mdisk_w_ms 9, drive_r_ms 22), which is the same
        // unit at lower precision.
        //
        // CAVEAT worth keeping: attested on 9.1.0.2 and 8.3.1.10. pmcl01 runs
        // 8.7.x, which sits between them, so ms is the safe reading - but it
        // is an inference across versions, not a direct observation on ours.
        let notes = [gettext(
            'Latency is in milliseconds, confirmed against array output on '
            + '9.1.0.2 and 8.3.1.10. IBM 8.7 documentation contradicts itself '
            + 'on this - the attribute table is the correct one.')];
        if (d.performance && d.performance.derived) {
            notes.push(gettext(
                'System totals are derived from per-node statistics: '
                + 'throughput summed across canisters, latency and percentages '
                + 'taken from the busiest one.'));
        }

        me.PERF_GROUPS.forEach(function(g) {
            let rows = g.metrics.filter(function(m) { return stats[m.k] !== undefined; });
            if (!rows.length) { return; }
            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext(g.label))}</div>`);
            h.push('<div class="fs-tiles">');
            rows.forEach(function(m) {
                let s = stats[m.k];
                h.push('<div class="fs-tile">'
                    + `<div class="fs-tile-l">${e(gettext(m.l))}</div>`
                    + `<div class="fs-tile-v">${me.num(s.current)}`
                        + (m.u ? `<small>${e(m.u)}</small>` : '') + '</div>'
                    + '<div class="fs-tile-p">'
                        + (s.peak === undefined || s.peak === null
                            ? '&nbsp;'
                            : `${e(gettext('peak'))} ${me.num(s.peak)}`
                              + (s.peak_time ? ` &middot; ${me.stampTime(s.peak_time)}` : ''))
                    + '</div>'
                    + (g.spark ? me.sparkline(hist[m.k]) : '')
                    + '</div>');
            });
            h.push('</div></div>');
        });

        // Per-canister. An imbalance here is the clearest single signal that
        // one node is the bottleneck rather than the array as a whole.
        if (nodeRows.length) {
            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext('Nodes'))}</div>`);
            h.push('<table class="fs-tbl"><thead><tr>'
                + `<th>${e(gettext('Canister'))}</th>`
                + `<th class="fs-num">${e(gettext('CPU'))}</th>`
                + `<th class="fs-num">${e(gettext('Cache'))}</th>`
                + `<th class="fs-num">${e(gettext('Write cache'))}</th>`
                + `<th class="fs-num">${e(gettext('Latency'))}</th>`
                + `<th class="fs-num">${e(gettext('IOPS'))}</th>`
                + '</tr></thead><tbody>');
            nodeRows.forEach(function(n) {
                let st = n.stats || {};
                let cell = function(k, unit) {
                    let v = st[k];
                    return v === undefined || v.current === undefined || v.current === null
                        ? '<span class="fs-dim">&ndash;</span>'
                        : me.num(v.current) + (unit || '');
                };
                h.push('<tr>'
                    + `<td><b>${e(n.node)}</b></td>`
                    + `<td class="fs-num">${cell('cpu_pc', '%')}</td>`
                    + `<td class="fs-num">${cell('total_cache_pc', '%')}</td>`
                    + `<td class="fs-num">${cell('write_cache_pc', '%')}</td>`
                    + `<td class="fs-num">${cell('vdisk_ms')}</td>`
                    + `<td class="fs-num">${cell('vdisk_io')}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        // Throttles are a CONFIGURED cap, not a symptom — which makes them
        // the one "why is this slow" answer the array can give outright.
        let thr = d.throttles;
        if (thr && thr.total) {
            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext('Throttles'))}</div>`);
            h.push('<table class="fs-tbl"><thead><tr>'
                + `<th>${e(gettext('Object'))}</th><th>${e(gettext('Type'))}</th>`
                + `<th class="fs-num">${e(gettext('IOPS limit'))}</th>`
                + `<th class="fs-num">${e(gettext('Bandwidth'))}</th>`
                + '</tr></thead><tbody>');
            (thr.throttles || []).forEach(function(t) {
                h.push('<tr>'
                    + `<td>${e(t.object_name || t.throttle_name || '')}</td>`
                    + `<td class="fs-muted">${e(t.throttle_type || '')}</td>`
                    + '<td class="fs-num">'
                        + (t.IOPs_limit ? me.num(t.IOPs_limit) : '<span class="fs-dim">&ndash;</span>')
                    + '</td>'
                    + '<td class="fs-num">'
                        + (t.bandwidth_limit_MB
                            ? me.num(t.bandwidth_limit_MB) + ' MB/s'
                            : '<span class="fs-dim">&ndash;</span>')
                    + '</td></tr>');
            });
            h.push('</tbody></table>'
                + `<div class="fs-note">${me.icon('info')}`
                + e(gettext('Throttle limits are per node, so the effective ceiling is '
                    + 'higher than the figure shown.')) + '</div></div>');
        }

        notes.forEach(function(n) {
            h.push(`<div class="fs-note">${me.icon('info')}${e(n)}</div>`);
        });

        if (d.errors) {
            h.push(`<div class="fs-note fs-warn">${me.icon('warn')}`
                + e(gettext('Sections unavailable')) + ': '
                + e(Object.keys(d.errors).join(', ')) + '</div>');
        }
        return h.join('');
    },
});

// ---------------------------------------------------------------------------
// LOCAL PATCH (datacenter overview, see UPSTREAM.md section 3): a "FlashSystem"
// entry in the Datacenter menu beside Ceph, aggregating every flashsystem
// storage in the cluster — array identity, per-pool capacity, which storages
// share each pool, ranked volume/guest consumption, FC ports, unfixed array
// alerts and array performance.
//
// Fed by TWO endpoints per array, /overview and /performance, each
// de-duplicated server-side: one request per array per section, and the array
// itself sees each fact fetched once rather than once per storage. They paint
// into separate targets so a slow statistics call cannot hold up the capacity
// view.
//
// The small formatters are duplicated from the health panel on purpose — that
// panel is validated in production and not worth refactoring for a dozen
// lines. The larger new sections live in PVE.FlashSystemUI above instead.
// ---------------------------------------------------------------------------

Ext.define('PVE.dc.FlashSystemOverview', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveDcFlashSystemOverview',

    scrollable: true,
    layout: 'anchor',

    // Two independent render targets, not one. Capacity and performance are
    // separate endpoints with separate deadlines precisely so a slow
    // lssystemstats cannot delay the pool capacity people came to read — and
    // that only pays off if the panel paints them independently too.
    // anchor:'100%' on both — an anchor layout leaves an unanchored child at
    // its natural width, which for a bare component is its content's width.
    defaults: { xtype: 'component', anchor: '100%' },
    items: [
        { itemId: 'caps', padding: '15 15 0 15',
          html: '<div>' + gettext('Loading...') + '</div>' },
        { itemId: 'perf', padding: 15, html: '' },
    ],

    tbar: [
        {
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('panel').reload();
            },
        },
    ],

    esc: Ext.htmlEncode,

    fmtBytes: function(v) {
        if (v === undefined || v === null) { return '-'; }
        return Proxmox.Utils.format_size(v);
    },

    fmtEventTime: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t || ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    setHtml: function(itemId, html) {
        let c = this.down('#' + itemId);
        if (c) { c.update(html); }
    },

    // Any online node will do — the endpoint is proxied to it and the data is
    // array-wide, not node-specific.
    anyNode: function() {
        let found;
        try {
            PVE.data.ResourceStore.each(function(rec) {
                if (!found && rec.data.type === 'node' && rec.data.status === 'online') {
                    found = rec.data.node;
                }
                return !found;
            });
        } catch (err) {
            // ignore — fall through to the Proxmox global below
        }
        if (!found && typeof Proxmox !== 'undefined' && Proxmox.NodeName
            && Proxmox.NodeName !== 'localhost') {
            found = Proxmox.NodeName;
        }
        return found;
    },

    renderArray: function(d, arrIdx) {
        let me = this;
        let e = me.esc;
        let UI = PVE.FlashSystemUI;
        let h = [];
        if (!d || d.error) {
            // d.error is response.htmlStatus, already encoded by the toolkit.
            return '<div class="fs-root"><div class="fs-err" style="margin-bottom:18px;">'
                + ((d && d.error) || e(gettext('Query failed'))) + '</div></div>';
        }
        UI.ensureStyles();
        let sys = d.system || {};

        h.push('<div class="fs-root"><div class="fs-array">');
        h.push(`<div class="fs-title">${e(sys.name || d.array || 'FlashSystem')}</div>`);
        let sub = [];
        if (sys.product_name) { sub.push(e(sys.product_name)); }
        if (sys.code_level) { sub.push(e(gettext('Firmware')) + ' ' + e(sys.code_level)); }
        if (d.array) { sub.push(e(d.array)); }
        h.push(`<div class="fs-sub">${sub.join(' &middot; ')}</div>`);

        // Array-wide facts on one status line each.
        h.push('<div class="fs-status">');
        if (d.ports) {
            let ok = d.ports.active === d.ports.total;
            h.push('<span>' + UI.icon(ok ? 'ok' : 'warn')
                + `${d.ports.active} / ${d.ports.total} ${e(gettext('FC ports active'))}</span>`);
        }
        if (d.events) {
            let alerts = d.events.alerts || 0;
            h.push('<span>'
                + (alerts === 0
                    ? UI.icon('ok') + e(gettext('No unfixed alerts'))
                    : UI.icon('crit') + `<b>${alerts}</b> ${e(gettext('unfixed alerts'))}`)
                // Only shown when the whole unfixed log was fetched. Under the
                // server-side alert filter the informational events are not in
                // the payload, and printing 0 would claim there are none.
                + (d.events.unfixed_total === undefined
                    ? ''
                    : ` <span class="fs-muted">(${d.events.unfixed_total} `
                      + `${e(gettext('events array-wide, incl. informational'))})</span>`)
                + '</span>');
        }
        h.push('</div>');

        (d.events && d.events.recent ? d.events.recent : []).forEach(function(ev) {
            h.push('<div class="fs-ev">'
                + `${e(me.fmtEventTime(ev.last_timestamp))} &nbsp; `
                + `<b class="fs-crit">${e(ev.error_code || '')}</b> ${e(ev.description || '')}`
                + (ev.object_name ? ` <span class="fs-dim">(${e(ev.object_name)})</span>` : '')
                + '</div>');
        });

        // one card per pool, listing the storages that share it
        (d.pools || []).forEach(function(p, poolIdx) {
            let c = p.capacity || {};
            let known = c.provision_total !== undefined;
            let pct = known ? (c.provision_used_pct || 0) : 0;
            let v = pct >= 90 ? 'var(--fs-crit)' : (pct >= 75 ? 'var(--fs-warn)' : 'var(--fs-ok)');
            h.push('<div class="fs-card">');
            h.push('<div class="fs-card-h">'
                + `<b>${e(p.pool || '')}</b>`
                + '<span class="fs-muted">'
                + (known ? `${pct}% ${e(gettext('of physical'))}` : e(gettext('capacity unavailable')))
                + (c.data_reduction === 'yes'
                    ? `<span class="fs-pill">${e(gettext('data reduction'))}</span>` : '')
                + '</span></div>');
            h.push(`<div class="fs-bar"><i style="width:${Math.min(pct, 100)}%;background:${v};"></i></div>`);
            h.push('<div class="fs-muted" style="font-size:12px;margin:5px 0 0;">'
                + (known
                    ? `${UI.bytes(c.provision_used)} / ${UI.bytes(c.provision_total)} `
                      + `&middot; ${UI.bytes(c.provision_free)} ${e(gettext('free'))}`
                    : UI.icon('info') + e(gettext('capacity unavailable')))
                + ' &middot; '
                + (p.pool_volumes === undefined
                    ? e(gettext('volume count unavailable'))
                    : `${p.pool_volumes} ${e(gettext('volumes in pool'))}`)
                + '</div>');

            h.push(`<div class="fs-sec"><div class="fs-sec-h">${e(gettext('Storages'))}</div>`);
            h.push('<table class="fs-tbl fs-w100"><tbody>');
            (p.storages || []).forEach(function(st) {
                h.push('<tr>'
                    + `<td><b>${e(st.storage)}</b></td>`
                    + '<td class="fs-muted">'
                        + (st.prefix
                            ? e(st.prefix)
                            : UI.icon('warn') + e(gettext('no prefix')))
                    + '</td>'
                    + '<td class="fs-num">'
                        + (st.volumes === undefined
                            ? '<span class="fs-dim">&ndash;</span>'
                            : `${Number(st.volumes) || 0} ${e(gettext('vols'))}`)
                    + '</td>'
                    + '<td class="fs-num">'
                        + (st.provisioned === undefined
                            ? '<span class="fs-dim">&ndash;</span>'
                            : UI.bytes(st.provisioned))
                    + '</td>'
                    + '<td class="fs-muted">'
                        + e(st.thin ? gettext('thin') : gettext('thick'))
                        + (st.snapshots ? `<span class="fs-pill">${e(gettext('snapshots'))}</span>` : '')
                    + '</td></tr>');
            });
            h.push('</tbody></table></div>');

            // Ranked consumers — what is actually occupying this pool.
            if (p.top) {
                h.push(UI.renderTop(p.top, `a${arrIdx}p${poolIdx}`,
                    (me.sortState || {})[`a${arrIdx}p${poolIdx}`]));
            }
            h.push('</div>');
        });

        if (d.errors) {
            h.push(`<div class="fs-note fs-warn">${UI.icon('warn')}`
                + e(gettext('Sections unavailable')) + ': '
                + e(Object.keys(d.errors).join(', ')) + '</div>');
        }
        h.push('</div></div>');
        return h.join('');
    },

    renderPerfBlock: function(d, i) {
        let e = this.esc;
        let sys = (d && d.system) || {};
        let title = sys.name || (d && d.array) || `FlashSystem ${i + 1}`;
        PVE.FlashSystemUI.ensureStyles();
        return '<div class="fs-root"><div class="fs-array">'
            + `<div class="fs-title">${e(title)} &mdash; ${e(gettext('Performance'))}</div>`
            + `<div class="fs-sub">`
            + e(gettext('Array-wide. Peak values cover the last five minutes.')) + '</div>'
            + PVE.FlashSystemUI.renderPerformance(d)
            + '</div></div>';
    },

    // Re-render one target from cached data — used both when a fetch lands
    // and when a column header changes the sort.
    repaint: function(which) {
        let me = this;
        let reps = me.fsReps || [];
        if (which === 'caps') {
            let data = me.capsData || [];
            me.setHtml('caps', reps.map(function(_, i) { return me.renderArray(data[i], i); }).join(''));
        } else {
            let data = me.perfData || [];
            me.setHtml('perf', reps.map(function(_, i) { return me.renderPerfBlock(data[i], i); }).join(''));
        }
    },

    // One request per array per section. NB: Proxmox.Utils.API2Request invokes
    // `callback` BEFORE success/failure, so counting down there renders with
    // the data still unassigned — on a single-array cluster that is a
    // permanently blank panel. Count down inside both handlers.
    fanout: function(node, reps, subpath, cacheKey, which) {
        let me = this;
        let out = [];
        let pending = reps.length;
        let done = function() {
            pending--;
            if (pending > 0) { return; }
            me[cacheKey] = out;
            me.repaint(which);
        };
        reps.forEach(function(st, i) {
            Proxmox.Utils.API2Request({
                url: `/nodes/${node}/flashsystem/${encodeURIComponent(st)}/${subpath}`,
                method: 'GET',
                success: function(r) { out[i] = r.result.data; done(); },
                failure: function(r) { out[i] = { error: r.htmlStatus }; done(); },
            });
        });
    },

    reload: function() {
        let me = this;
        let node = me.anyNode();
        if (!node) {
            me.setHtml('caps', '<div class="fs-root">' + gettext('No online node found.') + '</div>');
            me.setHtml('perf', '');
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${node}/flashsystem`,
            method: 'GET',
            waitMsgTarget: me,
            failure: function(response) {
                me.setHtml('caps', '<div class="fs-root fs-err">'
                    + (response.htmlStatus || Ext.htmlEncode(gettext('Query failed'))) + '</div>');
                me.setHtml('perf', '');
            },
            success: function(response) {
                let list = response.result.data || [];
                if (!list.length) {
                    me.setHtml('caps', '<div class="fs-root">' + gettext('No FlashSystem storages are configured.') + '</div>');
                    me.setHtml('perf', '');
                    return;
                }
                // One representative storage per array: both endpoints are
                // array-wide, so querying every storage would repeat itself.
                let seen = Object.create(null);
                let reps = [];
                list.forEach(function(s) {
                    let key = s.address || '_';
                    if (!seen[key]) { seen[key] = true; reps.push(s.storage); }
                });
                me.fsReps = reps;
                me.setHtml('perf', '<div class="fs-root fs-muted">' + gettext('Loading...') + '</div>');
                me.fanout(node, reps, 'overview', 'capsData', 'caps');
                me.fanout(node, reps, 'performance', 'perfData', 'perf');
            },
        });
    },

    listeners: {
        activate: function() {
            this.reload();
        },
        // Delegated so the tables stay plain HTML. Sorting is a convenience:
        // the server already returns highest-first, so a handler that never
        // fires costs nothing.
        click: {
            element: 'body',
            fn: function(ev) {
                let me = this;
                let el = ev.getTarget('[data-fssort]', 6);
                if (!el) { return; }
                let key = el.getAttribute('data-fssort');
                let tid = el.getAttribute('data-fstable');
                if (!key || !tid) { return; }
                me.sortState = me.sortState || {};
                let cur = me.sortState[tid];
                me.sortState[tid] = (cur && cur.key === key)
                    ? { key: key, dir: cur.dir === 'asc' ? 'desc' : 'asc' }
                    : { key: key, dir: 'desc' };
                me.repaint('caps');
            },
        },
    },
});
