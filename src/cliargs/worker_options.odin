#+vet explicit-allocators
// The #94/#124 upgrade ADR-0038 calls for: the option-name-to-ceiling
// pairing as an enum-keyed table rather than pipeline's string-keyed
// WORKER_OPTION_CEILINGS, so a table left incomplete does not build
// (`Unhandled enumerated array case`) instead of running with a silently
// absent ceiling. cliargs owns the enum and the table's SHAPE; the actual
// ceiling ints stay pipeline's own (ADR-0006's bounds), filled into a
// Worker_Ceilings value by src/cli, immediately before dispatch, from
// pipeline.MAX_EXTRACT_WORKERS and pipeline.MAX_QUEUE_DEPTH -- both already
// `::` constants, so no runtime pipeline.worker_option_ceiling lookup
// crosses the fence at all, and the literal itself is what the compiler
// checks for completeness (ADR-0038 addendum, resolving the ADR's own
// "ceiling-lookup placement" wrinkle for the batch migration).
package cliargs

Worker_Option :: enum {
	Extract_Workers,
	Queue_Depth,
}

Worker_Ceilings :: [Worker_Option]int
