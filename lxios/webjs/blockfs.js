// The accelerated engine's root file system (linked with --post-js into lxweb.js): the tree
// (names, modes, sizes, links, block lists) lives in memory, the file contents in one disk
// image in the Origin Private File System (4 KiB blocks, read and written in place through a
// synchronous access handle). Memory holds only the tree and a small block cache, not the
// whole system, and a save writes only the tree (into one of two slots, the newer valid one
// wins), not every file again.
//
// Crash safety: blocks freed since the last save are not given out again until the next
// save, so the saved tree never points at blocks reused for something else; data written to
// a file's existing blocks may be newer than the saved tree, as on a disk without a journal.
(function () {
    if (typeof FS === 'undefined') return;
    var BS = 4096, CACHE_MAX = 4096;                               /* 16 MiB of cached blocks */
    var MAGIC = 0x4c584653;                                         /* 'LXFS' */
    var img = null, metas = [], gen = 0;
    var free = [], pendingFree = [], next = 0;                     /* block allocator */
    var cache = new Map();
    var dirty = false, lastSave = 0, root = null;
    var zero = new Uint8Array(BS);

    function now() { return Date.now(); }
    function err(n) { return new FS.ErrnoError(n); }

    function alloc() { dirty = true; return free.length ? free.pop() : next++; }
    function release(list) {
        for (var i = 0; i < list.length; i++) if (list[i] >= 0) { pendingFree.push(list[i]); cache.delete(list[i]); }
        dirty = true;
    }
    function readBlock(b) {                                        /* a cached copy of block b */
        var c = cache.get(b);
        if (c) { cache.delete(b); cache.set(b, c); return c; }
        c = new Uint8Array(BS);
        img.read(c, { at: b * BS });
        cache.set(b, c);
        if (cache.size > CACHE_MAX) cache.delete(cache.keys().next().value);
        return c;
    }

    function fileRead(node, buf, off, len, pos) {
        if (pos >= node.size) return 0;
        if (pos + len > node.size) len = node.size - pos;
        var done = 0;
        while (done < len) {
            var p = pos + done, bi = Math.floor(p / BS), o = p % BS, n = Math.min(BS - o, len - done), b = node.blocks[bi];
            if (b === undefined || b < 0) { buf.fill(0, off + done, off + done + n); done += n; continue; }
            if (o === 0 && n === BS && !cache.has(b)) {            /* whole blocks: straight into the buffer, runs at once */
                var run = 1;
                while (done + (run + 1) * BS <= len && node.blocks[bi + run] === b + run && !cache.has(b + run)) run++;
                img.read(buf.subarray(off + done, off + done + run * BS), { at: b * BS });
                done += run * BS;
                continue;
            }
            buf.set(readBlock(b).subarray(o, o + n), off + done);
            done += n;
        }
        return len;
    }

    function fileWrite(node, buf, off, len, pos) {
        var done = 0;
        while (done < len) {
            var p = pos + done, bi = Math.floor(p / BS), o = p % BS, n = Math.min(BS - o, len - done), b = node.blocks[bi];
            while (node.blocks.length < bi) node.blocks.push(-1);
            if (o === 0 && n === BS) {                              /* whole blocks: runs written at once */
                var run = 0;
                while (done + (run + 1) * BS <= len) {
                    var k = bi + run;
                    if (node.blocks[k] === undefined || node.blocks[k] < 0) node.blocks[k] = alloc();
                    if (run && node.blocks[k] !== node.blocks[bi] + run) break;
                    cache.delete(node.blocks[k]);
                    run++;
                }
                img.write(buf.subarray(off + done, off + done + run * BS), { at: node.blocks[bi] * BS });
                done += run * BS;
                continue;
            }
            var blk;
            if (b === undefined || b < 0) { b = node.blocks[bi] = alloc(); blk = new Uint8Array(BS); }
            else blk = readBlock(b).slice();
            blk.set(buf.subarray(off + done, off + done + n), o);
            img.write(blk, { at: b * BS });
            if (cache.has(b)) cache.set(b, blk);
            done += n;
        }
        if (pos + len > node.size) node.size = pos + len;
        node.mtime = now();
        dirty = true;
        return len;
    }

    function truncate(node, size) {
        var keep = Math.ceil(size / BS);
        if (node.blocks.length > keep) release(node.blocks.splice(keep));
        if (size < node.size && size % BS) {                       /* the rest of the last block reads as zeros */
            var b = node.blocks[keep - 1];
            if (b !== undefined && b >= 0) {
                var blk = readBlock(b).slice();
                blk.fill(0, size % BS);
                img.write(blk, { at: b * BS });
                cache.set(b, blk);
            }
        }
        node.size = size;
        node.mtime = now();
        dirty = true;
    }

    function drop(node) {                                          /* an unlinked file: its blocks go when nobody has it open */
        if (!FS.isFile(node.mode)) return;
        node.unlinked = true;
        if (!node.opens) { release(node.blocks); node.blocks = []; }
    }

    var B = {
        mount: function (mount) {
            img = mount.opts.img; metas = mount.opts.metas || [];
            root = B.createNode(null, '/', 16384 | 493, 0);
            if (!mount.opts.fresh) B.load(root);
            return root;
        },
        createNode: function (parent, name, mode, dev) {
            var node = FS.createNode(parent, name, mode, dev);
            node.node_ops = B.node_ops;
            node.stream_ops = B.stream_ops;
            node.mtime = now();
            if (FS.isDir(mode)) node.contents = {};
            else if (FS.isFile(mode)) { node.blocks = []; node.size = 0; node.opens = 0; }
            if (parent) { parent.contents[name] = node; parent.mtime = node.mtime; }
            dirty = true;
            return node;
        },
        node_ops: {
            getattr: function (node) {
                var t = new Date(node.mtime), size = FS.isDir(node.mode) ? 4096 : FS.isLink(node.mode) ? node.link.length : node.size;
                return { dev: 1, ino: node.id, mode: node.mode, nlink: 1, uid: 0, gid: 0, rdev: node.rdev, size: size,
                         atime: t, mtime: t, ctime: t, blksize: BS, blocks: Math.ceil(size / 512) };
            },
            setattr: function (node, attr) {
                if (attr.mode !== undefined && attr.mode !== null) node.mode = attr.mode;
                if (attr.timestamp !== undefined && attr.timestamp !== null) node.mtime = +attr.timestamp;
                if (attr.mtime !== undefined && attr.mtime !== null) node.mtime = +attr.mtime;
                if (attr.size !== undefined && attr.size !== null && FS.isFile(node.mode)) truncate(node, attr.size);
                dirty = true;
            },
            lookup: function (parent, name) {
                var n = parent.contents[name];
                if (!n) throw (FS.genericErrors && FS.genericErrors[44]) || err(44);
                return n;
            },
            mknod: function (parent, name, mode, dev) { return B.createNode(parent, name, mode, dev); },
            rename: function (old, newDir, newName) {
                var target = newDir.contents[newName];
                if (target && target !== old) {
                    if (FS.isDir(old.mode)) { for (var k in target.contents) throw err(55); }
                    else drop(target);
                    try { FS.hashRemoveNode(target); } catch (e) {}
                }
                delete old.parent.contents[old.name];
                old.parent.mtime = now();
                old.name = newName;
                newDir.contents[newName] = old;
                newDir.mtime = now();
                old.parent = newDir;
                dirty = true;
            },
            unlink: function (parent, name) {
                var n = parent.contents[name];
                delete parent.contents[name];
                parent.mtime = now();
                if (n) drop(n);
                dirty = true;
            },
            rmdir: function (parent, name) {
                var n = FS.lookupNode(parent, name);
                for (var k in n.contents) throw err(55);
                delete parent.contents[name];
                parent.mtime = now();
                dirty = true;
            },
            readdir: function (node) { return ['.', '..'].concat(Object.keys(node.contents)); },
            symlink: function (parent, name, target) {
                var n = B.createNode(parent, name, 511 | 40960, 0);
                n.link = target;
                return n;
            },
            readlink: function (node) {
                if (!FS.isLink(node.mode)) throw err(28);
                return node.link;
            },
        },
        stream_ops: {
            open: function (stream) { if (FS.isFile(stream.node.mode)) stream.node.opens++; },
            close: function (stream) {
                var n = stream.node;
                if (!FS.isFile(n.mode)) return;
                if (--n.opens <= 0) { n.opens = 0; if (n.unlinked) { release(n.blocks); n.blocks = []; } }
            },
            read: function (stream, buffer, offset, length, position) { return length ? fileRead(stream.node, buffer, offset, length, position) : 0; },
            write: function (stream, buffer, offset, length, position) { return length ? fileWrite(stream.node, buffer, offset, length, position) : 0; },
            llseek: function (stream, offset, whence) {
                var pos = offset;
                if (whence === 1) pos += stream.position;
                else if (whence === 2 && FS.isFile(stream.node.mode)) pos += stream.node.size;
                if (pos < 0) throw err(28);
                return pos;
            },
            allocate: function (stream, offset, length) {
                var n = stream.node;
                if (offset + length > n.size) { n.size = offset + length; dirty = true; }
            },
        },

        /* the tree: [type u8: 1 dir, 2 file, 3 link][mode u32][mtime f64][name u16 + bytes] then
         * dir: count u32 + entries; file: size f64, count u32, blocks i32...; link: u16 + bytes */
        save: function (force) {
            if (!root || !metas.length || (!dirty && !force)) return false;
            var enc = new TextEncoder(), parts = [], total = 0;
            function push(a) { parts.push(a); total += a.length; }
            function u32(v) { var a = new Uint8Array(4); new DataView(a.buffer).setUint32(0, v >>> 0, true); push(a); }
            function f64(v) { var a = new Uint8Array(8); new DataView(a.buffer).setFloat64(0, v, true); push(a); }
            function str(s) { var b = enc.encode(s), a = new Uint8Array(2); new DataView(a.buffer).setUint16(0, b.length, true); push(a); push(b); }
            function walk(node, name) {
                var t = FS.isDir(node.mode) ? 1 : FS.isFile(node.mode) ? 2 : FS.isLink(node.mode) ? 3 : 0;
                if (!t || node.mounted) {                         /* (a mount point, e.g. /root/Files: an empty directory) */
                    if (node.mounted) { push(new Uint8Array([1])); u32(16384 | 493); f64(node.mtime || now()); str(name); u32(0); }
                    return;
                }
                push(new Uint8Array([t])); u32(node.mode); f64(node.mtime || 0); str(name);
                if (t === 1) {
                    var keys = Object.keys(node.contents);
                    u32(keys.length);
                    for (var i = 0; i < keys.length; i++) walk(node.contents[keys[i]], keys[i]);
                } else if (t === 2) {
                    f64(node.size); u32(node.blocks.length);
                    push(new Uint8Array(Int32Array.from(node.blocks).buffer));
                } else str(node.link);
            }
            walk(root, '');
            var body = new Uint8Array(total), o = 0;
            for (var i = 0; i < parts.length; i++) { body.set(parts[i], o); o += parts[i].length; }
            var h = 0x811c9dc5;
            for (var j = 0; j < body.length; j++) h = Math.imul(h ^ body[j], 16777619);
            gen++;
            var head = new Uint8Array(20), dv = new DataView(head.buffer);
            dv.setUint32(0, MAGIC, true); dv.setUint32(4, gen, true); dv.setUint32(8, body.length, true); dv.setUint32(12, h >>> 0, true); dv.setUint32(16, next, true);
            var m = metas[gen % metas.length];
            m.truncate(0); m.write(body, { at: 20 }); m.flush();
            m.write(head, { at: 0 }); m.flush();                   /* the header last: a torn write leaves the other slot */
            img.flush();
            for (var k = 0; k < pendingFree.length; k++) free.push(pendingFree[k]);
            pendingFree = [];
            dirty = false;
            lastSave = now();
            return true;
        },
        load: function (rootNode) {
            var best = null, bestGen = -1;
            for (var i = 0; i < metas.length; i++) {
                var m = metas[i], size = m.getSize();
                if (size < 20) continue;
                var head = new Uint8Array(20); m.read(head, { at: 0 });
                var dv = new DataView(head.buffer);
                if (dv.getUint32(0, true) !== MAGIC) continue;
                var g = dv.getUint32(4, true), len = dv.getUint32(8, true), sum = dv.getUint32(12, true);
                if (len + 20 > size || g <= bestGen) continue;
                var body = new Uint8Array(len); m.read(body, { at: 20 });
                var h = 0x811c9dc5;
                for (var j = 0; j < body.length; j++) h = Math.imul(h ^ body[j], 16777619);
                if ((h >>> 0) !== sum) continue;
                best = body; bestGen = g;
            }
            if (!best) return false;
            gen = bestGen;
            var dvb = new DataView(best.buffer), o = 0, dec = new TextDecoder(), used = [];
            function str() { var n = dvb.getUint16(o, true); o += 2; var s = dec.decode(best.subarray(o, o + n)); o += n; return s; }
            function walk(parent) {
                var t = best[o++], mode = dvb.getUint32(o, true); o += 4;
                var mtime = dvb.getFloat64(o, true); o += 8;
                var name = str(), node;
                node = parent ? B.createNode(parent, name, mode, 0) : rootNode;
                node.mtime = mtime;
                if (t === 1) {
                    var c = dvb.getUint32(o, true); o += 4;
                    for (var i = 0; i < c; i++) walk(node);
                } else if (t === 2) {
                    node.size = dvb.getFloat64(o, true); o += 8;
                    var nb = dvb.getUint32(o, true); o += 4;
                    node.blocks = Array.from(new Int32Array(best.slice(o, o + nb * 4).buffer)); o += nb * 4;
                    for (var k = 0; k < nb; k++) if (node.blocks[k] >= 0) used.push(node.blocks[k]);
                } else if (t === 3) node.link = str();
            }
            walk(null);
            used.sort(function (a, b) { return a - b; });         /* every block below the end not in use is free */
            next = used.length ? used[used.length - 1] + 1 : 0;
            free = [];
            for (var u = 0, b = 0; b < next; b++) { while (u < used.length && used[u] < b) u++; if (used[u] !== b) free.push(b); }
            dirty = false;
            return true;
        },
        dirty: function () { return dirty; },
        sinceSave: function () { return now() - lastSave; },
        stats: function () { return { blocks: next, free: free.length + pendingFree.length, cached: cache.size }; },
    };
    Module.BLOCKFS = B;
})();
