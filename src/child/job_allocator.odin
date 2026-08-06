#+vet explicit-allocators
package child

import "base:runtime"
import "core:mem"

// The one spelling of the outlives-the-caller policy (issue #66): a thread
// this package -- or `transcibr:artifact`, `transcibr:audio`,
// `transcibr:engine`, `transcibr:planning` -- cannot safely stop still
// needs somewhere to put what it was working on, and the caller's own
// `allocator` is the wrong place for that. A worker in `transcibr:pipeline`
// may hand a bounded call a per-Recording arena that gets destroyed once
// that Recording's stage finishes, and a thread abandoned past its bound has
// no way to know that happened -- an arena-backed allocation reached after
// the arena is gone is a use-after-free, not a leak. Under `odin test` the
// same hazard shows up as a per-test tracking allocator torn down the
// moment the test that started the call returns, which is what caught it
// here originally, in `child.read_bounded`. Every allocation a job's
// worker thread might still touch after its caller has stopped waiting on
// it goes through this fixed, always-valid heap instead -- never through
// `runtime.heap_allocator()` spelled out again at the call site, which is
// the same policy retyped rather than reused.
@(require_results)
job_allocator :: proc() -> mem.Allocator {
	return runtime.heap_allocator()
}
