package audio

import "core:testing"

// This file is the READ SIDE of what ffmpeg was asked for (CLAUDE.md A4). The
// extraction spells `-ac 1 -ar 16000` on the command line; these cases are what
// checks it got it, and they walk the chunks to find out rather than reading a
// fixed offset.
//
// THE FIXTURE IS THE WHOLE POINT. `fixtures/ffmpeg-mono-16k.wav` is not
// hand-built: it is what ffmpeg actually wrote from a 0.2-second clip under the
// argument list this package builds, committed byte for byte under
// `**/fixtures/** -text`. Every number below was read off a hex dump of that
// file before a line of riff.odin existed, so no case here can agree with the
// walker by construction.
//
// What the dump said, and what CLAUDE.md rule A5 uses this ticket to illustrate:
//
//   0   RIFF <size> WAVE                      12 bytes
//   12  `fmt ` 16 <PCM body>                  24 bytes, ending at 36
//   36  `LIST` 26 INFO ISFT 13 "Lavf63.5.101" 34 bytes, ending at 70
//   70  `data` 6400                            8 bytes, payload at 78
//
// ffmpeg's muxer writes that `LIST`/`INFO` chunk unconditionally, so the payload
// starts at 78 and NOT at 44. A reader that assumed 44 would take 34 bytes of
// the chunk table as audio and report a length 34 bytes long.
@(private)
FFMPEG_WAV :: #load("fixtures/ffmpeg-mono-16k.wav")

// The fixture's own length, held so a checkout that rewrote it fails HERE rather
// than as an unreadable difference in every case below. Read off the file, not
// computed.
@(private)
FFMPEG_WAV_BYTES :: 6478

@(test)
real_ffmpeg_output_does_not_put_its_data_chunk_at_byte_44 :: proc(t: ^testing.T) {
	testing.expect_value(t, len(FFMPEG_WAV), FFMPEG_WAV_BYTES)

	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	// 78 and not 44, which is the criterion this ticket exists for.
	testing.expect_value(t, facts.data_offset, 78)
	testing.expect_value(t, facts.data_bytes, 6400)
}

@(test)
real_ffmpeg_output_is_the_mono_16_khz_the_command_line_asked_for :: proc(t: ^testing.T) {
	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	testing.expect_value(t, facts.channels, 1)
	testing.expect_value(t, facts.samples_per_second, 16000)
	testing.expect_value(t, facts.bits_per_sample, 16)
	// 16000 samples a second, two bytes each, one channel.
	testing.expect_value(t, facts.bytes_per_second, 32000)
}

@(test)
the_length_of_real_ffmpeg_output_comes_from_its_data_chunk :: proc(t: ^testing.T) {
	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	// The clip ffmpeg was given was 0.2 seconds long, and 6400 bytes at 32,000
	// bytes a second is exactly that. A reader starting at 44 would answer 201.
	testing.expect_value(t, audio_ms(facts), i64(200))
}

// The fixture on the stack, so a case may edit it without touching the bytes
// every other case reads.
@(private)
edited_fixture :: proc() -> (copied: [FFMPEG_WAV_BYTES]u8) {
	copy(copied[:], FFMPEG_WAV)
	return
}

// One four-byte little-endian length written into a buffer, spelled out byte by
// byte so a case edits a chunk length the way the file spells it. Writing only
// the low byte and leaving the other three is how two cases below first failed:
// the length they meant to shrink stayed in the thousands.
@(private)
put_length :: proc(bytes: []u8, at: int, length: u32) {
	bytes[at] = u8(length)
	bytes[at + 1] = u8(length >> 8)
	bytes[at + 2] = u8(length >> 16)
	bytes[at + 3] = u8(length >> 24)
}

// ------------------------------------------------------- the negative space --
//
// Rule A3: every case above is satisfied by a walker that accepts anything at
// all, and the criterion this package exists for is that a Recording whose audio
// came back wrong FAILS rather than being transcribed half-way and marked
// complete forever.

@(test)
a_wav_the_head_does_not_reach_the_end_of_is_not_a_wav_without_a_data_chunk :: proc(t: ^testing.T) {
	// FORTY-FOUR BYTES exactly, which is the header size the assumption this
	// package refuses would have read. It covers `RIFF`, `WAVE`, the whole
	// `fmt ` chunk and the first eight bytes of the `LIST` chunk -- so a walker
	// that ran out here and said "no data chunk" would report a malformed file
	// for a file that is perfectly well formed and merely unread.
	bytes := edited_fixture()
	_, fault := read_wav_facts(bytes[:44], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Head_Too_Short)
}

