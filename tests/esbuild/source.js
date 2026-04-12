// source.js - esbuild bundler test input
//
// Tests that wasmz correctly runs esbuild.wasm and produces bundled output.
// esbuild is invoked in stdin mode (--sourcefile flag), so this file is
// piped via stdin rather than read from the filesystem.

const items = [1, 2, 3, 4, 5];

// Arrow function + Array.prototype.map
const doubled = items.map((x) => x * 2);

// Template literal
const msg = `doubled: ${doubled.join(", ")}`;

console.log(msg);

// Default export (tests ESM syntax handling)
export default msg;
