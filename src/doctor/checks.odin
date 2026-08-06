#+vet explicit-allocators
package doctor

// The four checks the ticket names: extraction tooling, the Engine directory,
// the Model, and the GPU -- each turned into one Check the report can render,
// and nothing here decides how they are presented; that is `transcibr:cli`'s
// job (ADR-0009).

import "core:mem"
import "core:strings"
import "transcibr:artifact"
import "transcibr:child"

// `-version` costs nothing and both ffmpeg and ffprobe answer it instantly,
// the same probe shape the Engine check uses for `--help`.
@(rodata)
FFMPEG_PROBE_ARGUMENTS := []string{"-version"}

@(require_results)
extraction_tool_check :: proc(
	group: ^child.Job_Object,
	name: string,
	executable: string,
	arguments: []string,
	allocator: mem.Allocator,
) -> Check {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(name) > 0, "a check with no name reports nothing a user can act on")
	assert(len(executable) > 0, "there is no tool here to check")

	probe := probe_executable(group, executable, arguments, allocator)
	defer delete(probe.captured, allocator)

	switch probe.run {
	case .Not_Started:
		reason := child.error_message(probe.child, allocator)
		defer delete(reason, allocator)
		message := combined_message(executable, "could not be started", reason, allocator)
		return failed(name, message)
	case .Stopped, .Unstoppable:
		message := combined_message(
			executable,
			"did not exit on its own within a few seconds of being asked its own version",
			"",
			allocator,
		)
		return failed(name, message)
	case .Finished:
	}
	if len(probe.captured) == 0 {
		message := combined_message(executable, "ran, but reported nothing at all", "", allocator)
		return failed(name, message)
	}
	return passed(name)
}

@(require_results)
engine_check :: proc(
	group: ^child.Job_Object,
	executable: string,
	allocator: mem.Allocator,
) -> Check {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(executable) > 0, "there is no engine here to check")

	verified := verify_engine(group, executable, allocator)
	defer artifact.destroy_model(verified.model, allocator)

	if verified.fault != .None {
		message := engine_error_message(verified, executable, allocator)
		return failed("engine", message)
	}
	return passed("engine")
}

@(require_results)
model_check :: proc(path: string, allocator: mem.Allocator) -> Check {
	assert(len(path) > 0, "there is no model here to check")

	identified, unreadable := artifact.identify_model(path, allocator)
	defer artifact.destroy_model(identified, allocator)

	if unreadable != .None {
		message := artifact.model_error_message(unreadable, path, allocator)
		return failed("model", message)
	}
	return passed("model")
}

// Diagnostic only, and never the verdict on GPU usability (ADR-0011): this
// reports what Windows can see without spawning anything, purely to help a
// user read a `.engine` failure -- "no GPU at all" reads differently from "a
// GPU is here but the Engine could not reach it."
@(require_results)
gpu_diagnostic_check :: proc(allocator: mem.Allocator) -> Check {
	gpus := listed_gpus(allocator)
	defer destroy_gpus(gpus, allocator)

	if len(gpus) == 0 {
		message := strings.clone(
			"no GPU could be enumerated at all; the engine will have nothing to reach even if it starts",
			allocator,
		)
		return failed("gpu (diagnostic)", message)
	}
	return passed("gpu (diagnostic)")
}
