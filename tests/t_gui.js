#!/usr/bin/env node
//
// Unit tests for the render helpers in flashsystem-gui.js.
//
// The GUI is where two of the six defects found in adversarial review lived,
// and both were of the same kind: data the API computed, returned and
// unit-tested, which the renderer then never looked at. A Perl test cannot
// catch that. So this stubs just enough of ExtJS/Proxmox to load the real file
// and execute the real render functions against fixtures.
//
// Run: run.sh in this directory (skipped when node is unavailable).

'use strict';
const fs = require('fs');
const path = require('path');

// ---- minimal ExtJS / Proxmox / PVE stubs ----------------------------------
const nsSet = (root, dotted, value) => {
    const parts = dotted.split('.');
    let o = root;
    for (const p of parts.slice(0, -1)) { o = o[p] = o[p] || {}; }
    o[parts[parts.length - 1]] = value;
};

global.gettext = (s) => s;

global.Ext = {
    isObject: (o) => o !== null && typeof o === 'object' && !Array.isArray(o),
    htmlEncode: (s) => String(s === undefined || s === null ? '' : s)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;'),
    define: function (name, cfg) {
        // Overrides target classes we do not model; recording is enough.
        if (cfg && cfg.override) { return; }
        // Singletons are the only thing these tests execute, so only those
        // need to become real objects.
        nsSet(global, name, cfg && cfg.singleton ? Object.assign({}, cfg) : cfg);
    },
};

global.Proxmox = {
    Utils: {
        format_size: (v) => {
            const n = Number(v);
            if (!isFinite(n)) { return '-'; }
            const u = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
            let i = 0, x = n;
            while (x >= 1024 && i < u.length - 1) { x /= 1024; i++; }
            return `${Math.round(x * 100) / 100} ${u[i]}`;
        },
        API2Request: () => {},
    },
    NodeName: 'testnode',
};

// The resource store is what turns a VMID into something an operator can act
// on; the join is the point, so it must be exercised.
global.PVE = {
    Utils: { storageSchema: {} },
    data: {
        ResourceStore: {
            each: (fn) => {
                [
                    { data: { type: 'qemu', vmid: 124, name: 'web-prod-01', node: 'pve-node-1' } },
                    { data: { type: 'lxc', vmid: 900, name: 'log-shipper', node: 'pve-node-2' } },
                    { data: { type: 'node', vmid: undefined, node: 'pve-node-0', status: 'online' } },
                ].forEach((r) => fn(r));
            },
        },
    },
};

// ---- load the real file ---------------------------------------------------
const candidates = [
    path.join(__dirname, '..', 'files', 'flashsystem-gui.js'),
    path.join(__dirname, '..', 'gui', 'flashsystem-gui.js'),
];
const src = candidates.find((p) => fs.existsSync(p));
if (!src) { console.error('flashsystem-gui.js not found'); process.exit(1); }
// eslint-disable-next-line no-eval
eval(fs.readFileSync(src, 'utf8'));

const UI = global.PVE.FlashSystemUI;
if (!UI || typeof UI.renderTop !== 'function') {
    console.error('PVE.FlashSystemUI did not load');
    process.exit(1);
}

let fail = 0;
const ok = (name, got, want) => {
    const good = got === want;
    console.log(`${name.padEnd(46)} ${String(got).padEnd(10)} ${good ? 'ok' : 'FAIL want=' + want}`);
    if (!good) { fail++; }
};
const has = (name, html, needle, want = true) =>
    ok(name, html.includes(needle), want);

// ---- attention rows must render, regardless of size ----------------------
// Both cases that review proved invisible: a small offline volume that never
// makes the top ten, and fast_write_state=corrupt arriving WITH status online,
// which the status column alone displays as perfectly healthy.
{
    const top = {
        volumes: [{ name: 'vm-124-disk-0', vmid: 124, storage: 'Gold', capacity: 2199023255552 }],
        vms: [],
        attention: [
            { name: 'vm-900-disk-0', vmid: 900, storage: 'Gold', capacity: 34359738368, status: 'offline' },
            { name: 'vm-500-disk-0', vmid: 500, storage: 'Gold', capacity: 1073741824,
              status: 'online', fast_write_state: 'corrupt' },
        ],
        attention_total: 2,
        ours: { count: 3, capacity: 1 },
        foreign: { count: 0, capacity: 0, volumes: [] },
    };
    const html = UI.renderTop(top, 't1', undefined);
    has('attention: offline volume shown', html, 'vm-900-disk-0');
    has('attention: offline flagged', html, 'offline');
    has('attention: corrupt volume shown', html, 'vm-500-disk-0');
    has('attention: corrupt flagged', html, 'corrupt');
    has('attention: names the remedy', html, 'needs recovervdisk');
    has('attention: heading present', html, 'Needs attention');
    // The VM-name join is the reason any of this is actionable.
    has('attention: vm name joined', html, 'log-shipper');
    has('ranking: vm name joined', html, 'web-prod-01');
    has('ranking: node joined', html, 'pve-node-1');
}

