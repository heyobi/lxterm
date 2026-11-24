// LxTerm's accelerated engine, in a worker of a hidden WKWebView (lxios/LxTerm/WebEngine.swift):
// the core built for WebAssembly (lxweb.js, with its translator to WebAssembly) runs Debian;
// every ⚡ tab is a session of this one core. The root file system is BLOCKFS
// (lxios/webjs/blockfs.js): file contents in a disk image in the Origin Private File System,
// the tree in memory, saved when the app asks (it goes to the background) and every 15 s
// while something changed. The terminals, the network and /root/Files reach the app over
// lx://host/ (tty, net, fs) with synchronous requests.
'use strict';
importScripts('lxweb.js');

let M = null, ttySeq = 0, handles = null;

// tar entries from a stream of chunks, written into the file system as they come
async function untarStream(FS, reader, root) {
    const dec = new TextDecoder();
    let buf = new Uint8Array(0), longName = null, files = 0;
    const links = [];
    const need = async n => {                                      /* at least n bytes in buf, or false at the end */
        while (buf.length < n) {
            const { value, done } = await reader.read();
            if (done) return false;
            const b = new Uint8Array(buf.length + value.length);
            b.set(buf); b.set(value, buf.length); buf = b;
        }
        return true;
    };
    const str = (a, o, n) => { let e = o; while (e < o + n && a[e]) e++; return dec.decode(a.subarray(o, e)); };
    const oct = (a, o, n) => parseInt(str(a, o, n).trim() || '0', 8);
    for (;;) {
        if (!(await need(512))) break;
        const h = buf.subarray(0, 512);
        if (h[0] === 0 && h[1] === 0) break;
        let name = str(h, 0, 100);
        const prefix = str(h, 345, 155);
        if (prefix && str(h, 257, 5) === 'ustar') name = prefix + '/' + name;
        const mode = oct(h, 100, 8), size = oct(h, 124, 12), type = String.fromCharCode(h[156] || 48), link = str(h, 157, 100);
        const padded = Math.ceil(size / 512) * 512;
        buf = buf.subarray(512);
        if (type === 'L') {
            await need(padded); longName = str(buf, 0, size); buf = buf.subarray(padded); continue;
        }
        if (longName) { name = longName; longName = null; }
        name = name.replace(/^\.\//, '').replace(/\/$/, '');
        const path = root + '/' + name;
        const skip = !name || name === '.';
        if (!skip) { try { FS.mkdirTree(path.slice(0, path.lastIndexOf('/'))); } catch (e) {} }
        if (type === '0' || type === '7') {
            let fd = null;
            if (!skip) { try { fd = FS.open(path, 'w', mode & 4095); } catch (e) {} }
            let left = size;
            while (left > 0) {                                     /* the contents in pieces: never a whole big file in memory */
                if (!buf.length && !(await need(1))) break;
                const n = Math.min(left, buf.length);
                if (fd) FS.write(fd, buf, 0, n);
                buf = buf.subarray(n); left -= n;
            }
            if (fd) { FS.close(fd); try { FS.chmod(path, mode & 4095); } catch (e) {} files++; }
            const pad = padded - size;
            if (pad) { await need(pad); buf = buf.subarray(pad); }
            continue;
        }
        if (padded) { await need(padded); buf = buf.subarray(padded); }
        if (skip) continue;
        try {
            if (type === '5') { try { FS.mkdir(path); } catch (e) {} FS.chmod(path, mode & 4095); }
            else if (type === '2') FS.symlink(link, path);
            else if (type === '1') links.push([root + '/' + link.replace(/^\.\//, ''), path]);
        } catch (e) {}
    }
    for (const [from, to] of links) { try { FS.writeFile(to, FS.readFile(from)); FS.chmod(to, FS.stat(from).mode); } catch (e) {} }
    return files;
}

async function streamOf(name, gz) {
    try {
        const res = await fetch(name);
        if (!res.ok || !res.body) return null;
        return (gz ? res.body.pipeThrough(new DecompressionStream('gzip')) : res.body).getReader();
    } catch (e) { return null; }
}

function save(force) {
    if (!M || !M.BLOCKFS) return;
    try { M.BLOCKFS.save(force); } catch (e) { postMessage({ log: 'save: ' + e }); }
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
    if (x.getResponseHeader('X-Save')) save(true);
    else if (M && M.BLOCKFS && M.BLOCKFS.dirty() && M.BLOCKFS.sinceSave() > 15000) save(false);
    const s = x.responseText;
    if (!s.length) return null;
    const r = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) r[i] = s.charCodeAt(i) & 255;
    return r;
}

async function openHandles(fresh) {
    const dir = await navigator.storage.getDirectory();
    if (fresh) for (const n of ['root.img', 'root.meta0', 'root.meta1', 'root.tar']) { try { await dir.removeEntry(n); } catch (e) {} }
    const h = async n => (await dir.getFileHandle(n, { create: true })).createSyncAccessHandle();
    const r = { dir, img: await h('root.img'), metas: [await h('root.meta0'), await h('root.meta1')], old: null };
    try {                                                          /* the earlier format: the whole root as one tar */
        const t = await (await dir.getFileHandle('root.tar')).createSyncAccessHandle();
        if (t.getSize() > 1024) r.old = t; else { t.close(); await dir.removeEntry('root.tar'); }
    } catch (e) {}
    return r;
}

onmessage = async e => {
    if (!e.data.start) return;
    let rc = 0;
    try {
        handles = await openHandles(e.data.fresh);
        M = await createLx({
            print: s => {}, printErr: s => { if (e.data.debug) postMessage({ log: s }); }, lxPollMulti,
            preRun: [m => { m.ENV.TERM = 'xterm-256color'; m.ENV.LXRUN_QUIET = '1'; m.ENV.LANG = 'C.UTF-8';
                            m.ENV.LXRUN_MULTI = '1'; m.ENV.LXRUN_SESSION = String(e.data.id || 0);
                            if (e.data.debug) { delete m.ENV.LXRUN_QUIET; m.ENV.LXRUN_DEBUG = '2'; } }],
        });
        const FS = M.FS;
        FS.mkdir('/r');
        FS.mount(M.BLOCKFS, { img: handles.img, metas: handles.metas }, '/r');
        if (FS.readdir('/r').length <= 2) {                        /* nothing saved yet: fill it */
            const t0 = performance.now();
            let reader = null, from = '', files = 0;
            if (handles.old) {                                     /* the old tar is moved over, then dropped */
                const old = handles.old, size = old.getSize();
                let at = 0;
                reader = { read: async () => {
                    if (at >= size) return { done: true };
                    const n = Math.min(1 << 20, size - at), b = new Uint8Array(n);
                    old.read(b, { at }); at += n;
                    return { value: b, done: false };
                } };
                from = 'saved copy';
                files = await untarStream(FS, reader, '/r');
            }
            if (files < 100) { reader = await streamOf('native-root.tar', false); from = 'native engine'; files = reader ? await untarStream(FS, reader, '/r') : 0; }
            if (files < 100) { reader = await streamOf('rootfs-debian.tar.gz', true); from = 'app'; files = await untarStream(FS, reader, '/r'); }
            save(true);
            if (handles.old) { handles.old.close(); try { await handles.dir.removeEntry('root.tar'); } catch (err) {} }
            postMessage({ log: 'root from the ' + from + ': ' + files + ' files in ' + ((performance.now() - t0) / 1000).toFixed(1) + ' s' });
        }
        try {                                                      /* the bridge answers any nameserver */
            const rcf = FS.readFile('/r/etc/resolv.conf', { encoding: 'utf8' });
            if (!/nameserver/.test(rcf)) throw 0;
        } catch (err) { try { FS.writeFile('/r/etc/resolv.conf', 'nameserver 10.0.2.3\n'); } catch (e2) {} }
        if (M.BRIDGEFS) { try { FS.mkdirTree('/r/root/Files'); FS.mount(M.BRIDGEFS, {}, '/r/root/Files'); } catch (err) {} }
        postMessage({ started: true });
        postMessage({ log: 'blockfs ' + JSON.stringify(M.BLOCKFS.stats()) });
        try { rc = M.callMain(['-i', '/r', '/bin/bash', '-l']); } catch (err) { rc = err && err.status !== undefined ? err.status : 1; }
        save(true);
    } catch (err) {
        postMessage({ error: String(err && err.stack || err) });
    }
    postMessage({ done: rc });
};
