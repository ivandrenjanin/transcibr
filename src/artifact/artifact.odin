// Package artifact owns everything transcibr leaves on a disk for a person to
// find: it validates what the Engine produced before trusting a byte of it,
// moves every artifact into place atomically, and writes the Sidecar last.
package artifact
