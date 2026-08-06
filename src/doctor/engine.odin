#+vet explicit-allocators
package doctor

// The Engine is unpacked to roughly twenty DLLs beside its executable, one of
// them the CUDA backend, and it is built with runtime backend discovery: a
// candidate DLL that fails to load is skipped, not reported (ADR-0011). So
// resolving "the Engine" as a directory and checking the backend DLL sits
// beside the executable catches a mislaid install, and actually spawning the
// Engine and reading what it says catches everything that check cannot --
// a driver too old for the bundled CUDA runtime, or a GPU in a reset state --
// neither of which leaves the DLL missing.

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "transcibr:artifact"
import "transcibr:child"

// `ggml-cuda.dll`: the one backend library ADR-0011 names by its actual
// filename, the same file `docs/adr/0011-engine-acquisition-and-gpu-verification.md`
// cites and the one the installed reference release at `C:\tools\whisper\Release`
// carries beside `whisper-cli.exe`.
GPU_BACKEND_LIBRARY :: "ggml-cuda.dll"

// `--help` costs nothing: the Engine loads every backend candidate before it
// even looks at its arguments, so this is enough to prove the CUDA backend
// either loaded or was silently skipped, without spending a Model or a
// Recording on the question.
@(rodata)
ENGINE_PROBE_ARGUMENTS := []string{"--help"}

Engine_Fault :: enum u8 {
	None = 0,
	Backend_Library_Missing,
	Unreadable,
	Not_Started,
	Did_Not_Finish,
	Backend_Not_Loaded,
}

Engine_Check :: struct {
	fault: Engine_Fault,
	// Only meaningful when fault == .Not_Started.
	child: child.Error,
	// Owned; free with destroy_model and the same allocator, whichever way
	// this ends -- a refusal that never reached hashing identifies nothing.
	model: artifact.Model,
}

// `executable` is the same path `--engine-exe` already names -- ADR-0011's
// "resolved as a directory" means the DIRECTORY beside it, derived here,
// never a second flag asking a user to spell out what this program can
// already see.
@(require_results)
verify_engine :: proc(
	group: ^child.Job_Object,
	executable: string,
	allocator: mem.Allocator,
) -> (
	check: Engine_Check,
) {
	assert(group != nil, "a child started outside a job object outlives transcibr")
	assert(len(executable) > 0, "there is no Engine here to verify")
	assert(allocator.procedure != nil, "the check outlives this procedure and needs an allocator")

	if !backend_library_present(executable) {
		return Engine_Check{fault = .Backend_Library_Missing}
	}

	identified, unreadable := artifact.identify_model(executable, allocator)
	if unreadable != .None {
		return Engine_Check{fault = .Unreadable, model = identified}
	}

	probe := probe_executable(group, executable, ENGINE_PROBE_ARGUMENTS, allocator)
	defer delete(probe.captured, allocator)

	switch probe.run {
	case .Not_Started:
		return Engine_Check{fault = .Not_Started, child = probe.child, model = identified}
	case .Stopped, .Unstoppable:
		return Engine_Check{fault = .Did_Not_Finish, model = identified}
	case .Finished:
	}
	if !strings.contains(probe.captured, "loaded CUDA backend from") {
		return Engine_Check{fault = .Backend_Not_Loaded, model = identified}
	}
	return Engine_Check{fault = .None, model = identified}
}

@(private)
@(require_results)
backend_library_present :: proc(executable: string) -> bool {
	assert(len(executable) > 0, "there is no Engine here to resolve a directory for")

	directory := filepath.dir(executable)
	beside, joined := filepath.join(
		{directory, GPU_BACKEND_LIBRARY},
		allocator = context.allocator,
	)
	if joined != nil {
		return false
	}
	defer delete(beside, context.allocator)
	return os.is_file(beside)
}

@(private)
@(require_results)
engine_fault_says :: proc(fault: Engine_Fault) -> string {
	switch fault {
	case .Backend_Library_Missing:
		return(
			"ggml-cuda.dll is not beside the engine's executable; the install is incomplete and the engine will transcribe on the cpu without saying so" \
		)
	case .Unreadable:
		return "the engine's executable could not be read and hashed"
	case .Not_Started:
		return "the engine could not be started"
	case .Did_Not_Finish:
		return(
			"the engine did not exit on its own within a few seconds of being started with --help" \
		)
	case .Backend_Not_Loaded:
		return(
			"the engine started but its own diagnostic output never named the cuda backend as loaded; a candidate gpu backend library failed to load and was silently skipped" \
		)
	case .None:
	}
	return ""
}

@(require_results)
engine_error_message :: proc(
	check: Engine_Check,
	executable: string,
	allocator: mem.Allocator,
) -> string {
	assert(check.fault != .None, "there is no message for an engine that passed its check")
	assert(len(executable) > 0, "a refusal must name the engine it is reported against")
	assert(
		allocator.procedure != nil,
		"the message outlives this procedure and needs an allocator",
	)

	says := engine_fault_says(check.fault)
	assert(len(says) > 0, "a fault was added to Engine_Fault without a sentence")

	if check.fault == .Not_Started {
		reason := child.error_message(check.child, allocator)
		defer delete(reason, allocator)
		return combined_message(executable, says, reason, allocator)
	}
	return combined_message(executable, says, "", allocator)
}
