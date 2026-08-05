#+vet explicit-allocators
package process

// Whether a fault against one Recording means the Recording is done, or the
// same Recording can be tried again -- its command line shortened, or its stale
// Engine output quarantined first. `process` holds the one copy because every
// package that reports a Disposition already imports it for Build_Fault or
// ascii_only, and two of the three values below are never produced here: see
// ADR-0030.
Disposition :: enum u8 {
	Fail_The_Recording = 0,
	Quarantine_And_Rerun,
	Shorten_And_Replan,
}