// ---- siblings are ours, tenants are not ----------------------------------
{
    const html = UI.renderTop({
        volumes: [], vms: [], attention: [], attention_total: 0,
        ours: { count: 1, capacity: 100 },
        siblings: { count: 2, capacity: 500 },
        foreign: { count: 1, capacity: 900, volumes: [{ capacity: 900 }] },
    }, 't2', undefined);
    has('siblings: labelled as ours', html, 'Other storages of this cluster in the same pool');
    has('siblings: tenant bucket distinct', html, 'Not managed by this cluster');
    ok('siblings: unnamed tenant not printed', html.includes('VMWARE'), false);
}

// ---- fill: DRP must explain itself, never draw an empty bar --------------
{
    const drp = UI.renderTop({
        volumes: [{ name: 'vm-1-disk-0', vmid: 1, storage: 'Gold', capacity: 100 }],
        vms: [], attention: [], attention_total: 0,
        ours: { count: 1, capacity: 100 },
        foreign: { count: 0, capacity: 0, volumes: [] },
        fill: { available: 0, reason: 'data-reduction-pool' },
    }, 't3', undefined);
    has('fill: DRP explained', drp, 'data reduction pool');

    // autoexpand off measures against ALLOCATED - reaching 100% there takes
    // the volume offline, so the basis has to be on screen.
    const thin = UI.renderTop({
        volumes: [{ name: 'vm-2-disk-0', vmid: 2, storage: 'Gold', capacity: 107374182400,
                    thin: 1, used: 9126805504, fill_pct: 85, fill_basis: 'allocated' }],
        vms: [], attention: [], attention_total: 0,
        ours: { count: 1, capacity: 1 },
        foreign: { count: 0, capacity: 0, volumes: [] },
        fill: { available: 1, copies: 1, measured: 1 },
    }, 't4', undefined);
    has('fill: percentage rendered', thin, '85%');
    has('fill: basis stated', thin, 'of allocated');
}

// ---- sparklines: the history keys must match what the panel draws --------
// This is the defect where the API requested vdisk_io/mb/ms while every
// sparkline row looked up vdisk_r_io/w_io/... - an empty intersection, so the
// column was blank on every array and firmware.
{
    const sparkGroup = UI.PERF_GROUPS.find((g) => g.spark);
    ok('spark: exactly one spark group', !!sparkGroup, true);
    const wanted = sparkGroup.metrics.map((m) => m.k);
    // Mirror the series the API actually asks for.
    const requested = 'vdisk_r_io:vdisk_w_io:vdisk_r_mb:vdisk_w_mb:vdisk_r_ms:vdisk_w_ms'.split(':');
    const missing = wanted.filter((k) => !requested.includes(k));
    ok('spark: every drawn series is requested', missing.join(',') || 'none', 'none');

    const hist = {};
    requested.forEach((k) => { hist[k] = [1, 5, 3, 9, 4]; });
    const stats = {};
    wanted.forEach((k) => { stats[k] = { current: 10, peak: 20, peak_time: '260826104304' }; });
    const html = UI.renderPerformance({ performance: { stats }, history: hist });
    has('spark: svg emitted', html, '<svg');
    has('spark: polyline emitted', html, 'polyline');
    ok('spark: no NaN coordinates', html.includes('NaN'), false);
    // Peaks cover the last five minutes, so the tile prints the time alone -
    // the date is always today, and printing it overflowed the tile.
    has('perf: peak time is time-only', html, '10:43:04');
    ok('perf: peak time drops the date', html.includes('2026-08-26 10:43:04'), false);
    // The event log keeps the full stamp, where the date is real information.
    ok('perf: full stamp still available', UI.stamp('260826104304'), '2026-08-26 10:43:04');
    // RESOLVED 2026-09-15 by IBM, from array output rather than documentation:
    // the *_ms statistics are MILLISECONDS. On 9.1.0.2, mdisk_ms 10.103 is
    // 10.103 ms and drive_ms 0.790 is 790 microseconds; on 8.3.1.10 the same
    // fields are integers at lower precision. IBM's 8.7 docs contradict
    // themselves (stat_name descriptions say microseconds, the attribute table
    // says milliseconds) and the attribute table is the correct one.
    //
    // These previously asserted the OPPOSITE - that no unit was shown and the
    // ambiguity was disclosed - which was right while it was unknown and is
    // wrong now. Guessing the unit is a 1000x error, so it stays pinned.
    has('perf: latency labelled in ms', html, 'Read latency (ms)');
    has('perf: write latency too',      html, 'Write latency (ms)');
    has('perf: note states the unit',   html, 'Latency is in milliseconds');
    ok('perf: no longer claims ambiguity',
        html.includes('microseconds or milliseconds'), false);
    // Long labels and values must not break the tile grid.
    has('perf: value uses tabular figures', html, 'fs-tile-v');
}

