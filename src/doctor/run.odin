#+vet explicit-allocators
package doctor

// The whole preflight doctor, top to bottom: extraction tooling, the Engine,
// the Model, then the GPU diagnostic -- one Report `transcibr:cli` renders and
// nothing here prints. Every check runs even after an earlier one fails, so a
// user sees every actionable reason at once rather than fixing one problem
// per run. The one dependency between them is the Model's load probe, which
// runs the Engine and so cannot be read as the Model's verdict when the
// Engine itself is the thing that is broken -- the Model line reports SKIP
// there, never FAIL.

import "core:mem"
import "transcibr:child"

Options :: struct {
	ffmpeg:  string,
	ffprobe: string,
	engine:  string,
	model:   string,
}

// The caller owns the returned slice and every Check it holds; free with
// destroy_report and the same allocator.
@(require_results)
run_preflight :: proc(group: ^child.Job_Object, o: Options, allocator: mem.Allocator) -> []Check {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(o.ffmpeg) > 0, "a doctor run was asked to check no ffmpeg at all")
	assert(len(o.ffprobe) > 0, "a doctor run was asked to check no ffprobe at all")
	assert(len(o.engine) > 0, "a doctor run was asked to check no engine at all")
	assert(len(o.model) > 0, "a doctor run was asked to check no model at all")

	checks := make([dynamic]Check, 0, 5, allocator)
	append(
		&checks,
		extraction_tool_check(group, "ffmpeg", o.ffmpeg, FFMPEG_PROBE_ARGUMENTS, allocator),
	)
	append(
		&checks,
		extraction_tool_check(group, "ffprobe", o.ffprobe, FFMPEG_PROBE_ARGUMENTS, allocator),
	)
	engine := engine_check(group, o.engine, allocator)
	append(&checks, engine)
	append(&checks, model_check(group, o.engine, o.model, engine.ok, allocator))
	append(&checks, gpu_diagnostic_check(allocator))

	assert(len(checks) == 5, "a doctor run reported a different number of checks than it ran")
	return checks[:]
}
