package audio

import "core:encoding/endian"
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

	// 78 and not 44, which is the criterion this ticket exists for. THIS is the
	// pin rule A5 is about, and the reason the number lives in an assertion
	// rather than in the comment above it: the day ffmpeg's version string
	// changes length the payload moves and every other number below holds, so
	// this line is the only one that goes red and sends the next reader to a hex
	// dump.
	testing.expect_value(t, facts.data_offset, 78)
	// And read back a second way, through the length the walk came home with. At
	// 44 the four bytes taken for the `data` length are the middle of the `LIST`
	// chunk's own header, and 6,400 is not what they say.
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

// ------------------------------------------ the audio that was asked for --
//
// The read side of `-ac 1 -ar 16000 -c:a pcm_s16le` (A4). All three numbers,
// because the third had a write side and nothing at all on the read side.

@(test)
real_ffmpeg_output_is_the_audio_the_command_line_asked_for :: proc(t: ^testing.T) {
	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)
	testing.expect(t, as_asked_for(facts), "real ffmpeg output is not what ffmpeg was asked for")
}

@(test)
audio_of_the_wrong_bit_depth_is_refused_however_right_the_rest_of_it_is :: proc(t: ^testing.T) {
	// The bit depth is the last field of the `fmt ` payload, which the dump puts
	// at offset 34. Everything else is left alone: one channel, 16,000 samples a
	// second and a byte rate of 32,000, so this file walks with no fault at all
	// and is refused for the one thing that is wrong with it.
	//
	// The Engine reads 16-bit PCM and nothing else. Eight is a real ffmpeg
	// output format (`-c:a pcm_u8`), and zero is what a `fmt ` chunk carries when
	// whatever wrote it did not fill the field -- `Nonsense_Format` guards the
	// rate, the channels and the byte rate, and neither of these.
	eight := edited_fixture()
	eight[34] = 8
	shallow, shallow_fault := read_wav_facts(eight[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, shallow_fault, Riff_Fault.None)
	testing.expect_value(t, shallow.bits_per_sample, 8)
	testing.expect(
		t,
		!as_asked_for(shallow),
		"eight-bit audio passed as the mono 16 kHz asked for",
	)

	none := edited_fixture()
	none[34] = 0
	nothing, nothing_fault := read_wav_facts(none[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, nothing_fault, Riff_Fault.None)
	testing.expect(t, !as_asked_for(nothing), "audio declaring no bit depth at all was accepted")
}

@(test)
audio_of_the_wrong_rate_or_channel_count_is_refused :: proc(t: ^testing.T) {
	// The two that were already paired, kept as cases so the pairing cannot be
	// dropped quietly while the depth check stands in for all three.
	stereo := edited_fixture()
	stereo[22] = 2
	two, two_fault := read_wav_facts(stereo[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, two_fault, Riff_Fault.None)
	testing.expect(t, !as_asked_for(two), "stereo audio passed as the mono it was asked for")

	fast := edited_fixture()
	// 44,100 over the four bytes of the sample rate at offset 24.
	put_length(fast[:], 24, 44_100)
	rate, rate_fault := read_wav_facts(fast[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, rate_fault, Riff_Fault.None)
	testing.expect(t, !as_asked_for(rate), "44.1 kHz audio passed as the 16 kHz it was asked for")
}

// The fixture on the stack, so a case may edit it without touching the bytes
// every other case reads.
@(private)
edited_fixture :: proc() -> (copied: [FFMPEG_WAV_BYTES]u8) {
	copy(copied[:], FFMPEG_WAV)
	return
}

// One four-byte little-endian length written into a buffer, so a case edits a
// chunk length the way the file spells it. Writing only the low byte and leaving
// the other three is how two cases below first failed: the length they meant to
// shrink stayed in the thousands.
//
// `core:encoding/endian` is the four assignments spelled once, and it reports a
// buffer too short to hold them rather than writing off the end.
@(private)
put_length :: proc(bytes: []u8, at: int, length: u32) {
	written := endian.put_u32(bytes[at:], .Little, length)
	assert(written, "a chunk length was written past the end of the buffer")
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

// A WAV carrying TWO `fmt ` chunks, which RIFF permits and ffmpeg does not
// write. The second says stereo at 48 kHz; everything else is the fixture.
@(private)
TWO_FMT_WAV_BYTES :: 72
@(private)
two_fmt_wav :: proc() -> (bytes: [TWO_FMT_WAV_BYTES]u8) {
	whole := edited_fixture()
	copy(bytes[:], whole[:36]) // RIFF, WAVE and the whole fmt chunk
	copy(bytes[36:60], whole[12:36]) // and the same fmt chunk over again
	put_length(bytes[:], 4, TWO_FMT_WAV_BYTES - size_of(Riff_Chunk_Header))
	// The second one, edited: two channels at 48,000 samples a second, and the
	// byte rate that goes with them.
	bytes[46] = 2
	put_length(bytes[:], 48, 48_000)
	put_length(bytes[:], 52, 192_000)
	copy(bytes[60:], "data")
	put_length(bytes[:], 64, 4)
	return
}

@(test)
the_first_fmt_chunk_is_the_one_that_describes_the_audio :: proc(t: ^testing.T) {
	// RIFF permits a second `fmt ` chunk and says nothing about which of them
	// describes the `data` that follows, so the walk has to CHOOSE -- and the
	// walk was choosing by accident. Each `fmt ` it met overwrote the last, so
	// the last one before the data chunk won, and this file walked out as stereo
	// at 48 kHz.
	//
	// Nothing downstream was hurt by that, because as_asked_for refuses both
	// answers. It is pinned anyway: an accident that happens to be safe is not a
	// decision, and the day a second `fmt ` says something as_asked_for accepts
	// is the day it matters which one was read.
	bytes := two_fmt_wav()
	facts, fault := read_wav_facts(bytes[:], TWO_FMT_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	testing.expect_value(t, facts.channels, 1)
	testing.expect_value(t, facts.samples_per_second, 16000)
	testing.expect_value(t, facts.bytes_per_second, 32000)
	// The data chunk is still found, past both of them: it sits at 68, and a walk
	// that stopped anywhere short of it would not answer with its length.
	testing.expect_value(t, facts.data_bytes, 4)
}

@(test)
the_pad_byte_after_an_odd_length_chunk_is_stepped_over :: proc(t: ^testing.T) {
	bytes := odd_chunk_wav()
	facts, fault := read_wav_facts(bytes[:], ODD_CHUNK_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	// 36 + 8 header + 1 payload + 1 pad = 46, and the data payload eight bytes
	// past that, at 54. A walker that skipped the pad would look for a chunk at
	// 45, read an identifier out of the middle of `data`, and never answer with
	// its length at all.
	testing.expect_value(t, facts.data_bytes, 4)
}