// ---- derived stats must say so, and must not deny live node data ---------
{
    const derived = UI.renderPerformance({
        performance: { derived: 1, stats: { cpu_pc: { current: 6, peak: 9 } } },
        nodes: { nodes: [{ node: 'node1', stats: { cpu_pc: { current: 5 } } }] },
    });
    has('derived: provenance disclosed', derived, 'derived from per-node statistics');
    has('derived: node table rendered', derived, 'node1');

    // Empty stats but live nodes: the panel must not claim nothing was
    // reported directly above a populated canister table.
    const partial = UI.renderPerformance({
        performance: { stats: {} },
        nodes: { nodes: [{ node: 'node1', stats: { cpu_pc: { current: 5 } } }] },
    });
    ok('partial: no false "nothing reported"',
        partial.includes('No performance statistics reported.'), false);
    has('partial: node data still shown', partial, 'node1');

    const nothing = UI.renderPerformance({ performance: { stats: {} } });
    has('empty: says nothing reported', nothing, 'No performance statistics reported.');
}

// ---- escaping: array-supplied text must be escaped exactly once ----------
{
    const html = UI.renderTop({
        volumes: [{ name: '<img src=x onerror=alert(1)>', vmid: 7, storage: 'G&old', capacity: 1 }],
        vms: [], attention: [], attention_total: 0,
        ours: { count: 1, capacity: 1 },
        foreign: { count: 1, capacity: 2, volumes: [{ name: '"><script>', capacity: 2 }] },
    }, 't5', undefined);
    ok('escape: no raw img tag', html.includes('<img src=x'), false);
    has('escape: name escaped once', html, '&lt;img src=x onerror=alert(1)&gt;');
    ok('escape: not double-escaped', html.includes('&amp;lt;'), false);
    has('escape: ampersand in storage id', html, 'G&amp;old');

    const thr = UI.renderPerformance({
        performance: { stats: {} },
        throttles: { total: 1, throttles: [{ object_name: '<b>x</b>', throttle_type: 'vdisk', IOPs_limit: '20' }] },
    });
    ok('escape: throttle name escaped', thr.includes('<b>x</b>'), false);
    has('escape: throttle name shown', thr, '&lt;b&gt;x&lt;/b&gt;');
}

// ---- sorting is a convenience, and must not corrupt the data -------------
{
    const rows = [
        { name: 'a', capacity: 100 }, { name: 'b', capacity: 300 },
        { name: 'c' },  // capacity absent - must sort last, not crash
    ];
    const desc = UI.sortRows(rows, 'capacity', 'desc');
    ok('sort: largest first', desc[0].name, 'b');
    ok('sort: undefined last', desc[2].name, 'c');
    ok('sort: input not mutated', rows[0].name, 'a');
    const asc = UI.sortRows(rows, 'capacity', 'asc');
    ok('sort: ascending', asc[0].name, 'a');
}


// ---- theme safety: no hardcoded light- or dark-only colours ---------------
// PVE ships both themes. The first cut of this panel hardcoded dark greys
// (#888 text, #2a2a2a bar tracks) while the older health panel hardcoded the
// opposite (#eee bar on #000 text) - each looked broken under the other
// theme. Text is currentColor plus opacity, and lines and fills are neutral
// rgba greys, so nothing here needs to know which theme is active.
{
    const fs = require('fs');
    const srcText = fs.readFileSync(src, 'utf8');
    // Strip comments before scanning: the rationale above quotes the old values.
    const code = srcText.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '');
    const hexes = [...new Set((code.match(/#[0-9a-fA-F]{6}\b/g) || []))];
    // The only absolute colours allowed are the four semantic tokens, which
    // are mid-tones chosen to carry on both grounds and used on icons and
    // bars rather than body text.
    const allowed = ['#3ba55d', '#c8860d', '#d9534f', '#4b8fc7'];
    const stray = hexes.filter((c) => !allowed.includes(c.toLowerCase()));
    ok('theme: no stray hardcoded colours', stray.join(',') || 'none', 'none');
    ok('theme: semantic tokens defined once',
        allowed.every((c) => code.includes(c)), true);
    // A literal grey text colour is the specific regression that made the
    // panel unreadable on the light theme.
    ok('theme: no literal grey text', /color:\s*#(888|666|999|ccc|eee)\b/.test(code), false);
    ok('theme: muted text is opacity-based', code.includes('.fs-muted{opacity:'), true);
}

console.log(fail ? `\n${fail} FAILURE(S)` : '\nall gui cases pass');
process.exit(fail ? 1 : 0);
