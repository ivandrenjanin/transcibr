package audio

import "core:slice"
import "transcibr:process"

// The chunks are walked because a WAV header is not a fixed 44 bytes: ffmpeg's
// muxer writes a `LIST`/`INFO` chunk before `data`, so the payload begins at a
// per-file offset. See ADR-0022.

Riff_Chunk_Header :: struct #packed {
	id:    [4]u8,
	bytes: u32le,
}

#assert(size_of(Riff_Chunk_Header) == 8)

// The PCM length only: a `fmt ` chunk may be longer -- 18 bytes for the
// extensible header's `cbSize`, 40 for `WAVE_FORMAT_EXTENSIBLE` -- so the length
// is read from the chunk and only the first sixteen bytes are decoded.
Wav_Fmt_Body :: struct #packed {
	format:             u16le,
	channels:           u16le,
	samples_per_second: u32le,
	bytes_per_second:   u32le,
	block_align:        u16le,
	bits_per_sample:    u16le,
}

#assert(size_of(Wav_Fmt_Body) == 16)

@(private)
WAVE_FORMAT_PCM :: 1

// `RIFF`, its length, and the four-byte form type.
@(private)
FIRST_CHUNK :: 12

Riff_Fault :: enum u8 {
	None = 0,
	Not_Riff,
	Not_Wave,
	Truncated,
	Head_Too_Short,
	No_Fmt_Chunk,
	Short_Fmt_Chunk,
	Not_Pcm,
	No_Data_Chunk,
	Empty_Data_Chunk,
	Nonsense_Format,
}

// `data_offset` has one consumer and it is riff_test.odin's pin. It is the only
// field that moves when the fixture's chunk table does, so it is not dead.
Wav_Facts :: struct {
	channels:           int,
	samples_per_second: int,
	bytes_per_second:   int,
	bits_per_sample:    int,
	data_offset:        int,
	data_bytes:         i64,
}

// `head` is the front of the file and need not be all of it, which is what lets
// a caller read a few kilobytes off a huge file and still check its lengths
// against `file_bytes`.
read_wav_facts :: proc(head: []u8, file_bytes: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	assert(file_bytes >= 0, "a file cannot hold a negative number of bytes")
	assert(i64(len(head)) <= file_bytes, "more head was read than the file was said to hold")

	if len(head) < FIRST_CHUNK {
		return {}, .Head_Too_Short
	}
	container, present := chunk_at(head, 0)
	assert(present, "twelve bytes of head did not hold an eight-byte chunk header")
	if string(container.id[:]) != "RIFF" {
		return {}, .Not_Riff
	}
	if i64(u32(container.bytes)) + size_of(Riff_Chunk_Header) > file_bytes {
		return {}, .Truncated
	}
	if string(head[8:FIRST_CHUNK]) != "WAVE" {
		return {}, .Not_Wave
	}
	return walk_chunks(head, file_bytes)
}

@(private)
walk_chunks :: proc(head: []u8, file_bytes: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	found_format := false
	at := FIRST_CHUNK
	for {
		header, present := chunk_at(head, at)
		if !present {
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
			if !found_format {
				facts, fault = read_fmt(head, payload, length)
				if fault != .None {
					return {}, fault
				}
				found_format = true
			}
		case "data":
			if !found_format {
				return {}, .No_Fmt_Chunk
			}
			if length == 0 {
				return {}, .Empty_Data_Chunk
			}
			assert(payload >= FIRST_CHUNK, "a chunk payload landed inside the RIFF header")
			facts.data_offset = payload
			facts.data_bytes = length
			return facts, .None
		}
		at = payload + int(length) + int(length & 1)
	}

	if !found_format {
		return {}, .No_Fmt_Chunk
	}
	return {}, .No_Data_Chunk
}

@(private)
chunk_at :: proc(head: []u8, at: int) -> (header: Riff_Chunk_Header, present: bool) {
	assert(at >= 0, "a chunk cannot sit at a negative offset")

	if at > len(head) {
		return {}, false
	}
	return slice.to_type(head[at:], Riff_Chunk_Header)
}

@(private)
read_fmt :: proc(head: []u8, payload: int, length: i64) -> (facts: Wav_Facts, fault: Riff_Fault) {
	assert(payload >= FIRST_CHUNK, "a fmt chunk payload landed inside the RIFF header")
	assert(length >= 0, "a chunk cannot be a negative number of bytes long")

	assert(payload <= len(head), "a chunk payload that starts past the head was walked to")

	if length < size_of(Wav_Fmt_Body) {
		return {}, .Short_Fmt_Chunk
	}
	body, whole := slice.to_type(head[payload:], Wav_Fmt_Body)
	if !whole {
		return {}, .Head_Too_Short
	}
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

as_asked_for :: proc(facts: Wav_Facts) -> bool {
	assert(facts.channels > 0, "audio with no channels never came out of the walk")
	assert(facts.samples_per_second > 0, "audio with no sample rate never came out of the walk")

	if facts.channels != process.AUDIO_CHANNELS {
		return false
	}
	if facts.samples_per_second != process.AUDIO_SAMPLE_RATE {
		return false
	}
	return facts.bits_per_sample == process.AUDIO_BITS_PER_SAMPLE
}

audio_ms :: proc(facts: Wav_Facts) -> i64 {
	assert(facts.bytes_per_second > 0, "audio with no byte rate has no length to work out")
	assert(facts.data_bytes >= 0, "audio cannot hold a negative number of bytes")

	return facts.data_bytes * 1000 / i64(facts.bytes_per_second)
}
