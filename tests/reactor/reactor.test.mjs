import { spawn } from 'child_process';
import { existsSync } from 'fs';
import { dirname, join, resolve } from 'path';
import { fileURLToPath } from 'url';
import { describe, it, expect } from 'vitest';

const __dirname = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = resolve(__dirname, '../..');

const WASMZ = process.env.WASMZ || 'wasmz';

// The reactor_add.wasm fixture lives in the source tree (committed).
// It is a reactor module (no _start) that exports:
//   _initialize, add(i32,i32)->i32, fib(i32)->i32, is_initialized()->i32
const REACTOR_WASM = join(
  REPO_ROOT,
  'src/wasmz/tests/fixtures/reactor_add.wasm',
);

/**
 * Run wasmz with the given arguments.
 * Resolves with { stdout, stderr, code }.
 * Never rejects — check `code` yourself.
 */
function runWasmz(args) {
  return new Promise((resolve) => {
    const proc = spawn(WASMZ, args, { stdio: ['ignore', 'pipe', 'pipe'] });
    let stdout = '';
    let stderr = '';
    proc.stdout.on('data', (d) => { stdout += d.toString(); });
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    proc.on('close', (code) => resolve({ stdout, stderr, code }));
  });
}

describe.concurrent('reactor model CLI', () => {
  it('fixture file exists', () => {
    expect(existsSync(REACTOR_WASM)).toBe(true);
  });

  it('lists exports when no func is given (reactor, no _start auto-run)', async () => {
    const { stdout, code } = await runWasmz([REACTOR_WASM]);
    expect(code).toBe(0);
    // Should list exported function names
    expect(stdout).toMatch(/Exported functions:/);
    expect(stdout).toMatch(/add/);
    expect(stdout).toMatch(/fib/);
    expect(stdout).toMatch(/_initialize/);
  });

  it('positional: calls add(10, 32) => 42', async () => {
    const { stdout, code } = await runWasmz([REACTOR_WASM, 'add', '10', '32']);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('42');
  });

  it('--func: calls add(19, 23) => 42', async () => {
    const { stdout, code } = await runWasmz([REACTOR_WASM, '--func', 'add', '19', '23']);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('42');
  });

  it('--func: calls fib(10) => 55', async () => {
    const { stdout, code } = await runWasmz([REACTOR_WASM, '--func', 'fib', '10']);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('55');
  });

  it('--reactor --func: initializes then calls fib(20) => 6765', async () => {
    const { stdout, code } = await runWasmz([
      REACTOR_WASM, '--reactor', '--func', 'fib', '20',
    ]);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('6765');
  });

  it('--reactor --func: is_initialized() returns 1 after _initialize', async () => {
    const { stdout, code } = await runWasmz([
      REACTOR_WASM, '--reactor', '--func', 'is_initialized',
    ]);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('1');
  });

  it('without --reactor: is_initialized() returns 0 (no _initialize called)', async () => {
    const { stdout, code } = await runWasmz([
      REACTOR_WASM, '--func', 'is_initialized',
    ]);
    expect(code).toBe(0);
    expect(stdout.trim()).toBe('0');
  });

  it('fib boundary: fib(0) => 0, fib(1) => 1', async () => {
    const r0 = await runWasmz([REACTOR_WASM, '--func', 'fib', '0']);
    expect(r0.code).toBe(0);
    expect(r0.stdout.trim()).toBe('0');

    const r1 = await runWasmz([REACTOR_WASM, '--func', 'fib', '1']);
    expect(r1.code).toBe(0);
    expect(r1.stdout.trim()).toBe('1');
  });

  it('error: ExportNotFound for unknown function', async () => {
    const { code, stderr } = await runWasmz([REACTOR_WASM, '--func', 'nonexistent']);
    expect(code).not.toBe(0);
    expect(stderr).toMatch(/ExportNotFound|not found/i);
  });
});
