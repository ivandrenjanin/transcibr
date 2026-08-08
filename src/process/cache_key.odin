#+vet explicit-allocators
package process

import "core:crypto/sha2"
import "core:encoding/hex"
import "core:fmt"
import "core:mem"

// The one seam every scratch-cache path keys against -- relocated here from
// `src/audio/run.odin` (issue #275) once the Engine's own `<name>.json`
// needed the identical key `wav_cache_path`/`probe_cache_path` already used
// (#256/#268) and neither `transcibr:audio` nor `transcibr:engine` may
// import the other. `transcibr:process` already sits under both, the same
// shared-importable-home role `read_natural` fills for `src/artifact` and
// `src/cliargs`: two packages consume one function rather than each holding,
// or re-deriving, their own copy.

// Long enough that two different Recordings' sources collide on a cache key
// by chance only far below any Batch this program will ever run against (a
// birthday bound over 2^64 keys), short enough that the filename stays
// legible next to the artifact stem it still carries. Issue #256, item 3.
SOURCE_KEY_BYTES :: 8
SOURCE_KEY_CHARS :: 2 * SOURCE_KEY_BYTES

#assert(SOURCE_KEY_BYTES <= sha2.DIGEST_SIZE_256)

// A short, deterministic key over a Recording's own source path -- not its
// bytes, which nothing here has read as a whole. Two Recordings sharing an
// artifact stem from different subfolders of one Batch root are a real,
// legitimate shape (ADR-0008's own injectivity note is scoped to one
// directory), and the stem alone cannot tell them apart in the flat scratch
// cache.
@(private)
@(require_results)
source_key :: proc(source: string, allocator: mem.Allocator) -> string {
	assert(len(source) > 0, "there is no Recording source here to key")
	assert(allocator.procedure != nil, "a key outliving this procedure needs an allocator")

	context_256: sha2.Context_256
	sha2.init_256(&context_256)
	sha2.update(&context_256, transmute([]u8)source)
	sum: [sha2.DIGEST_SIZE_256]u8
	sha2.final(&context_256, sum[:])

	encoded, _ := hex.encode(sum[:SOURCE_KEY_BYTES], allocator)
	key := string(encoded)
	assert(len(key) == SOURCE_KEY_CHARS, "a source key rendered to the wrong number of characters")
	return key
}

// The single seam every scratch-cache path keys against: `<cache>\<stem>.<key>`,
// with no suffix. Every cache path in the collision family -- the wav, the
// probe intermediate, and the Engine's own JSON output -- appends its own
// suffix to this, so none of the three can drift from the others the way
// issue #268 measured the probe path had, and issue #275 measured the JSON
// path still did. The caller frees the answer with `delete` and the same
// allocator.
@(require_results)
cache_key_prefix :: proc(cache, name, source: string, allocator: mem.Allocator) -> string {
	assert(len(cache) > 0, "there is no cache here to place anything into")
	assert(len(name) > 0, "a Recording with no artifact stem has nowhere to put its cache entry")
	assert(len(source) > 0, "there is no Recording source here to key its cache entry to")

	key := source_key(source, allocator)
	defer delete(key, allocator)
	prefix := fmt.aprintf("%s\\%s.%s", cache, name, key, allocator = allocator)
	assert(len(prefix) > len(cache), "a cache key prefix was not built at all")
	return prefix
}
