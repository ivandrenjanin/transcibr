package audio

import "core:mem"

// This file reads back what ffmpeg wrote by WALKING the chunks it wrote, which
// is the only way to find where the audio starts.
//
// The temptation is a 44-byte header struct, and CLAUDE.md rule A5 uses this
// exact file as its worked example of why that fails. ffmpeg's WAV muxer writes
// a `LIST`/`INFO` chunk carrying its own version string between `fmt ` and
// `data`, unconditionally, so the payload begins at a per-file offset -- 78 in
// `fixtures/ffmpeg-mono-16k.wav`, and something else the day that version string
// changes length. `#assert(size_of(Wav_Header) == 44)` is the claim that looks
// rigorous, passes review, and fires on the first real input.
//
// So the two records below are the shapes of two RECORDS, each of which really
// is a fixed run of bytes, and there is deliberately no record for the file.

// The eight bytes every RIFF chunk begins with: a four-byte identifier and the
// length of the payload that follows it.
//
// Little-endian by declaration and not by assumption. RIFF is little-endian
// whatever the machine is -- the big-endian variant announces itself as `RIFX`
// and is refused as `.Not_Riff` -- so `u32le` is the type that says so and reads
// correctly wherever this is compiled.
Riff_Chunk_Header :: struct #packed {
	id:    [4]u8,
	bytes: u32le,
}

// A record, not a file layout (A5): four bytes of identifier and four of length,
// with nothing between them and nothing implied about what follows.
#assert(size_of(Riff_Chunk_Header) == 8)

// The payload of a PCM `fmt ` chunk, which is the one chunk shape this package
// needs and the one that genuinely is a fixed run of bytes.
//
// Sixteen is the PCM length. A `fmt ` chunk may be LONGER -- 18 bytes for the
// extensible header's `cbSize`, 40 for `WAVE_FORMAT_EXTENSIBLE` -- so the length
// is read from the chunk and only the first sixteen bytes are decoded. A reader
// demanding exactly sixteen would refuse a file ffmpeg can be configured to
// write.
Wav_Fmt_Body :: struct #packed {
	format:             u16le,
	channels:           u16le,
	samples_per_second: u32le,
	bytes_per_second:   u32le,
	block_align:        u16le,
	bits_per_sample:    u16le,
}

#assert(size_of(Wav_Fmt_Body) == 16)

// `WAVE_FORMAT_PCM`. The Engine reads 16-bit PCM and nothing else, so a `fmt `
// chunk announcing anything else is refused rather than decoded on the chance
// that it might work.
@(private)
WAVE_FORMAT_PCM :: 1

// Where the first chunk starts: `RIFF`, its length, and the four-byte form type.
@(private)
FIRST_CHUNK :: 12

// What was wrong with a piece of audio ffmpeg produced.
//
// Every one of these is an OPERATING error (A8): the file was written by another
// program, and a Recording whose audio comes back malformed fails on its own
// while the Batch carries on. None of them may reach an assertion.
Riff_Fault :: enum u8 {
	None = 0,
	// No `RIFF` at the front. An empty file, an ffmpeg that wrote nothing, or
	// the big-endian `RIFX` this package does not read.
	Not_Riff,
	// A RIFF file of some other kind -- `AVI `, `WEBP`. Never what was asked
	// for here, and never audio.
	Not_Wave,
	// A chunk claims more bytes than the file holds. THE TRUNCATION DETECTOR,
	// and the reason the lengths are checked rather than trusted: ffmpeg writes
	// placeholder lengths and seeks back to patch them when it closes the file,
	// so a killed ffmpeg leaves 0xFFFFFFFF in both the RIFF length and the data
	// length, and every byte before them is perfectly well formed.
	Truncated,
	// The chunk table runs past what was READ, which is not the same as running
	// past the file. Reported apart so that a buffer too small is never
	// mistaken for a malformed file -- the two are fixed in different places.
	Head_Too_Short,
	No_Fmt_Chunk,
	// A `fmt ` chunk too short to be PCM at all.
	Short_Fmt_Chunk,
	Not_Pcm,
	No_Data_Chunk,
	// A `data` chunk of no bytes at all. ADR-0002's own case, one layer down:
	// exit code zero means nothing, and a run that produced a well-formed file
	// holding no audio is a failure that reports success everywhere else.
	Empty_Data_Chunk,
	// A rate, a channel count or a byte rate of zero. Refused here rather than
	// left to divide by zero in audio_ms.
	Nonsense_Format,
}

// Everything this package needs to know about a piece of audio ffmpeg wrote.
//
// `int` rather than the widths the file spells them in: these are decoded
// values used as lengths and divisors in this process, never written back out
// (CLAUDE.md rule T1). The one exception is `data_bytes`, which is a file
// length and is i64 for the same reason every file length here is.
Wav_Facts :: struct {
	channels:           int,
	samples_per_second: int,
	bytes_per_second:   int,
	bits_per_sample:    int,
	// Where the audio itself begins -- the `data` chunk's PAYLOAD, past its
	// eight-byte header.
	data_offset:        int,
	data_bytes:         i64,
}

