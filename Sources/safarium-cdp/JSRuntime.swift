import Foundation

/// JavaScript run inside the page by Runtime.evaluate / callFunctionOn. Every snippet returns a JSON string
/// (`{result, exceptionDetails?}`) so Swift never has to guess how WebKit bridged a JS value.
enum JSRuntime {
    /// Shared preamble: remote-object registry (objectId = "<contextId>.<n>"), serializer, exception mapper.
    /// Arguments in scope: ctx (Int), byValue (Bool), awaitP (Bool).
    static let preamble = #"""
    const K = Symbol.for('safarium.cdp.objects');
    const R = globalThis[K] || (globalThis[K] = { n: 0, m: new Map() });
    const reg = (v) => { const n = ++R.n; R.m.set(n, v); return ctx + '.' + n; };
    const tag = (v) => Object.prototype.toString.call(v).slice(8, -1);
    const ser = (v, byVal) => {
      const t = typeof v;
      if (v === undefined) return { type: 'undefined' };
      if (v === null) return { type: 'object', subtype: 'null', value: null };
      if (t === 'boolean' || t === 'string') return { type: t, value: v };
      if (t === 'number') {
        if (!Number.isFinite(v) || Object.is(v, -0)) { const s = Object.is(v, -0) ? '-0' : String(v); return { type: 'number', unserializableValue: s, description: s }; }
        return { type: 'number', value: v, description: String(v) };
      }
      if (t === 'bigint') return { type: 'bigint', unserializableValue: v + 'n', description: v + 'n' };
      if (byVal) {
        if (t === 'function' || t === 'symbol') throw new Error("Object couldn't be returned by value");
        const s = JSON.stringify(v);
        return { type: 'object', value: s === undefined ? undefined : JSON.parse(s) };
      }
      if (t === 'symbol') return { type: 'symbol', description: String(v), objectId: reg(v) };
      const g = tag(v);
      let subtype;
      if (Array.isArray(v)) subtype = 'array';
      else if (g === 'Error') subtype = 'error';
      else if (typeof Node !== 'undefined' && v instanceof Node) subtype = 'node';
      else if (g === 'Promise') subtype = 'promise';
      else if (g === 'RegExp') subtype = 'regexp';
      else if (g === 'Date') subtype = 'date';
      else if (g === 'Map') subtype = 'map';
      else if (g === 'Set') subtype = 'set';
      let className = (v && v.constructor && v.constructor.name) || (t === 'function' ? 'Function' : 'Object');
      let description = className;
      if (t === 'function') description = Function.prototype.toString.call(v).slice(0, 500);
      else if (subtype === 'array') description = 'Array(' + v.length + ')';
      else if (subtype === 'error') description = v.name + ': ' + v.message;
      else if (subtype === 'node') description = (v.nodeName || '').toLowerCase();
      const o = { type: t === 'function' ? 'function' : 'object', className, description, objectId: reg(v) };
      if (subtype) o.subtype = subtype;
      return o;
    };
    const fail = (e) => {
      let exception;
      if (tag(e) === 'Error') {
        const d = e.name + ': ' + e.message;
        exception = { type: 'object', subtype: 'error', className: e.name || 'Error', description: d + '\n    at <anonymous>:1:1', objectId: reg(e) };
      } else {
        try { exception = ser(e, false); } catch (_) { exception = { type: 'string', value: String(e) }; }
      }
      return JSON.stringify({ result: exception, exceptionDetails: { exceptionId: 1, text: 'Uncaught', lineNumber: 0, columnNumber: 0, exception } });
    };
    const unser = (s) => s === 'NaN' ? NaN : s === 'Infinity' ? Infinity : s === '-Infinity' ? -Infinity : s === '-0' ? -0 : /n$/.test(s) ? BigInt(s.slice(0, -1)) : undefined;
    const lookup = (id) => { const [c, n] = String(id).split('.'); const m = R.m; if (!m.has(+n)) throw new Error('Could not find object with given id'); return m.get(+n); };
    """#

    /// args: expression
    static let evaluate = preamble + #"""
    try {
      let v = (0, eval)(expression);
      if (awaitP) v = await v;
      return JSON.stringify({ result: ser(v, byValue) });
    } catch (e) { return fail(e); }
    """#

    /// args: decl, argv, thisId (string or null)
    static let callFunctionOn = preamble + #"""
    try {
      const fn = (0, eval)('(' + decl + '\n)');
      const args = argv.map((a) => (a && 'objectId' in a) ? lookup(a.objectId) : (a && 'unserializableValue' in a) ? unser(a.unserializableValue) : (a ? a.value : undefined));
      const self = thisId ? lookup(thisId) : globalThis;
      let v = fn.apply(self, args);
      if (awaitP) v = await v;
      return JSON.stringify({ result: ser(v, byValue) });
    } catch (e) { return fail(e); }
    """#

    /// args: objectId, base (Int, first backendNodeId to hand out). Returns {node:{...}} for DOM.describeNode.
    static let describeNode = preamble + #"""
    try {
      const n = lookup(objectId);
      if (!n || typeof n.nodeType !== 'number') throw new Error('Object id doesn\'t reference a node');
      R.nodes = R.nodes || new Map(); R.ids = R.ids || new WeakMap();
      let id = R.ids.get(n);
      if (!id) { id = base + R.nodes.size; R.ids.set(n, id); R.nodes.set(id, n); }
      const attrs = []; if (n.attributes) for (const a of n.attributes) attrs.push(a.name, a.value);
      return JSON.stringify({ node: { nodeId: 0, backendNodeId: id, nodeType: n.nodeType, nodeName: n.nodeName, localName: n.localName || '',
        nodeValue: n.nodeValue || '', childNodeCount: n.childNodes ? n.childNodes.length : 0, attributes: attrs } });
    } catch (e) { return JSON.stringify({ error: String(e && e.message || e) }); }
    """#

    /// args: backendNodeId. Returns {object} for DOM.resolveNode (same world as describeNode only).
    static let resolveNode = preamble + #"""
    try {
      const n = R.nodes && R.nodes.get(backendNodeId);
      if (!n) throw new Error('No node with given id found');
      return JSON.stringify({ object: ser(n, false) });
    } catch (e) { return JSON.stringify({ error: String(e && e.message || e) }); }
    """#

    /// args: n (Int) - release a remote object
    static let release = #"""
    const R = globalThis[Symbol.for('safarium.cdp.objects')]; if (R) R.m.delete(n); return '{}';
    """#

    /// Installed in every frame at document start (page world). Relays load events, console and errors to Swift.
    static let boot = #"""
    (() => {
      const post = (m) => { try { window.webkit.messageHandlers.sfEvents.postMessage(m); } catch (e) {} };
      const isTop = window === window.top;
      const brief = (v) => {
        const t = typeof v;
        if (v === undefined) return { type: 'undefined' };
        if (v === null) return { type: 'object', subtype: 'null', value: null };
        if (t === 'string' || t === 'boolean') return { type: t, value: v };
        if (t === 'number') return { type: 'number', value: Number.isFinite(v) ? v : null, description: String(v) };
        let d; try { d = (t === 'function') ? 'function' : (v instanceof Error ? (v.name + ': ' + v.message) : (Array.isArray(v) ? JSON.stringify(v) : (JSON.stringify(v) || String(v)))); } catch (_) { d = String(v); }
        return { type: t === 'function' ? 'function' : 'object', description: d };
      };
      if (isTop) {
        document.addEventListener('DOMContentLoaded', () => post({ k: 'dcl' }));
        window.addEventListener('load', () => post({ k: 'load' }));
        const map = { log: 'log', info: 'info', debug: 'debug', warn: 'warning', error: 'error', dir: 'dir', table: 'table', trace: 'trace' };
        for (const name of Object.keys(map)) {
          const orig = console[name];
          if (typeof orig !== 'function') continue;
          console[name] = function (...a) { try { post({ k: 'console', t: map[name], a: a.map(brief) }); } catch (_) {} return orig.apply(this, a); };
        }
        window.addEventListener('error', (e) => post({ k: 'exc', m: String(e.message), u: e.filename || '', l: e.lineno || 0, c: e.colno || 0, n: (e.error && e.error.name) || 'Error' }));
        window.addEventListener('unhandledrejection', (e) => post({ k: 'exc', m: 'Uncaught (in promise) ' + String(e.reason), u: '', l: 0, c: 0, n: 'Error' }));
      }
    })();
    """#

    static func bindingScript(name: String) -> String {
        let n = (try? String(data: JSONSerialization.data(withJSONObject: [name]), encoding: .utf8)).map { String($0.dropFirst().dropLast()) } ?? "\"\""
        return "(() => { const n = \(n); window[n] = (p) => { window.webkit.messageHandlers.sfEvents.postMessage({ k: 'binding', n, p: String(p) }); }; })();"
    }
}
