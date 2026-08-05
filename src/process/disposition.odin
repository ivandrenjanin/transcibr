#+vet explicit-allocators
package process

// Whether a fault against one Recording means the Recording is done, or the
// same Recording can be tried again -- its command line shortened, or its stale
// Engine output quarantined first. `process` holds the one copy because `child`
// already imports it for Build_Error and gains nothing new, `process` itself has
// no `transcibr:`-internal imports to cycle against, and `transcript` is the only
// package that imports `process` for this type alone. `Quarantine_And_Rerun` is
// never produced here -- only `transcript`'s faults ask for it. See ADR-0030 for
// the placement argument in full, including the trade `Unset` is asserted
// against.
Disposition :: enum u8 {
	Unset = 0,
	Fail_The_Recording,
	Quarantine_And_Rerun,
	Shorten_And_Replan,
}
