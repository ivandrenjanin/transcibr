package audio

// This file holds one decision: whether the audio ffmpeg produced is the whole
// Recording.
//
// It is a judgement call, and the judgement is written down here rather than
// left as a number somebody meets later. What is being caught is a source that
// is still being written, truncated, or one that fails to decode part-way -- all
// of which yield audio SHORTER than the Recording, and all of which otherwise
// produce a Transcript that stops mid-sentence and is marked complete forever.
// The container's own duration is the only independent claim about how long the
// Recording is, so it is what the produced audio is measured against.
//
// The tolerance is a pair rather than one number because two different things
// are being allowed for, and they scale differently.

// How far the produced audio may sit from the container's own claim.
//
// Handed in rather than read from a constant inside, so a test can pin the
// arithmetic at tolerances the shipped default never takes -- and so that a
// Batch over material known to carry bad container metadata could one day be
// told to be stricter or looser without an edit here.
Tolerance :: struct {
	// The smallest difference always allowed, whatever the Recording's length.
	floor_ms:  i64,
	// And, past a certain length, a thousandth of the container's duration per
	// unit. Thousandths rather than a percentage because integer arithmetic is
	// what makes the bound exactly pinnable from both sides -- a percentage
	// would be a float, and a float threshold is one nobody can hold to a
	// millisecond.
	per_mille: i64,
}

// What a Batch uses unless it is told otherwise. Every number here was measured;
// duration_test.odin carries the table and pins both constants.
//
// THE FLOOR IS ONE SECOND. It covers the quantisation effects that make a
// well-formed container disagree with its own audio: AAC encoder priming and
// padding, at most 2,112 samples and so 48 ms at 44.1 kHz; one video frame of
// container rounding, 42 ms at 23.976 fps; a non-zero audio start time; and the
// whole-sample rounding of a WAV. The largest measured across five real
// containers of the same 300-second sine was 6 ms, in AC3 inside Matroska. A
// second is twenty times the largest reasoned-about case and 160 times the
// largest measured one.
//
// THE RELATIVE TERM IS A THOUSANDTH, which keeps that margin proportional on a
// long Recording -- the reference corpus's longest is 168 minutes, where it
// allows 10 seconds. It is still three orders of magnitude tighter than the
// smallest real truncation measured here: half an MP3 lost 150 seconds of 300.
DEFAULT_TOLERANCE :: Tolerance {
	floor_ms  = 1000,
	per_mille = 1,
}

// The largest per-mille a caller may ask for, so that the multiplication below
// cannot be walked into an overflow by a policy nobody checked. A thousand
// per-mille is the whole duration, and a tolerance of the whole duration already
// means the check has been turned off.
@(private)
MAX_PER_MILLE :: i64(1000)

// How far apart the two durations may be for this Recording.
allowed_difference_ms :: proc(container_ms: i64, tolerance: Tolerance) -> i64 {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(tolerance.floor_ms >= 0, "a tolerance cannot allow a negative difference")
	assert(tolerance.per_mille >= 0, "a tolerance cannot allow a negative share of the duration")
	assert(tolerance.per_mille <= MAX_PER_MILLE, "a tolerance of more than the whole duration")

	return max(tolerance.floor_ms, container_ms * tolerance.per_mille / 1000)
}

// Whether the audio that came back is the Recording the container describes.
//
// SYMMETRIC, and deliberately: audio shorter than the container is the
// truncation this exists to catch, and audio longer than it is a probe and an
// extraction that were not looking at the same file. A check written only one
// way round passes every truncation case and waves the other through.
//
// Not an assertion anywhere in here (A8). Both durations come from files
// transcibr did not write, and a Recording whose two answers disagree fails on
// its own while the Batch carries on.
durations_agree :: proc(container_ms: i64, audio_ms: i64, tolerance: Tolerance) -> bool {
	assert(container_ms > 0, "a container with no duration was never accepted by the probe")
	assert(audio_ms >= 0, "audio cannot be a negative number of milliseconds long")

	difference := container_ms - audio_ms
	if difference < 0 {
		difference = -difference
	}
	return difference <= allowed_difference_ms(container_ms, tolerance)
}
