package version

import "core:testing"

@(test)
banner_names_the_program_and_its_version :: proc(t: ^testing.T) {
	line := banner("transcibr-cli", Version{major = 1, minor = 2, patch = 3}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, line, "transcibr-cli 1.2.3")
}
