// Shared helpers for the safarium-cdp Node harness. puppeteer-core lives in scratch, not in the vault:
//   PPTR_DIR=<dir containing node_modules/puppeteer-core>  SAFARIUM_CDP=<path to safarium-cdp>
import { createRequire } from 'node:module';
import { execFileSync } from 'node:child_process';
import { writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

export const here = dirname(fileURLToPath(import.meta.url));
export const exe = process.env.SAFARIUM_CDP;
if (!exe) throw new Error('set SAFARIUM_CDP to the safarium-cdp executable');
const pptrDir = process.env.PPTR_DIR;
if (!pptrDir) throw new Error('set PPTR_DIR to a folder whose node_modules has puppeteer-core 25.x');
export const puppeteer = createRequire(join(pptrDir, 'x.js'))('puppeteer-core');
export const fixtureURL = (name) => pathToFileURL(join(here, 'fixtures', name)).href;
export const scratch = () => mkdtempSync(join(process.env.SCRATCH_DIR || tmpdir(), 'cdp-'));

/** Decode a PNG/JPEG buffer to raw RGBA via ffmpeg. Returns {width,height,px(x,y)->[r,g,b,a]}. */
export function decode(buf, ext = 'png') {
  const dir = scratch();
  const f = join(dir, `in.${ext}`);
  writeFileSync(f, buf);
  const probe = execFileSync('ffprobe', ['-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', f]).toString().trim().split(',').map(Number);
  const [width, height] = probe;
  const raw = execFileSync('ffmpeg', ['-v', 'error', '-i', f, '-f', 'rawvideo', '-pix_fmt', 'rgba', '-'], { maxBuffer: 1 << 28 });
  return { width, height, px: (x, y) => Array.from(raw.subarray((y * width + x) * 4, (y * width + x) * 4 + 4)) };
}
