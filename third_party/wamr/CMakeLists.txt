# Builds the WAMR runtime as a static, PIC library for linking into plzig.so.
# Configuration per PLAN.md D2: classic interpreter only, no AOT/JIT/WASI/libc,
# no threads, no shared memory, no multi-module, no GC/memory64/SIMD, software
# bounds checks (no signal handlers), linear memory through the host allocator.
#
# Invoked by the top-level Makefile:
#   cmake -S third_party/wamr -B build/wamr -DWAMR_ROOT_DIR=<patched copy>
cmake_minimum_required(VERSION 3.14)
project(plzig_wamr C ASM)

if (NOT DEFINED WAMR_ROOT_DIR)
  message(FATAL_ERROR "WAMR_ROOT_DIR must point to the patched WAMR copy")
endif ()

set(CMAKE_C_STANDARD 99)
if (NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif ()
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(WAMR_BUILD_PLATFORM "linux")
if (CMAKE_SYSTEM_PROCESSOR MATCHES "^(arm64|aarch64)")
  set(WAMR_BUILD_TARGET "AARCH64")
elseif (CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(WAMR_BUILD_TARGET "X86_64")
else ()
  message(FATAL_ERROR "unsupported target")
endif ()

set(WAMR_BUILD_INTERP 1)
set(WAMR_BUILD_FAST_INTERP 0)
set(WAMR_BUILD_AOT 0)
set(WAMR_BUILD_JIT 0)
set(WAMR_BUILD_FAST_JIT 0)
set(WAMR_BUILD_LAZY_JIT 0)
set(WAMR_BUILD_LIBC_BUILTIN 0)
set(WAMR_BUILD_LIBC_WASI 0)
set(WAMR_BUILD_LIBC_UVWASI 0)
set(WAMR_BUILD_LIBC_EMCC 0)
set(WAMR_BUILD_LIB_PTHREAD 0)
set(WAMR_BUILD_LIB_WASI_THREADS 0)
set(WAMR_BUILD_THREAD_MGR 0)
set(WAMR_BUILD_SHARED_MEMORY 0)
set(WAMR_BUILD_SHARED_HEAP 0)
set(WAMR_BUILD_MULTI_MODULE 0)
set(WAMR_BUILD_MULTI_MEMORY 0)
set(WAMR_BUILD_MINI_LOADER 0)
set(WAMR_BUILD_GC 0)
set(WAMR_BUILD_STRINGREF 0)
set(WAMR_BUILD_MEMORY64 0)
set(WAMR_BUILD_SIMD 0)
set(WAMR_BUILD_REF_TYPES 0)
set(WAMR_BUILD_BULK_MEMORY 0)
set(WAMR_BUILD_TAIL_CALL 0)
set(WAMR_BUILD_EXCE_HANDLING 0)
set(WAMR_BUILD_EXTENDED_CONST_EXPR 0)
set(WAMR_BUILD_DEBUG_INTERP 0)
set(WAMR_BUILD_DUMP_CALL_STACK 0)
set(WAMR_BUILD_MEMORY_PROFILING 0)
set(WAMR_BUILD_PERF_PROFILING 0)
set(WAMR_BUILD_INSTRUCTION_METERING 0)
set(WAMR_BUILD_CUSTOM_NAME_SECTION 0)
set(WAMR_BUILD_LOAD_CUSTOM_SECTION 0)
set(WAMR_BUILD_WASM_CACHE 0)
set(WAMR_BUILD_SPEC_TEST 0)
set(WAMR_BUILD_WASI_NN 0)
set(WAMR_BUILD_LIB_RATS 0)
set(WAMR_BUILD_SHRUNK_MEMORY 0)
set(WAMR_BUILD_ALLOC_WITH_USAGE 1)
set(WAMR_BUILD_ALLOC_WITH_USER_DATA 0)
set(WAMR_BUILD_GLOBAL_HEAP_POOL 0)
set(WAMR_DISABLE_HW_BOUND_CHECK 1)
set(WAMR_DISABLE_STACK_HW_BOUND_CHECK 1)
set(WAMR_DISABLE_WAKEUP_BLOCKING_OP 1)
set(WAMR_DISABLE_WRITE_GS_BASE 1)
set(WAMR_DISABLE_APP_ENTRY 1)

include(${WAMR_ROOT_DIR}/build-scripts/runtime_lib.cmake)

# PL/Zig interrupt patch (third_party/wamr-interrupt.patch); route WAMR's
# printf-style logging to the host (which discards it), hidden visibility.
# BLOCK_ADDR_CACHE_SIZE (config.h default 64, x2 ways, per exec env): the
# classic interpreter looks up the end of a block in this cache when it
# enters an `if` or branches out of a block, and rescans the bytecode to the
# block's end on a miss.  The set is the block's address modulo the size, so
# which hot blocks collide depends on code layout.  Zig inlines most of a
# function's callees into one large wasm function, so with 64 sets hot
# blocks evicted each other on every call and the rescans cost several
# microseconds per call (PLAN.md Deviations 30); 256 sets fixed the SDK's
# hot paths but not large user functions (40 % of the cycles in
# wasm_loader_find_block_addr, a function twice as slow because unexecuted
# code was added; PLAN.md Deviations 54).  1024 sets bring the rescans below
# 0.3 % of the cycles there; 4096 and 16384 measured the same.  An exec env
# holds 1024 x 2 x 24 bytes = 48 kB of cache (36 kB more than with 256),
# next to its 512 kB interpreter stack; no change to what modules are
# accepted.
add_definitions(-DWASM_ENABLE_PLZIG_INTERRUPT=1 -DBH_VPRINTF=plzig_wamr_vprintf -DBLOCK_ADDR_CACHE_SIZE=1024)
set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fvisibility=hidden -fno-strict-aliasing")
set(CMAKE_ASM_FLAGS "${CMAKE_ASM_FLAGS} -Wa,--noexecstack")

add_library(vmlib STATIC ${WAMR_RUNTIME_LIB_SOURCE})
set_target_properties(vmlib PROPERTIES OUTPUT_NAME iwasm POSITION_INDEPENDENT_CODE ON)
