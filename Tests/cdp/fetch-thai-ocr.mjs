// Optional end-to-end text acceptance: CDP-supplied bytes -> WebKit pixels -> macOS Vision OCR.
// Build bench/ocr/main.swift and set SAFARIUM_OCR, in addition to SAFARIUM_CDP/PPTR_DIR/SCRATCH_DIR.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { once } from 'node:events';
import { writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { exe, puppeteer, scratch } from './lib.mjs';

if (!process.env.SAFARIUM_OCR) throw new Error('set SAFARIUM_OCR to the built local Vision OCR tool');
const work = scratch(), rows = ['เอาตัวรอด', 'กับแสงมณี'];
const html = `<!doctype html><html lang="th"><meta charset="utf-8"><style>
body{margin:0;background:#fff;color:#111;font:700 76px/1.55 Thonburi,sans-serif}
main{padding:32px 48px;white-space:pre-line}</style><main>CONTROL</main><script src="/words.js"></script></html>`;
let hits = 0;
const server = createServer((req,res) => {
  res.setHeader('Cache-Control','no-store');
  if (req.url === '/index.html') { res.writeHead(200,{'Content-Type':'text/html; charset=utf-8'}); return res.end(html); }
  if (req.url === '/words.js') hits++;
  res.writeHead(404); res.end();
}).listen(0,'127.0.0.1');
await once(server,'listening');
const base = `http://127.0.0.1:${server.address().port}`;
let browser;
try {
  browser = await puppeteer.launch({executablePath:exe,pipe:true,protocolTimeout:15000});
  const page = await browser.newPage();
  await page.setViewport({width:800,height:340,deviceScaleFactor:1});
  const c = await page.createCDPSession();
  await c.send('Fetch.enable',{patterns:[{urlPattern:base+'/words.js',requestStage:'Request'}]});
  const supplied = once(c,'Fetch.requestPaused',{signal:AbortSignal.timeout(12000)}).then(([evt]) => {
    assert.equal(evt.request.url,base+'/words.js');
    return c.send('Fetch.fulfillRequest',{requestId:evt.requestId,responseCode:200,
      responseHeaders:[{name:'Content-Type',value:'text/javascript; charset=utf-8'}],
      body:Buffer.from(`document.querySelector('main').textContent=${JSON.stringify(rows.join('\n'))}`,'utf8').toString('base64')});
  });
  await Promise.all([supplied,page.goto(base+'/index.html',{waitUntil:'load',timeout:15000})]);
  await page.evaluate(async () => { await document.fonts.ready; });
  const png = join(work,'thai.png');
  await page.screenshot({path:png});
  await browser.close();
  browser = undefined;
  // This is an OCR correctness gate. Vision took 23.42 s on the saved correct
  // screenshot on this host; keep a bounded watchdog independent of render speed.
  const output = execFileSync(process.env.SAFARIUM_OCR,[png],{encoding:'utf8',timeout:90000});
  const text = output.split('\n').map(s=>s.split('\t').slice(1).join('\t')).join('\n').trim();
  const normalized = text.normalize('NFC').replace(/\s/g,'');
  const report = {origin_script_hits:hits,expected_lines:rows,recognized:text.trim(),
    pass:hits === 0 && rows.every(row=>normalized.includes(row.normalize('NFC'))), image:png};
  writeFileSync(join(work,'ocr.json'),JSON.stringify(report,null,2)+'\n');
  console.log(JSON.stringify(report,null,2));
  assert.ok(report.pass,'Both Thai phrases must actually be readable in the screenshot');
} finally {
  if (browser) await browser.close();
  server.close(); server.closeAllConnections();
}
