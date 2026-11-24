// Minimal raw CDP pipe client (no puppeteer) for protocol-level tests and debugging.
import { spawn } from 'node:child_process';
import { exe } from './lib.mjs';

export function rawClient(extraArgs = []) {
  const child = spawn(exe, ['--remote-debugging-pipe', '--headless', ...extraArgs], { stdio: ['ignore', 'ignore', 'inherit', 'pipe', 'pipe'] });
  const toBrowser = child.stdio[3], fromBrowser = child.stdio[4];
  let id = 0, buf = '';
  const waiting = new Map();
  const events = [];
  const listeners = [];
  fromBrowser.on('data', (d) => {
    buf += d.toString('utf8');
    let i;
    while ((i = buf.indexOf('\0')) >= 0) {
      const msg = JSON.parse(buf.slice(0, i)); buf = buf.slice(i + 1);
      if (msg.id !== undefined && waiting.has(msg.id)) { waiting.get(msg.id)(msg); waiting.delete(msg.id); }
      else { events.push(msg); listeners.forEach((l) => l(msg)); }
    }
  });
  const exited = new Promise((r) => child.on('exit', (code, sig) => r({ code, sig })));
  return {
    child, events, exited,
    send(method, params = {}, sessionId) {
      const m = { id: ++id, method, params }; if (sessionId) m.sessionId = sessionId;
      toBrowser.write(JSON.stringify(m) + '\0');
      return new Promise((res, rej) => {
        const t = setTimeout(() => rej(new Error(`timeout waiting for ${method}`)), 20000);
        waiting.set(m.id, (r) => { clearTimeout(t); res(r); });
      });
    },
    waitEvent(method, pred = () => true, ms = 20000) {
      const hit = events.find((e) => e.method === method && pred(e));
      if (hit) return Promise.resolve(hit);
      return new Promise((res, rej) => {
        const t = setTimeout(() => rej(new Error(`timeout waiting for event ${method}`)), ms);
        listeners.push((e) => { if (e.method === method && pred(e)) { clearTimeout(t); res(e); } });
      });
    },
    kill() { child.kill('SIGKILL'); },
  };
}
