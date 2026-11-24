// LxTerm's accelerated engine, in a worker of a hidden WKWebView (lxios/LxTerm/WebEngine.swift):
// the core built for WebAssembly (lxweb.js, with its translator to WebAssembly) runs Debian's
// bash. The root file system lives in memory (MEMFS) and is kept in the Origin Private File
// System as one uncompressed tar (root.tar), saved when the app asks (it goes to the
// background, the shell ends). The terminal, the network and /root/Files reach the app over
// lx://host/ (tty, net, fs) with synchronous requests.
'use strict';
importScripts('lxweb.js');

let M = null, saveHandle = null, ttySeq = 0;

async function gunzipped(name) {
    const res = await fetch(name);
    const stream = res.body.pipeThrough(new DecompressionStream('gzip'));
    return new Uint8Array(await new Response(stream).arrayBuffer());
}

function untar(FS, tar, root) {
    const dec = new TextDecoder();
    const str = (o, n) => { let e = o; while (e < o + n && tar[e]) e++; return dec.decode(tar.subarray(o, e)); };
    const oct = (o, n) => parseInt(str(o, n).trim() || '0', 8);
    let off = 0, longName = null;
    const links = [];
    while (off + 512 <= tar.length) {
        if (tar[off] === 0 && tar[off + 1] === 0) break;
        let name = str(off, 100);
        const prefix = str(off + 345, 155);
        if (prefix && str(off + 257, 5) === 'ustar') name = prefix + '/' + name;
        const mode = oct(off + 100, 8), size = oct(off + 124, 12), type = String.fromCharCode(tar[off + 156] || 48);
        const link = str(off + 157, 100);
        const data = off + 512;
        off = data + Math.ceil(size / 512) * 512;
        if (type === 'L') { longName = str(data, size); continue; }
        if (longName) { name = longName; longName = null; }
        name = name.replace(/^\.\//, '').replace(/\/$/, '');
        if (!name || name === '.') continue;
        const path = root + '/' + name;
        try { FS.mkdirTree(path.slice(0, path.lastIndexOf('/'))); } catch (e) {}
        try {
            if (type === '5') { try { FS.mkdir(path); } catch (e) {} FS.chmod(path, mode); }
            else if (type === '2') FS.symlink(link, path);
            else if (type === '1') links.push([root + '/' + link.replace(/^\.\//, ''), path]);
            else if (type === '0' || type === '7') { FS.writeFile(path, tar.subarray(data, data + size)); FS.chmod(path, mode); }
        } catch (e) {}
    }
    for (const [from, to] of links) { try { FS.writeFile(to, FS.readFile(from)); FS.chmod(to, FS.stat(from).mode); } catch (e) {} }
}

// the root as an uncompressed tar, without the shared folder (it lives in the app)
function tarFS(FS, root, skip) {
    const enc = new TextEncoder(), chunks = [];
    let total = 0;
    const push = b => { chunks.push(b); total += b.length; };
    const header = (name, mode, size, type, link) => {
        const h = new Uint8Array(512);
        const put = (o, n, s) => h.set(enc.encode(s).subarray(0, n), o);
        const oct = (o, n, v) => put(o, n, v.toString(8).padStart(n - 1, '0') + '\0');
        put(0, 100, name); oct(100, 8, mode & 0o7777); oct(108, 8, 0); oct(116, 8, 0);
        oct(124, 12, size); oct(136, 12, Math.floor(Date.now() / 1000)); h.fill(32, 148, 156); h[156] = type.charCodeAt(0);
        put(157, 100, link || ''); put(257, 6, 'ustar\0'); put(263, 2, '00');
        let sum = 0; for (const b of h) sum += b;
        put(148, 8, sum.toString(8).padStart(6, '0') + '\0 ');
        return h;
    };
    const entry = (name, mode, data, type, link) => {
        const nb = enc.encode(name);
        if (nb.length > 99) {
            push(header('././@LongLink', 0o644, nb.length + 1, 'L'));
            const pad = new Uint8Array(Math.ceil((nb.length + 1) / 512) * 512); pad.set(nb); push(pad);
        }
        push(header(name, mode, data ? data.length : 0, type, link));
        if (data && data.length) { const pad = new Uint8Array(Math.ceil(data.length / 512) * 512); pad.set(data); push(pad); }
    };
    const walk = rel => {
        let names;
        try { names = FS.readdir(root + rel); } catch (e) { return; }
        for (const n of names) {
            if (n === '.' || n === '..') continue;
            const path = rel + '/' + n, full = root + path, name = path.slice(1);
            if (path === skip) { entry(name + '/', 0o755, null, '5'); continue; }
            let st;
            try { st = FS.lstat(full); } catch (e) { continue; }
            if (FS.isLink(st.mode)) entry(name, st.mode, null, '2', FS.readlink(full));
            else if (FS.isDir(st.mode)) { entry(name + '/', st.mode, null, '5'); walk(path); }
            else if (FS.isFile(st.mode)) { try { entry(name, st.mode, FS.readFile(full), '0'); } catch (e) {} }
        }
    };
    walk('');
    push(new Uint8Array(1024));
    const out = new Uint8Array(total);
    let o = 0; for (const c of chunks) { out.set(c, o); o += c.length; }
    return out;
}

function save() {
    if (!M || !saveHandle) return;
    try {
        const img = tarFS(M.FS, '/r', '/root/Files');
        saveHandle.truncate(0);
        saveHandle.write(img, { at: 0 });
        saveHandle.flush();
    } catch (e) {}
}

// the terminals' host turn (lxrun -i, several sessions: tools/lxrun.c): every tab's output to
// the app as frames ([u32 id][u32 length][bytes]) with titles and ended sessions in X-Meta;
// the answer is the keys (frames), X-Ctl (new, resized, closed sessions) and X-Save
function lxPollMulti(out, waitMs, meta) {
    let total = 0;
    for (const [, c] of out) total += 8 + c.length;
    const body = new Uint8Array(total), dv = new DataView(body.buffer);
    let o = 0;
    for (const [id, c] of out) { dv.setUint32(o, id, true); dv.setUint32(o + 4, c.length, true); body.set(c, o + 8); o += 8 + c.length; }
    const x = new XMLHttpRequest();
    x.open('POST', 'lx://host/tty?wait=' + waitMs + '&n=' + (++ttySeq), false);
    x.overrideMimeType('text/plain; charset=x-user-defined');
    if (meta) x.setRequestHeader('X-Meta', encodeURIComponent(meta));
    x.send(body);
    const ctl = x.getResponseHeader('X-Ctl');
    if (ctl && M) M.lxCtl = (M.lxCtl || '') + ctl;
    if (x.getResponseHeader('X-Save')) save();
    const s = x.responseText;
    if (!s.length) return null;
    const r = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) r[i] = s.charCodeAt(i) & 255;
    return r;
}

// the native engine's root (what the user installed before), or else the root in the app
async function firstRoot() {
    try {
        const res = await fetch('native-root.tar');
        const b = new Uint8Array(await res.arrayBuffer());
        if (b.length > 1024) return b;
    } catch (e) {}
    return gunzipped('rootfs-debian.tar.gz');
}

onmessage = async e => {
    if (!e.data.start) return;
    let rc = 0;
    try {
        const dir = await navigator.storage.getDirectory();
        const fh = await dir.getFileHandle('root.tar', { create: true });
        saveHandle = await fh.createSyncAccessHandle();         // opened now: saves happen inside the running shell
        let tar;
        if (saveHandle.getSize() > 0 && !e.data.fresh) {
            tar = new Uint8Array(saveHandle.getSize());
            saveHandle.read(tar, { at: 0 });
        } else tar = await firstRoot();
        M = await createLx({
            print: s => {}, printErr: s => {}, lxPollMulti,
            preRun: [m => { m.ENV.TERM = 'xterm-256color'; m.ENV.LXRUN_QUIET = '1'; m.ENV.LANG = 'C.UTF-8';
                            m.ENV.LXRUN_MULTI = '1'; m.ENV.LXRUN_SESSION = String(e.data.id || 0); }],
        });
        untar(M.FS, tar, '/r');
        tar = null;
        try {                                                      /* the bridge answers any nameserver */
            const rc = M.FS.readFile('/r/etc/resolv.conf', { encoding: 'utf8' });
            if (!/nameserver/.test(rc)) throw 0;
        } catch (err) { try { M.FS.writeFile('/r/etc/resolv.conf', 'nameserver 10.0.2.3\n'); } catch (e2) {} }
        if (M.BRIDGEFS) { try { M.FS.mkdirTree('/r/root/Files'); M.FS.mount(M.BRIDGEFS, {}, '/r/root/Files'); } catch (err) {} }
        postMessage({ started: true });
        try { rc = M.callMain(['-i', '/r', '/bin/bash', '-l']); } catch (err) { rc = err && err.status !== undefined ? err.status : 1; }
        save();
    } catch (err) {
        postMessage({ error: String(err && err.stack || err) });
    }
    postMessage({ done: rc });
};
