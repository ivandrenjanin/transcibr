package version

import "core:testing"

@(test)
banner_names_the_program_and_its_version :: proc(t: ^testing.T) {
	line := banner("transcibr-cli", Version{major = 1, minor = 2, patch = 3}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, line, "transcibr-cli 1.2.3")
}

// Multi-digit components, the one thing exact equality on 1.2.3 does not settle:
// a renderer that truncated a component, or padded it to a fixed width, agrees
// with 1.2.3 and disagrees here.
@(test)
banner_renders_multi_digit_components :: proc(t: ^testing.T) {
	line := banner("transcibr-cli", Version{major = 10, minor = 20, patch = 30}, context.allocator)
	defer delete(line, context.allocator)
	testing.expect_value(t, line, "transcibr-cli 10.20.30")
}
