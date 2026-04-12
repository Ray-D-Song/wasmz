import { spawn } from 'child_process';
import { existsSync, mkdirSync, readFileSync, rmSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { describe, it, expect, beforeAll } from 'vitest';

const __dirname = dirname(fileURLToPath(import.meta.url));

const WASMZ = process.env.WASMZ || 'wasmz';
const WASM_DIR = join(__dirname, 'package');
const WASM = join(WASM_DIR, 'esbuild.wasm');
const SOURCE = join(__dirname, 'source.js');
const EXPECTED = join(__dirname, 'output.js');

/**
 * Download and extract esbuild.wasm if not present
 */
async function ensureWasm() {
  if (existsSync(WASM)) return;

  console.log('Downloading esbuild.wasm...');
  mkdirSync(WASM_DIR, { recursive: true });

  const npmPack = spawn('npm', ['pack', '@esbuild/wasi-preview1'], {
    cwd: WASM_DIR,
    stdio: ['ignore', 'pipe', 'pipe']
  });

  let tarballName = '';
  npmPack.stdout.on('data', (data) => {
    tarballName = data.toString().trim();
  });

  await new Promise((resolve, reject) => {
    npmPack.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`npm pack failed with code ${code}`));
    });
  });

  const tarballPath = join(WASM_DIR, tarballName);
  await new Promise((resolve, reject) => {
    const tar = spawn('tar', ['-xzf', tarballName, '--strip-components=1'], {
      cwd: WASM_DIR,
      stdio: 'ignore'
    });
    tar.on('close', (code) => {
      if (code === 0) resolve();
      else reject(new Error(`tar extraction failed with code ${code}`));
    });
  });

  rmSync(tarballPath);
}

/**
 * @typedef {Object} RunResult
 * @property {string} output - esbuild output
 * @property {number} time - execution time in seconds
 */

/**
 * Run esbuild.wasm via wasmz
 * @returns {Promise<RunResult>}
 */
async function runEsbuild(wasmzArgs = []) {
  const startTime = performance.now();
  const sourceContent = readFileSync(SOURCE, 'utf-8');

  return new Promise((resolve, reject) => {
    const wasmz = spawn(WASMZ, [WASM, ...wasmzArgs, '--args', '--bundle --platform=node --sourcefile=source.js'], {
      stdio: ['pipe', 'pipe', 'pipe']
    });

    let output = '';
    let errorOutput = '';

    wasmz.stdout.on('data', (data) => {
      output += data.toString();
    });

    wasmz.stderr.on('data', (data) => {
      errorOutput += data.toString();
    });

    wasmz.on('close', (code) => {
      const time = (performance.now() - startTime) / 1000;
      if (code !== 0) {
        reject(new Error(`wasmz exited with code ${code}: ${errorOutput}`));
      } else {
        resolve({ output, time, stderr: errorOutput });
      }
    });

    wasmz.stdin.write(sourceContent);
    wasmz.stdin.end();
  });
}

describe.concurrent('esbuild', () => {
  beforeAll(async () => {
    await ensureWasm();
  }, 60000);

  it('should bundle source.js and match expected output', async () => {
    const { output, time, stderr } = await runEsbuild(['--mem-stats']);
    console.log(`esbuild execution time: ${time.toFixed(2)}s`);
    if (stderr) {
      console.log(stderr.trimEnd());
    }
    const expectedOutput = readFileSync(EXPECTED, 'utf-8');
    expect(output.trim()).toBe(expectedOutput.trim());
  }, 30000);

  it('should trap when memory limit is 10MB', async () => {
    await expect(runEsbuild(['--mem-stats', '--mem-limit', '10'])).rejects.toThrow();
  }, 30000);
});
