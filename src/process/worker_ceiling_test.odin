#+vet explicit-allocators
package process

// Relocated from src/pipeline/defaults_test.odin (ADR-0038's worker-ceiling
// section): the original test cannot simply move whole, because it names
// MAX_EXTRACT_WORKERS/MAX_QUEUE_DEPTH six times and pipeline already imports
// transcibr:process, so a copy naming those two constants here would make
// process import pipeline while pipeline imports process -- a cyclic
// importation the compiler reports at this file, not a test-only wrinkle.
// Walking literal representative ceilings instead proves the predicate is
// keyed to whichever ceiling it is handed and not the other option's, a
// property that holds for any two distinct ceilings and not only today's
// pipeline-specific pair -- every assertion the original test made survives,
// including the "itself was accepted against its own ceiling" boundary
// check at each walked value.

import "core:testing"

@(test)
worker_count_within_ceiling_checks_its_own_ceiling_and_not_the_others :: proc(t: ^testing.T) {
	for ceiling in ([]int{1, 2, 5, 9}) {
		testing.expectf(
			t,
			!worker_count_within_ceiling(0, ceiling),
			"zero workers passed against ceiling %d",
			ceiling,
		)
		for count in 1 ..= ceiling {
			testing.expectf(
				t,
				worker_count_within_ceiling(count, ceiling),
				"%d workers refused against a ceiling of %d",
				count,
				ceiling,
			)
		}
		testing.expectf(
			t,
			!worker_count_within_ceiling(ceiling + 1, ceiling),
			"%d workers passed against a ceiling of %d",
			ceiling + 1,
			ceiling,
		)
		testing.expectf(
			t,
			worker_count_within_ceiling(ceiling, ceiling),
			"%d itself was refused against its own ceiling",
			ceiling,
		)
	}
}
