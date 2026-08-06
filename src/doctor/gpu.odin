#+vet explicit-allocators
package doctor

// Diagnostics only, per ADR-0011: enumerating a GPU proves nothing about
// whether the Engine can actually reach it, so nothing in this file is ever
// the verdict on GPU usability -- see engine.odin and health.odin for the two
// checks that spawn the Engine and actually decide that.
//
// DXGI, not `core:sys/info.iterate_gpus`: measured directly on this
// repository's own dev machine (round-3 adversarial review), `iterate_gpus`
// enumerates zero adapters even though a real, working NVIDIA GPU is present
// and reachable by the Engine -- every doctor run printed a false "no GPU
// could be enumerated at all" directly beneath a passing `engine` check that
// only exists because the Engine reached that same GPU. `CreateDXGIFactory1`
// and `IFactory1.EnumAdapters1` enumerate the identical machine correctly, so
// this file talks to DXGI directly rather than through the stdlib wrapper.

import "core:fmt"
import "core:mem"
import win32 "core:sys/windows"
import "vendor:directx/dxgi"

Gpu :: struct {
	vendor: string,
	model:  string,
	vram:   i64,
}

// The caller owns the returned slice and every string it names; free both
// with destroy_gpus and the same allocator. Empty means DXGI itself could not
// be reached at all (`CreateDXGIFactory1` failing) -- a real machine always
// enumerates at least the Basic Render Driver, so an empty answer here is
// itself informative rather than the routine case the old stdlib wrapper made
// it look like.
@(require_results)
listed_gpus :: proc(allocator: mem.Allocator) -> (gpus: []Gpu) {
	assert(
		allocator.procedure != nil,
		"the GPU list outlives this procedure and needs an allocator",
	)

	factory_ptr: rawptr
	created := dxgi.CreateDXGIFactory1(dxgi.IFactory1_UUID, &factory_ptr)
	if created < 0 || factory_ptr == nil {
		return {}
	}
	factory := (^dxgi.IFactory1)(factory_ptr)
	defer factory->Release()

	built := make([dynamic]Gpu, 0, 1, allocator)
	index: u32 = 0
	for {
		adapter: ^dxgi.IAdapter1
		enumerated := factory->EnumAdapters1(index, &adapter)
		if enumerated != 0 || adapter == nil {
			break
		}
		append(&built, gpu_from_adapter(adapter, allocator))
		adapter->Release()
		index += 1
	}
	return built[:]
}

@(private)
@(require_results)
gpu_from_adapter :: proc(adapter: ^dxgi.IAdapter1, allocator: mem.Allocator) -> Gpu {
	assert(adapter != nil, "there is no adapter here to describe")
	assert(
		allocator.procedure != nil,
		"the described adapter outlives this procedure and needs an allocator",
	)

	desc: dxgi.ADAPTER_DESC1
	adapter->GetDesc1(&desc)

	name, unreadable := win32.wstring_to_utf8(win32.wstring(&desc.Description[0]), -1, allocator)
	if unreadable != .None {
		name = ""
	}
	return Gpu {
		vendor = fmt.aprintf("0x%04X", desc.VendorId, allocator = allocator),
		model = name,
		vram = i64(desc.DedicatedVideoMemory),
	}
}

destroy_gpus :: proc(gpus: []Gpu, allocator: mem.Allocator) {
	for gpu in gpus {
		delete(gpu.vendor, allocator)
		delete(gpu.model, allocator)
	}
	delete(gpus, allocator)
}
