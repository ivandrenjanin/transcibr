#+vet explicit-allocators
package transcript

import "core:fmt"
import "core:strings"
import "core:testing"

@(private)
hand_escaped_byte :: proc(b: u8, out: ^strings.Builder) {
	assert(out != nil, "there is nowhere here to write an escaped byte")

	switch b {
	case '\\':
		strings.write_string(out, `\\`)
	case '"':
		strings.write_string(out, `\"`)
	case '\n':
		strings.write_string(out, `\n`)
	case '\r':
		strings.write_string(out, `\r`)
	case '\t':
		strings.write_string(out, `\t`)
	case:
		if b < 0x20 || b == 0x7F {
			fmt.sbprintf(out, `\x%02x`, b)
		} else {
			strings.write_byte(out, b)
		}
	}
}

@(test)
every_byte_from_0x00_to_0xff_writes_by_the_pinned_escape_table :: proc(t: ^testing.T) {
	value := make([]u8, 256, context.allocator)
	defer delete(value, context.allocator)
	for i in 0 ..< 256 {
		value[i] = u8(i)
	}

	want := strings.builder_make(0, 1_024, context.allocator)
	defer strings.builder_destroy(&want)
	strings.write_byte(&want, '"')
	for b in value {
		hand_escaped_byte(b, &want)
	}
	strings.write_byte(&want, '"')

	got := strings.builder_make(0, 1_024, context.allocator)
	defer strings.builder_destroy(&got)
	write_quoted_scalar(&got, string(value))

	testing.expect_value(t, strings.to_string(got), strings.to_string(want))
}

@(test)
the_named_escapes_take_priority_over_the_hex_escape :: proc(t: ^testing.T) {
	Case :: struct {
		byte:   u8,
		writes: string,
	}
	cases := []Case {
		{'\\', `\\`},
		{'"', `\"`},
		{'\n', `\n`},
		{'\r', `\r`},
		{'\t', `\t`},
		{0x00, `\x00`},
		{0x1F, `\x1f`},
		{0x7F, `\x7f`},
	}
	for c in cases {
		out := strings.builder_make(0, 8, context.allocator)
		defer strings.builder_destroy(&out)
		one := []u8{c.byte}
		write_quoted_scalar(&out, string(one))

		want := strings.builder_make(0, 8, context.allocator)
		defer strings.builder_destroy(&want)
		strings.write_byte(&want, '"')
		strings.write_string(&want, c.writes)
		strings.write_byte(&want, '"')

		testing.expectf(
			t,
			strings.to_string(out) == strings.to_string(want),
			"0x%02x wrote %q, want %q",
			c.byte,
			strings.to_string(out),
			strings.to_string(want),
		)
	}
}
