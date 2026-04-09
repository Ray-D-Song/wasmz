Initially I chose Dart, but Dart is currently still using wasm's legacy exception instructions.  
So I have no choice but use Kotlin to test it... 

https://github.com/dart-lang/sdk/issues/54394

```bash
./build.sh

# use wasmtime test it
wasmtime -W gc,function-references,exceptions tests/gc/build/compileSync/wasmWasi/main/productionExecutable/kotlin/gc.wasm
```