// Walks the chunks of a WAV and answers what the audio in it is.
//
// `head` is the front of the file and need not be all of it; `file_bytes` is how
// long the whole file is. Splitting them is what lets a caller read a few
// kilobytes off a multi-hundred-megabyte file and still check the lengths
// against the real one.
//
// A8: every byte here was written by ffmpeg, which is outside this program, so
// every refusal travels in `fault`.
read_wav_facts :: proc(head: []u8, file_bytes: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	assert(file_bytes >= 0, "a file cannot hold a negative number of bytes")
	assert(i64(len(head)) <= file_bytes, "more head was read than the file was said to hold")

	container, present := chunk_at(head, 0)
	if !present || len(head) < FIRST_CHUNK {
		return {}, .Head_Too_Short
	}
	if string(container.id[:]) != "RIFF" {
		return {}, .Not_Riff
	}
	// The RIFF length covers everything after it, so the file must hold that
	// plus the identifier and the length itself.
	if i64(u32(container.bytes)) + size_of(Riff_Chunk_Header) > file_bytes {
		return {}, .Truncated
	}
	if string(head[8:FIRST_CHUNK]) != "WAVE" {
		return {}, .Not_Wave
	}
	return walk_chunks(head, file_bytes)
}

// The chunk table itself, from the first chunk to the `data` chunk.
//
// Split from read_wav_facts because the two are different jobs and neither fits
// beside the other under rule F1: this one is a loop, and what it walks has
// already been established to be a WAVE.
@(private)
walk_chunks :: proc(head: []u8, file_bytes: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	assert(len(head) >= FIRST_CHUNK, "the chunk table was walked before the form type was read")

	found_format := false
	at := FIRST_CHUNK
	for {
		header, present := chunk_at(head, at)
		if !present {
			// Out of head. Whether the FILE ran out too is the difference
			// between a malformed WAV and a buffer that was too small.
			if i64(len(head)) < file_bytes {
				return {}, .Head_Too_Short
			}
			break
		}
		payload := at + size_of(Riff_Chunk_Header)
		length := i64(u32(header.bytes))
		if i64(payload) + length > file_bytes {
			return {}, .Truncated
		}

		switch string(header.id[:]) {
		case "fmt ":
			facts, fault = read_fmt(head, payload, length)
			if fault != .None {
				return {}, fault
			}
			found_format = true
		case "data":
			if !found_format {
				return {}, .No_Fmt_Chunk
			}
			if length == 0 {
				return {}, .Empty_Data_Chunk
			}
			// The write-side check on the walk's own arithmetic (A4): the
			// payload of any chunk sits past the form type, and audio_ms
			// asserts the read side of the same claim.
			assert(payload >= FIRST_CHUNK, "a chunk payload landed inside the RIFF header")
			facts.data_offset = payload
			facts.data_bytes = length
			return facts, .None
		}
		// Chunks are padded to an even length, and the pad byte is not counted
		// in the length. Without this every chunk after an odd one is read from
		// one byte off and the walk finds nothing at all.
		at = payload + int(length) + int(length & 1)
	}

	if !found_format {
		return {}, .No_Fmt_Chunk
	}
	return {}, .No_Data_Chunk
}

// One chunk header read out of the buffer, or nothing where the buffer ends
// first. The ONE place a chunk header is read, so the bounds check cannot be
// remembered at one call site and forgotten at the next.
@(private)
chunk_at :: proc(head: []u8, at: int) -> (header: Riff_Chunk_Header, present: bool) {
	assert(at >= 0, "a chunk cannot sit at a negative offset")

	if at > len(head) - size_of(Riff_Chunk_Header) {
		return {}, false
	}
	// A byte copy and not a cast: the buffer is whatever the filesystem handed
	// back and carries no alignment, and every field is declared
	// little-endian, which is the order the bytes are already in.
	mem.copy(&header, raw_data(head[at:]), size_of(Riff_Chunk_Header))
	return header, true
}

// The first sixteen bytes of a `fmt ` payload, decoded.
@(private)
read_fmt :: proc(head: []u8, payload: int, length: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	assert(payload >= FIRST_CHUNK, "a fmt chunk payload landed inside the RIFF header")
	assert(length >= 0, "a chunk cannot be a negative number of bytes long")

	if length < size_of(Wav_Fmt_Body) {
		return {}, .Short_Fmt_Chunk
	}
	if payload + size_of(Wav_Fmt_Body) > len(head) {
		return {}, .Head_Too_Short
	}

	body: Wav_Fmt_Body
	mem.copy(&body, raw_data(head[payload:]), size_of(Wav_Fmt_Body))
	if u16(body.format) != WAVE_FORMAT_PCM {
		return {}, .Not_Pcm
	}
	if body.channels == 0 || body.samples_per_second == 0 || body.bytes_per_second == 0 {
		return {}, .Nonsense_Format
	}
	return Wav_Facts {
			channels = int(body.channels),
			samples_per_second = int(body.samples_per_second),
			bytes_per_second = int(body.bytes_per_second),
			bits_per_sample = int(body.bits_per_sample),
		},
		.None
}

// How long the audio in a WAV is, in milliseconds.
//
// From the `data` chunk's own length and the format's byte rate, which is the
// only place the answer lives: the spec is explicit that duration never comes
// from a scratch audio file's header, and this is why -- the header does not
// carry one.
audio_ms :: proc(facts: Wav_Facts) -> i64 {
	// The read side of read_fmt's refusal (A4), and the reason it is a refusal
	// there rather than a division by zero here.
	assert(facts.bytes_per_second > 0, "audio with no byte rate has no length to work out")
	assert(facts.data_bytes >= 0, "audio cannot hold a negative number of bytes")

	return facts.data_bytes * 1000 / i64(facts.bytes_per_second)
}
