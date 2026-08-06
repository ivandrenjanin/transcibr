#+vet explicit-allocators
package doctor

// Diagnostics only, per ADR-0011: enumerating a GPU proves nothing about
// whether the Engine can actually reach it, so nothing in this file is ever
// the verdict on GPU usability -- see engine.odin and health.odin for the two
// checks that spawn the Engine and actually decide that.

import "core:mem"
import "core:strings"
import "core:sys/info"

Gpu :: struct {
	vendor: string,
	model:  string,
	driver: string,
	vram:   i64,
}

// The caller owns the returned slice and every string it names; free both
// with destroy_gpus and the same allocator. Empty covers two things this
// procedure cannot tell apart -- a machine with no adapter Windows will name,
// and a platform `core:sys/info` does not enumerate on at all -- and the
// diagnostic check reads both the identical way: nothing here to report.
@(require_results)
listed_gpus :: proc(allocator: mem.Allocator) -> (gpus: []Gpu) {
	assert(
		allocator.procedure != nil,
		"the GPU list outlives this procedure and needs an allocator",
	)

	built := make([dynamic]Gpu, 0, 1, allocator)
	it: info.GPU_Iterator
	for gpu in info.iterate_gpus(&it) {
		append(
			&built,
			Gpu {
				vendor = strings.clone(gpu.vendor, allocator),
				model = strings.clone(gpu.model, allocator),
				driver = strings.clone(gpu.driver, allocator),
				vram = gpu.vram,
			},
		)
	}
	return built[:]
}

destroy_gpus :: proc(gpus: []Gpu, allocator: mem.Allocator) {
	for gpu in gpus {
		delete(gpu.vendor, allocator)
		delete(gpu.model, allocator)
		delete(gpu.driver, allocator)
	}
	delete(gpus, allocator)
}
