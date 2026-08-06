#+vet explicit-allocators
package child

import "core:thread"

// The `.Unstoppable`-do-not-release contract, spelled once (issue #66):
// every bounded one-shot call in this tree -- `read_bounded`,
// `make_directory_bounded`, `list_directory_bounded`,
// `artifact.digest_of_bounded`, `audio.read_head_bounded`,
// `engine.landed_bounded`, and the worker-tier joins in `transcibr:pipeline`
// -- used to spell this exact three-case switch on `Wait` by hand:
// `.Finished`/`.Stopped` are safe to reclaim, `.Unstoppable` is not, and only
// `.Finished` means whatever the thread was writing into is actually
// trustworthy. `reclaim_for` names that mapping once and exhaustively, the
// same shape `transcript_state_of` (`transcibr:planning`'s `walk.odin`) uses
// for its own per-caller `Wait` vocabulary, so a member added to `Wait`
// fails the build here rather than falling through silently.
@(require_results)
reclaim_for :: proc(wait: Wait) -> (finished: bool, reclaim: bool) {
	switch wait {
	case .Finished:
		return true, true
	case .Stopped:
		return false, true
	case .Unstoppable:
		return false, false
	}
	unreachable()
}

// `await_or_abandon` plus `reclaim_for` in one call -- the whole of what
// every site above used to re-derive as its own switch. `finished` decides
// whether `t`'s job holds a real answer; `reclaim` decides whether `t` and
// that job may be touched again at all. A caller must check `reclaim`
// before it frees or reads anything the job wrote, never only `finished`:
// `.Stopped` is `!finished` yet still `reclaim`, because a cancelled thread
// is known idle even though it never produced an answer.
@(require_results)
await_and_reclaim :: proc(t: ^thread.Thread, bound_ms: i64) -> (finished: bool, reclaim: bool) {
	return reclaim_for(await_or_abandon(t, bound_ms))
}