@(test)
a_wav_cut_in_half_is_refused_rather_than_read_as_half_the_audio :: proc(t: ^testing.T) {
	// The real file, with the real chunk lengths, and half the bytes. This is
	// the shape a Stop press or a full disk leaves behind, and the reason the
	// lengths are checked against the file rather than trusted.
	bytes := edited_fixture()
	half := FFMPEG_WAV_BYTES / 2
	_, fault := read_wav_facts(bytes[:half], i64(half))
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
the_placeholder_lengths_a_killed_ffmpeg_leaves_behind_are_refused :: proc(t: ^testing.T) {
	// ffmpeg writes -1 into the RIFF and data lengths and seeks back to patch
	// them when it closes the file, so this is exactly what is on disk when it
	// is killed part-way through -- with every byte before it well formed.
	bytes := edited_fixture()
	for at in 4 ..< 8 {
		bytes[at] = 0xFF
	}
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
a_data_chunk_claiming_more_than_the_file_holds_is_refused :: proc(t: ^testing.T) {
	// The RIFF length left alone and only the data length inflated, so this
	// case cannot pass on the check above.
	bytes := edited_fixture()
	bytes[74] = 0xFF
	bytes[75] = 0xFF
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
something_that_is_not_riff_at_all_is_refused :: proc(t: ^testing.T) {
	// An HTML error page saved under a .wav name is the shape this catches; any
	// twelve bytes that are not `RIFF` will do.
	_, fault := read_wav_facts(transmute([]u8)string("<!doctype html>"), 15)
	testing.expect_value(t, fault, Riff_Fault.Not_Riff)
}

@(test)
a_riff_file_that_is_not_a_wave_is_refused :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	copy(bytes[8:12], "AVI ")
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Not_Wave)
}

@(test)
audio_that_is_not_pcm_is_refused_rather_than_decoded_hopefully :: proc(t: ^testing.T) {
	// The format tag is the first field of the `fmt ` payload, which the dump
	// puts at offset 20. 3 is IEEE float, which the Engine does not read.
	bytes := edited_fixture()
	bytes[20] = 3
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Not_Pcm)
}

@(test)
a_sample_rate_of_zero_is_refused_rather_than_divided_by :: proc(t: ^testing.T) {
	// The byte rate is the divisor audio_ms uses, at offset 28.
	bytes := edited_fixture()
	for at in 28 ..< 32 {
		bytes[at] = 0
	}
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Nonsense_Format)
}

@(test)
a_well_formed_file_holding_no_audio_at_all_is_refused :: proc(t: ^testing.T) {
	// ADR-0002's own case one layer down: exit code zero means nothing, and a
	// run that produced a file with a valid header and no samples in it reports
	// success everywhere else.
	bytes := edited_fixture()
	put_length(bytes[:], 74, 0)
	// The RIFF length shrinks with it, so the file is well formed rather than
	// merely inconsistent -- otherwise this passes on the truncation check
	// above and says nothing about an empty data chunk at all.
	put_length(bytes[:], 4, 78 - size_of(Riff_Chunk_Header))
	_, fault := read_wav_facts(bytes[:78], 78)
	testing.expect_value(t, fault, Riff_Fault.Empty_Data_Chunk)
}

// A WAV assembled here rather than by ffmpeg, so a case can put a chunk shape
// in it that ffmpeg does not currently write. `junk` is one byte long, which is
// ODD -- the pad byte after it is not counted in its length, and a walker that
// forgets it reads every later chunk one byte off and finds nothing.
@(private)
ODD_CHUNK_WAV_BYTES :: 58
@(private)
odd_chunk_wav :: proc() -> (bytes: [ODD_CHUNK_WAV_BYTES]u8) {
	whole := edited_fixture()
	copy(bytes[:], whole[:36]) // RIFF, WAVE and the whole fmt chunk
	put_length(bytes[:], 4, ODD_CHUNK_WAV_BYTES - size_of(Riff_Chunk_Header))
	copy(bytes[36:], "junk")
	put_length(bytes[:], 40, 1)
	copy(bytes[46:], "data")
	put_length(bytes[:], 50, 4)
	return
}

@(test)
the_pad_byte_after_an_odd_length_chunk_is_stepped_over :: proc(t: ^testing.T) {
	bytes := odd_chunk_wav()
	facts, fault := read_wav_facts(bytes[:], ODD_CHUNK_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	// 36 + 8 header + 1 payload + 1 pad = 46, and the data payload eight bytes
	// past that. A walker that skipped the pad would look for a chunk at 45 and
	// find nothing at all.
	testing.expect_value(t, facts.data_offset, 54)
	testing.expect_value(t, facts.data_bytes, 4)
}
