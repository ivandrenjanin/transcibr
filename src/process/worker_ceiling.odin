#+vet explicit-allocators
// worker_count_within_ceiling relocated from src/pipeline (ADR-0038's
// worker-ceiling section): src/cliargs's own worker-count reader has to
// apply the ceiling it was handed, and calling into src/pipeline to do that
// would pull transcibr:child into src/cliargs's import closure behind it --
// pipeline's own recording.odin and run.odin both import child. Taking
// ceiling as a parameter rather than reading a pipeline-owned constant by
// name is what already let issue #94's fix take this shape in the first
// place -- nothing in this procedure's body is pipeline-specific, which is
// what makes the relocation possible at all.
package process

@(require_results)
worker_count_within_ceiling :: proc(count: int, ceiling: int) -> bool {
	assert(ceiling > 0, "a ceiling of zero admits no worker count at all")
	return count > 0 && count <= ceiling
}
