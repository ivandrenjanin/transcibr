#+vet explicit-allocators
package doctor

// The four checks the ticket names: extraction tooling, the Engine directory,
// the Model, and the GPU -- each turned into one Check the report can render,
// and nothing here decides how they are presented; that is `transcibr:cli`'s
// job (ADR-0009).

import "core:mem"
import "core:os"
import "core:strings"
import "transcibr:child"

// `-hide_banner` costs nothing and both ffmpeg and ffprobe answer it
// instantly, the same probe shape the Engine check uses for `--help`. Unlike
// `-version`, which both tools write to stdout -- a stream this program never
// captures (ADR-0004) -- `-hide_banner` alone is missing its required input
// file, so both tools print their usage message to stderr and exit nonzero;
// the probe reads only whether something was captured, never the exit code.
@(rodata)
FFMPEG_PROBE_ARGUMENTS := []string{"-hide_banner"}

// A round-3 adversarial review's 8 MiB floor was fitted to that round's own
// fixtures; a round-4 review then measured a 67,108,864-byte (64 MiB) head-
// truncation of the real 1,624,555,275-byte ggml-large-v3-turbo.bin still
// passing. `ggml-tiny.bin`, the smallest Model whisper.cpp actually ships
// (quantized Models are out of scope, docs/spec/0001-transcibr-v1.md's Out
// of Scope), is roughly 77.7 MB -- so 70 MiB sits clear of the truncation
// fixture on one side and clear of the smallest real Model on the other.
MODEL_MIN_PLAUSIBLE_BYTES :: i64(70 * 1024 * 1024)

#assert(MODEL_MIN_PLAUSIBLE_BYTES > 0)

// The real Model's first four bytes, measured directly against the
// reference install at `C:\Users\drenj\models\ggml-large-v3-turbo.bin`
// (`6c 6d 67 67`): ggml's own magic number, 0x67676d6c, stored little-endian
// -- the least significant byte first, which is why the byte order on disk
// reads backwards from how the constant is normally spoken. A head-
// truncation keeps this intact (only the tail is missing, which the size
// floor above is what catches), but an unrelated file -- an HTML error
// page, a stub, a run of random bytes -- almost never starts with it, the
// same "magic bytes" step docs/spec/0001-transcibr-v1.md's own download-
// verification order names.
MODEL_MAGIC_BYTES :: [4]u8{0x6c, 0x6d, 0x67, 0x67}

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
	signature := strings.concatenate({"usage: ", name}, allocator)
	defer delete(signature, allocator)
	if !strings.contains(probe.captured, signature) {
		message := combined_message(
			executable,
			"ran, but did not report itself as this tool",
			"",
			allocator,
		)
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

	if verified.fault != .None {
		message := engine_error_message(verified, executable, allocator)
		return failed("engine", message)
	}
	return passed("engine")
}

@(private)
@(require_results)
model_magic_present :: proc(path: string) -> bool {
	assert(len(path) > 0, "there is no model here to check for a magic header")

	handle, unopenable := os.open(path)
	if unopenable != nil {
		return false
	}
	defer os.close(handle)

	buffer: [4]u8
	read, unreadable := os.read(handle, buffer[:])
	if unreadable != nil {
		return false
	}
	if read != len(buffer) {
		return false
	}
	return buffer == MODEL_MAGIC_BYTES
}

// The cheap half: everything that can refuse a Model without spawning
// anything, and everything that is the Model's own fault rather than the
// Engine's. `refusal.name` is empty where nothing here refuses it.
@(private)
@(require_results)
model_screened :: proc(path: string, allocator: mem.Allocator) -> (refusal: Check) {
	assert(len(path) > 0, "there is no model here to screen")

	info, unstattable := os.stat(path, allocator)
	defer os.file_info_delete(info, allocator)

	if unstattable != nil {
		message := combined_message(
			path,
			"could not be read at all; check the path passed to --model-file",
			"",
			allocator,
		)
		return failed("model", message)
	}
	if info.type == .Directory {
		message := combined_message(
			path,
			"is a directory, not a file; check the path passed to --model-file",
			"",
			allocator,
		)
		return failed("model", message)
	}
	if info.size <= 0 {
		message := combined_message(
			path,
			"is zero bytes; the download is missing or was never completed",
			"",
			allocator,
		)
		return failed("model", message)
	}
	return model_screened_further(path, info.size, allocator)
}

@(private)
@(require_results)
model_screened_further :: proc(path: string, bytes: i64, allocator: mem.Allocator) -> Check {
	assert(len(path) > 0, "there is no model here to screen")
	assert(bytes > 0, "an empty model reached the screen that comes after the empty check")

	if bytes < MODEL_MIN_PLAUSIBLE_BYTES {
		message := combined_message(
			path,
			"is far smaller than any real Model; the download is truncated or incomplete",
			"",
			allocator,
		)
		return failed("model", message)
	}
	if !model_magic_present(path) {
		message := combined_message(
			path,
			"does not begin with the ggml magic bytes; this is not a whisper Model file",
			"",
			allocator,
		)
		return failed("model", message)
	}
	return Check{}
}

// `engine_ok` is the verdict of the Engine check that ran just before this
// one. A Model cannot be judged through an Engine that does not work: with
// `ggml-cuda.dll` removed from a real install, the Engine loads a real Model
// perfectly well on the CPU, and the doctor that failed the Model on that
// evidence sent a user to re-download 1.6 GB for nothing. The Engine's own
// FAIL already carries the nonzero exit; this line has to be a SKIP.
@(require_results)
model_check :: proc(
	group: ^child.Job_Object,
	engine_executable: string,
	path: string,
	engine_ok: bool,
	allocator: mem.Allocator,
) -> Check {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(engine_executable) > 0, "there is no engine here to load the model with")
	assert(len(path) > 0, "there is no model here to check")

	refusal := model_screened(path, allocator)
	if len(refusal.name) > 0 {
		return refusal
	}
	if !engine_ok {
		message := combined_message(
			path,
			"was not judged: a model cannot be loaded through an engine that does not work -- fix the engine check above first, then run the doctor again",
			"",
			allocator,
		)
		return skipped("model", message)
	}
	return model_load_check(group, engine_executable, path, allocator)
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
		return failed("gpu (diagnostic)", message, advisory = true)
	}
	return passed("gpu (diagnostic)", advisory = true)
}
