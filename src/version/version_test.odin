package version

import "core:strings"
import "core:testing"

@(test)
banner_names_the_program_and_its_version :: proc(t: ^testing.T) {
	line := banner("transcibr-cli", Version{major = 1, minor = 2, patch = 3}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, line, "transcibr-cli 1.2.3")
}

// The shape anything reading a binary's output depends on: the program name,
// one space, then the version and nothing else. main asserts the same three
// facts on the way out of `banner` (CLAUDE.md rule A4).
@(test)
banner_separates_the_program_name_from_the_version :: proc(t: ^testing.T) {
	program := "transcibr-cli"
	line := banner(program, Version{major = 10, minor = 20, patch = 30}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect(t, strings.has_prefix(line, program), "line must start with the program name")
	testing.expect_value(t, line[len(program)], u8(' '))
	testing.expect_value(t, line[len(program) + 1:], "10.20.30")
}

@(test)
banner_renders_one_line :: proc(t: ^testing.T) {
	line := banner("transcibr-cli", CURRENT, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, strings.index_byte(line, '\n'), -1)
	testing.expect_value(t, strings.index_byte(line, '\r'), -1)
}
