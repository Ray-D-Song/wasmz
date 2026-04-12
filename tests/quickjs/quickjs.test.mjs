import { spawn } from 'child_process';
import { existsSync, mkdirSync, writeFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { describe, it, expect, beforeAll } from 'vitest';

const __dirname = dirname(fileURLToPath(import.meta.url));

const WASMZ = process.env.WASMZ || 'wasmz';

// quickjs-ng v0.14.0 — standalone wasm32-wasi command binary (has _start)
const QJS_VERSION = 'v0.14.0';
const WASM_DIR = join(__dirname, 'package');
const QJS_WASM = join(WASM_DIR, 'qjs-wasi.wasm');
const QJS_URL = `https://github.com/quickjs-ng/quickjs/releases/download/${QJS_VERSION}/qjs-wasi.wasm`;

/**
 * Download qjs-wasi.wasm from quickjs-ng GitHub releases if not cached.
 */
async function ensureWasm() {
  if (existsSync(QJS_WASM)) return;

  console.log(`Downloading qjs-wasi.wasm (${QJS_VERSION})...`);
  mkdirSync(WASM_DIR, { recursive: true });

  const res = await fetch(QJS_URL);
  if (!res.ok) throw new Error(`Failed to download qjs-wasi.wasm: ${res.status} ${res.statusText}`);

  const buf = await res.arrayBuffer();
  writeFileSync(QJS_WASM, Buffer.from(buf));
}

/**
 * @typedef {Object} RunResult
 * @property {string} stdout
 * @property {string} stderr
 * @property {number} time - seconds
 */

/**
 * Run qjs-wasi.wasm via wasmz with `-e <script>` (inline eval, no filesystem needed).
 * @param {string} script  - JS source to evaluate
 * @param {string[]} wasmzArgs - extra wasmz flags (e.g. ['--mem-stats', '--mem-limit', '1'])
 * @returns {Promise<RunResult>}
 */
function runQjs(script, wasmzArgs = []) {
  const startTime = performance.now();

  return new Promise((resolve, reject) => {
    const wasmz = spawn(
      WASMZ,
      [...wasmzArgs, QJS_WASM, '--args', `-e '${script}'`],
      { stdio: ['ignore', 'pipe', 'pipe'] },
    );

    let stdout = '';
    let stderr = '';

    wasmz.stdout.on('data', (d) => { stdout += d.toString(); });
    wasmz.stderr.on('data', (d) => { stderr += d.toString(); });

    wasmz.on('close', (code) => {
      const time = (performance.now() - startTime) / 1000;
      if (code !== 0) {
        reject(new Error(`wasmz exited with code ${code}: ${stderr}`));
      } else {
        resolve({ stdout, stderr, time });
      }
    });
  });
}

describe.concurrent('quickjs-ng (qjs-wasi.wasm)', () => {
  beforeAll(async () => {
    await ensureWasm();
  }, 60000);

  it('should evaluate a simple expression', async () => {
    const { stdout } = await runQjs('print(1 + 1)');
    expect(stdout.trim()).toBe('2');
  }, 15000);

  it('should evaluate fibonacci correctly', async () => {
    const script = 'function fib(n){return n<=1?n:fib(n-1)+fib(n-2)} print(fib(10))';
    const { stdout } = await runQjs(script);
    expect(stdout.trim()).toBe('55');
  }, 15000);

  it('should print mem-stats to stderr', async () => {
    const { stdout, stderr, time } = await runQjs('print(42)', ['--mem-stats']);
    console.log(`qjs execution time: ${time.toFixed(2)}s`);
    console.log(stderr.trimEnd());
    expect(stdout.trim()).toBe('42');
    expect(stderr).toMatch(/Memory usage:/);
    expect(stderr).toMatch(/Linear memory:/);
    expect(stderr).toMatch(/Total:/);
  }, 15000);

  it('should fail when memory limit is too small', async () => {
    // 0 MB prevents the initial linear-memory pages from growing → OOM before JS context
    await expect(runQjs('print(42)', ['--mem-limit', '0'])).rejects.toThrow();
  }, 15000);
});
