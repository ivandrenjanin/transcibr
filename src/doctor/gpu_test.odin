#+vet explicit-allocators
package doctor

import "core:testing"

// The finding this pins: `core:sys/info.iterate_gpus` enumerated zero
// adapters on this repository's own dev machine even though a real, working
// NVIDIA GPU was present and reachable by the Engine. Windows always
// enumerates at least a Basic Render Driver through DXGI, so a real,
// unmocked call here proving `len(gpus) > 0` is the only proof this file's
// switch away from that stdlib wrapper actually fixed anything -- a mock
// would prove nothing about the machine `iterate_gpus` was wrong about.
@(test)
review_dxgi_enumerates_at_least_one_real_adapter_on_this_machine :: proc(t: ^testing.T) {
	gpus := listed_gpus(context.allocator)
	defer destroy_gpus(gpus, context.allocator)

	if !testing.expect(
		t,
		len(gpus) > 0,
		"DXGI enumerated no adapters at all on a real Windows machine",
	) {
		return
	}
	testing.expect(t, len(gpus[0].vendor) > 0, "an enumerated adapter named no vendor")
}
