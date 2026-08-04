package audio

import "core:encoding/endian"
import "core:testing"

// Not hand-built: what ffmpeg wrote from a 0.2-second clip under this package's
// own argument list, committed byte for byte, with every number below read off a
// hex dump of it. Why the chunks are walked: ADR-0022.
@(private)
FFMPEG_WAV :: #load("fixtures/ffmpeg-mono-16k.wav")

// Read off the file, so a checkout that rewrote the fixture fails here.
@(private)
FFMPEG_WAV_BYTES :: 6478

@(test)
real_ffmpeg_output_does_not_put_its_data_chunk_at_byte_44 :: proc(t: ^testing.T) {
	testing.expect_value(t, len(FFMPEG_WAV), FFMPEG_WAV_BYTES)

	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

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
	testing.expect_value(t, facts.bytes_per_second, 32000)
}

@(test)
the_length_of_real_ffmpeg_output_comes_from_its_data_chunk :: proc(t: ^testing.T) {
	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	testing.expect_value(t, audio_ms(facts), i64(200))
}

@(test)
real_ffmpeg_output_is_the_audio_the_command_line_asked_for :: proc(t: ^testing.T) {
	facts, fault := read_wav_facts(FFMPEG_WAV, FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)
	testing.expect(t, as_asked_for(facts), "real ffmpeg output is not what ffmpeg was asked for")
}

@(test)
audio_of_the_wrong_bit_depth_is_refused_however_right_the_rest_of_it_is :: proc(t: ^testing.T) {
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
	stereo := edited_fixture()
	stereo[22] = 2
	two, two_fault := read_wav_facts(stereo[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, two_fault, Riff_Fault.None)
	testing.expect(t, !as_asked_for(two), "stereo audio passed as the mono it was asked for")

	fast := edited_fixture()
	put_length(fast[:], 24, 44_100)
	rate, rate_fault := read_wav_facts(fast[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, rate_fault, Riff_Fault.None)
	testing.expect(t, !as_asked_for(rate), "44.1 kHz audio passed as the 16 kHz it was asked for")
}

@(private)
@(require_results)
edited_fixture :: proc() -> (copied: [FFMPEG_WAV_BYTES]u8) {
	copy(copied[:], FFMPEG_WAV)
	return
}

// Writing only the low byte and leaving the other three is how two cases here
// first failed: the length they meant to shrink stayed in the thousands.
@(private)
put_length :: proc(bytes: []u8, at: int, length: u32) {
	written := endian.put_u32(bytes[at:], .Little, length)
	assert(written, "a chunk length was written past the end of the buffer")
}

@(test)
a_wav_the_head_does_not_reach_the_end_of_is_not_a_wav_without_a_data_chunk :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	_, fault := read_wav_facts(bytes[:44], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Head_Too_Short)
}

@(test)
a_wav_cut_in_half_is_refused_rather_than_read_as_half_the_audio :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	half := FFMPEG_WAV_BYTES / 2
	_, fault := read_wav_facts(bytes[:half], i64(half))
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
the_placeholder_lengths_a_killed_ffmpeg_leaves_behind_are_refused :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	for at in 4 ..< 8 {
		bytes[at] = 0xFF
	}
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
a_data_chunk_claiming_more_than_the_file_holds_is_refused :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	bytes[74] = 0xFF
	bytes[75] = 0xFF
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Truncated)
}

@(test)
something_that_is_not_riff_at_all_is_refused :: proc(t: ^testing.T) {
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
	bytes := edited_fixture()
	bytes[20] = 3
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Not_Pcm)
}

@(test)
a_sample_rate_of_zero_is_refused_rather_than_divided_by :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	for at in 28 ..< 32 {
		bytes[at] = 0
	}
	_, fault := read_wav_facts(bytes[:], FFMPEG_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.Nonsense_Format)
}

@(test)
a_well_formed_file_holding_no_audio_at_all_is_refused :: proc(t: ^testing.T) {
	bytes := edited_fixture()
	put_length(bytes[:], 74, 0)
	put_length(bytes[:], 4, 78 - size_of(Riff_Chunk_Header))
	_, fault := read_wav_facts(bytes[:78], 78)
	testing.expect_value(t, fault, Riff_Fault.Empty_Data_Chunk)
}

// Assembled here rather than by ffmpeg: `junk` is one byte long, and the pad
// byte after an odd length is not counted in it.
@(private)
ODD_CHUNK_WAV_BYTES :: 58
@(private)
@(require_results)
odd_chunk_wav :: proc() -> (bytes: [ODD_CHUNK_WAV_BYTES]u8) {
	whole := edited_fixture()
	copy(bytes[:], whole[:36])
	put_length(bytes[:], 4, ODD_CHUNK_WAV_BYTES - size_of(Riff_Chunk_Header))
	copy(bytes[36:], "junk")
	put_length(bytes[:], 40, 1)
	copy(bytes[46:], "data")
	put_length(bytes[:], 50, 4)
	return
}

// Two `fmt ` chunks, which RIFF permits and ffmpeg does not write.
@(private)
TWO_FMT_WAV_BYTES :: 72
@(private)
@(require_results)
two_fmt_wav :: proc() -> (bytes: [TWO_FMT_WAV_BYTES]u8) {
	whole := edited_fixture()
	copy(bytes[:], whole[:36])
	copy(bytes[36:60], whole[12:36])
	put_length(bytes[:], 4, TWO_FMT_WAV_BYTES - size_of(Riff_Chunk_Header))
	bytes[46] = 2
	put_length(bytes[:], 48, 48_000)
	put_length(bytes[:], 52, 192_000)
	copy(bytes[60:], "data")
	put_length(bytes[:], 64, 4)
	return
}

@(test)
the_first_fmt_chunk_is_the_one_that_describes_the_audio :: proc(t: ^testing.T) {
	bytes := two_fmt_wav()
	facts, fault := read_wav_facts(bytes[:], TWO_FMT_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	testing.expect_value(t, facts.channels, 1)
	testing.expect_value(t, facts.samples_per_second, 16000)
	testing.expect_value(t, facts.bytes_per_second, 32000)
	testing.expect_value(t, facts.data_bytes, 4)
}

@(test)
the_pad_byte_after_an_odd_length_chunk_is_stepped_over :: proc(t: ^testing.T) {
	bytes := odd_chunk_wav()
	facts, fault := read_wav_facts(bytes[:], ODD_CHUNK_WAV_BYTES)
	testing.expect_value(t, fault, Riff_Fault.None)

	testing.expect_value(t, facts.data_bytes, 4)
}
