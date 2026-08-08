#+vet explicit-allocators
package doctor

// The Engine is unpacked to roughly twenty DLLs beside its executable, one of
// them the CUDA backend, and it is built with runtime backend discovery: a
// candidate DLL that fails to load is skipped, not reported (ADR-0011). So
// resolving "the Engine" as a directory and checking the backend DLL sits
// beside the executable catches a mislaid install, and actually spawning the
// Engine and reading what it says catches everything that check cannot --
// a driver too old for the bundled CUDA runtime, or a GPU in a reset state --
// neither of which leaves the DLL missing. That same spawn is what proves the
// executable is a genuine, working Engine -- a round-5 adversarial review
// found the hash this file used to compute over the executable was read by
// nothing and proved nothing a mutation to a bare `os.is_file` check did not
// already pass; the spawn below is the verification, not a digest beside it.

import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strings"
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
	Executable_Not_Found,
	Backend_Library_Missing,
	Not_Started,
	Did_Not_Finish,
	Backend_Not_Loaded,
	Capture_Overflowed,
}

Engine_Check :: struct {
	fault: Engine_Fault,
	// Only meaningful when fault == .Not_Started.
	child: child.Error,
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

	if !os.is_file(executable) {
		return Engine_Check{fault = .Executable_Not_Found}
	}
	if !backend_library_present(executable) {
		return Engine_Check{fault = .Backend_Library_Missing}
	}

	probe := probe_executable(group, executable, ENGINE_PROBE_ARGUMENTS, allocator)
	defer delete(probe.captured, allocator)

	return engine_probe_verdict(probe)
}

// Split out of `verify_engine` so the overflow refusal -- and every other
// branch here -- takes a caller-constructed `Probe` and can be proved
// without spawning a real flooding child (`engine_test.odin`).
@(private)
@(require_results)
engine_probe_verdict :: proc(probe: Probe) -> Engine_Check {
	if probe.overflowed {
		return Engine_Check{fault = .Capture_Overflowed}
	}
	switch probe.run {
	case .Not_Started:
		return Engine_Check{fault = .Not_Started, child = probe.child}
	case .Stopped, .Unstoppable:
		return Engine_Check{fault = .Did_Not_Finish}
	case .Finished:
	}
	if !strings.contains(probe.captured, "loaded CUDA backend from") {
		return Engine_Check{fault = .Backend_Not_Loaded}
	}
	return Engine_Check{fault = .None}
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

// A switch, not a table (CLAUDE.md, Odin notes: enumerated arrays and
// switches): a member added without a case here fails the build
// (`Unhandled switch case`). That guard does not reach a case whose arm
// compiles but returns nothing, the way `.None`'s does -- an empty arm is
// not a build failure, only a missing one is. `engine_fault_test.odin`
// walks the enumeration to prove every non-`.None` case still carries a
// sentence, rather than the renderer asserting it on the first Recording
// that hits the gap.
@(private)
@(require_results)
engine_fault_says :: proc(fault: Engine_Fault) -> string {
	switch fault {
	case .Executable_Not_Found:
		return "does not exist, or is not a file -- check the path passed to --engine-exe"
	case .Backend_Library_Missing:
		return(
			"ggml-cuda.dll is not beside the engine's executable; the install is incomplete and the engine will transcribe on the cpu without saying so" \
		)
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
	case .Capture_Overflowed:
		return(
			"reported more diagnostic output than a probe will capture (MAX_PROBE_CAPTURE_BYTES exceeded) and was refused rather than judged on a partial capture" \
		)
	case .None:
	}
	return ""
}

// Issue #208 round 1: the `.Not_Started` branch below used to call
// `child.error_message(check.child, allocator)` unconditionally, reaching
// that procedure's own `assert(err.fault != .None, ...)` (child.odin)
// for any fault-free `.Not_Started` check -- the same reachable-assert
// defect fixed for `model_load_verdict` (src/doctor/model_probe.odin), and
// reachable here through a public procedure. The fault check below means
// this branch never reaches that assert regardless of what any future
// caller-constructed Engine_Check carries.
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

	if check.fault == .Not_Started {
		reason: string
		if check.child.fault != .None {
			reason = child.error_message(check.child, allocator)
		}
		defer if len(reason) > 0 {
			delete(reason, allocator)
		}
		return combined_message(executable, says, reason, allocator)
	}
	return combined_message(executable, says, "", allocator)
}
